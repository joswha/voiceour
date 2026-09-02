#include "parakeet.h"
#include "parakeet-arch.h"

#include "ggml.h"
#include "ggml-cpp.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"

#include <atomic>
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cfloat>
#define _USE_MATH_DEFINES
#include <cmath>
#include <climits>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <cctype>
#include <limits>
#include <map>
#include <random>
#include <set>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#ifndef _WIN32
#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#ifdef _MSC_VER
#include <codecvt>
#endif

#if defined(PARAKEET_BIG_ENDIAN)
template<typename T>
static T byteswap(T value) {
    T value_swapped;
    char * source = reinterpret_cast<char *>(&value);
    char * target = reinterpret_cast<char *>(&value_swapped);
    int size = sizeof(T);
    for (int i = 0; i < size; i++) {
        target[size - 1 - i] = source[i];
    }
    return value_swapped;
}

template<typename T>
static void byteswap_tensor_data(ggml_tensor * tensor) {
    T * datum = reinterpret_cast<T *>(tensor->data);
    for (int i = 0; i < ggml_nelements(tensor); i++) {
        datum[i] = byteswap(datum[i]);
    }
}

static void byteswap_tensor(ggml_tensor * tensor) {
    switch (tensor->type) {
        case GGML_TYPE_I16: {
            byteswap_tensor_data<int16_t>(tensor);
            break;
        }
        case GGML_TYPE_F16: {
            byteswap_tensor_data<ggml_fp16_t>(tensor);
            break;
        }
        case GGML_TYPE_I32: {
            byteswap_tensor_data<int32_t>(tensor);
            break;
        }
        case GGML_TYPE_F32: {
            byteswap_tensor_data<float>(tensor);
            break;
        }
        default: { // GML_TYPE_I8
            break;
        }
    }
}

#define BYTESWAP_VALUE(d) d = byteswap(d)
#define BYTESWAP_FILTERS(f)           \
    do {                              \
        for (auto & datum : f.data) { \
            datum = byteswap(datum);  \
        }                             \
    } while (0)
#define BYTESWAP_TENSOR(t)  \
    do {                    \
        byteswap_tensor(t); \
    } while (0)
#else
#define BYTESWAP_VALUE(d) do {} while (0)
#define BYTESWAP_FILTERS(f) do {} while (0)
#define BYTESWAP_TENSOR(t) do {} while (0)
#endif

#ifdef __GNUC__
#ifdef __MINGW32__
#define PARAKEET_ATTRIBUTE_FORMAT(...) __attribute__((format(gnu_printf, __VA_ARGS__)))
#else
#define PARAKEET_ATTRIBUTE_FORMAT(...) __attribute__((format(printf, __VA_ARGS__)))
#endif
#else
#define PARAKEET_ATTRIBUTE_FORMAT(...)
#endif

//
// logging
//

PARAKEET_ATTRIBUTE_FORMAT(2, 3)
static void parakeet_log_internal        (ggml_log_level level, const char * format, ...);
static void parakeet_log_callback_default(ggml_log_level level, const char * text, void * user_data);

#define PARAKEET_LOG_ERROR(...) parakeet_log_internal(GGML_LOG_LEVEL_ERROR, __VA_ARGS__)
#define PARAKEET_LOG_WARN(...)  parakeet_log_internal(GGML_LOG_LEVEL_WARN , __VA_ARGS__)
#define PARAKEET_LOG_INFO(...)  parakeet_log_internal(GGML_LOG_LEVEL_INFO , __VA_ARGS__)

// define this to enable verbose trace logging - useful for debugging purposes
//#define PARAKEET_DEBUG

#if defined(PARAKEET_DEBUG)
#define PARAKEET_LOG_DEBUG(...) parakeet_log_internal(GGML_LOG_LEVEL_DEBUG, __VA_ARGS__)
#else
#define PARAKEET_LOG_DEBUG(...)
#endif

#define PARAKEET_ASSERT(x) \
    do { \
        if (!(x)) { \
            PARAKEET_LOG_ERROR("PARAKEET_ASSERT: %s:%d: %s\n", __FILE__, __LINE__, #x); \
            abort(); \
        } \
    } while (0)

#define PARAKEET_MAX_NODES 8192

// Threshold for when local attention should be used.
// 8192 frames x 80ms = 655 s (about 10.9 mins)
static constexpr int PARAKEET_LOCAL_ATTN_THRESHOLD = 8192;
// Window of context in each director of the current token.
// 128 frames * 80ms = 10.24 s
static constexpr int PARAKEET_LOCAL_ATTN_WINDOW    = 128;
// VOICEOUR PATCH: cache-aware streaming checkpoints train with
// `att_context_style: chunked_limited` and `att_context_size: [70, 13]`, so a
// query sees its whole `right + 1` frame chunk plus `left / (right + 1)`
// preceding chunks — not a per-frame `[q - left, q + right]` band. The two
// agree only on the last query of each chunk, so the band form perturbs every
// attention layer. Only the speaker-kernel files take this path.
static constexpr int PARAKEET_MULTITALKER_ATT_LEFT  = 70;
static constexpr int PARAKEET_MULTITALKER_ATT_RIGHT = 13;

static std::string format(const char * fmt, ...) {
    va_list ap;
    va_list ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int size = vsnprintf(NULL, 0, fmt, ap);
    GGML_ASSERT(size >= 0 && size < INT_MAX); // NOLINT
    std::vector<char> buf(size + 1);
    int size2 = vsnprintf(buf.data(), size + 1, fmt, ap2);
    GGML_ASSERT(size2 == size);
    va_end(ap2);
    va_end(ap);
    return std::string(buf.data(), size);
}

//
// ggml helpers
//

// VOICEOUR PATCH: pauses the persistent CPU pool on every exit path of a full decode,
// returning its workers to condvar sleep between utterances. Kickoff resumes a paused
// pool on the next compute, so pausing here costs the next utterance nothing.
struct parakeet_cpu_pool_quiescer {
    struct ggml_threadpool * pool;
    ~parakeet_cpu_pool_quiescer() { if (pool) { ggml_threadpool_pause(pool); } }
};

static bool ggml_graph_compute_helper(
          struct ggml_cgraph * graph,
                         int   n_threads,
         ggml_abort_callback   abort_callback,
                        void * abort_callback_data) {
    ggml_backend_ptr backend { ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr) };

    auto * reg = ggml_backend_dev_backend_reg(ggml_backend_get_device(backend.get()));

    auto * set_abort_callback_fn = (ggml_backend_set_abort_callback_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_abort_callback");
    if (set_abort_callback_fn) {
        set_abort_callback_fn(backend.get(), abort_callback, abort_callback_data);
    }

    auto ggml_backend_set_n_threads_fn = (ggml_backend_set_n_threads_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_n_threads");
    if (ggml_backend_set_n_threads_fn) {
        ggml_backend_set_n_threads_fn(backend.get(), n_threads);
    }

    return ggml_backend_graph_compute(backend.get(), graph) == GGML_STATUS_SUCCESS;
}

static bool ggml_graph_compute_helper(
      ggml_backend_sched_t   sched,
        struct ggml_cgraph * graph,
                       int   n_threads,
                      bool   sched_reset = true) {
    for (int i = 0; i < ggml_backend_sched_get_n_backends(sched); ++i) {
        ggml_backend_t backend = ggml_backend_sched_get_backend(sched, i);
        ggml_backend_dev_t dev = ggml_backend_get_device(backend);
        ggml_backend_reg_t reg = dev ? ggml_backend_dev_backend_reg(dev) : nullptr;

        auto * fn_set_n_threads = (ggml_backend_set_n_threads_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_n_threads");
        if (fn_set_n_threads) {
            fn_set_n_threads(backend, n_threads);
        }
    }

    const bool t = (ggml_backend_sched_graph_compute(sched, graph) == GGML_STATUS_SUCCESS);

    if (!t || sched_reset) {
        ggml_backend_sched_reset(sched);
    }

    return t;
}

// TODO: move these functions to ggml-base with support for ggml-backend?


struct parakeet_mel {
    int n_len     = 0;
    int n_len_org = 0;
    int n_mel     = 0;

    std::vector<float> data;
};

struct parakeet_filters {
    int32_t n_mel = 0;
    int32_t n_fb  = 0;  // number of frequency bins

    std::vector<float> data;
};

struct parakeet_vocab {
    using id    = int32_t;
    using token = std::string;

    int n_vocab = 8192;
    size_t max_token_length = 0;

    std::map<token, id> token_to_id;
    std::map<id, token> id_to_token;

    id token_unk;
    id token_bos;
    id token_blank;
    id token_eos;
};

struct parakeet_segment {
    int64_t t0;
    int64_t t1;

    std::string text;

    std::vector<parakeet_token_data> tokens;
};

struct parakeet_batch {
    int32_t n_tokens;

    parakeet_token  *  token;
    int32_t         *  i_time;   // index of the audio frame
    parakeet_pos    *  pos;
    int32_t         *  n_seq_id; // always 1, here for consistency with llama.cpp
    parakeet_seq_id ** seq_id;   // null terminated
    int8_t          *  logits;
};

// ggml_backend_sched wrapper for parakeet usage
struct parakeet_sched {
    ggml_backend_sched_t sched = nullptr;

    std::vector<uint8_t> meta;
};

// TODO: Find out is there a multiple version types. It is not yet clear to me
// at this point.
enum parakeet_arch {
    PARAKEET_ARCH_UNKNOWN = 0,
    PARAKEET_ARCH_TDT     = 1,  // NVIDIA Parakeet TDT (RNN-T)
};

struct parakeet_hparams {
    int32_t n_vocab                = 8192;
    int32_t n_audio_ctx            = 0;  // 0 = unlimited, will be set based on input
    int32_t n_audio_state          = 1024;
    int32_t n_audio_head           = 8;
    int32_t n_audio_layer          = 24;
    int32_t n_mels                 = 128;
    int32_t ftype                  = 1;
    int32_t n_fft                  = 512;  // FFT size for mel spectrogram
    float   eps                    = 1e-5f;
    int32_t subsampling_factor     = 8;
    int32_t n_subsampling_channels = 256;
    int32_t n_conv_kernel          = 9;
    int32_t n_pred_dim             = 640;
    int32_t n_pred_layers          = 2;
    int32_t n_tdt_durations        = 5;
    int32_t n_max_tokens           = 10;

    parakeet_arch arch     = PARAKEET_ARCH_TDT;
};

struct parakeet_layer_encoder {
    struct ggml_tensor * norm_ff1_w = nullptr;
    struct ggml_tensor * norm_ff1_b = nullptr;

    struct ggml_tensor * ff1_linear1_w = nullptr;
    struct ggml_tensor * ff1_linear2_w = nullptr;

    // VOICEOUR PATCH: optional per-layer biases for the bias-variant Conformer
    // checkpoints (parakeet-tdt-1.1b). All nullptr for the pinned bias-free files;
    // the loader enforces all-or-none per file.
    struct ggml_tensor * ff1_linear1_b = nullptr;
    struct ggml_tensor * ff1_linear2_b = nullptr;
    struct ggml_tensor * ff2_linear1_b = nullptr;
    struct ggml_tensor * ff2_linear2_b = nullptr;
    struct ggml_tensor * attn_q_b      = nullptr;
    struct ggml_tensor * attn_k_b      = nullptr;
    struct ggml_tensor * attn_v_b      = nullptr;
    struct ggml_tensor * attn_out_b    = nullptr;
    struct ggml_tensor * conv_pw1_b    = nullptr;
    struct ggml_tensor * conv_dw_b     = nullptr;
    struct ggml_tensor * conv_pw2_b    = nullptr;

    struct ggml_tensor * norm_conv_w = nullptr;
    struct ggml_tensor * norm_conv_b = nullptr;

    struct ggml_tensor * conv_pw1_w          = nullptr;  // pointwise_conv1
    struct ggml_tensor * conv_dw_w           = nullptr;  // depthwise_conv
    struct ggml_tensor * conv_bn_w           = nullptr;  // batch_norm weight
    struct ggml_tensor * conv_bn_b           = nullptr;  // batch_norm bias
    struct ggml_tensor * conv_bn_mean        = nullptr;  // batch_norm running_mean
    struct ggml_tensor * conv_bn_var         = nullptr;  // batch_norm running_var
    struct ggml_tensor * conv_bn_num_batches = nullptr;  // batch_norm num_batches_tracked
    struct ggml_tensor * conv_pw2_w          = nullptr;  // pointwise_conv2

    struct ggml_tensor * norm_attn_w = nullptr;
    struct ggml_tensor * norm_attn_b = nullptr;

    struct ggml_tensor * attn_pos_bias_u = nullptr;
    struct ggml_tensor * attn_pos_bias_v = nullptr;
    struct ggml_tensor * attn_q_w        = nullptr;
    struct ggml_tensor * attn_k_w        = nullptr;
    struct ggml_tensor * attn_v_w        = nullptr;
    struct ggml_tensor * attn_out_w      = nullptr;
    struct ggml_tensor * attn_pos_w      = nullptr;

    struct ggml_tensor * norm_ff2_w      = nullptr;
    struct ggml_tensor * norm_ff2_b      = nullptr;

    struct ggml_tensor * ff2_linear1_w = nullptr;
    struct ggml_tensor * ff2_linear2_w = nullptr;

    struct ggml_tensor * norm_out_w = nullptr;
    struct ggml_tensor * norm_out_b = nullptr;
};

struct parakeet_lsmt_layer {
    struct ggml_tensor * ih_w = nullptr;  // input-to-hidden weight
    struct ggml_tensor * hh_w = nullptr;  // hidden-to-hidden weight
    struct ggml_tensor * b_h = nullptr;   // bias (ih folded into hh at conversion time)
};

struct parakeet_prediction_network {
    struct ggml_tensor * embed_w = nullptr;

    std::vector<parakeet_lsmt_layer> lstm_layer;
};

struct parakeet_joint_network {
    struct ggml_tensor * pred_w = nullptr;
    struct ggml_tensor * pred_b = nullptr;
    struct ggml_tensor * enc_w  = nullptr;
    struct ggml_tensor * enc_b  = nullptr;
    struct ggml_tensor * net_w  = nullptr;
    struct ggml_tensor * net_b  = nullptr;
};

struct parakeet_model {
    parakeet_filters filters;
    parakeet_hparams hparams;

    struct ggml_tensor * enc_pre_out_w    = nullptr;
    struct ggml_tensor * enc_pre_out_b    = nullptr;
    struct ggml_tensor * enc_pre_conv_0_w = nullptr;
    struct ggml_tensor * enc_pre_conv_0_b = nullptr;
    struct ggml_tensor * enc_pre_conv_2_w = nullptr;
    struct ggml_tensor * enc_pre_conv_2_b = nullptr;
    struct ggml_tensor * enc_pre_conv_3_w = nullptr;
    struct ggml_tensor * enc_pre_conv_3_b = nullptr;
    struct ggml_tensor * enc_pre_conv_5_w = nullptr;
    struct ggml_tensor * enc_pre_conv_5_b = nullptr;
    struct ggml_tensor * enc_pre_conv_6_w = nullptr;
    struct ggml_tensor * enc_pre_conv_6_b = nullptr;

    std::vector<parakeet_layer_encoder> layers;

    parakeet_prediction_network prediction;

    parakeet_joint_network joint;

    // VOICEOUR PATCH: optional multitalker single-speaker residual FF kernel.
    struct ggml_tensor * spk_ff1_w = nullptr;
    struct ggml_tensor * spk_ff1_b = nullptr;
    struct ggml_tensor * spk_ff2_w = nullptr;
    struct ggml_tensor * spk_ff2_b = nullptr;
    struct ggml_tensor * bg_spk_ff1_w = nullptr;
    struct ggml_tensor * bg_spk_ff1_b = nullptr;
    struct ggml_tensor * bg_spk_ff2_w = nullptr;
    struct ggml_tensor * bg_spk_ff2_b = nullptr;

    std::vector<uint32_t> tdt_durations;

    std::vector<ggml_context *> ctxs;

    std::vector<ggml_backend_buffer_t> buffers;

    // VOICEOUR PATCH: the backend wrappers in `buffers` refer into this mapped arena.
    // They must be freed before the mapping and descriptor are released.
    void * weight_arena_addr = nullptr;
    size_t weight_arena_size = 0;
    int weight_arena_fd = -1;

    int n_loaded = 0;
    std::map<std::string, struct ggml_tensor *> tensors;
};

struct parakeet_lstm_state_layer {
    struct ggml_tensor * h_state = nullptr;
    struct ggml_tensor * c_state = nullptr;
};

struct parakeet_lstm_state {
    std::vector<parakeet_lstm_state_layer> layer;

    std::vector<uint8_t> ctx_buf;

    ggml_backend_buffer_t buffer = nullptr;
};

struct parakeet_state {
    int64_t t_sample_us = 0;
    int64_t t_encode_us = 0;
    int64_t t_decode_us = 0;
    int64_t t_predict_us = 0;
    int64_t t_predict_build_us   = 0; // time spent building the prediction graph
    int64_t t_predict_alloc_us   = 0; // time spent in ggml_backend_sched_alloc_graph
    int64_t t_predict_compute_us = 0; // time spent in ggml_graph_compute_helper
    int64_t t_mel_us = 0;

    int32_t n_sample = 0; // number of tokens sampled
    int32_t n_encode = 0; // number of encoder calls
    int32_t n_decode = 0; // number of decoder calls with n_tokens == 1  (text-generation)
    int32_t n_predict = 0; // number of prediction network calls
    int32_t n_fail_p = 0; // number of logprob threshold failures
    int32_t n_fail_h = 0; // number of entropy threshold failures

    parakeet_mel mel;

    parakeet_batch batch;

    int n_frames = 0;

    std::vector<ggml_backend_t> backends;

    // VOICEOUR PATCH: persistent decode inputs live with the CPU tail when it is selected.
    ggml_backend_t backend_decode_state = nullptr;
    // VOICEOUR PATCH: opt-in persistent CPU threadpool; nullptr keeps disposable pools.
    struct ggml_threadpool * cpu_pool = nullptr;

    parakeet_sched sched_encode;
    parakeet_sched sched_decode;

    // outputs from encoder stages
    struct ggml_tensor * enc_out     = nullptr;
    struct ggml_tensor * pred_out    = nullptr;

    std::vector<uint8_t> enc_out_buf;
    ggml_backend_buffer_t enc_out_buffer = nullptr;

    std::vector<uint8_t> pred_out_buf;
    ggml_backend_buffer_t pred_out_buffer = nullptr;

    struct ggml_tensor * attn_mask = nullptr;

    std::vector<float> inp_mel;
    std::vector<float> inp_mask;

    std::vector<float> logits;

    // VOICEOUR PATCH: populated only while the optional decode-step observer is installed.
    std::vector<float> token_logits_raw;

    // VOICEOUR PATCH (upstream ggml-org/whisper.cpp#3932): raw, pre-log-softmax duration
    // slots for the current joint step. `logits` above holds log-softmax output, whose
    // duration slots underflow to -inf whenever the winning vocab logit leads by more than
    // ~87, and an argmax over -inf values silently returns duration 0.
    std::vector<float> duration_logits_raw;

    std::vector<parakeet_segment> result_all;

    std::vector<parakeet_token>      decoded_tokens;
    std::vector<parakeet_token_data> decoded_token_data;

    std::string path_model;

    int32_t n_audio_ctx = 0;
    int32_t sched_encode_n_audio_ctx = 0;

    parakeet_lstm_state lstm_state;
};

// FFT cache for mel spectrogram computation
struct parakeet_mel_cache {
    int n_fft = 0;

    // In FFT, we frequently use sine and cosine operations with the same values.
    // We can use precalculated values to speed up the process.
    std::vector<float> sin_vals;
    std::vector<float> cos_vals;

    // Hann window (Use cosf to eliminate difference)
    // ref: https://pytorch.org/docs/stable/generated/torch.hann_window.html
    // ref: https://github.com/openai/whisper/blob/main/whisper/audio.py#L147
    std::vector<float> hann_window;

    // Window function from model (Parakeet uses actual window from training)
    std::vector<float> window;

    void init(int fft_size) {
        n_fft = fft_size;
        sin_vals.resize(n_fft);
        cos_vals.resize(n_fft);
        hann_window.resize(n_fft);

        fill_sin_cos_table();
        fill_hann_window(n_fft, true, hann_window.data());
    }

    void fill_sin_cos_table() {
        for (int i = 0; i < n_fft; i++) {
            double theta = (2 * M_PI * i) / n_fft;
            sin_vals[i] = sinf(theta);
            cos_vals[i] = cosf(theta);
        }
    }

    void fill_hann_window(int length, bool periodic, float * output) {
        int offset = -1;
        if (periodic) {
            offset = 0;
        }
        for (int i = 0; i < length; i++) {
            output[i] = 0.5 * (1.0 - cosf((2.0 * M_PI * i) / (length + offset)));
        }
    }
};

struct parakeet_context {
    int64_t t_load_us  = 0;
    int64_t t_start_us = 0;

    ggml_type wtype = ggml_type::GGML_TYPE_F16;
    ggml_type itype = ggml_type::GGML_TYPE_F16;

    parakeet_context_params params;

    parakeet_model model;
    parakeet_vocab vocab;

    parakeet_state * state = nullptr;

    parakeet_mel_cache mel_cache;

    std::string path_model;
};

struct parakeet_global {
    // We save the log callback globally
    ggml_log_callback log_callback = parakeet_log_callback_default;
    void * log_callback_user_data = nullptr;
};

static parakeet_global g_state;

static const std::string PARAKEET_SPM_SPACE = "\xE2\x96\x81";

static inline int utf8_codepoint_len(unsigned char c) {
    if ((c & 0x80) == 0x00) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;
}

static bool is_sentencepiece_control(const std::string & piece) {
    return piece == "<unk>" || piece == "<s>" || piece == "</s>" || piece == "[BLANK]";
}

static std::string sentencepiece_normalize(const std::string & text) {
    std::string normalized;
    normalized.reserve(text.size() + PARAKEET_SPM_SPACE.size());
    normalized += PARAKEET_SPM_SPACE; // SentencePiece dummy prefix

    for (unsigned char c : text) {
        if (std::isspace(c)) {
            normalized += PARAKEET_SPM_SPACE;
        } else {
            normalized += static_cast<char>(c);
        }
    }

    return normalized;
}

static std::string sentencepiece_piece_to_text(const std::string & piece, bool is_first_piece) {
    if (is_sentencepiece_control(piece)) {
        return "";
    }

    std::string text;
    text.reserve(piece.size());

    size_t pos = 0;
    while (pos < piece.size()) {
        if (piece.compare(pos, PARAKEET_SPM_SPACE.size(), PARAKEET_SPM_SPACE) == 0) {
            if (!is_first_piece || !text.empty()) {
                text += ' ';
            }
            pos += PARAKEET_SPM_SPACE.size();
            continue;
        }

        text += piece[pos];
        ++pos;
    }

    return text;
}


static struct parakeet_batch parakeet_batch_init(int32_t n_tokens) {
    parakeet_batch batch = { 0, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, };

    batch.token    = (parakeet_token *  ) malloc(sizeof(parakeet_token)    * (n_tokens));
    batch.i_time   = (int32_t *)          malloc(sizeof(int32_t)           * (n_tokens));
    batch.pos      = (parakeet_pos *)     malloc(sizeof(parakeet_pos)      * (n_tokens));
    batch.n_seq_id = (int32_t *)          malloc(sizeof(int32_t)           * (n_tokens));
    batch.seq_id   = (parakeet_seq_id **) malloc(sizeof(parakeet_seq_id *) * (n_tokens + 1));
    for (int i = 0; i < n_tokens; ++i) {
        batch.seq_id[i] = (parakeet_seq_id *) malloc(sizeof(parakeet_seq_id));
    }
    batch.seq_id[n_tokens] = nullptr;
    batch.logits   = (int8_t *)          malloc(sizeof(int8_t)           * n_tokens);

    return batch;
}

static void parakeet_batch_free(struct parakeet_batch batch) {
    if (batch.token)    free(batch.token);
    if (batch.i_time)   free(batch.i_time);
    if (batch.pos)      free(batch.pos);
    if (batch.n_seq_id) free(batch.n_seq_id);
    if (batch.seq_id) {
        for (int i = 0; batch.seq_id[i]; ++i) {
            free(batch.seq_id[i]);
        }
        free(batch.seq_id);
    }
    if (batch.logits)   free(batch.logits);
}

static void parakeet_batch_prep_legacy(parakeet_batch & batch, const parakeet_token * tokens, int n_tokens, int n_past, int seq_id) {
    batch.n_tokens = n_tokens;
    for (int i = 0; i < n_tokens; ++i) {
        if (tokens) {
            batch.token[i] = tokens[i];
        }
        batch.pos     [i]    = n_past + i;
        batch.n_seq_id[i]    = 1;
        batch.seq_id  [i][0] = seq_id;
        batch.logits  [i]    = 0;
    }
    batch.logits[n_tokens - 1] = 1;
}


static size_t parakeet_sched_size(struct parakeet_sched & allocr) {
    size_t size = allocr.meta.size();
    for (int i = 0; i < ggml_backend_sched_get_n_backends(allocr.sched); ++i) {
        ggml_backend_t backend = ggml_backend_sched_get_backend(allocr.sched, i);
        size += ggml_backend_sched_get_buffer_size(allocr.sched, backend);
    }
    return size;
}

static bool parakeet_sched_graph_init(struct parakeet_sched & allocr, std::vector<ggml_backend_t> backends, std::function<struct ggml_cgraph *()> && get_graph) {
    auto & sched = allocr.sched;
    auto & meta  = allocr.meta;

    sched = ggml_backend_sched_new(backends.data(), nullptr, backends.size(), PARAKEET_MAX_NODES, false, true);

    if (!sched) {
        PARAKEET_LOG_ERROR("%s: failed to create scheduler\n", __func__);
        return false;
    }

    meta.resize(ggml_tensor_overhead()*PARAKEET_MAX_NODES + ggml_graph_overhead());

    if (!ggml_backend_sched_alloc_graph(sched, get_graph())) {
        PARAKEET_LOG_ERROR("%s: failed to allocate the compute buffer\n", __func__);
        ggml_backend_sched_free(sched);
        sched = nullptr;
        return false;
    }

    ggml_backend_sched_reset(sched);

    return true;
}

static void parakeet_sched_free(struct parakeet_sched & sched) {
    if (sched.sched) {
        ggml_backend_sched_free(sched.sched);
        sched.sched = nullptr;
    }

    sched.meta.clear();
}


template<typename T>
static void read_safe(parakeet_model_loader * loader, T & dest) {
    loader->read(loader->context, &dest, sizeof(T));
    BYTESWAP_VALUE(dest);
}

// VOICEOUR PATCH: seekable built-in loaders make each validated tensor record authoritative
// for an explicit set of matrix weights. Keep parsing non-asserting: malformed model bytes must
// fail closed instead of reaching ggml's block-layout assertions.
using parakeet_tensor_name_set = std::set<std::string, std::less<>>;
using parakeet_tensor_record_index =
    std::map<std::string_view, size_t, std::less<>>;

struct parakeet_tensor_record {
    const std::string * name = nullptr;
    int32_t n_dims = 0;
    int32_t ne[4] = { 1, 1, 1, 1 };
    ggml_type type = GGML_TYPE_COUNT;
    int64_t payload_offset = -1;
    size_t payload_bytes = 0;
    size_t metadata_bytes = 0;
};

static bool parakeet_read_exact(
        parakeet_model_loader * loader,
        void * output,
        size_t size) {
    return size == 0 || loader->read(loader->context, output, size) == size;
}

template<typename T>
static bool parakeet_read_value(parakeet_model_loader * loader, T & value) {
    if (!parakeet_read_exact(loader, &value, sizeof(value))) {
        return false;
    }
    BYTESWAP_VALUE(value);
    return true;
}

static bool parakeet_tensor_record_type_layout(
        int32_t type_id,
        ggml_type & type,
        size_t & block_size,
        size_t & type_size) {
    switch (type_id) {
        case GGML_TYPE_F32:
        case GGML_TYPE_F16:
        case GGML_TYPE_Q8_0:
        case GGML_TYPE_Q4_K:
        case GGML_TYPE_Q6_K:
            type = static_cast<ggml_type>(type_id);
            break;
        default:
            return false;
    }

    const int64_t block_size_i64 = ggml_blck_size(type);
    if (block_size_i64 <= 0 ||
            static_cast<uint64_t>(block_size_i64) >
                static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
        return false;
    }
    block_size = static_cast<size_t>(block_size_i64);
    type_size = ggml_type_size(type);
    return type_size > 0;
}

static bool parakeet_checked_add(size_t lhs, size_t rhs, size_t & result);

static bool parakeet_checked_multiply(size_t lhs, size_t rhs, size_t & result) {
    if (lhs != 0 && rhs > std::numeric_limits<size_t>::max() / lhs) {
        return false;
    }
    result = lhs * rhs;
    return true;
}

static bool parakeet_is_valid_tensor_name(std::string_view name) {
    if (name.empty()) {
        return false;
    }

    for (size_t i = 0; i < name.size();) {
        const uint8_t first = static_cast<uint8_t>(name[i]);
        if (first == 0) {
            return false;
        }
        if (first < 0x80) {
            ++i;
            continue;
        }

        size_t continuation_count = 0;
        uint32_t codepoint = 0;
        uint32_t minimum = 0;
        if ((first & 0xe0) == 0xc0) {
            continuation_count = 1;
            codepoint = first & 0x1f;
            minimum = 0x80;
        } else if ((first & 0xf0) == 0xe0) {
            continuation_count = 2;
            codepoint = first & 0x0f;
            minimum = 0x800;
        } else if ((first & 0xf8) == 0xf0) {
            continuation_count = 3;
            codepoint = first & 0x07;
            minimum = 0x10000;
        } else {
            return false;
        }
        if (continuation_count > name.size() - i - 1) {
            return false;
        }
        for (size_t j = 1; j <= continuation_count; ++j) {
            const uint8_t next = static_cast<uint8_t>(name[i + j]);
            if ((next & 0xc0) != 0x80) {
                return false;
            }
            codepoint = (codepoint << 6) | (next & 0x3f);
        }
        if (codepoint < minimum ||
                codepoint > 0x10ffff ||
                (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
            return false;
        }
        i += continuation_count + 1;
    }
    return true;
}

static bool parakeet_tensor_record_payload_bytes(
        ggml_type type,
        const int32_t ne[4],
        size_t & payload_bytes) {
    ggml_type checked_type = GGML_TYPE_COUNT;
    size_t block_size = 0;
    size_t type_size = 0;
    if (!parakeet_tensor_record_type_layout(
            static_cast<int32_t>(type),
            checked_type,
            block_size,
            type_size) ||
            checked_type != type ||
            ne[0] <= 0 ||
            static_cast<size_t>(ne[0]) % block_size != 0) {
        return false;
    }

    payload_bytes = static_cast<size_t>(ne[0]) / block_size;
    if (!parakeet_checked_multiply(payload_bytes, type_size, payload_bytes)) {
        return false;
    }
    for (int i = 1; i < 4; ++i) {
        if (ne[i] <= 0 ||
                !parakeet_checked_multiply(
                    payload_bytes,
                    static_cast<size_t>(ne[i]),
                    payload_bytes)) {
            return false;
        }
    }
    return true;
}

static bool parakeet_tensor_has_audio_layer(parakeet_tensor tensor) {
    return
        tensor >= PARAKEET_TENSOR_ENC_NORM_FF1_WEIGHT &&
        tensor <= PARAKEET_TENSOR_ENC_NORM_OUT_BIAS;
}

static bool parakeet_tensor_has_prediction_layer(parakeet_tensor tensor) {
    return
        tensor >= PARAKEET_TENSOR_PRED_LSTM_WEIGHT_IH &&
        tensor <= PARAKEET_TENSOR_PRED_LSTM_BIAS_H;
}

static bool parakeet_expected_tensor_names(
        int32_t n_audio_layer,
        int32_t n_pred_layers,
        parakeet_tensor_name_set & names) {
    names.clear();
    for (const auto & entry : PARAKEET_TENSOR_NAMES) {
        const parakeet_tensor tensor = entry.first;
        const char * pattern = entry.second;
        const int32_t layer_count =
            parakeet_tensor_has_audio_layer(tensor) ? n_audio_layer :
            parakeet_tensor_has_prediction_layer(tensor) ? n_pred_layers :
            1;
        for (int32_t layer = 0; layer < layer_count; ++layer) {
            const std::string name =
                layer_count == 1 && !parakeet_tensor_has_audio_layer(tensor) &&
                        !parakeet_tensor_has_prediction_layer(tensor) ?
                    pattern :
                    format(pattern, layer);
            if (name.empty() ||
                    name.size() >= GGML_MAX_NAME ||
                    !names.emplace(name).second) {
                PARAKEET_LOG_ERROR(
                    "%s: invalid or duplicate architecture tensor name '%s'\n",
                    __func__,
                    name.c_str()
                );
                return false;
            }
        }
    }
    return true;
}

static bool parakeet_read_tensor_record(
        parakeet_model_loader * loader,
        int64_t file_size,
        const parakeet_tensor_name_set & expected_names,
        parakeet_tensor_record & record) {
    int32_t name_length = 0;
    int32_t type_id = 0;
    if (!parakeet_read_value(loader, record.n_dims) ||
            !parakeet_read_value(loader, name_length) ||
            !parakeet_read_value(loader, type_id)) {
        PARAKEET_LOG_ERROR("%s: truncated tensor header in model file\n", __func__);
        return false;
    }
    if (record.n_dims < 0 ||
            record.n_dims > 4 ||
            name_length <= 0 ||
            name_length >= GGML_MAX_NAME) {
        PARAKEET_LOG_ERROR("%s: invalid tensor header in model file\n", __func__);
        return false;
    }

    size_t dimensions_bytes = 0;
    if (!parakeet_checked_multiply(
            static_cast<size_t>(record.n_dims),
            sizeof(int32_t),
            dimensions_bytes) ||
            !parakeet_checked_add(
                3 * sizeof(int32_t),
                dimensions_bytes,
                record.metadata_bytes) ||
            !parakeet_checked_add(
                record.metadata_bytes,
                static_cast<size_t>(name_length),
                record.metadata_bytes)) {
        PARAKEET_LOG_ERROR("%s: tensor metadata byte count overflows\n", __func__);
        return false;
    }

    size_t block_size = 0;
    size_t type_size = 0;
    if (!parakeet_tensor_record_type_layout(
            type_id,
            record.type,
            block_size,
            type_size)) {
        PARAKEET_LOG_ERROR("%s: unsupported tensor type %d in model file\n", __func__, type_id);
        return false;
    }

    for (int i = 0; i < record.n_dims; ++i) {
        if (!parakeet_read_value(loader, record.ne[i])) {
            PARAKEET_LOG_ERROR("%s: truncated tensor dimensions in model file\n", __func__);
            return false;
        }
        if (record.ne[i] <= 0) {
            PARAKEET_LOG_ERROR("%s: invalid tensor dimensions in model file\n", __func__);
            return false;
        }
    }

    char name_bytes[GGML_MAX_NAME] = {};
    if (!parakeet_read_exact(
            loader,
            name_bytes,
            static_cast<size_t>(name_length))) {
        PARAKEET_LOG_ERROR("%s: truncated tensor name in model file\n", __func__);
        return false;
    }
    const std::string_view parsed_name(name_bytes, static_cast<size_t>(name_length));
    if (!parakeet_is_valid_tensor_name(parsed_name)) {
        PARAKEET_LOG_ERROR("%s: invalid tensor name in model file\n", __func__);
        return false;
    }
    const auto expected = expected_names.find(parsed_name);
    if (expected == expected_names.end()) {
        PARAKEET_LOG_ERROR(
            "%s: unknown tensor '%.*s' in model file\n",
            __func__,
            name_length,
            name_bytes
        );
        return false;
    }
    record.name = &*expected;

    record.payload_offset = loader->tell(loader->context);
    if (!parakeet_tensor_record_payload_bytes(record.type, record.ne, record.payload_bytes)) {
        PARAKEET_LOG_ERROR(
            "%s: tensor '%s' has an invalid block shape for type %d\n",
            __func__,
            record.name->c_str(),
            type_id
        );
        return false;
    }
    if (record.payload_offset < 0 ||
            record.payload_offset > file_size ||
            record.payload_bytes >
                static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
            static_cast<int64_t>(record.payload_bytes) >
                file_size - record.payload_offset) {
        PARAKEET_LOG_ERROR(
            "%s: tensor '%s' payload exceeds model bounds\n",
            __func__,
            record.name->c_str()
        );
        return false;
    }
    return true;
}

static bool parakeet_tensor_records_equal(
        const parakeet_tensor_record & lhs,
        const parakeet_tensor_record & rhs) {
    if (lhs.name != rhs.name ||
            lhs.n_dims != rhs.n_dims ||
            lhs.type != rhs.type ||
            lhs.payload_offset != rhs.payload_offset ||
            lhs.payload_bytes != rhs.payload_bytes ||
            lhs.metadata_bytes != rhs.metadata_bytes) {
        return false;
    }
    for (int i = 0; i < 4; ++i) {
        if (lhs.ne[i] != rhs.ne[i]) {
            return false;
        }
    }
    return true;
}

static bool parakeet_scan_tensor_records(
        parakeet_model_loader * loader,
        int64_t tensor_records_offset,
        const parakeet_tensor_name_set & expected_names,
        size_t optional_bias_record_count,
        size_t optional_norm_stat_count,
        size_t optional_speaker_record_count,
        std::vector<parakeet_tensor_record> & records,
        parakeet_tensor_record_index & records_by_name,
        int64_t & file_size) {
    if (!loader->seek(loader->context, 0, SEEK_END)) {
        PARAKEET_LOG_ERROR("%s: cannot determine model bounds\n", __func__);
        return false;
    }
    file_size = loader->tell(loader->context);
    if (file_size < tensor_records_offset ||
            !loader->seek(loader->context, tensor_records_offset, SEEK_SET)) {
        PARAKEET_LOG_ERROR("%s: invalid tensor-record offset\n", __func__);
        return false;
    }

    const size_t expected_record_count = expected_names.size();
    size_t maximum_metadata_bytes = 0;
    const size_t maximum_record_metadata_bytes =
        3 * sizeof(int32_t) +
        4 * sizeof(int32_t) +
        (GGML_MAX_NAME - 1);
    if (!parakeet_checked_multiply(
            expected_record_count,
            maximum_record_metadata_bytes,
            maximum_metadata_bytes)) {
        PARAKEET_LOG_ERROR("%s: tensor metadata cap overflows\n", __func__);
        return false;
    }

    records.clear();
    records.reserve(expected_record_count);
    records_by_name.clear();
    size_t total_metadata_bytes = 0;
    while (true) {
        const int64_t record_offset = loader->tell(loader->context);
        if (record_offset < 0 || record_offset > file_size) {
            PARAKEET_LOG_ERROR("%s: invalid tensor-record position\n", __func__);
            return false;
        }
        if (record_offset == file_size) {
            break;
        }
        if (records.size() >= expected_record_count) {
            PARAKEET_LOG_ERROR("%s: too many tensor records in model file\n", __func__);
            return false;
        }

        parakeet_tensor_record record;
        if (!parakeet_read_tensor_record(
                loader,
                file_size,
                expected_names,
                record)) {
            return false;
        }
        if (!parakeet_checked_add(
                total_metadata_bytes,
                record.metadata_bytes,
                total_metadata_bytes) ||
                total_metadata_bytes > maximum_metadata_bytes) {
            PARAKEET_LOG_ERROR("%s: tensor metadata exceeds bounded cap\n", __func__);
            return false;
        }
        const size_t record_index = records.size();
        if (!records_by_name.emplace(*record.name, record_index).second) {
            PARAKEET_LOG_ERROR(
                "%s: duplicate tensor '%s' in model file\n",
                __func__,
                record.name->c_str()
            );
            return false;
        }
        const int64_t next_record_offset =
            record.payload_offset + static_cast<int64_t>(record.payload_bytes);
        records.push_back(record);
        if (!loader->seek(loader->context, next_record_offset, SEEK_SET)) {
            PARAKEET_LOG_ERROR("%s: tensor payload seek exceeds model bounds\n", __func__);
            return false;
        }
    }

    // VOICEOUR PATCH: expected names include three independent all-or-none
    // optional families: bias-variant linear/conv biases, BatchNorm running
    // statistics, and the multitalker single-speaker residual kernel.
    if (records.size() > expected_record_count) {
        PARAKEET_LOG_ERROR("%s: too many tensor records: %zu > %zu\n",
                __func__, records.size(), expected_record_count);
        return false;
    }
    const size_t missing = expected_record_count - records.size();
    const size_t groups[] = {
        optional_bias_record_count,
        optional_norm_stat_count,
        optional_speaker_record_count,
    };
    bool valid_optional_total = false;
    for (unsigned mask = 0; mask < 8; ++mask) {
        size_t candidate = 0;
        for (unsigned bit = 0; bit < 3; ++bit) {
            if (mask & (1u << bit)) { candidate += groups[bit]; }
        }
        valid_optional_total = valid_optional_total || candidate == missing;
    }
    if (!valid_optional_total) {
        PARAKEET_LOG_ERROR(
            "%s: wrong tensor-record count: expected %zu, got %zu (missing %zu is not optional families)\n",
            __func__, expected_record_count, records.size(), missing);
        return false;
    }
    if (!loader->seek(loader->context, tensor_records_offset, SEEK_SET)) {
        PARAKEET_LOG_ERROR("%s: cannot rewind tensor records\n", __func__);
        return false;
    }
    return true;
}

static bool parakeet_tensor_uses_record_type(parakeet_tensor tensor) {
    switch (tensor) {
        case PARAKEET_TENSOR_ENC_PRE_OUT_WEIGHT:
        case PARAKEET_TENSOR_ENC_FF1_LINEAR1_WEIGHT:
        case PARAKEET_TENSOR_ENC_FF1_LINEAR2_WEIGHT:
        case PARAKEET_TENSOR_ENC_CONV_PW1_WEIGHT:
        case PARAKEET_TENSOR_ENC_CONV_PW2_WEIGHT:
        case PARAKEET_TENSOR_ENC_ATTN_Q_WEIGHT:
        case PARAKEET_TENSOR_ENC_ATTN_K_WEIGHT:
        case PARAKEET_TENSOR_ENC_ATTN_V_WEIGHT:
        case PARAKEET_TENSOR_ENC_ATTN_OUT_WEIGHT:
        case PARAKEET_TENSOR_ENC_ATTN_POS_WEIGHT:
        case PARAKEET_TENSOR_ENC_FF2_LINEAR1_WEIGHT:
        case PARAKEET_TENSOR_ENC_FF2_LINEAR2_WEIGHT:
        case PARAKEET_TENSOR_SPK_FF1_WEIGHT:
        case PARAKEET_TENSOR_SPK_FF2_WEIGHT:
        case PARAKEET_TENSOR_BG_SPK_FF1_WEIGHT:
        case PARAKEET_TENSOR_BG_SPK_FF2_WEIGHT:
        case PARAKEET_TENSOR_PRED_EMBED_WEIGHT:
        case PARAKEET_TENSOR_PRED_LSTM_WEIGHT_IH:
        case PARAKEET_TENSOR_PRED_LSTM_WEIGHT_HH:
        case PARAKEET_TENSOR_JOINT_PRED_WEIGHT:
        case PARAKEET_TENSOR_JOINT_ENC_WEIGHT:
        case PARAKEET_TENSOR_JOINT_NET_WEIGHT:
            return true;
        default:
            return false;
    }
}


static bool parakeet_validate_hparams(const std::map<parakeet_hparam, int32_t> & hparam_values) {
    for (const auto & hparam_expected : PARAKEET_HPARAM_MODEL_VALUES) {
        const parakeet_hparam hparam = hparam_expected.first;
        const auto hparam_value = hparam_values.find(hparam);
        if (hparam_value == hparam_values.end()) {
            PARAKEET_LOG_ERROR("%s: missing Parakeet metadata: %s\n",
                    __func__, PARAKEET_HPARAM_NAMES.at(hparam));
            return false;
        }

        const int32_t actual = hparam_value->second;
        const int32_t expected = hparam_expected.second;
        // VOICEOUR PATCH: zero duration slots is the explicit plain-RNNT
        // decoder-family marker; every other architecture count remains >0.
        const bool rnnt_zero_durations =
                hparam == PARAKEET_HPARAM_N_TDT_DURATIONS && actual == 0;
        if ((!rnnt_zero_durations && actual <= 0) || actual > expected) {
            PARAKEET_LOG_ERROR("%s: invalid Parakeet metadata: %s = %d, expected <= %d\n",
                __func__, PARAKEET_HPARAM_NAMES.at(hparam), actual, expected);
            return false;
        }
        if(actual != expected){
            PARAKEET_LOG_WARN("%s: non-standard Parakeet metadata: %s = %d, expected %d\n. Transcription will be affected. ",
                __func__, PARAKEET_HPARAM_NAMES.at(hparam), actual, expected);
        }

    }

    return true;
}

static bool parakeet_lstm_state_init(
               struct parakeet_state & pstate,
                      ggml_backend_t   backend,
                                 int   n_layer,
                                 int   n_pred_dim) {
    parakeet_lstm_state & lstm_state = pstate.lstm_state;

    lstm_state.ctx_buf.resize(ggml_tensor_overhead() * n_layer * 2);
    lstm_state.layer.resize(n_layer);

    struct ggml_init_params params = {
        /*.mem_size   =*/ lstm_state.ctx_buf.size(),
        /*.mem_buffer =*/ lstm_state.ctx_buf.data(),
        /*.no_alloc   =*/ true,
    };

    struct ggml_context * ctx = ggml_init(params);

    if (!ctx) {
        PARAKEET_LOG_ERROR("%s: failed to allocate memory for the lstm states context\n", __func__);
        return false;
    }


    for (int il = 0; il < n_layer; ++il) {
        lstm_state.layer[il].h_state = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_pred_dim);
        lstm_state.layer[il].c_state = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_pred_dim);
    }

    lstm_state.buffer = ggml_backend_alloc_ctx_tensors(ctx, backend);
    if (!lstm_state.buffer) {
        PARAKEET_LOG_ERROR("%s: failed to allocate memory for the lstm states\n", __func__);
        return false;
    }

    ggml_backend_buffer_clear(lstm_state.buffer, 0);

    ggml_free(ctx);

    return true;
}

static bool parakeet_pred_state_init(
               struct parakeet_state & pstate,
                      ggml_backend_t   backend,
                                 int   n_pred_dim) {
    pstate.pred_out_buf.resize(ggml_tensor_overhead());

    struct ggml_init_params params = {
        /*.mem_size   =*/ pstate.pred_out_buf.size(),
        /*.mem_buffer =*/ pstate.pred_out_buf.data(),
        /*.no_alloc   =*/ true,
    };

    struct ggml_context * ctx = ggml_init(params);
    if (!ctx) {
        PARAKEET_LOG_ERROR("%s: failed to allocate memory for pred tensor context\n", __func__);
        return false;
    }

    pstate.pred_out = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_pred_dim);
    pstate.pred_out_buffer = ggml_backend_alloc_ctx_tensors(ctx, backend);
    if (!pstate.pred_out_buffer) {
        PARAKEET_LOG_ERROR("%s: failed to allocate memory for pred tensor\n", __func__);
        ggml_free(ctx);
        return false;
    }

    ggml_free(ctx);

    return true;
}

static int parakeet_encoder_frame_count(const parakeet_model & model, int mel_frames) {
    if (model.spk_ff1_w) {
        for (int stage = 0; stage < 3; ++stage) {
            mel_frames = mel_frames / 2 + 1;
        }
        return mel_frames;
    }
    const int factor = model.hparams.subsampling_factor;
    return (mel_frames + factor - 1) / factor;
}

static bool parakeet_enc_state_init(
               struct parakeet_state & pstate,
                      ggml_backend_t   backend,
                                 int   n_audio_state,
                                 int   n_frames_max) {
    pstate.enc_out_buf.resize(ggml_tensor_overhead());

    struct ggml_init_params params = {
        /*.mem_size   =*/ pstate.enc_out_buf.size(),
        /*.mem_buffer =*/ pstate.enc_out_buf.data(),
        /*.no_alloc   =*/ true,
    };

    struct ggml_context * ctx = ggml_init(params);
    if (!ctx) {
        PARAKEET_LOG_ERROR("%s: failed to allocate memory for enc_out tensor context\n", __func__);
        return false;
    }

    pstate.enc_out = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, n_audio_state, n_frames_max);
    pstate.enc_out_buffer = ggml_backend_alloc_ctx_tensors(ctx, backend);
    if (!pstate.enc_out_buffer) {
        PARAKEET_LOG_ERROR("%s: failed to allocate memory for enc_out tensor\n", __func__);
        ggml_free(ctx);
        return false;
    }

    ggml_free(ctx);

    return true;
}

static ggml_backend_t parakeet_backend_init_gpu(const parakeet_context_params & params) {
    ggml_log_set(g_state.log_callback, g_state.log_callback_user_data);

    ggml_backend_dev_t dev = nullptr;

    int cnt = 0;
    if (params.use_gpu) {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t dev_cur = ggml_backend_dev_get(i);
            enum ggml_backend_dev_type dev_type = ggml_backend_dev_type(dev_cur);
            const char * dev_name = ggml_backend_dev_name(dev_cur);
            PARAKEET_LOG_INFO("%s: device %zu: %s (type: %d)\n", __func__, i, dev_name, dev_type);
            if (dev_type == GGML_BACKEND_DEVICE_TYPE_GPU || dev_type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                PARAKEET_LOG_INFO("%s: found GPU device %zu: %s (type: %d, cnt: %d)\n", __func__, i, dev_name, dev_type, cnt);
                if (cnt == params.gpu_device) {
                    dev = dev_cur;
                }

                if (++cnt > params.gpu_device) {
                    break;
                }
            }
        }
    }

    if (dev == nullptr) {
        PARAKEET_LOG_INFO("%s: no GPU found\n", __func__);
        return nullptr;
    }

    PARAKEET_LOG_INFO("%s: using %s backend\n", __func__, ggml_backend_dev_name(dev));
    ggml_backend_t result = ggml_backend_dev_init(dev, nullptr);
    if (!result) {
        PARAKEET_LOG_ERROR("%s: failed to initialize %s backend\n", __func__, ggml_backend_dev_name(dev));
    }

    return result;
}

static std::vector<ggml_backend_t> parakeet_backend_init(const parakeet_context_params & params) {
    std::vector<ggml_backend_t> result;

    ggml_backend_t backend_gpu = parakeet_backend_init_gpu(params);

    if (backend_gpu) {
        result.push_back(backend_gpu);
    }

    // ACCEL backends
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_ACCEL) {
            PARAKEET_LOG_INFO("%s: using %s backend\n", __func__, ggml_backend_dev_name(dev));
            ggml_backend_t backend = ggml_backend_dev_init(dev, nullptr);
            if (!backend) {
                PARAKEET_LOG_ERROR("%s: failed to initialize %s backend\n", __func__, ggml_backend_dev_name(dev));
                continue;
            }
            result.push_back(backend);
        }
    }

    ggml_backend_t backend_cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (backend_cpu == nullptr) {
        throw std::runtime_error("failed to initialize CPU backend");
    }
    result.push_back(backend_cpu);

    return result;
}

// VOICEOUR PATCH: keep the encoder's full heterogeneous list while restricting the scalar TDT
// tail to Accelerate (when registered) plus the mandatory CPU fallback. Backend ownership stays
// with parakeet_state::backends; this vector is only the scheduler's ordered view.
static std::vector<ggml_backend_t> parakeet_backend_decode_list(
        const parakeet_context_params & params,
        const std::vector<ggml_backend_t> & backends) {
    if (!params.tail_backend_cpu) {
        return backends;
    }

    std::vector<ggml_backend_t> result;
    ggml_backend_t backend_cpu = nullptr;
    result.reserve(backends.size());

    for (ggml_backend_t backend : backends) {
        const enum ggml_backend_dev_type type = ggml_backend_dev_type(ggml_backend_get_device(backend));
        if (type == GGML_BACKEND_DEVICE_TYPE_ACCEL) {
            result.push_back(backend);
        } else if (type == GGML_BACKEND_DEVICE_TYPE_CPU) {
            backend_cpu = backend;
        }
    }

    if (!backend_cpu) {
        throw std::runtime_error("CPU backend missing from decode backend list");
    }
    result.push_back(backend_cpu);
    return result;
}

using buft_list_t = std::vector<std::pair<ggml_backend_dev_t, ggml_backend_buffer_type_t>>;

static buft_list_t make_buft_list(parakeet_context_params & params) {
    // Prio order: GPU -> CPU Extra -> CPU
    buft_list_t buft_list;

    // GPU
    if (params.use_gpu) {
        int cnt = 0;
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t dev = ggml_backend_dev_get(i);
            if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU || ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                if (cnt == params.gpu_device) {
                    auto * buft = ggml_backend_dev_buffer_type(dev);
                    if (buft) {
                        buft_list.emplace_back(dev, buft);
                    }
                }

                if (++cnt > params.gpu_device) {
                    break;
                }
            }
        }
    }

    // CPU Extra
    auto * cpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    auto * cpu_reg = ggml_backend_dev_backend_reg(cpu_dev);
    auto get_extra_bufts_fn = (ggml_backend_dev_get_extra_bufts_t)
        ggml_backend_reg_get_proc_address(cpu_reg, "ggml_backend_dev_get_extra_bufts");
    if (get_extra_bufts_fn) {
        ggml_backend_buffer_type_t * extra_bufts = get_extra_bufts_fn(cpu_dev);
        while (extra_bufts && *extra_bufts) {
            buft_list.emplace_back(cpu_dev, *extra_bufts);
            ++extra_bufts;
        }
    }

    // CPU
    buft_list.emplace_back(cpu_dev, ggml_backend_cpu_buffer_type());

    return buft_list;
}

static bool weight_buft_supported(const parakeet_hparams & hparams, ggml_tensor * w, ggml_op op, ggml_backend_buffer_type_t buft, ggml_backend_dev_t dev) {
    bool op_supported = true;

    if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU ||
        ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_IGPU ||
        (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_CPU && buft == ggml_backend_cpu_buffer_type())) {
        // GPU and default CPU backend support all operators
        op_supported = true;
    } else {
        switch (op) {
            // The current extra_buffer_type implementations only support GGML_OP_MUL_MAT and GGML_OP_GET_ROWS
            case GGML_OP_GET_ROWS:
            case GGML_OP_MUL_MAT: {
                ggml_init_params params = {
                    /*.mem_size   =*/ 2 * ggml_tensor_overhead(),
                    /*.mem_buffer =*/ nullptr,
                    /*.no_alloc   =*/ true,
                };

                ggml_context_ptr ctx_ptr { ggml_init(params) };
                if (!ctx_ptr) {
                    throw std::runtime_error("failed to create ggml context");
                }
                ggml_context * ctx = ctx_ptr.get();

                ggml_tensor * op_tensor = nullptr;

                if (op == GGML_OP_MUL_MAT) {
                    int64_t n_ctx = hparams.n_audio_ctx;
                    ggml_tensor * b = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, w->ne[0], n_ctx, w->ne[2], w->ne[3]);
                    op_tensor = ggml_mul_mat(ctx, w, b);
                } else if (op == GGML_OP_GET_ROWS) {
                    int64_t num_indices = 8;
                    ggml_tensor * indices = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, num_indices);
                    op_tensor = ggml_get_rows(ctx, w, indices);
                }

                // create a temporary dummy buffer for the weight so that supports_op can check the buffer type
                GGML_ASSERT(w->buffer == nullptr);
                w->buffer = ggml_backend_buft_alloc_buffer(buft, 0);
                op_supported = ggml_backend_dev_supports_op(dev, op_tensor);
                ggml_backend_buffer_free(w->buffer);
                w->buffer = nullptr;
                break;
            }
            default: {
                op_supported = false;
                break;
            }
        };
    }

    return op_supported;
}

static ggml_backend_buffer_type_t select_weight_buft(const parakeet_hparams & hparams, ggml_tensor * w, ggml_op op, buft_list_t buft_list) {
    GGML_ASSERT(!buft_list.empty());
    for (const auto & p : buft_list) {
        ggml_backend_dev_t dev = p.first;
        ggml_backend_buffer_type_t buft = p.second;
        if (weight_buft_supported(hparams, w, op, buft, dev)) {
            return buft;
        }
    }

    return nullptr;
}

// VOICEOUR PATCH: file-backed weight arena.
//
// ggml's ordinary Metal buffers are anonymous VM even though the weights are immutable after
// load. On macOS that charges the entire model to every sidecar's physical footprint. The arena
// below preserves ggml's proven allocation order, but backs it with one versioned MAP_SHARED
// file. The source model is still parsed on every load; a warm arena only replaces each payload
// read with a checked seek. Any cache/locking/mapping/durability failure returns to the ordinary
// allocator, so derived state can never make the model unavailable.
#ifndef _WIN32

static constexpr uint32_t PARAKEET_WEIGHT_ARENA_VERSION = 1;
static constexpr uint64_t PARAKEET_FNV64_OFFSET = 1469598103934665603ULL;
static constexpr uint64_t PARAKEET_FNV64_PRIME  = 1099511628211ULL;

using parakeet_weight_ctx_map = std::map<ggml_backend_buffer_type_t, ggml_context *>;

struct parakeet_weight_arena_slice {
    ggml_backend_buffer_type_t buft = nullptr;
    ggml_context * ctx = nullptr;
    size_t offset = 0;
    size_t size = 0;
    size_t max_tensor_size = 0;
};

struct parakeet_weight_arena_plan {
    std::vector<parakeet_weight_arena_slice> slices;
    size_t size = 0;
    uint64_t layout = PARAKEET_FNV64_OFFSET;
};

struct parakeet_weight_arena_lock {
    int fd = -1;

    ~parakeet_weight_arena_lock() {
        if (fd >= 0) {
            flock(fd, LOCK_UN);
            close(fd);
        }
    }

    bool acquire(const std::string & path) {
        fd = open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) {
            PARAKEET_LOG_WARN("%s: cannot open arena lock '%s': %s\n", __func__, path.c_str(), strerror(errno));
            return false;
        }

        struct stat st = {};
        if (fstat(fd, &st) != 0 ||
                !S_ISREG(st.st_mode) ||
                st.st_uid != geteuid() ||
                st.st_nlink != 1 ||
                (st.st_mode & 0022) != 0) {
            PARAKEET_LOG_WARN("%s: refusing unsafe arena lock '%s'\n", __func__, path.c_str());
            close(fd);
            fd = -1;
            return false;
        }
        if (flock(fd, LOCK_EX) != 0) {
            PARAKEET_LOG_WARN("%s: cannot lock arena '%s': %s\n", __func__, path.c_str(), strerror(errno));
            close(fd);
            fd = -1;
            return false;
        }
        return true;
    }
};

struct parakeet_weight_arena_transaction {
    std::string data_temp;
    std::string manifest_temp;
    bool committed = false;

    ~parakeet_weight_arena_transaction() {
        if (!committed) {
            if (!data_temp.empty()) {
                unlink(data_temp.c_str());
            }
            if (!manifest_temp.empty()) {
                unlink(manifest_temp.c_str());
            }
        }
    }
};

static bool parakeet_checked_add(size_t lhs, size_t rhs, size_t & result) {
    if (rhs > std::numeric_limits<size_t>::max() - lhs) {
        return false;
    }
    result = lhs + rhs;
    return true;
}

static bool parakeet_align_up(size_t value, size_t alignment, size_t & result) {
    if (alignment == 0) {
        return false;
    }
    const size_t remainder = value % alignment;
    return remainder == 0 ? (result = value, true) : parakeet_checked_add(value, alignment - remainder, result);
}

static void parakeet_hash_bytes(uint64_t & hash, const void * bytes, size_t size) {
    const uint8_t * cursor = static_cast<const uint8_t *>(bytes);
    for (size_t i = 0; i < size; ++i) {
        hash ^= cursor[i];
        hash *= PARAKEET_FNV64_PRIME;
    }
}

template<typename T>
static void parakeet_hash_value(uint64_t & hash, const T & value) {
    parakeet_hash_bytes(hash, &value, sizeof(value));
}

// VOICEOUR PATCH: ggml's canonical CPU buffer type deliberately has no device pointer, but its
// registered CPU device does support mapped host buffers. Resolve that device explicitly so a
// split Metal-encoder/CPU-tail arena retains the file-backed weight path.
static ggml_backend_dev_t parakeet_weight_arena_device(
        ggml_backend_buffer_type_t buft,
        bool map_cpu_buffer) {
    return map_cpu_buffer && buft == ggml_backend_cpu_buffer_type()
        ? ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)
        : ggml_backend_buft_get_device(buft);
}

static bool parakeet_make_weight_arena_plan(
        const parakeet_weight_ctx_map & ctx_map,
        bool map_cpu_buffer,
        parakeet_weight_arena_plan & plan) {
    const long page_size_long = sysconf(_SC_PAGESIZE);
    if (page_size_long <= 0) {
        return false;
    }
    const size_t page_size = static_cast<size_t>(page_size_long);

    size_t cursor = 0;
    size_t slice_index = 0;
    for (const auto & entry : ctx_map) {
        ggml_backend_buffer_type_t buft = entry.first;
        ggml_context * ctx = entry.second;
        const size_t size = ggml_backend_alloc_ctx_tensors_from_buft_size(ctx, buft);
        if (size == 0) {
            continue;
        }

        ggml_backend_dev_t device = parakeet_weight_arena_device(buft, map_cpu_buffer);
        if (!device) {
            return false;
        }
        ggml_backend_dev_props props = {};
        ggml_backend_dev_get_props(device, &props);
        if (!props.caps.buffer_from_host_ptr) {
            return false;
        }

        size_t offset = 0;
        if (!parakeet_align_up(cursor, page_size, offset)) {
            return false;
        }

        size_t max_tensor_size = 0;
        const char * buft_name = ggml_backend_buft_name(buft);
        parakeet_hash_value(plan.layout, slice_index);
        parakeet_hash_bytes(plan.layout, buft_name, strlen(buft_name));
        parakeet_hash_value(plan.layout, offset);
        parakeet_hash_value(plan.layout, size);

        size_t tensor_index = 0;
        for (ggml_tensor * tensor = ggml_get_first_tensor(ctx);
                tensor != nullptr;
                tensor = ggml_get_next_tensor(ctx, tensor)) {
            const size_t alloc_size = ggml_backend_buft_get_alloc_size(buft, tensor);
            max_tensor_size = std::max(max_tensor_size, alloc_size);
            parakeet_hash_value(plan.layout, tensor_index);
            parakeet_hash_bytes(plan.layout, tensor->name, strnlen(tensor->name, GGML_MAX_NAME));
            parakeet_hash_value(plan.layout, tensor->type);
            parakeet_hash_bytes(plan.layout, tensor->ne, sizeof(tensor->ne));
            parakeet_hash_value(plan.layout, alloc_size);
            ++tensor_index;
        }

        size_t end = 0;
        if (!parakeet_checked_add(offset, size, end)) {
            return false;
        }
        plan.slices.push_back({ buft, ctx, offset, size, max_tensor_size });
        cursor = end;
        ++slice_index;
    }

    plan.size = cursor;
    return !plan.slices.empty() && plan.size > 0;
}

static std::string parakeet_weight_arena_manifest(const parakeet_weight_arena_plan & plan) {
    char layout[17] = {};
    snprintf(layout, sizeof(layout), "%016llx", static_cast<unsigned long long>(plan.layout));
    return
        "VOICEOUR_PARAKEET_WEIGHT_ARENA\n"
        "version=" + std::to_string(PARAKEET_WEIGHT_ARENA_VERSION) + "\n"
        "arena_size=" + std::to_string(plan.size) + "\n"
        "layout=" + layout + "\n";
}

static bool parakeet_safe_regular_file(const struct stat & st, size_t expected_size) {
    return
        S_ISREG(st.st_mode) &&
        st.st_uid == geteuid() &&
        st.st_nlink == 1 &&
        (st.st_mode & 0022) == 0 &&
        st.st_size >= 0 &&
        static_cast<uint64_t>(st.st_size) == static_cast<uint64_t>(expected_size);
}

static bool parakeet_read_exact_file(const std::string & path, const std::string & expected) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        return false;
    }

    struct stat st = {};
    bool ok =
        fstat(fd, &st) == 0 &&
        parakeet_safe_regular_file(st, expected.size());
    std::string observed(expected.size(), '\0');
    size_t done = 0;
    while (ok && done < observed.size()) {
        const ssize_t count = read(fd, observed.data() + done, observed.size() - done);
        if (count <= 0) {
            ok = false;
            break;
        }
        done += static_cast<size_t>(count);
    }
    close(fd);
    return ok && done == observed.size() && observed == expected;
}

static void parakeet_reset_weight_tensors(const parakeet_weight_arena_plan & plan) {
    for (const auto & slice : plan.slices) {
        for (ggml_tensor * tensor = ggml_get_first_tensor(slice.ctx);
                tensor != nullptr;
                tensor = ggml_get_next_tensor(slice.ctx, tensor)) {
            tensor->buffer = nullptr;
            tensor->data = nullptr;
        }
    }
}

static void parakeet_release_weight_arena_storage(parakeet_model & model) {
    if (model.weight_arena_addr) {
        munmap(model.weight_arena_addr, model.weight_arena_size);
        model.weight_arena_addr = nullptr;
        model.weight_arena_size = 0;
    }
    if (model.weight_arena_fd >= 0) {
        close(model.weight_arena_fd);
        model.weight_arena_fd = -1;
    }
}

static void parakeet_discard_mapped_weight_buffers(
        parakeet_model & model,
        const parakeet_weight_arena_plan & plan) {
    for (ggml_backend_buffer_t buffer : model.buffers) {
        ggml_backend_buffer_free(buffer);
    }
    model.buffers.clear();
    parakeet_reset_weight_tensors(plan);
    parakeet_release_weight_arena_storage(model);
}

static bool parakeet_allocate_weight_arena_buffers(
        parakeet_model & model,
        const parakeet_weight_arena_plan & plan) {
    uint8_t * base = static_cast<uint8_t *>(model.weight_arena_addr);
    for (const auto & slice : plan.slices) {
        ggml_backend_dev_t device = parakeet_weight_arena_device(slice.buft, true);
        ggml_backend_buffer_t buffer = ggml_backend_dev_buffer_from_host_ptr(
            device,
            base + slice.offset,
            slice.size,
            slice.max_tensor_size
        );
        if (!buffer) {
            return false;
        }
        model.buffers.push_back(buffer);

        ggml_tallocr tallocr = ggml_tallocr_new(buffer);
        for (ggml_tensor * tensor = ggml_get_first_tensor(slice.ctx);
                tensor != nullptr;
                tensor = ggml_get_next_tensor(slice.ctx, tensor)) {
            ggml_status status = GGML_STATUS_SUCCESS;
            if (tensor->data == nullptr) {
                if (tensor->view_src == nullptr) {
                    status = ggml_tallocr_alloc(&tallocr, tensor);
                } else if (tensor->buffer == nullptr) {
                    status = ggml_backend_view_init(tensor);
                }
            } else if (tensor->view_src != nullptr && tensor->buffer == nullptr) {
                status = ggml_backend_view_init(tensor);
            }
            if (status != GGML_STATUS_SUCCESS) {
                PARAKEET_LOG_WARN("%s: failed to map tensor '%s'\n", __func__, tensor->name);
                return false;
            }
        }

        PARAKEET_LOG_INFO("%s: %12s arena size = %8.2f MB\n",
            __func__, ggml_backend_buffer_name(buffer), slice.size / 1e6);
    }
    return true;
}

static bool parakeet_map_existing_weight_arena(
        const std::string & path,
        const parakeet_weight_arena_plan & plan,
        parakeet_model & model) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        return false;
    }

    struct stat st = {};
    if (fstat(fd, &st) != 0 || !parakeet_safe_regular_file(st, plan.size)) {
        close(fd);
        return false;
    }

    void * address = mmap(nullptr, plan.size, PROT_READ, MAP_SHARED, fd, 0);
    if (address == MAP_FAILED) {
        close(fd);
        return false;
    }

    model.weight_arena_addr = address;
    model.weight_arena_size = plan.size;
    model.weight_arena_fd = fd;
    if (!parakeet_allocate_weight_arena_buffers(model, plan)) {
        parakeet_discard_mapped_weight_buffers(model, plan);
        return false;
    }
    return true;
}

static bool parakeet_preallocate_weight_arena(int fd, size_t size) {
    if (size > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
        errno = EFBIG;
        return false;
    }
    const off_t length = static_cast<off_t>(size);
#if defined(__APPLE__)
    fstore_t store = {};
    store.fst_flags = F_ALLOCATECONTIG;
    store.fst_posmode = F_PEOFPOSMODE;
    store.fst_offset = 0;
    store.fst_length = length;
    if (fcntl(fd, F_PREALLOCATE, &store) != 0) {
        store.fst_flags = F_ALLOCATEALL;
        if (fcntl(fd, F_PREALLOCATE, &store) != 0) {
            return false;
        }
    }
#else
    const int result = posix_fallocate(fd, 0, length);
    if (result != 0) {
        errno = result;
        return false;
    }
#endif
    return ftruncate(fd, length) == 0;
}

static bool parakeet_create_weight_arena(
        const std::string & path,
        const parakeet_weight_arena_plan & plan,
        parakeet_model & model) {
    unlink(path.c_str());
    const int fd = open(path.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        return false;
    }
    // Reserve physical blocks before mmap: a sparse ftruncate can SIGBUS later on ENOSPC,
    // outside the error-return path that guarantees ordinary-buffer fallback.
    if (!parakeet_preallocate_weight_arena(fd, plan.size)) {
        close(fd);
        unlink(path.c_str());
        return false;
    }

    void * address = mmap(nullptr, plan.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (address == MAP_FAILED) {
        close(fd);
        unlink(path.c_str());
        return false;
    }

    model.weight_arena_addr = address;
    model.weight_arena_size = plan.size;
    model.weight_arena_fd = fd;
    if (!parakeet_allocate_weight_arena_buffers(model, plan)) {
        parakeet_discard_mapped_weight_buffers(model, plan);
        unlink(path.c_str());
        return false;
    }
    return true;
}

static bool parakeet_allocate_regular_weight_buffers(
        const parakeet_weight_ctx_map & ctx_map,
        parakeet_model & model) {
    for (const auto & entry : ctx_map) {
        ggml_backend_buffer_t buffer =
            ggml_backend_alloc_ctx_tensors_from_buft(entry.second, entry.first);
        if (!buffer) {
            for (ggml_backend_buffer_t allocated : model.buffers) {
                ggml_backend_buffer_free(allocated);
            }
            model.buffers.clear();
            for (const auto & reset_entry : ctx_map) {
                for (ggml_tensor * tensor = ggml_get_first_tensor(reset_entry.second);
                        tensor != nullptr;
                        tensor = ggml_get_next_tensor(reset_entry.second, tensor)) {
                    tensor->buffer = nullptr;
                    tensor->data = nullptr;
                }
            }
            return false;
        }
        model.buffers.push_back(buffer);
        PARAKEET_LOG_INFO("%s: %12s total size = %8.2f MB\n",
            __func__, ggml_backend_buffer_name(buffer), ggml_backend_buffer_get_size(buffer) / 1e6);
    }
    return true;
}

static bool parakeet_sync_weight_tensor(const parakeet_model & model, const ggml_tensor * tensor) {
    const long page_size_long = sysconf(_SC_PAGESIZE);
    if (page_size_long <= 0 || !tensor->data) {
        return false;
    }
    const uintptr_t page_size = static_cast<uintptr_t>(page_size_long);
    const uintptr_t arena_begin = reinterpret_cast<uintptr_t>(model.weight_arena_addr);
    if (model.weight_arena_size > std::numeric_limits<uintptr_t>::max() - arena_begin) {
        return false;
    }
    const uintptr_t arena_end = arena_begin + model.weight_arena_size;
    const uintptr_t tensor_begin = reinterpret_cast<uintptr_t>(tensor->data);
    if (tensor_begin < arena_begin ||
            tensor_begin > arena_end ||
            ggml_nbytes(tensor) > arena_end - tensor_begin) {
        return false;
    }

    const uintptr_t begin = tensor_begin - (tensor_begin % page_size);
    size_t tensor_end_size = 0;
    if (!parakeet_checked_add(static_cast<size_t>(tensor_begin), ggml_nbytes(tensor), tensor_end_size)) {
        return false;
    }
    size_t end_size = 0;
    if (!parakeet_align_up(tensor_end_size, page_size, end_size)) {
        return false;
    }
    const uintptr_t end = std::min(static_cast<uintptr_t>(end_size), arena_end);
    return begin < end && msync(reinterpret_cast<void *>(begin), end - begin, MS_SYNC) == 0;
}

static bool parakeet_write_all(int fd, const char * data, size_t size) {
    size_t done = 0;
    while (done < size) {
        const ssize_t count = write(fd, data + done, size - done);
        if (count <= 0) {
            return false;
        }
        done += static_cast<size_t>(count);
    }
    return true;
}

static std::string parakeet_parent_directory(const std::string & path) {
    const size_t slash = path.find_last_of('/');
    if (slash == std::string::npos) {
        return ".";
    }
    return slash == 0 ? "/" : path.substr(0, slash);
}

static bool parakeet_sync_directory(const std::string & path) {
    const std::string directory = parakeet_parent_directory(path);
    const int fd = open(directory.c_str(), O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) {
        return false;
    }
    const bool ok = fsync(fd) == 0;
    close(fd);
    return ok;
}

static bool parakeet_commit_weight_arena(
        const std::string & arena_path,
        const std::string & manifest_path,
        parakeet_weight_arena_transaction & transaction,
        const std::string & manifest,
        parakeet_model & model) {
    if (fsync(model.weight_arena_fd) != 0 || fchmod(model.weight_arena_fd, 0400) != 0) {
        return false;
    }

    unlink(transaction.manifest_temp.c_str());
    const int manifest_fd = open(
        transaction.manifest_temp.c_str(),
        O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
        0600
    );
    if (manifest_fd < 0) {
        return false;
    }
    const bool manifest_ok =
        parakeet_write_all(manifest_fd, manifest.data(), manifest.size()) &&
        fsync(manifest_fd) == 0 &&
        fchmod(manifest_fd, 0400) == 0;
    close(manifest_fd);
    if (!manifest_ok) {
        return false;
    }

    if (rename(transaction.data_temp.c_str(), arena_path.c_str()) != 0) {
        return false;
    }
    if (rename(transaction.manifest_temp.c_str(), manifest_path.c_str()) != 0) {
        unlink(arena_path.c_str());
        return false;
    }
    if (!parakeet_sync_directory(arena_path)) {
        unlink(arena_path.c_str());
        unlink(manifest_path.c_str());
        parakeet_sync_directory(arena_path);
        return false;
    }

    transaction.committed = true;
    return true;
}

static bool parakeet_remove_weight_arena_files(const std::string & arena_path) {
    parakeet_weight_arena_lock lock;
    if (!lock.acquire(arena_path + ".lock")) {
        return false;
    }

    bool ok = true;
    for (const std::string & path : {
            arena_path,
            arena_path + ".manifest",
            arena_path + ".tmp",
            arena_path + ".manifest.tmp",
        }) {
        if (unlink(path.c_str()) != 0 && errno != ENOENT) {
            ok = false;
        }
    }
    return parakeet_sync_directory(arena_path) && ok;
}

#endif // _WIN32


// load the model from a ggml file
//

// see the convert-parakeet-to-ggml.py script for details
//
static bool parakeet_model_load(
        struct parakeet_model_loader * loader,
        parakeet_context & wctx,
        const char * path_weight_arena) {
    PARAKEET_LOG_INFO("%s: loading model\n", __func__);

    const int64_t t_start_us = ggml_time_us();

    wctx.t_start_us = t_start_us;

    auto & model = wctx.model;
    auto & vocab = wctx.vocab;

    // verify magic
    {
        uint32_t magic;
        read_safe(loader, magic);
        if (magic != GGML_FILE_MAGIC) {
            PARAKEET_LOG_ERROR("%s: invalid model data (bad magic)\n", __func__);
            return false;
        }
    }

    //load hparams
    parakeet_hparams hparams;
    {
        std::map<parakeet_hparam, int32_t>hparam_values;
        auto read_hparam = [&] (parakeet_hparam hparam, int32_t &value){
            read_safe(loader, value);
            hparam_values[hparam] = value;
        };
        read_hparam(PARAKEET_HPARAM_N_VOCAB, hparams.n_vocab);
        read_hparam(PARAKEET_HPARAM_N_AUDIO_CTX, hparams.n_audio_ctx);
        read_hparam(PARAKEET_HPARAM_N_AUDIO_STATE, hparams.n_audio_state);
        read_hparam(PARAKEET_HPARAM_N_AUDIO_HEAD, hparams.n_audio_head);
        read_hparam(PARAKEET_HPARAM_N_AUDIO_LAYER, hparams.n_audio_layer);
        read_hparam(PARAKEET_HPARAM_N_MELS, hparams.n_mels);
        /*
        ftype just requires the type check already being done in the loading process.
        */
        read_safe(loader, hparams.ftype);
        read_hparam(PARAKEET_HPARAM_N_FFT, hparams.n_fft);
        read_hparam(PARAKEET_HPARAM_SUBSAMPLING_FACTOR, hparams.subsampling_factor);
        read_hparam(PARAKEET_HPARAM_N_SUBSAMPLING_CHANNELS, hparams.n_subsampling_channels);
        read_hparam(PARAKEET_HPARAM_N_CONV_KERNEL, hparams.n_conv_kernel);
        read_hparam(PARAKEET_HPARAM_N_PRED_DIM, hparams.n_pred_dim);
        read_hparam(PARAKEET_HPARAM_N_PRED_LAYERS, hparams.n_pred_layers);
        read_hparam(PARAKEET_HPARAM_N_TDT_DURATIONS, hparams.n_tdt_durations);
        read_hparam(PARAKEET_HPARAM_N_MAX_TOKENS, hparams.n_max_tokens);

        if(!parakeet_validate_hparams(hparam_values)) {
            return false;
        }

        hparams.arch = PARAKEET_ARCH_TDT;
        wctx.model.hparams = hparams;

        const int32_t qntvr = hparams.ftype / GGML_QNT_VERSION_FACTOR;

        hparams.ftype %= GGML_QNT_VERSION_FACTOR;

        // for the big tensors, we have the option to store the data in 16-bit floats or quantized
        // in order to save memory and also to speed up the computation
        wctx.wtype = ggml_ftype_to_ggml_type((ggml_ftype) hparams.ftype);
        if (wctx.wtype == GGML_TYPE_COUNT) {
            PARAKEET_LOG_ERROR("%s: invalid model (bad ftype value %d)\n", __func__, hparams.ftype);
            return false;
        }

        const char* arch_name = hparams.arch == PARAKEET_ARCH_TDT ? "Parakeet TDT" : "unknown";
        PARAKEET_LOG_INFO("%s: arch                   = %s\n", __func__, arch_name);
        PARAKEET_LOG_INFO("%s: n_vocab                = %d\n", __func__, hparams.n_vocab);
        PARAKEET_LOG_INFO("%s: n_audio_ctx            = %d\n", __func__, hparams.n_audio_ctx);
        PARAKEET_LOG_INFO("%s: n_audio_state          = %d\n", __func__, hparams.n_audio_state);
        PARAKEET_LOG_INFO("%s: n_audio_head           = %d\n", __func__, hparams.n_audio_head);
        PARAKEET_LOG_INFO("%s: n_audio_layer          = %d\n", __func__, hparams.n_audio_layer);
        PARAKEET_LOG_INFO("%s: n_mels                 = %d\n", __func__, hparams.n_mels);
        PARAKEET_LOG_INFO("%s: n_fft                  = %d\n", __func__, hparams.n_fft);
        PARAKEET_LOG_INFO("%s: eps                    = %f\n", __func__, hparams.eps);
        PARAKEET_LOG_INFO("%s: ftype                  = %d\n", __func__, hparams.ftype);
        PARAKEET_LOG_INFO("%s: qntvr                  = %d\n", __func__, qntvr);
        PARAKEET_LOG_INFO("%s: subsampling_factor     = %d\n", __func__, hparams.subsampling_factor);
        PARAKEET_LOG_INFO("%s: n_subsampling_channels = %d\n", __func__, hparams.n_subsampling_channels);
        PARAKEET_LOG_INFO("%s: n_conv_kernel          = %d\n", __func__, hparams.n_conv_kernel);
        PARAKEET_LOG_INFO("%s: n_pred_dim             = %d\n", __func__, hparams.n_pred_dim);
        PARAKEET_LOG_INFO("%s: n_pred_layers          = %d\n", __func__, hparams.n_pred_layers);
        PARAKEET_LOG_INFO("%s: n_tdt_durations        = %d\n", __func__, hparams.n_tdt_durations);
        PARAKEET_LOG_INFO("%s: n_max_tokens           = %d\n", __func__, hparams.n_max_tokens);
    }

    // load mel filters
    {
        auto & filters = wctx.model.filters;

        read_safe(loader, filters.n_mel);
        read_safe(loader, filters.n_fb);

        filters.data.resize(filters.n_mel * filters.n_fb);
        loader->read(loader->context, filters.data.data(), filters.data.size() * sizeof(float));
        BYTESWAP_FILTERS(filters);
    }

    // load window function
    {
        int32_t n_window = 0;
        read_safe(loader, n_window);

        wctx.mel_cache.window.resize(n_window);
        loader->read(loader->context, wctx.mel_cache.window.data(), n_window * sizeof(float));

#ifdef GGML_BIG_ENDIAN
        for (auto & datum : wctx.mel_cache.window) {
            datum = byteswap(datum);
        }
#endif

        PARAKEET_LOG_INFO("%s: loaded window function with %d samples\n", __func__, n_window);
    }

    // load TDT (Token and Duration Transducer) values
    {
        auto & tdt_durations = wctx.model.tdt_durations;
        tdt_durations.resize(hparams.n_tdt_durations);
        loader->read(loader->context, tdt_durations.data(), hparams.n_tdt_durations * sizeof(uint32_t));

        PARAKEET_LOG_INFO("%s: loaded tdt_durations: [", __func__);
        for (const auto value : tdt_durations) {
            PARAKEET_LOG_INFO("%u ", value);
        }
        PARAKEET_LOG_INFO("]\n");
    }

    // load vocab
    {
        int32_t n_vocab = 0;
        read_safe(loader, n_vocab);

        std::string word;
        std::vector<char> tmp;

        tmp.reserve(128);

        for (int i = 0; i < n_vocab; i++) {
            uint32_t len;
            read_safe(loader, len);

            if (len > 0) {
                tmp.resize(len);
                loader->read(loader->context, &tmp[0], tmp.size()); // read to buffer
                word.assign(&tmp[0], tmp.size());
            } else {
                PARAKEET_LOG_WARN("%s: warning: empty-string token in vocab, i = %d\n", __func__, i);
                word = "";
            }

            vocab.token_to_id[word] = i;
            vocab.id_to_token[i] = word;
            vocab.max_token_length = std::max(vocab.max_token_length, word.size());
        }
        // Blank token for transducer is at index n_vocab (8192), outside the vocabulary
        int blank_id = n_vocab;
        vocab.token_blank = blank_id;
        vocab.id_to_token[blank_id] = "[BLANK]";
        vocab.token_to_id["[BLANK]"] = blank_id;

        // Set special token IDs by looking them up in the loaded vocabulary
        // These are from the SentencePiece vocab file loaded above
        if (vocab.token_to_id.find("<unk>") != vocab.token_to_id.end()) {
            vocab.token_unk = vocab.token_to_id.at("<unk>");
        } else {
            vocab.token_unk = 0;  // Fallback
        }

        if (vocab.token_to_id.find("<s>") != vocab.token_to_id.end()) {
            vocab.token_bos = vocab.token_to_id.at("<s>");
        } else if (vocab.token_to_id.find("<|startoftranscript|>") != vocab.token_to_id.end()) {
            vocab.token_bos = vocab.token_to_id.at("<|startoftranscript|>");
        } else {
            vocab.token_bos = 0;  // Fallback
        }

        if (vocab.token_to_id.find("</s>") != vocab.token_to_id.end()) {
            vocab.token_eos = vocab.token_to_id.at("</s>");
        } else if (vocab.token_to_id.find("<|endoftext|>") != vocab.token_to_id.end()) {
            vocab.token_eos = vocab.token_to_id.at("<|endoftext|>");
        } else {
            vocab.token_eos = 0;  // Fallback
        }

        vocab.n_vocab = model.hparams.n_vocab;

        PARAKEET_LOG_INFO("%s: loaded vocab with %d tokens (blank_id=%d, unk=%d, bos=%d, eos=%d)\n",
            __func__, n_vocab, blank_id, vocab.token_unk, vocab.token_bos, vocab.token_eos);
    }

    const ggml_type wtype = wctx.wtype;
    const int n_audio_layer = hparams.n_audio_layer;

    // VOICEOUR PATCH: checked exact architecture count: pre-encode plus the
    // optional eight-record foreground/background speaker kernels, per-layer
    // encoder (29 mandatory plus 11 optional biases), prediction embedding
    // plus three records per LSTM layer, and joint.
    size_t n_tensors = 20;
    size_t optional_bias_tensors = 0;
    size_t optional_norm_stats = 0;
    const size_t optional_speaker_tensors = 8;
    size_t family_tensors = 0;
    if (!parakeet_checked_multiply(
            29 + 11,
            static_cast<size_t>(n_audio_layer),
            family_tensors) ||
            !parakeet_checked_multiply(
                11,
                static_cast<size_t>(n_audio_layer),
                optional_bias_tensors) ||
            !parakeet_checked_multiply(
                3,
                static_cast<size_t>(n_audio_layer),
                optional_norm_stats) ||
            !parakeet_checked_add(n_tensors, family_tensors, n_tensors) ||
            !parakeet_checked_multiply(
                3,
                static_cast<size_t>(hparams.n_pred_layers),
                family_tensors) ||
            !parakeet_checked_add(n_tensors, 1, n_tensors) ||
            !parakeet_checked_add(n_tensors, family_tensors, n_tensors) ||
            !parakeet_checked_add(n_tensors, 6, n_tensors)) {
        PARAKEET_LOG_ERROR("%s: tensor-record count overflows\n", __func__);
        return false;
    }

    const bool has_record_directory = loader->seek && loader->tell;
    int64_t weight_records_offset = -1;
    int64_t model_file_size = -1;
    parakeet_tensor_name_set expected_tensor_names;
    std::vector<parakeet_tensor_record> tensor_records;
    parakeet_tensor_record_index tensor_records_by_name;
    if (has_record_directory) {
        weight_records_offset = loader->tell(loader->context);
        if (!parakeet_expected_tensor_names(
                n_audio_layer,
                hparams.n_pred_layers,
                expected_tensor_names) ||
                expected_tensor_names.size() != n_tensors ||
                weight_records_offset < 0 ||
                !parakeet_scan_tensor_records(
                    loader,
                    weight_records_offset,
                    expected_tensor_names,
                    optional_bias_tensors,
                    optional_norm_stats,
                    optional_speaker_tensors,
                    tensor_records,
                    tensor_records_by_name,
                    model_file_size)) {
            return false;
        }
    }

    std::map<ggml_backend_buffer_type_t, ggml_context *> ctx_map;
    auto get_ctx = [&](ggml_backend_buffer_type_t buft) -> ggml_context * {
        auto it = ctx_map.find(buft);
        if (it == ctx_map.end()) {
            ggml_init_params params = {
                /*.mem_size   =*/ n_tensors * ggml_tensor_overhead(),
                /*.mem_buffer =*/ nullptr,
                /*.no_alloc   =*/ true,
            };

            ggml_context * ctx = ggml_init(params);
            if (!ctx) {
                throw std::runtime_error("failed to create ggml context");
            }

            ctx_map[buft] = ctx;
            wctx.model.ctxs.emplace_back(ctx);

            return ctx;
        }

        return it->second;
    };

    // Create a list of available bufts, in priority order
    buft_list_t buft_list = make_buft_list(wctx.params);

    // Construct exactly one metadata tensor per architecture tensor. On seekable inputs the
    // record is looked up, shape-checked, and its authoritative mixed-v1 type is chosen first;
    // the nominal/global type is never passed to ggml for an authoritative record.
    ggml_init_params params = {
        /*.mem_size   =*/ n_tensors * ggml_tensor_overhead(),
        /*.mem_buffer =*/ nullptr,
        /*.no_alloc   =*/ true,
    };
    ggml_context * ctx = ggml_init(params);
    if (!ctx) {
        throw std::runtime_error("failed to create tensor metadata context");
    }

    std::set<std::string_view, std::less<>> record_authoritative_names;
    // VOICEOUR PATCH: tail records repacked f16 -> q8_0 at load; the copy loop converts.
    // A model that already ships quantized tail records (the q8_0 GGUF variant) makes the
    // repack a legitimate no-op, counted separately so the sham guard can tell the two apart.
    std::set<std::string_view, std::less<>> q8_converted_names;
    int n_tail_already_quantized = 0;
    auto create_tensor = [&](
            parakeet_tensor type,
            ggml_type legacy_type,
            int32_t n_dims,
            const int64_t * architecture_ne,
            int layer = -1) -> ggml_tensor * {
        std::string tensor_name;
        if (layer >= 0) {
            tensor_name = format(PARAKEET_TENSOR_NAMES.at(type), layer);
        } else {
            tensor_name = PARAKEET_TENSOR_NAMES.at(type);
        }
        if (n_dims <= 0 || n_dims > GGML_MAX_DIMS) {
            throw std::runtime_error(format(
                "parakeet tensor %s has invalid architecture dimensions",
                tensor_name.c_str()
            ));
        }

        int64_t selected_ne[GGML_MAX_DIMS] = { 1, 1, 1, 1 };
        for (int32_t i = 0; i < n_dims; ++i) {
            if (architecture_ne[i] <= 0) {
                throw std::runtime_error(format(
                    "parakeet tensor %s has invalid architecture dimensions",
                    tensor_name.c_str()
                ));
            }
            selected_ne[i] = architecture_ne[i];
        }

        ggml_type selected_type = legacy_type;
        const parakeet_tensor_record * source_record = nullptr;
        if (has_record_directory) {
            const auto record_position = tensor_records_by_name.find(tensor_name);
            if (record_position == tensor_records_by_name.end()) {
                throw std::runtime_error(format(
                    "missing parakeet tensor record %s",
                    tensor_name.c_str()
                ));
            }
            source_record = &tensor_records[record_position->second];
            for (int i = 0; i < GGML_MAX_DIMS; ++i) {
                if (selected_ne[i] != source_record->ne[i]) {
                    throw std::runtime_error(format(
                        "parakeet tensor %s has the wrong record dimensions",
                        tensor_name.c_str()
                    ));
                }
            }

            if (parakeet_tensor_uses_record_type(type)) {
                if (source_record->n_dims != 2 || n_dims != 2) {
                    throw std::runtime_error(format(
                        "parakeet tensor %s is not a 2-D quantizable weight record",
                        tensor_name.c_str()
                    ));
                }
                selected_type = source_record->type;
                record_authoritative_names.emplace(*source_record->name);
            }
        }

        // VOICEOUR PATCH: opt-in load-time q8_0 repack of the CPU tail. Only 2-D f16
        // matmul weights with whole q8_0 blocks per row convert; the record stays f16
        // on disk and the payload copy below quantizes. The embedding stays f16: its
        // per-token row lookup carries no meaningful traffic.
        const bool tail_matmul_2d = source_record != nullptr &&
                wctx.params.tail_backend_cpu && wctx.params.tail_quant_q8 &&
                type >= PARAKEET_TENSOR_PRED_EMBED_WEIGHT &&
                n_dims == 2 &&
                PARAKEET_TENSOR_INFO.at(type) == GGML_OP_MUL_MAT;
        bool convert_to_q8 = false;
        if (tail_matmul_2d && selected_type == GGML_TYPE_F16 &&
                selected_ne[0] % ggml_blck_size(GGML_TYPE_Q8_0) == 0) {
            selected_type = GGML_TYPE_Q8_0;
            convert_to_q8 = true;
            q8_converted_names.emplace(*source_record->name);
        } else if (tail_matmul_2d && ggml_is_quantized(selected_type)) {
            n_tail_already_quantized += 1;
        }

        ggml_tensor * selected_meta =
            ggml_new_tensor(ctx, selected_type, n_dims, selected_ne);
        if (source_record && !convert_to_q8 &&
                source_record->payload_bytes != ggml_nbytes(selected_meta)) {
            throw std::runtime_error(format(
                "parakeet tensor %s has the wrong record payload size",
                tensor_name.c_str()
            ));
        }
        if (source_record && convert_to_q8 &&
                source_record->payload_bytes !=
                    static_cast<size_t>(ggml_nelements(selected_meta)) * sizeof(ggml_fp16_t)) {
            throw std::runtime_error(format(
                "parakeet tensor %s has the wrong record payload size",
                tensor_name.c_str()
            ));
        }

        ggml_op op = PARAKEET_TENSOR_INFO.at(type);
        // VOICEOUR PATCH: a CPU tail must keep its immutable prediction/joint weights in the
        // CPU buffer type too; a CPU-only scheduler cannot execute preallocated MTL0 tensors.
        ggml_backend_buffer_type_t buft =
            wctx.params.tail_backend_cpu && type >= PARAKEET_TENSOR_PRED_EMBED_WEIGHT
                ? ggml_backend_cpu_buffer_type()
                : select_weight_buft(hparams, selected_meta, op, buft_list);
        if (!buft) {
            throw std::runtime_error(format(
                "failed to find a compatible buffer type for parakeet tensor %s",
                tensor_name.c_str()
            ));
        }

        ggml_context * tensor_ctx = get_ctx(buft);
        ggml_tensor * tensor = ggml_dup_tensor(tensor_ctx, selected_meta);
        if (!wctx.model.tensors.emplace(tensor_name, tensor).second) {
            throw std::runtime_error(format(
                "duplicate parakeet architecture tensor %s",
                tensor_name.c_str()
            ));
        }
        return tensor;
    };

    auto create_tensor_1d = [&](
            parakeet_tensor type,
            ggml_type legacy_type,
            int64_t ne0,
            int layer = -1) -> ggml_tensor * {
        const int64_t ne[] = { ne0 };
        return create_tensor(type, legacy_type, 1, ne, layer);
    };
    auto create_tensor_2d = [&](
            parakeet_tensor type,
            ggml_type legacy_type,
            int64_t ne0,
            int64_t ne1,
            int layer = -1) -> ggml_tensor * {
        const int64_t ne[] = { ne0, ne1 };
        return create_tensor(type, legacy_type, 2, ne, layer);
    };
    auto create_tensor_4d = [&](
            parakeet_tensor type,
            ggml_type legacy_type,
            int64_t ne0,
            int64_t ne1,
            int64_t ne2,
            int64_t ne3,
            int layer = -1) -> ggml_tensor * {
        const int64_t ne[] = { ne0, ne1, ne2, ne3 };
        return create_tensor(type, legacy_type, 4, ne, layer);
    };
    // VOICEOUR PATCH: optional per-layer bias records for the bias-variant Conformer
    // checkpoints. Only a seekable loader can know a record is absent, so the legacy
    // sequential path keeps bias-free semantics; presence is tracked so a file that
    // carries a partial bias set is rejected below.
    size_t optional_bias_created = 0;
    auto create_optional_tensor_1d = [&](
            parakeet_tensor type,
            int64_t ne0,
            int layer) -> ggml_tensor * {
        if (!has_record_directory) {
            return nullptr;
        }
        const std::string tensor_name = format(PARAKEET_TENSOR_NAMES.at(type), layer);
        if (tensor_records_by_name.find(tensor_name) == tensor_records_by_name.end()) {
            return nullptr;
        }
        optional_bias_created += 1;
        return create_tensor_1d(type, GGML_TYPE_F32, ne0, layer);
    };
    // VOICEOUR PATCH: conv-LayerNorm checkpoints omit BatchNorm running
    // mean/variance/counter while retaining the affine weight+bias names.
    size_t optional_norm_stats_created = 0;
    auto create_optional_norm_tensor_1d = [&](
            parakeet_tensor type,
            ggml_type legacy_type,
            int64_t ne0,
            int layer) -> ggml_tensor * {
        if (!has_record_directory) {
            return nullptr;
        }
        const std::string tensor_name = format(PARAKEET_TENSOR_NAMES.at(type), layer);
        if (tensor_records_by_name.find(tensor_name) == tensor_records_by_name.end()) {
            return nullptr;
        }
        optional_norm_stats_created += 1;
        return create_tensor_1d(type, legacy_type, ne0, layer);
    };


    // prepare tensors for the weights

    const int n_audio_state = hparams.n_audio_state;

    model.layers.resize(n_audio_layer);

    // Encoder pre_encode. Causal dw-striding has one extra frequency cell;
    // seekable records are authoritative for the flattened feature width.
    const int n_subsampling_channels = hparams.n_subsampling_channels;
    int n_pre_enc_features =
        (hparams.n_mels / hparams.subsampling_factor) * n_subsampling_channels;
    if (has_record_directory) {
        const auto position = tensor_records_by_name.find(
            PARAKEET_TENSOR_NAMES.at(PARAKEET_TENSOR_ENC_PRE_OUT_WEIGHT));
        if (position != tensor_records_by_name.end()) {
            n_pre_enc_features = tensor_records[position->second].ne[0];
        }
    }
    model.enc_pre_out_w = create_tensor_2d(
        PARAKEET_TENSOR_ENC_PRE_OUT_WEIGHT, wtype, n_pre_enc_features, n_audio_state);
    ggml_set_name(model.enc_pre_out_w, "enc_pre_out_w");
    model.enc_pre_out_b = create_tensor_1d(PARAKEET_TENSOR_ENC_PRE_OUT_BIAS, GGML_TYPE_F32, n_audio_state);
    ggml_set_name(model.enc_pre_out_b, "enc_pre_out_b");

    model.enc_pre_conv_0_w = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_0_WEIGHT, GGML_TYPE_F32, 3, 3, 1, n_subsampling_channels);
    ggml_set_name(model.enc_pre_conv_0_w, "enc_pre_conv_0_w");
    model.enc_pre_conv_0_b = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_0_BIAS, GGML_TYPE_F32, 1, 1, n_subsampling_channels, 1);
    ggml_set_name(model.enc_pre_conv_0_b, "enc_pre_conv_0_b");

    model.enc_pre_conv_2_w = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_2_WEIGHT, GGML_TYPE_F32, 3, 3, 1, n_subsampling_channels);
    ggml_set_name(model.enc_pre_conv_2_w, "enc_pre_conv_2_w");
    model.enc_pre_conv_2_b = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_2_BIAS, GGML_TYPE_F32, 1, 1, n_subsampling_channels, 1);
    ggml_set_name(model.enc_pre_conv_2_b, "enc_pre_conv_2_b");

    model.enc_pre_conv_3_w = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_3_WEIGHT, GGML_TYPE_F32, 1, 1, n_subsampling_channels, n_subsampling_channels);
    ggml_set_name(model.enc_pre_conv_3_w, "enc_pre_conv_3_w");
    model.enc_pre_conv_3_b = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_3_BIAS, GGML_TYPE_F32, 1, 1, n_subsampling_channels, 1);
    ggml_set_name(model.enc_pre_conv_3_b, "enc_pre_conv_3_b");

    model.enc_pre_conv_5_w = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_5_WEIGHT, GGML_TYPE_F32, 3, 3, 1, n_subsampling_channels);
    ggml_set_name(model.enc_pre_conv_5_w, "enc_pre_conv_5_w");
    model.enc_pre_conv_5_b = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_5_BIAS, GGML_TYPE_F32, 1, 1, n_subsampling_channels, 1);
    ggml_set_name(model.enc_pre_conv_5_b, "enc_pre_conv_5_b");

    model.enc_pre_conv_6_w = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_6_WEIGHT, GGML_TYPE_F32, 1, 1, n_subsampling_channels, n_subsampling_channels);
    ggml_set_name(model.enc_pre_conv_6_w, "enc_pre_conv_6_w");
    model.enc_pre_conv_6_b = create_tensor_4d(PARAKEET_TENSOR_ENC_PRE_CONV_6_BIAS, GGML_TYPE_F32, 1, 1, n_subsampling_channels, 1);
    ggml_set_name(model.enc_pre_conv_6_b, "enc_pre_conv_6_b");

    // Encoder layers
    for (int i = 0; i < n_audio_layer; ++i) {
        auto & layer = model.layers[i];

        // Feed forward 1
        layer.norm_ff1_w    = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_FF1_WEIGHT, GGML_TYPE_F32, n_audio_state, i);
        layer.norm_ff1_b    = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_FF1_BIAS, GGML_TYPE_F32, n_audio_state, i);
        layer.ff1_linear1_w = create_tensor_2d(PARAKEET_TENSOR_ENC_FF1_LINEAR1_WEIGHT, wtype, n_audio_state, 4*n_audio_state, i);
        ggml_format_name(layer.ff1_linear1_w, "enc_%d_ff1_linear1_w", i);
        layer.ff1_linear2_w = create_tensor_2d(PARAKEET_TENSOR_ENC_FF1_LINEAR2_WEIGHT, wtype, 4*n_audio_state, n_audio_state, i);
        ggml_format_name(layer.ff1_linear2_w, "enc_%d_ff1_linear2_w", i);
        layer.ff1_linear1_b = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_FF1_LINEAR1_BIAS, 4*n_audio_state, i);
        layer.ff1_linear2_b = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_FF1_LINEAR2_BIAS, n_audio_state, i);

        // Convolution module
        layer.norm_conv_w         = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_CONV_WEIGHT, GGML_TYPE_F32, n_audio_state, i);
        ggml_format_name(layer.norm_conv_w, "enc_%d_norm_conv_w", i);
        layer.norm_conv_b         = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_CONV_BIAS, GGML_TYPE_F32, n_audio_state, i);
        ggml_format_name(layer.norm_conv_b, "enc_%d_norm_conv_b", i);
        layer.conv_pw1_w          = create_tensor_2d(PARAKEET_TENSOR_ENC_CONV_PW1_WEIGHT, wtype, n_audio_state, 2*n_audio_state, i);
        ggml_format_name(layer.conv_pw1_w, "enc_%d_conv_pw1_w", i);
        layer.conv_dw_w           = create_tensor_2d(PARAKEET_TENSOR_ENC_CONV_DW_WEIGHT, GGML_TYPE_F32, hparams.n_conv_kernel, n_audio_state, i);
        ggml_format_name(layer.conv_dw_w, "enc_%d_conv_dw_w", i);
        layer.conv_bn_w           = create_tensor_1d(PARAKEET_TENSOR_ENC_CONV_BN_WEIGHT, GGML_TYPE_F32, n_audio_state, i);
        ggml_format_name(layer.conv_bn_w, "enc_%d_conv_bn_w", i);
        layer.conv_bn_b           = create_tensor_1d(PARAKEET_TENSOR_ENC_CONV_BN_BIAS, GGML_TYPE_F32, n_audio_state, i);
        ggml_format_name(layer.conv_bn_b, "enc_%d_conv_bn_b", i);
        layer.conv_bn_mean = create_optional_norm_tensor_1d(
            PARAKEET_TENSOR_ENC_CONV_BN_MEAN, GGML_TYPE_F32, n_audio_state, i);
        layer.conv_bn_var = create_optional_norm_tensor_1d(
            PARAKEET_TENSOR_ENC_CONV_BN_VAR, GGML_TYPE_F32, n_audio_state, i);
        if (layer.conv_bn_var) {
            ggml_format_name(layer.conv_bn_var, "enc_%d_conv_bn_var", i);
        }
        layer.conv_bn_num_batches = create_optional_norm_tensor_1d(
            PARAKEET_TENSOR_ENC_CONV_BN_NUM_BATCHES, GGML_TYPE_I32, 1, i);
        layer.conv_pw2_w          = create_tensor_2d(PARAKEET_TENSOR_ENC_CONV_PW2_WEIGHT, wtype, n_audio_state, n_audio_state, i);
        ggml_format_name(layer.conv_pw2_w, "enc_%d_conv_pw2_w", i);
        layer.conv_pw1_b = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_CONV_PW1_BIAS, 2*n_audio_state, i);
        layer.conv_dw_b  = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_CONV_DW_BIAS, n_audio_state, i);
        layer.conv_pw2_b = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_CONV_PW2_BIAS, n_audio_state, i);

        // Self attention
        layer.norm_attn_w      = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_ATTN_WEIGHT, GGML_TYPE_F32, n_audio_state, i);
        layer.norm_attn_b      = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_ATTN_BIAS, GGML_TYPE_F32, n_audio_state, i);
        layer.attn_pos_bias_u  = create_tensor_2d(PARAKEET_TENSOR_ENC_ATTN_POS_BIAS_U, GGML_TYPE_F32, hparams.n_audio_state / hparams.n_audio_head, hparams.n_audio_head, i);
        layer.attn_pos_bias_v  = create_tensor_2d(PARAKEET_TENSOR_ENC_ATTN_POS_BIAS_V, GGML_TYPE_F32, hparams.n_audio_state / hparams.n_audio_head, hparams.n_audio_head, i);
        layer.attn_q_w         = create_tensor_2d(PARAKEET_TENSOR_ENC_ATTN_Q_WEIGHT, wtype, n_audio_state, n_audio_state, i);
        layer.attn_k_w         = create_tensor_2d(PARAKEET_TENSOR_ENC_ATTN_K_WEIGHT, wtype, n_audio_state, n_audio_state, i);
        layer.attn_v_w         = create_tensor_2d(PARAKEET_TENSOR_ENC_ATTN_V_WEIGHT, wtype, n_audio_state, n_audio_state, i);
        layer.attn_out_w       = create_tensor_2d(PARAKEET_TENSOR_ENC_ATTN_OUT_WEIGHT, wtype, n_audio_state, n_audio_state, i);
        layer.attn_pos_w       = create_tensor_2d(PARAKEET_TENSOR_ENC_ATTN_POS_WEIGHT, wtype, n_audio_state, n_audio_state, i);
        ggml_format_name(layer.attn_pos_w, "enc_%d_attn_pos_w", i);
        layer.attn_q_b   = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_ATTN_Q_BIAS, n_audio_state, i);
        layer.attn_k_b   = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_ATTN_K_BIAS, n_audio_state, i);
        layer.attn_v_b   = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_ATTN_V_BIAS, n_audio_state, i);
        layer.attn_out_b = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_ATTN_OUT_BIAS, n_audio_state, i);

        // Feed forward 2
        layer.norm_ff2_w    = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_FF2_WEIGHT, GGML_TYPE_F32, n_audio_state, i);
        layer.norm_ff2_b    = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_FF2_BIAS, GGML_TYPE_F32, n_audio_state, i);
        layer.ff2_linear1_w = create_tensor_2d(PARAKEET_TENSOR_ENC_FF2_LINEAR1_WEIGHT, wtype, n_audio_state, 4*n_audio_state, i);
        layer.ff2_linear2_w = create_tensor_2d(PARAKEET_TENSOR_ENC_FF2_LINEAR2_WEIGHT, wtype, 4*n_audio_state, n_audio_state, i);
        layer.ff2_linear1_b = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_FF2_LINEAR1_BIAS, 4*n_audio_state, i);
        layer.ff2_linear2_b = create_optional_tensor_1d(PARAKEET_TENSOR_ENC_FF2_LINEAR2_BIAS, n_audio_state, i);

        // Output norm
        layer.norm_out_w = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_OUT_WEIGHT, GGML_TYPE_F32, n_audio_state, i);
        layer.norm_out_b = create_tensor_1d(PARAKEET_TENSOR_ENC_NORM_OUT_BIAS, GGML_TYPE_F32, n_audio_state, i);
    }

    // VOICEOUR PATCH: a bias-variant file carries the complete per-layer bias set;
    // anything partial is a malformed or truncated conversion.
    if (optional_bias_created != 0 &&
            optional_bias_created != 11 * static_cast<size_t>(n_audio_layer)) {
        PARAKEET_LOG_ERROR(
            "%s: partial encoder bias set: %zu of %zu records present\n",
            __func__,
            optional_bias_created,
            11 * static_cast<size_t>(n_audio_layer)
        );
        return false;
    }

    if (optional_norm_stats_created != 0 &&
            optional_norm_stats_created != 3 * static_cast<size_t>(n_audio_layer)) {
        PARAKEET_LOG_ERROR(
            "%s: partial BatchNorm statistics set: %zu of %zu records present\n",
            __func__,
            optional_norm_stats_created,
            3 * static_cast<size_t>(n_audio_layer)
        );
        return false;
    }

    const parakeet_tensor speaker_types[] = {
        PARAKEET_TENSOR_SPK_FF1_WEIGHT,
        PARAKEET_TENSOR_SPK_FF1_BIAS,
        PARAKEET_TENSOR_SPK_FF2_WEIGHT,
        PARAKEET_TENSOR_SPK_FF2_BIAS,
        PARAKEET_TENSOR_BG_SPK_FF1_WEIGHT,
        PARAKEET_TENSOR_BG_SPK_FF1_BIAS,
        PARAKEET_TENSOR_BG_SPK_FF2_WEIGHT,
        PARAKEET_TENSOR_BG_SPK_FF2_BIAS,
    };
    size_t speaker_records = 0;
    for (parakeet_tensor type : speaker_types) {
        speaker_records += has_record_directory &&
                tensor_records_by_name.find(PARAKEET_TENSOR_NAMES.at(type)) !=
                    tensor_records_by_name.end();
    }
    if (speaker_records != 0 && speaker_records != 8) {
        PARAKEET_LOG_ERROR("%s: partial speaker-kernel record set\n", __func__);
        return false;
    }
    if (speaker_records == 8) {
        model.spk_ff1_w = create_tensor_2d(
            PARAKEET_TENSOR_SPK_FF1_WEIGHT, wtype, n_audio_state, n_audio_state);
        model.spk_ff1_b = create_tensor_1d(
            PARAKEET_TENSOR_SPK_FF1_BIAS, GGML_TYPE_F32, n_audio_state);
        model.spk_ff2_w = create_tensor_2d(
            PARAKEET_TENSOR_SPK_FF2_WEIGHT, wtype, n_audio_state, n_audio_state);
        model.spk_ff2_b = create_tensor_1d(
            PARAKEET_TENSOR_SPK_FF2_BIAS, GGML_TYPE_F32, n_audio_state);
        model.bg_spk_ff1_w = create_tensor_2d(
            PARAKEET_TENSOR_BG_SPK_FF1_WEIGHT, wtype, n_audio_state, n_audio_state);
        model.bg_spk_ff1_b = create_tensor_1d(
            PARAKEET_TENSOR_BG_SPK_FF1_BIAS, GGML_TYPE_F32, n_audio_state);
        model.bg_spk_ff2_w = create_tensor_2d(
            PARAKEET_TENSOR_BG_SPK_FF2_WEIGHT, wtype, n_audio_state, n_audio_state);
        model.bg_spk_ff2_b = create_tensor_1d(
            PARAKEET_TENSOR_BG_SPK_FF2_BIAS, GGML_TYPE_F32, n_audio_state);
    }

    // Prediction network (decoder)
    const int dec_hidden   = hparams.n_pred_dim;
    const int n_pred_embed = hparams.n_vocab + 1;                            // vocab + blank token
    const int n_lstm_gates = 4 * dec_hidden;                                 // 4 LSTM gates
    const int n_joint_out  = hparams.n_vocab + hparams.n_tdt_durations + 1;  // vocab + durations + blank

    // The legacy/non-seekable global path keeps its K-quant fallback for the 640-wide
    // prediction/joint tensors. A seekable record directory overrides only allowlisted weights.
    const int blck         = ggml_blck_size(wtype);
    const ggml_type pred_wtype = (blck > 1 && dec_hidden % blck != 0) ? GGML_TYPE_F32 : wtype;
    const ggml_type join_wtype = pred_wtype;

    model.prediction.embed_w = create_tensor_2d(PARAKEET_TENSOR_PRED_EMBED_WEIGHT, pred_wtype, dec_hidden, n_pred_embed);
    model.prediction.lstm_layer.resize(hparams.n_pred_layers);
    for (int i = 0; i < hparams.n_pred_layers; ++i) {
        auto & layer = model.prediction.lstm_layer[i];
        layer.ih_w = create_tensor_2d(PARAKEET_TENSOR_PRED_LSTM_WEIGHT_IH, pred_wtype, dec_hidden, n_lstm_gates, i);
        ggml_format_name(layer.ih_w, "pred_%d_ih_w", i);

        layer.hh_w = create_tensor_2d(PARAKEET_TENSOR_PRED_LSTM_WEIGHT_HH, pred_wtype, dec_hidden, n_lstm_gates, i);
        ggml_format_name(layer.hh_w, "pred_%d_hh_w", i);

        layer.b_h = create_tensor_1d(PARAKEET_TENSOR_PRED_LSTM_BIAS_H, GGML_TYPE_F32, n_lstm_gates, i);
        ggml_format_name(layer.b_h, "pred_%d_b_h", i);
    }

    // Joint network
    model.joint.pred_w = create_tensor_2d(PARAKEET_TENSOR_JOINT_PRED_WEIGHT, join_wtype, dec_hidden, dec_hidden);
    ggml_set_name(model.joint.pred_w, "pred_w");
    model.joint.pred_b = create_tensor_1d(PARAKEET_TENSOR_JOINT_PRED_BIAS, GGML_TYPE_F32, dec_hidden);
    ggml_set_name(model.joint.pred_b, "pred_b");
    model.joint.enc_w  = create_tensor_2d(PARAKEET_TENSOR_JOINT_ENC_WEIGHT, wtype, n_audio_state, dec_hidden);
    ggml_set_name(model.joint.enc_w, "enc_w");
    model.joint.enc_b  = create_tensor_1d(PARAKEET_TENSOR_JOINT_ENC_BIAS, GGML_TYPE_F32, dec_hidden);
    ggml_set_name(model.joint.enc_b, "enc_b");
    model.joint.net_w  = create_tensor_2d(PARAKEET_TENSOR_JOINT_NET_WEIGHT, join_wtype, dec_hidden, n_joint_out);
    ggml_set_name(model.joint.net_w, "net_w");
    model.joint.net_b  = create_tensor_1d(PARAKEET_TENSOR_JOINT_NET_BIAS, GGML_TYPE_F32, n_joint_out);
    ggml_set_name(model.joint.net_b, "net_b");

    if (has_record_directory) {
        bool exact_name_set = model.tensors.size() == tensor_records.size();
        for (const parakeet_tensor_record & record : tensor_records) {
            exact_name_set =
                exact_name_set &&
                model.tensors.find(*record.name) != model.tensors.end();
        }
        if (!exact_name_set) {
            PARAKEET_LOG_ERROR("%s: tensor record names do not match the architecture\n", __func__);
            ggml_free(ctx);
            return false;
        }
    }

    ggml_free(ctx);

    bool arena_warm = false;
    bool arena_cold = false;
    bool arena_cache_failed = false;

#ifndef _WIN32
    parakeet_weight_arena_plan arena_plan;
    parakeet_weight_arena_lock arena_lock;
    parakeet_weight_arena_transaction arena_transaction;
    std::string arena_path;
    std::string arena_manifest_path;
    std::string arena_manifest;

    const bool arena_requested =
        path_weight_arena &&
        path_weight_arena[0] != '\0' &&
        loader->seek &&
        loader->tell;
    if (arena_requested &&
            parakeet_make_weight_arena_plan(
                ctx_map,
                wctx.params.tail_backend_cpu,
                arena_plan)) {
        arena_path = path_weight_arena;
        arena_manifest_path = arena_path + ".manifest";
        arena_manifest = parakeet_weight_arena_manifest(arena_plan);
        arena_transaction.data_temp = arena_path + ".tmp";
        arena_transaction.manifest_temp = arena_manifest_path + ".tmp";

        if (arena_lock.acquire(arena_path + ".lock")) {
            // Fixed temporary names are safe under the cross-process lock. Removing them rejects
            // a writer that died before the manifest commit marker was renamed.
            unlink(arena_transaction.data_temp.c_str());
            unlink(arena_transaction.manifest_temp.c_str());

            const bool manifest_ok =
                parakeet_read_exact_file(arena_manifest_path, arena_manifest);
            if (manifest_ok) {
                arena_warm = parakeet_map_existing_weight_arena(arena_path, arena_plan, model);
            }

            if (!arena_warm) {
                // A manifest without an exact-size matching arena, or an arena without its exact
                // manifest, is partial/stale derived state and is never reused.
                unlink(arena_path.c_str());
                unlink(arena_manifest_path.c_str());
                arena_cold = parakeet_create_weight_arena(
                    arena_transaction.data_temp,
                    arena_plan,
                    model
                );
            }
        }
    }

    if (!arena_warm && !arena_cold) {
        if (!parakeet_allocate_regular_weight_buffers(ctx_map, model)) {
            return false;
        }
    }
#else
    for (auto & entry : ctx_map) {
        ggml_backend_buffer_t buffer =
            ggml_backend_alloc_ctx_tensors_from_buft(entry.second, entry.first);
        if (buffer) {
            model.buffers.emplace_back(buffer);
            PARAKEET_LOG_INFO("%s: %12s total size = %8.2f MB\n",
                __func__, ggml_backend_buffer_name(buffer), ggml_backend_buffer_get_size(buffer) / 1e6);
        }
    }
#endif

#ifndef _WIN32
    if (arena_cold) {
        weight_records_offset = loader->tell(loader->context);
        if (weight_records_offset < 0) {
            PARAKEET_LOG_WARN("%s: loader cannot checkpoint arena payload; using ordinary buffers\n", __func__);
            parakeet_discard_mapped_weight_buffers(model, arena_plan);
            unlink(arena_transaction.data_temp.c_str());
            if (!parakeet_allocate_regular_weight_buffers(ctx_map, model)) {
                return false;
            }
            arena_cold = false;
        }
    }
#endif

    auto load_weight_records = [&]() -> bool {
        size_t total_size = 0;
        auto & tensors_map = model.tensors;
        int & n_loaded = model.n_loaded;
        n_loaded = 0;
        std::vector<char> read_buf;
        // VOICEOUR PATCH: q8_0 repack scratch and accounting.
        std::vector<float> convert_f32;
        std::vector<uint8_t> convert_q8_buf;
        int n_q8_converted = 0;
        size_t q8_source_bytes = 0;
        size_t q8_packed_bytes = 0;
        size_t record_index = 0;

        while (true) {
            parakeet_tensor_record source_record;
            std::string legacy_name;
            int64_t nelements = 1;

            if (has_record_directory) {
                if (record_index == tensor_records.size()) {
                    break;
                }
                if (!parakeet_read_tensor_record(
                        loader,
                        model_file_size,
                        expected_tensor_names,
                        source_record)) {
                    return false;
                }
                if (!parakeet_tensor_records_equal(
                        source_record,
                        tensor_records[record_index])) {
                    PARAKEET_LOG_ERROR(
                        "%s: tensor record %zu changed between directory and payload pass\n",
                        __func__,
                        record_index
                    );
                    return false;
                }
            } else {
                int32_t name_length = 0;
                int32_t type_id = 0;
                read_safe(loader, source_record.n_dims);
                read_safe(loader, name_length);
                read_safe(loader, type_id);

                if (loader->eof(loader->context)) {
                    break;
                }
                if (source_record.n_dims < 0 ||
                        source_record.n_dims > 4 ||
                        name_length <= 0 ||
                        name_length >= GGML_MAX_NAME) {
                    PARAKEET_LOG_ERROR("%s: invalid tensor header in model file\n", __func__);
                    return false;
                }
                if (type_id < 0 || type_id >= GGML_TYPE_COUNT) {
                    PARAKEET_LOG_ERROR(
                        "%s: invalid tensor type %d in model file\n",
                        __func__,
                        type_id
                    );
                    return false;
                }
                source_record.type = static_cast<ggml_type>(type_id);

                for (int i = 0; i < source_record.n_dims; ++i) {
                    read_safe(loader, source_record.ne[i]);
                    if (source_record.ne[i] <= 0 ||
                            nelements >
                                std::numeric_limits<int64_t>::max() /
                                source_record.ne[i]) {
                        PARAKEET_LOG_ERROR(
                            "%s: invalid tensor dimensions in model file\n",
                            __func__
                        );
                        return false;
                    }
                    nelements *= source_record.ne[i];
                }

                legacy_name.assign(static_cast<size_t>(name_length), '\0');
                if (loader->read(
                        loader->context,
                        legacy_name.data(),
                        legacy_name.size()) != legacy_name.size()) {
                    PARAKEET_LOG_ERROR("%s: truncated tensor name in model file\n", __func__);
                    return false;
                }
                if (!parakeet_is_valid_tensor_name(legacy_name)) {
                    PARAKEET_LOG_ERROR("%s: invalid tensor name in model file\n", __func__);
                    return false;
                }
                source_record.name = &legacy_name;
            }

            const auto found = tensors_map.find(*source_record.name);
            if (found == tensors_map.end()) {
                PARAKEET_LOG_ERROR(
                    "%s: unknown tensor '%s' in model file\n",
                    __func__,
                    source_record.name->c_str()
                );
                return false;
            }
            ggml_tensor * tensor = found->second;

            if (tensor->ne[0] != source_record.ne[0] ||
                    tensor->ne[1] != source_record.ne[1] ||
                    tensor->ne[2] != source_record.ne[2] ||
                    tensor->ne[3] != source_record.ne[3] ||
                    (!has_record_directory && ggml_nelements(tensor) != nelements)) {
                PARAKEET_LOG_ERROR(
                    "%s: tensor '%s' has the wrong shape in model file\n",
                    __func__,
                    source_record.name->c_str()
                );
                return false;
            }

            const size_t tensor_bytes = ggml_nbytes(tensor);
            size_t source_bytes = 0;
            // VOICEOUR PATCH: a repacked tail tensor is q8_0 in memory while its record
            // stays f16 on disk; the checks below compare against the f16 payload and the
            // read path quantizes.
            const bool convert_q8 =
                q8_converted_names.find(*source_record.name) != q8_converted_names.end();
            if (has_record_directory) {
                source_bytes = source_record.payload_bytes;
                if (!convert_q8 &&
                        record_authoritative_names.find(*source_record.name) !=
                            record_authoritative_names.end() &&
                        source_record.type != tensor->type) {
                    PARAKEET_LOG_ERROR(
                        "%s: authoritative tensor '%s' has the wrong type in model file\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
                if (convert_q8 && source_record.type != GGML_TYPE_F16) {
                    PARAKEET_LOG_ERROR(
                        "%s: repacked tensor '%s' is not f16 in model file\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
            } else {
                const size_t type_size = ggml_type_size(source_record.type);
                if (type_size == 0 ||
                        static_cast<uint64_t>(nelements) >
                            std::numeric_limits<size_t>::max() / type_size) {
                    PARAKEET_LOG_ERROR(
                        "%s: tensor '%s' byte count overflows\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
                const size_t unblocked_bytes =
                    static_cast<size_t>(nelements) * type_size;
                source_bytes = unblocked_bytes / ggml_blck_size(tensor->type);
            }
            const size_t expected_bytes = convert_q8
                ? static_cast<size_t>(ggml_nelements(tensor)) * sizeof(ggml_fp16_t)
                : tensor_bytes;
            if (source_bytes != expected_bytes) {
                PARAKEET_LOG_ERROR(
                    "%s: tensor '%s' has wrong byte size in model file\n",
                    __func__,
                    source_record.name->c_str()
                );
                return false;
            }

            if (arena_warm) {
                // The source model remains authoritative: the second metadata pass matched the
                // directory exactly. Only the already-materialised payload read is skipped.
                if (!loader->seek ||
                        source_bytes >
                            static_cast<size_t>(std::numeric_limits<int64_t>::max()) ||
                        !loader->seek(
                            loader->context,
                            static_cast<int64_t>(source_bytes),
                            SEEK_CUR)) {
                    PARAKEET_LOG_ERROR(
                        "%s: tensor '%s' payload seek exceeds model bounds\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
            } else if (convert_q8) {
                // VOICEOUR PATCH: read the f16 payload, quantize rows to q8_0, and place
                // the blocks. A cold arena then caches the quantized image, so warm loads
                // above skip this work entirely.
                read_buf.resize(source_bytes);
                if (loader->read(loader->context, read_buf.data(), read_buf.size()) !=
                        read_buf.size()) {
                    PARAKEET_LOG_ERROR(
                        "%s: truncated tensor '%s' payload\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
                const int64_t tensor_elements = ggml_nelements(tensor);
                convert_f32.resize(static_cast<size_t>(tensor_elements));
                ggml_fp16_to_fp32_row(
                    reinterpret_cast<const ggml_fp16_t *>(read_buf.data()),
                    convert_f32.data(),
                    tensor_elements);
                convert_q8_buf.resize(tensor_bytes);
                const size_t quantized_bytes = ggml_quantize_chunk(
                    GGML_TYPE_Q8_0,
                    convert_f32.data(),
                    convert_q8_buf.data(),
                    0,
                    tensor->ne[1],
                    tensor->ne[0],
                    nullptr);
                if (quantized_bytes != tensor_bytes) {
                    PARAKEET_LOG_ERROR(
                        "%s: tensor '%s' quantized to the wrong byte count\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
                if (ggml_backend_buffer_is_host(tensor->buffer)) {
                    memcpy(tensor->data, convert_q8_buf.data(), tensor_bytes);
#ifndef _WIN32
                    if (arena_cold && !parakeet_sync_weight_tensor(model, tensor)) {
                        PARAKEET_LOG_WARN(
                            "%s: cannot synchronise arena tensor '%s': %s\n",
                            __func__,
                            source_record.name->c_str(),
                            strerror(errno)
                        );
                        arena_cache_failed = true;
                        return false;
                    }
#endif
                } else {
                    ggml_backend_tensor_set(tensor, convert_q8_buf.data(), 0, tensor_bytes);
                }
                n_q8_converted += 1;
                q8_source_bytes += source_bytes;
                q8_packed_bytes += tensor_bytes;
            } else if (ggml_backend_buffer_is_host(tensor->buffer)) {
                if (loader->read(loader->context, tensor->data, source_bytes) != source_bytes) {
                    PARAKEET_LOG_ERROR(
                        "%s: truncated tensor '%s' payload\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
                BYTESWAP_TENSOR(tensor);
#ifndef _WIN32
                if (arena_cold && !parakeet_sync_weight_tensor(model, tensor)) {
                    PARAKEET_LOG_WARN(
                        "%s: cannot synchronise arena tensor '%s': %s\n",
                        __func__,
                        source_record.name->c_str(),
                        strerror(errno)
                    );
                    arena_cache_failed = true;
                    return false;
                }
#endif
            } else {
                read_buf.resize(source_bytes);
                if (loader->read(loader->context, read_buf.data(), read_buf.size()) !=
                        read_buf.size()) {
                    PARAKEET_LOG_ERROR(
                        "%s: truncated tensor '%s' payload\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
                ggml_backend_tensor_set(tensor, read_buf.data(), 0, source_bytes);
            }

            if (has_record_directory) {
                const int64_t expected_offset =
                    source_record.payload_offset + static_cast<int64_t>(source_bytes);
                if (loader->tell(loader->context) != expected_offset) {
                    PARAKEET_LOG_ERROR(
                        "%s: tensor '%s' payload ended at the wrong offset\n",
                        __func__,
                        source_record.name->c_str()
                    );
                    return false;
                }
            }
            if (tensor_bytes > std::numeric_limits<size_t>::max() - total_size) {
                PARAKEET_LOG_ERROR("%s: total model byte count overflows\n", __func__);
                return false;
            }
            total_size += tensor_bytes;
            ++n_loaded;
            ++record_index;
        }

        if (has_record_directory &&
                (record_index != tensor_records.size() ||
                    loader->tell(loader->context) != model_file_size)) {
            PARAKEET_LOG_ERROR("%s: tensor payload pass did not end at model EOF\n", __func__);
            return false;
        }

        PARAKEET_LOG_INFO("%s: model size    = %7.2f MB\n", __func__, total_size / 1e6);
        // VOICEOUR PATCH: a requested repack that converted nothing would silently
        // measure the f16 tail; fail loudly instead. Two convert-nothing cases are
        // legitimate: a warm arena (image already quantized) and a model whose tail
        // records ship quantized (the q8_0 GGUF variant).
        if (wctx.params.tail_backend_cpu && wctx.params.tail_quant_q8 && n_loaded > 0) {
            if (arena_warm) {
                PARAKEET_LOG_INFO(
                    "%s: tail q8_0 repack: warm arena already quantized\n", __func__);
            } else if (n_q8_converted == 0 && n_tail_already_quantized > 0) {
                PARAKEET_LOG_INFO(
                    "%s: tail q8_0 repack: %d tail records already quantized in model file; no-op\n",
                    __func__,
                    n_tail_already_quantized);
            } else if (n_q8_converted == 0) {
                PARAKEET_LOG_ERROR(
                    "%s: tail q8_0 repack requested but no record converted\n", __func__);
                return false;
            } else {
                PARAKEET_LOG_INFO(
                    "%s: tail q8_0 repack: %d records, %.2f MB -> %.2f MB\n",
                    __func__,
                    n_q8_converted,
                    q8_source_bytes / 1e6,
                    q8_packed_bytes / 1e6);
            }
        }
        if (n_loaded == 0) {
            PARAKEET_LOG_WARN(
                "%s: WARN no tensors loaded from model file - assuming empty model for testing\n",
                __func__
            );
        } else if (n_loaded != static_cast<int>(tensors_map.size())) {
            PARAKEET_LOG_ERROR(
                "%s: ERROR not all tensors loaded from model file - expected %zu, got %d\n",
                __func__,
                tensors_map.size(),
                n_loaded
            );
            return false;
        }
        return true;
    };

    // VOICEOUR PATCH: the bias-variant variance fix-up must land on freshly read
    // payloads and be persisted by the arena commit below; a warm arena already
    // carries folded values, so folding there would drift 1e-5 per process.
    auto fold_bias_variant_bn_eps = [&]() {
        if (optional_bias_created == 0) { return; }
        const float bn_eps = 1e-5f;
        std::vector<float> var_data(hparams.n_audio_state);
        for (auto & layer : model.layers) {
            if (!layer.conv_bn_var) { continue; }
            ggml_backend_tensor_get(
                layer.conv_bn_var, var_data.data(), 0, var_data.size() * sizeof(float));
            for (float & v : var_data) { v += bn_eps; }
            ggml_backend_tensor_set(
                layer.conv_bn_var, var_data.data(), 0, var_data.size() * sizeof(float));
#ifndef _WIN32
            if (arena_cold && !parakeet_sync_weight_tensor(model, layer.conv_bn_var)) {
                PARAKEET_LOG_WARN("%s: cannot synchronise folded bn variance\n", __func__);
            }
#endif
        }
        PARAKEET_LOG_INFO("%s: folded batch-norm eps for bias-variant checkpoint\n", __func__);
    };

    bool weights_loaded = !arena_cache_failed && load_weight_records();
    if (weights_loaded && !arena_warm) {
        fold_bias_variant_bn_eps();
    }

#ifndef _WIN32
    if (weights_loaded && arena_cold) {
        if (!parakeet_commit_weight_arena(
                arena_path,
                arena_manifest_path,
                arena_transaction,
                arena_manifest,
                model)) {
            PARAKEET_LOG_WARN("%s: arena commit failed; reloading into ordinary buffers\n", __func__);
            arena_cache_failed = true;
            weights_loaded = false;
        }
    }

    if (!weights_loaded && arena_cold && arena_cache_failed) {
        // This is a derived-cache failure, not a model failure. Discard every mapped wrapper
        // before munmap/close, rewind to the first tensor record, then exercise the unchanged
        // ordinary allocation/load path.
        parakeet_discard_mapped_weight_buffers(model, arena_plan);
        unlink(arena_transaction.data_temp.c_str());
        unlink(arena_transaction.manifest_temp.c_str());
        unlink(arena_path.c_str());
        unlink(arena_manifest_path.c_str());
        if (!parakeet_allocate_regular_weight_buffers(ctx_map, model) ||
                weight_records_offset < 0 ||
                !loader->seek(loader->context, weight_records_offset, SEEK_SET)) {
            return false;
        }
        arena_cold = false;
        arena_cache_failed = false;
        weights_loaded = load_weight_records();
        if (weights_loaded) {
            fold_bias_variant_bn_eps();
        }
    }
#endif

    if (!weights_loaded) {
        return false;
    }

    auto & buffers = wctx.model.buffers;
    for (auto & buf : buffers) {
        ggml_backend_buffer_set_usage(buf, GGML_BACKEND_BUFFER_USAGE_WEIGHTS);
    }

    // VOICEOUR PATCH: fold PyTorch BatchNorm1d's eps (1e-5) into the conv batch-norm
    // running variance for bias-variant Conformer checkpoints (parakeet-tdt-1.1b). The
    // graph computes sqrt(var) with no eps term; the pinned bias-free checkpoints have
    // no near-zero variance channel so their historical arithmetic is untouched, but
    // the 1.1b carries fp16-rounded zero (and one negative-epsilon) channels whose
    // unprotected rsqrt poisons every later layer with NaN. The fold ran above, before
    // the arena commit, so a committed arena persists the corrected variance and a
    // warm arena load must never fold again (see `fold_bias_variant_bn_eps`).

    wctx.t_load_us = ggml_time_us() - t_start_us;

    return true;
}

// VOICEOUR PATCH: a 2-D convolution that stops before the copy `ggml_conv_2d` ends with, and
// lets the bias add every one of this encoder's convolutions performs next materialise the
// layout instead.
//
// `ggml_conv_2d` finishes with `ggml_cont(ggml_permute(result, 0, 1, 3, 2))`. That permutation
// leaves dim 0 in place, so the view is row-contiguous, and ggml-metal's binary ops require only
// row contiguity — while the bias add writes a dense tensor of the same shape regardless. The
// copy therefore wrote the whole convolution result an extra time for nothing. Measured by
// per-op-class skipping restricted to the subsampling encode context: its copies cost 8.91 ms of
// a 155 ms encode.
//
// Composed from the same public ggml ops in the same order as `ggml_conv_2d`, so the arithmetic
// is unchanged; `ggml_conv_2d` itself keeps its contract for any other caller.
static struct ggml_tensor * parakeet_conv_2d_bias(
        struct ggml_context * ctx0,
         struct ggml_tensor * w,
         struct ggml_tensor * x,
         struct ggml_tensor * bias,
                        int   s0,
                        int   s1,
                        int   p0,
                        int   p1,
                        int   d0,
                        int   d1) {
    const enum ggml_type itype = w->type == GGML_TYPE_BF16 ? GGML_TYPE_F32 : GGML_TYPE_F16;

    struct ggml_tensor * lhs;
    int64_t OW;
    int64_t OH;

    // VOICEOUR PATCH: a 1x1 kernel at unit stride and dilation with no padding needs no
    // `ggml_im2col` — that call reduces to a transpose and a cast, which is what this branch
    // does instead.
    //
    // im2col writes `dst[c, oh*OW + ow] = x[c*IW*IH + oh*IW + ow]`, and with `OW == IW` and
    // `OH == IH` that is exactly `transpose(x)` over the [IW*IH, IC] view, converted to the
    // matmul's input type. Identical values: both paths round the same f32 elements to f16 with
    // Metal's round-to-nearest-even.
    //
    // The reason to care is the dispatch. `ggml_metal_op_im2col` sizes its threadgroup as
    // `(min(max_threads/(KH*KW), N), KH, KW)` and its grid as `(IC, OH, OW)`. Single-utterance
    // inference has N == 1, so a pointwise kernel gets threadgroups of exactly one thread over a
    // grid of IC*OH*OW — 7.2 million one-thread threadgroups for the first of these two
    // convolutions, at roughly 3% SIMD occupancy. Measured: im2col cost 23.66 ms of a 147 ms
    // encode, essentially all of it here, while moving only ~56 MB.
    if (w->ne[0] == 1 && w->ne[1] == 1 &&
        s0 == 1 && s1 == 1 && p0 == 0 && p1 == 0 && d0 == 1 && d1 == 1 && x->ne[3] == 1) {
        OW = x->ne[0];
        OH = x->ne[1];

        struct ggml_tensor * planes = ggml_reshape_2d(ctx0, x, x->ne[0] * x->ne[1], x->ne[2]);
        lhs = ggml_cast(ctx0, ggml_transpose(ctx0, planes), itype);
    } else {
        struct ggml_tensor * im2col = ggml_im2col(ctx0, w, x, s0, s1, p0, p1, d0, d1, true, itype);

        OW = im2col->ne[1];
        OH = im2col->ne[2];

        lhs = ggml_reshape_2d(ctx0, im2col, im2col->ne[0],
                im2col->ne[3] * im2col->ne[2] * im2col->ne[1]);
    }

    struct ggml_tensor * result = ggml_mul_mat(ctx0, lhs,
            ggml_reshape_2d(ctx0, w, w->ne[0] * w->ne[1] * w->ne[2], w->ne[3]));

    result = ggml_reshape_4d(ctx0, result, OW, OH, x->ne[3], w->ne[3]);
    result = ggml_permute(ctx0, result, 0, 1, 3, 2);

    return ggml_add(ctx0, result, bias);
}

// conv subsampling + conformer encoder
static struct ggml_cgraph * parakeet_build_graph_encode(parakeet_context & pctx, parakeet_state & pstate) {
    const auto & model    = pctx.model;
    const auto & hparams  = model.hparams;
    const int n_mel_time  = pstate.n_audio_ctx > 0 ? pstate.n_audio_ctx : hparams.n_audio_ctx;
    const int n_mels      = hparams.n_mels;
    const int n_layer     = hparams.n_audio_layer;
    const int n_state     = hparams.n_audio_state;
    const float fc_factor = 0.5f;

    struct ggml_init_params params = {
        /*.mem_size   =*/ pstate.sched_encode.meta.size(),
        /*.mem_buffer =*/ pstate.sched_encode.meta.data(),
        /*.no_alloc   =*/ true,
    };

    struct ggml_context * ctx0 = ggml_init(params);
    ggml_cgraph * gf = ggml_new_graph_custom(ctx0, PARAKEET_MAX_NODES, false);

    // Conv subsampling

    // [freq, time]
    struct ggml_tensor * mel = ggml_new_tensor_4d(ctx0, GGML_TYPE_F32, n_mels, n_mel_time, 1, 1);
    ggml_set_name(mel, "mel");
    ggml_set_input(mel);

    // VOICEOUR PATCH: causal dw-striding pads each frequency/time axis with
    // two leading and one trailing zero before every stride-2 3x3 convolution.
    auto causal_pad_2d = [&](ggml_tensor * input) {
        if (!model.spk_ff1_w) { return input; }
        ggml_tensor * padded = ggml_pad(ctx0, input, 3, 3, 0, 0);
        padded = ggml_roll(ctx0, padded, 2, 0, 0, 0);
        return ggml_roll(ctx0, padded, 0, 2, 0, 0);
    };
    const int stride_padding = model.spk_ff1_w ? 0 : 1;

    // [freq, time, channels, batch]
    struct ggml_tensor * cur = parakeet_conv_2d_bias(
        ctx0,
        model.enc_pre_conv_0_w,
        causal_pad_2d(mel),
        model.enc_pre_conv_0_b,
        2, 2, stride_padding, stride_padding, 1, 1
    );
    ggml_set_name(cur, "pre_conv_0");

    cur = ggml_relu(ctx0, cur);
    ggml_set_name(cur, "pre_conv_0_relu");

    // [freq, time, channels, batch]
    cur = ggml_conv_2d_dw_direct(
        ctx0,
        model.enc_pre_conv_2_w,
        causal_pad_2d(cur),
        2, 2, stride_padding, stride_padding, 1, 1
    );
    cur = ggml_add(ctx0, cur, model.enc_pre_conv_2_b);
    ggml_set_name(cur, "pre_conv_2");

    // [freq, time, channels, batch]
    cur = parakeet_conv_2d_bias(ctx0, model.enc_pre_conv_3_w, cur,
            model.enc_pre_conv_3_b, 1, 1, 0, 0, 1, 1);
    ggml_set_name(cur, "pre_conv_3");

    cur = ggml_relu(ctx0, cur);
    ggml_set_name(cur, "pre_conv_3_relu");

    // [freq, time, channels, batch]
    cur = ggml_conv_2d_dw_direct(
        ctx0,
        model.enc_pre_conv_5_w,
        causal_pad_2d(cur),
        2, 2, stride_padding, stride_padding, 1, 1
    );
    ggml_set_name(cur, "pre_conv_5_direct");
    cur = ggml_add(ctx0, cur, model.enc_pre_conv_5_b);
    ggml_set_name(cur, "pre_conv_5");

    // [freq, time, channels, batch]
    cur = parakeet_conv_2d_bias(ctx0, model.enc_pre_conv_6_w, cur,
            model.enc_pre_conv_6_b, 1, 1, 0, 0, 1, 1);
    ggml_set_name(cur, "pre_conv_6");

    cur = ggml_relu(ctx0, cur);
    ggml_set_name(cur, "pre_conv_6_relu");

    // [freq, time, chan]
    cur = ggml_permute(ctx0, cur, 0, 2, 1, 3);
    // [freq, chan, time]
    cur = ggml_cont(ctx0, cur);

    const int n_freq   = cur->ne[0]; // 16
    const int n_chan   = cur->ne[1]; // 256
    const int n_frames = cur->ne[2]; // time

    // [freq, time, chan, batch] -> [(freq * chan), time]
    cur = ggml_reshape_2d(ctx0, cur, n_freq * n_chan, n_frames);

    cur = ggml_mul_mat(ctx0, model.enc_pre_out_w, cur);
    cur = ggml_add(ctx0, cur, model.enc_pre_out_b);

    ggml_set_name(cur, "pre_enc_out");

    // VOICEOUR PATCH: multitalker single-speaker mode uses an all-ones speaker
    // mask, so its layer-0 hook is exactly this residual FF transform. Dropout
    // is disabled at inference.
    if (model.spk_ff1_w) {
        struct ggml_tensor * speaker = ggml_mul_mat(ctx0, model.spk_ff1_w, cur);
        speaker = ggml_add(ctx0, speaker, model.spk_ff1_b);
        speaker = ggml_relu(ctx0, speaker);
        speaker = ggml_mul_mat(ctx0, model.spk_ff2_w, speaker);
        speaker = ggml_add(ctx0, speaker, model.spk_ff2_b);
        cur = ggml_add(ctx0, cur, speaker);
        ggml_set_name(cur, "speaker_kernel_out");
        // Background targets are absent in single-speaker transcription, so
        // their mask is zero. The biased FF kernel still contributes a learned
        // constant residual and must not be dropped.
        struct ggml_tensor * background = ggml_scale(ctx0, cur, 0.0f);
        background = ggml_mul_mat(ctx0, model.bg_spk_ff1_w, background);
        background = ggml_add(ctx0, background, model.bg_spk_ff1_b);
        background = ggml_relu(ctx0, background);
        background = ggml_mul_mat(ctx0, model.bg_spk_ff2_w, background);
        background = ggml_add(ctx0, background, model.bg_spk_ff2_b);
        cur = ggml_add(ctx0, cur, background);
        ggml_set_name(cur, "background_speaker_kernel_out");
    }

    // Encoder
    // cur: [n_state, n_enc_time]

    const int  n_time      = cur->ne[1];
    const bool local_attn  = n_time > PARAKEET_LOCAL_ATTN_THRESHOLD;
    const int  att_left    = local_attn ? PARAKEET_LOCAL_ATTN_WINDOW : n_time - 1;
    const int  att_right   = local_attn ? PARAKEET_LOCAL_ATTN_WINDOW : n_time - 1;
    const int  window_size = local_attn ? att_left + att_right + 1 : 2 * n_time - 1;
    const int  d_half      = n_state / 2;
    const int  mask_dim    = local_attn ? window_size : n_time;

    // mask [key, n_time]
    struct ggml_tensor * attn_mask = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, mask_dim, n_time);
    ggml_set_name(attn_mask, "attn_mask");
    ggml_set_input(attn_mask);

    struct ggml_tensor * local_mask = nullptr;
    if (local_attn) {
        const int chunk = att_left + att_right;
        local_mask = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, chunk + window_size - 1, chunk);
        ggml_set_name(local_mask, "local_mask");
        ggml_set_input(local_mask);
    }

    struct ggml_tensor * pos_freqs = ggml_new_tensor_1d(ctx0, GGML_TYPE_F32, d_half);
    ggml_set_name(pos_freqs, "pos_freqs");
    ggml_set_input(pos_freqs);

    struct ggml_tensor * rel_positions = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, 1, window_size);
    ggml_set_name(rel_positions, "rel_positions");
    ggml_set_input(rel_positions);

    struct ggml_tensor * freqs = ggml_repeat_4d(ctx0, pos_freqs, d_half, window_size, 1, 1);
    struct ggml_tensor * theta = ggml_mul(ctx0, freqs, rel_positions);

    struct ggml_tensor * sin_t = ggml_reshape_3d(ctx0, ggml_sin(ctx0, theta), 1, d_half, window_size);
    struct ggml_tensor * cos_t = ggml_reshape_3d(ctx0, ggml_cos(ctx0, theta), 1, d_half, window_size);
    // [n_state, window_size]
    struct ggml_tensor * pos_emb = ggml_reshape_2d(ctx0, ggml_cont(ctx0, ggml_concat(ctx0, sin_t, cos_t, 0)), n_state, window_size);
    ggml_set_name(pos_emb, "pos_emb");

    for (int il = 0; il < n_layer; ++il) {
        const auto & layer = model.layers[il];

        // FFN1
        {
            struct ggml_tensor * residual = cur;
            ggml_format_name(cur, "enc_%d_res", il);

            // norm
            cur = ggml_norm(ctx0, cur, hparams.eps);
            cur = ggml_add(ctx0, ggml_mul(ctx0, cur, layer.norm_ff1_w), layer.norm_ff1_b);
            ggml_format_name(cur, "enc_%d_ffn_norm_1", il);

            // ffn_1
            // VOICEOUR PATCH: optional linear biases for the bias-variant Conformer
            // checkpoints; nullptr for the pinned files keeps the graph unchanged.
            cur = ggml_mul_mat(ctx0, layer.ff1_linear1_w, cur);
            if (layer.ff1_linear1_b) {
                cur = ggml_add(ctx0, cur, layer.ff1_linear1_b);
            }
            cur = ggml_silu(ctx0, cur);
            ggml_format_name(cur, "enc_%d_silu", il);

            cur = ggml_mul_mat(ctx0, layer.ff1_linear2_w, cur);
            if (layer.ff1_linear2_b) {
                cur = ggml_add(ctx0, cur, layer.ff1_linear2_b);
            }
            ggml_format_name(cur, "enc_%d_ffn_1", il);

            cur = ggml_add(ctx0, residual, ggml_scale(ctx0, cur, fc_factor));
            ggml_format_name(cur, "enc_%d_res_ffn", il);
        }

        // self attention block using relative positional encoding computed in graph.
        {
            // [feat, time_frames, 1, 1]
            struct ggml_tensor * residual = cur;

            cur = ggml_norm(ctx0, cur, hparams.eps);
            cur = ggml_add(ctx0, ggml_mul(ctx0, cur, layer.norm_attn_w), layer.norm_attn_b);
            ggml_format_name(cur, "enc_%d_attn_norm", il);

            const int n_head = hparams.n_audio_head;
            const int d_head = n_state / n_head;

            // [feat, time_frames, 1, 1]
            struct ggml_tensor * Q_cur = ggml_mul_mat(ctx0, layer.attn_q_w, cur);
            struct ggml_tensor * K_cur = ggml_mul_mat(ctx0, layer.attn_k_w, cur);
            struct ggml_tensor * V_cur = ggml_mul_mat(ctx0, layer.attn_v_w, cur);
            // VOICEOUR PATCH: optional attention projection biases, added while the
            // projections are still [feat, time] so the 1-D bias broadcasts per feature.
            if (layer.attn_q_b) {
                Q_cur = ggml_add(ctx0, Q_cur, layer.attn_q_b);
            }
            if (layer.attn_k_b) {
                K_cur = ggml_add(ctx0, K_cur, layer.attn_k_b);
            }
            if (layer.attn_v_b) {
                V_cur = ggml_add(ctx0, V_cur, layer.attn_v_b);
            }

            Q_cur = ggml_reshape_3d(ctx0, Q_cur, d_head, n_head, n_time);
            K_cur = ggml_reshape_3d(ctx0, K_cur, d_head, n_head, n_time);
            V_cur = ggml_reshape_3d(ctx0, V_cur, d_head, n_head, n_time);

            struct ggml_tensor * pos = ggml_mul_mat(ctx0, layer.attn_pos_w, pos_emb);
            pos = ggml_reshape_3d(ctx0, pos, d_head, n_head, window_size);
            // VOICEOUR PATCH: keep the relative-position projection a permuted view. The dense
            // branch below feeds it straight to `ggml_mul_mat`, exactly as it already does with
            // the un-materialised `K_prep`/`Q_prep` views for the content scores; only the
            // local-attention branch still materialises it, at its own use site, so that
            // (untestable on any input this app can produce) path stays byte-identical.
            pos = ggml_permute(ctx0, pos, 0, 2, 1, 3);

            if (local_attn) {
                const int  chunk         = att_left + att_right;
                const int  n_group       = (n_time + chunk - 1) / chunk;
                const int  n_time_padded = n_group * chunk;
                const int  n_kv_chunk    = chunk + window_size - 1;
                const int  n_kv_dense    = n_kv_chunk * n_group;
                const bool need_padding  = n_time_padded > n_time;

                Q_cur = ggml_cont(ctx0, ggml_permute(ctx0, Q_cur, 0, 2, 1, 3));
                K_cur = ggml_cont(ctx0, ggml_permute(ctx0, K_cur, 0, 2, 1, 3));
                V_cur = ggml_cont(ctx0, ggml_permute(ctx0, V_cur, 0, 2, 1, 3));

                // content bias
                struct ggml_tensor * bias_u = ggml_reshape_3d(ctx0, layer.attn_pos_bias_u, d_head, 1, n_head);
                struct ggml_tensor * Q_u = ggml_add(ctx0, Q_cur, bias_u);

                // position bias
                struct ggml_tensor * bias_v = ggml_reshape_3d(ctx0, layer.attn_pos_bias_v, d_head, 1, n_head);
                struct ggml_tensor * Q_v = ggml_add(ctx0, Q_cur, bias_v);

                // right pad the time_frame.
                struct ggml_tensor * Q_u_padded = need_padding ?
                    ggml_pad_ext(ctx0, Q_u, 0, 0, 0, n_time_padded - n_time, 0, 0, 0, 0) : Q_u;
                Q_u_padded = ggml_reshape_4d(ctx0, Q_u_padded, d_head, chunk, n_group, n_head);

                // Add padding to front and back (for the first timeframe and the last timeframe).
                struct ggml_tensor * K_padded = ggml_pad_ext(ctx0, K_cur, 0, 0, att_left, att_right, 0, 0, 0, 0);

                // pad time axis to match n_kv_dense if needed.
                if (n_kv_dense > K_padded->ne[1]) {
                    K_padded = ggml_pad_ext(ctx0, K_padded, 0, 0, 0, n_kv_dense - K_padded->ne[1], 0, 0, 0, 0);
                }

                // Create a 4d tensor where each group spans a wide window of
                // 512 keys (n_kv_chunk), but moving to the next group (nb[2])
                // only jumps forward by 256 frames (chunk * nb[1]). This creates
                // a 256 frame overlap, shared keys in RAM without copies.
                struct ggml_tensor * K_chunk = ggml_view_4d(ctx0, K_padded,
                        d_head, n_kv_chunk, n_group, n_head,
                        K_padded->nb[1],
                        (size_t) chunk * K_padded->nb[1],
                        K_padded->nb[2],
                        0);
                K_chunk = ggml_cont(ctx0, K_chunk);

                struct ggml_tensor * content_scores = ggml_mul_mat(ctx0, K_chunk, Q_u_padded);

                // The above mul_mat operation, combined with K_chunk's overlapping
                // frames, produces a dense matrix. But some of the results in
                // this matrix were computed for keys that aren't part of that
                // query's window. So we shift each row to keep only the results
                // that we want.
                content_scores = ggml_view_4d(ctx0, content_scores,
                        window_size, chunk, n_group, n_head,
                        (size_t) (chunk + window_size) * content_scores->nb[0],
                        content_scores->nb[2],
                        content_scores->nb[3],
                        0);
                content_scores = ggml_cont(ctx0, content_scores);

                // ungrouping.
                content_scores = ggml_reshape_3d(ctx0, content_scores, window_size, n_time_padded, n_head);

                // remove padding if padding was applied (truncating to n_time).
                if (need_padding) {
                    content_scores = ggml_view_3d(ctx0, content_scores,
                            window_size, n_time, n_head,
                            content_scores->nb[1],
                            content_scores->nb[2],
                            0);
                }

                struct ggml_tensor * rel_pos_scores = ggml_mul_mat(ctx0, ggml_cont(ctx0, pos), Q_v);

                // attention_score = content similarity + relative position scores
                struct ggml_tensor * attn_scores = ggml_add(ctx0, content_scores, rel_pos_scores);

                attn_scores = ggml_soft_max_ext(ctx0, attn_scores, attn_mask, 1.0f / std::sqrt(d_head), 0.0f);

                // right pad the probabilites.
                struct ggml_tensor * probs_padded = need_padding ?
                    ggml_pad_ext(ctx0, attn_scores, 0, 0, 0, n_time_padded - n_time, 0, 0, 0, 0) : attn_scores;

                probs_padded = ggml_reshape_4d(ctx0, probs_padded, window_size, chunk, n_group, n_head);
                probs_padded = ggml_pad_ext(ctx0, probs_padded, 0, chunk, 0, 0, 0, 0, 0, 0);
                probs_padded = ggml_view_4d(ctx0, probs_padded,
                        n_kv_chunk, chunk, n_group, n_head,
                        (size_t) n_kv_chunk * probs_padded->nb[0],
                        probs_padded->nb[2],
                        probs_padded->nb[3],
                        0);
                probs_padded = ggml_cont(ctx0, probs_padded);
                probs_padded = ggml_mul(ctx0, probs_padded, local_mask);

                // Add padding to front and back (for the first timeframe and the last timeframe).
                struct ggml_tensor * V_padded = ggml_pad_ext(ctx0, V_cur, 0, 0, att_left, att_right, 0, 0, 0, 0);

                // pad time axis to match n_kv_dense if needed.
                if (n_kv_dense > V_padded->ne[1]) {
                    V_padded = ggml_pad_ext(ctx0, V_padded, 0, 0, 0, n_kv_dense - V_padded->ne[1], 0, 0, 0, 0);
                }

                V_padded = ggml_cont(ctx0, ggml_transpose(ctx0, V_padded));

                struct ggml_tensor * V_chunk = ggml_view_4d(ctx0, V_padded,
                        n_kv_chunk, d_head, n_group, n_head,
                        V_padded->nb[1],
                        (size_t) chunk * V_padded->nb[0],
                        V_padded->nb[2],
                        0);
                V_chunk = ggml_cont(ctx0, V_chunk);

                cur = ggml_mul_mat(ctx0, V_chunk, probs_padded);
                // ungroup.
                cur = ggml_reshape_3d(ctx0, cur, d_head, n_time_padded, n_head);
                // unpad
                if (need_padding) {
                    cur = ggml_view_3d(ctx0, cur, d_head, n_time, n_head, cur->nb[1], cur->nb[2], 0);
                }

                cur = ggml_cont(ctx0, ggml_permute(ctx0, cur, 0, 2, 1, 3));
                cur = ggml_reshape_2d(ctx0, cur, n_state, n_time);
                cur = ggml_mul_mat(ctx0, layer.attn_out_w, cur);
            } else {
                struct ggml_tensor * Q_u = ggml_add(ctx0, Q_cur, layer.attn_pos_bias_u);
                ggml_format_name(Q_u, "enc_%d_attn_q_u", il);

                struct ggml_tensor * K_prep = ggml_permute(ctx0, K_cur, 0, 2, 1, 3);
                struct ggml_tensor * Q_prep = ggml_permute(ctx0, Q_u,   0, 2, 1, 3);
                struct ggml_tensor * content_scores = ggml_mul_mat(ctx0, K_prep, Q_prep);
                ggml_format_name(content_scores, "enc_%d_attn_content_scores", il);

                struct ggml_tensor * Q_v = ggml_add(ctx0, Q_cur, layer.attn_pos_bias_v);
                ggml_format_name(Q_v, "enc_%d_attn_q_v", il);

                // VOICEOUR PATCH: no `ggml_cont` here either. This is the same permutation of
                // the same shape that `Q_prep` twelve lines above already hands to
                // `ggml_mul_mat` un-materialised for the content scores; upstream copied it
                // only on this operand.
                Q_v = ggml_permute(ctx0, Q_v, 0, 2, 1, 3);
                ggml_format_name(Q_v, "enc_%d_attn_q_v_perm", il);

                struct ggml_tensor * rel_pos_scores = ggml_mul_mat(ctx0, pos, Q_v);
                ggml_format_name(rel_pos_scores, "enc_%d_attn_rel_pos", il);

                // Relative position shifting is performed in the following block.
                // Some more details on the operations performed below can be found here:
                // https://github.com/danbev/learning-ai/blob/main/notes/whisper/parakeet.md#relative-position-shift
                {
                    const auto pos_window = rel_pos_scores->ne[0];
                    const auto n_frame    = rel_pos_scores->ne[1];
                    const auto n_head_cur = rel_pos_scores->ne[2];

                    rel_pos_scores = ggml_pad(ctx0, rel_pos_scores, 1, 0, 0, 0);

                    rel_pos_scores = ggml_reshape_3d(ctx0, rel_pos_scores, n_frame, pos_window + 1, n_head_cur);
                    ggml_format_name(rel_pos_scores, "enc_%d_attn_rel_pos_reshaped", il);

                    const int center = pos_window / 2;

                    // VOICEOUR PATCH: fold the shift's `ggml_roll` into this view's offset.
                    //
                    // `ggml_pad` appends one zero to each row, making the row pitch
                    // `pos_window + 1` while the payload stays `pos_window` long; the view below
                    // then walks rows with the shorter `pos_window` stride, which is what
                    // advances one position per query and produces the relative-position shift.
                    // Upstream additionally rolled dim 0 by one so the appended zero moved to the
                    // front, and then started the view one element later to skip it.
                    //
                    // Rolling the payload forward by one and then reading one element later is
                    // the identity. Reading from `center` instead of `center + 1` against the
                    // unrolled buffer selects, for output element (key k, query q), relative
                    // position `center + k - q` — the same index the rolled form selected, as the
                    // flat arithmetic shows: `center + q*pos_window + k = q*(pos_window + 1) + j`
                    // gives `j = center + k - q` either way. With `k, q` in `[0, n_frame)` and
                    // `n_frame - 1 == center`, `j` stays inside `[0, pos_window)`, so neither
                    // form ever reads the appended zero — it exists only to set the row pitch.
                    // Value-preserving: the same elements are read, so no arithmetic changes.
                    const size_t offset = rel_pos_scores->nb[0] * center;

                    rel_pos_scores = ggml_view_3d(ctx0, rel_pos_scores,
                                                  n_frame, pos_window, n_head_cur,
                                                  (pos_window) * 4,
                                                  rel_pos_scores->nb[2],
                                                  offset);

                    ggml_format_name(rel_pos_scores, "enc_%d_attn_rel_pos_shifted", il);

                    rel_pos_scores = ggml_view_3d(ctx0, rel_pos_scores,
                                                  content_scores->ne[0],
                                                  content_scores->ne[1],
                                                  rel_pos_scores->ne[2],
                                                  rel_pos_scores->nb[1],
                                                  rel_pos_scores->nb[2],
                                                  0);
                    // VOICEOUR PATCH: consume the relative-position shift as a strided view
                    // instead of materialising it.
                    //
                    // The two views above implement the rel-shift by deliberately reading the
                    // [2T-1, T] score block with a row stride of `pos_window` while using only
                    // the first `T` values of each row. Upstream then copies that into a fresh
                    // contiguous tensor purely so the following `ggml_add` sees a dense operand.
                    // ggml-metal's binary ops only require `ggml_is_contiguous_rows`, and this
                    // view satisfies it — `nb[0]` is one element; only the row stride has a gap.
                    // So the copy is pure overhead: at 24 layers x [n_time, n_time, n_head] f32
                    // it writes and re-reads ~290 MB per utterance, and `CONT` is the single
                    // most expensive op class in the encoder (27.8 ms of 171.9 ms measured by
                    // per-op-class skipping).
                    //
                    // Value-preserving by construction: a copy is removed, and the add reads
                    // exactly the elements the copy would have handed it.
                    ggml_format_name(rel_pos_scores, "enc_%d_attn_rel_pos_shifted_view", il);
                }

                struct ggml_tensor * attn_scores = ggml_add(ctx0, content_scores, rel_pos_scores);
                ggml_format_name(attn_scores, "enc_%d_attn_scores", il);
                attn_scores = ggml_scale(ctx0, attn_scores, 1.0f / std::sqrt(d_head));
                attn_scores = ggml_add(ctx0, attn_scores, attn_mask);
                ggml_format_name(attn_scores, "enc_%d_attn_scores_scaled", il);

                struct ggml_tensor * probs = ggml_soft_max(ctx0, attn_scores);
                ggml_format_name(probs, "enc_%d_attn_probs", il);

                V_cur = ggml_cont(ctx0, ggml_permute(ctx0, V_cur, 1, 2, 0, 3));
                ggml_format_name(V_cur, "enc_%d_attn_v_cur", il);
                cur = ggml_mul_mat(ctx0, probs, V_cur);
                ggml_format_name(cur, "enc_%d_attn_inp", il);

                cur = ggml_permute(ctx0, cur, 2, 0, 1, 3);
                cur = ggml_cont_2d(ctx0, cur, n_state, n_time);
                cur = ggml_mul_mat(ctx0, layer.attn_out_w, cur);
            }
            // VOICEOUR PATCH: optional attention output bias, shared by both branches.
            if (layer.attn_out_b) {
                cur = ggml_add(ctx0, cur, layer.attn_out_b);
            }
            ggml_format_name(cur, "enc_%d_attn_out", il);

            cur = ggml_add(ctx0, residual, cur);
            ggml_format_name(cur, "enc_%d_attn_res", il);
        }

        // Convolution
        {
            struct ggml_tensor * residual = cur;
            ggml_format_name(cur, "enc_%d_residual_conv", il);

            cur = ggml_norm(ctx0, cur, hparams.eps);
            cur = ggml_add(ctx0, ggml_mul(ctx0, cur, layer.norm_conv_w), layer.norm_conv_b);
            ggml_format_name(cur, "enc_%d_norm_conv", il);

            // pointwise 1d convolution: [1024, 138] -> [2048, 138]
            cur = ggml_mul_mat(ctx0, layer.conv_pw1_w, cur);
            ggml_format_name(cur, "enc_%d_conv_pw1", il);
            // VOICEOUR PATCH: optional pointwise-conv1 bias, before the GLU gate.
            if (layer.conv_pw1_b) {
                cur = ggml_add(ctx0, cur, layer.conv_pw1_b);
            }

            {
                int64_t d = cur->ne[0] / 2;
                struct ggml_tensor * signal = ggml_view_2d(ctx0, cur, d, cur->ne[1], cur->nb[1], 0);
                struct ggml_tensor * gate   = ggml_view_2d(ctx0, cur, d, cur->ne[1], cur->nb[1], d * cur->nb[0]);

                cur = ggml_mul(ctx0, signal, ggml_sigmoid(ctx0, gate));
                ggml_format_name(cur, "enc_%d_conv_glu", il);
            }

            cur = ggml_cont(ctx0, ggml_transpose(ctx0, cur));

            // use ggml_ssm_conv for f32 precision
            const int dw_pad = (hparams.n_conv_kernel - 1) / 2;
            // VOICEOUR PATCH: one right-pad of `2*dw_pad` where upstream used two of `dw_pad`
            // either side of the roll.
            //
            // `ggml_pad` right-pads and `ggml_roll(+n)` is a forward circular shift, so upstream's
            // pad/roll/pad produces `[0 x dw_pad, values, 0 x dw_pad]` by parking zeros at the end
            // and rotating half of them to the front. Padding to the final width first and then
            // rotating lands the identical tensor: the roll moves the last `dw_pad` of the
            // `2*dw_pad` trailing zeros to the front and shifts everything else right by
            // `dw_pad`. Same elements in the same places, one fewer node and one fewer
            // [n_time + dw_pad, n_state] f32 write-and-reread per layer.
            cur = ggml_pad(ctx0, cur, 2 * dw_pad, 0, 0, 0);
            const int dw_shift = model.spk_ff1_w ? 2 * dw_pad : dw_pad;
            cur = ggml_roll(ctx0, cur, dw_shift, 0, 0, 0);
            ggml_format_name(cur, "enc_%d_conv_dw_pad", il);

            cur = ggml_ssm_conv(ctx0, cur, layer.conv_dw_w);
            ggml_format_name(cur, "enc_%d_conv_1d_dw", il);
            // VOICEOUR PATCH: optional depthwise-conv bias, per channel like the
            // batch-norm terms directly below.
            if (layer.conv_dw_b) {
                cur = ggml_add(ctx0, cur, layer.conv_dw_b);
            }

            if (layer.conv_bn_mean && layer.conv_bn_var) {
                cur = ggml_sub(ctx0, cur, layer.conv_bn_mean);
                struct ggml_tensor * std = ggml_sqrt(ctx0, layer.conv_bn_var);
                cur = ggml_div(ctx0, cur, std);
            } else {
                // VOICEOUR PATCH: streaming/multitalker checkpoints configure
                // conv LayerNorm and therefore omit all running statistics.
                cur = ggml_norm(ctx0, cur, hparams.eps);
            }
            cur = ggml_add(ctx0, ggml_mul(ctx0, cur, layer.conv_bn_w), layer.conv_bn_b);
            ggml_format_name(cur, "enc_%d_conv_norm", il);

            cur = ggml_silu(ctx0, cur);
            ggml_format_name(cur, "enc_%d_conv_silu", il);

            cur = ggml_mul_mat(ctx0, layer.conv_pw2_w, cur);
            ggml_format_name(cur, "enc_%d_conv_pw2", il);
            // VOICEOUR PATCH: optional pointwise-conv2 bias, before the residual.
            if (layer.conv_pw2_b) {
                cur = ggml_add(ctx0, cur, layer.conv_pw2_b);
            }

            cur = ggml_add(ctx0, residual, cur);
            ggml_format_name(cur, "enc_%d_conv_res", il);
        }

        // FFN2
        {
            struct ggml_tensor * residual = cur;
            cur = ggml_norm(ctx0, cur, hparams.eps);
            cur = ggml_add(ctx0, ggml_mul(ctx0, cur, layer.norm_ff2_w), layer.norm_ff2_b);
            ggml_format_name(cur, "enc_%d_ffn_norm_2", il);

            cur = ggml_mul_mat(ctx0, layer.ff2_linear1_w, cur);
            // VOICEOUR PATCH: optional ffn_2 linear biases, mirroring ffn_1.
            if (layer.ff2_linear1_b) {
                cur = ggml_add(ctx0, cur, layer.ff2_linear1_b);
            }
            cur = ggml_silu(ctx0, cur);
            cur = ggml_mul_mat(ctx0, layer.ff2_linear2_w, cur);
            if (layer.ff2_linear2_b) {
                cur = ggml_add(ctx0, cur, layer.ff2_linear2_b);
            }
            cur = ggml_add(ctx0, residual, ggml_scale(ctx0, cur, 0.5));
            ggml_format_name(cur, "enc_%d_ffn_res", il);
        }

        cur = ggml_norm(ctx0, cur, hparams.eps);
        cur = ggml_add(ctx0, ggml_mul(ctx0, cur, layer.norm_out_w), layer.norm_out_b);
    }

    ggml_set_name(cur, "encoder_out");
    pstate.n_frames = cur->ne[1];

    struct ggml_tensor * enc_out_view = ggml_view_2d(ctx0, pstate.enc_out, n_state, pstate.n_frames, pstate.enc_out->nb[1], 0);
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, cur, enc_out_view));

    ggml_free(ctx0);

    return gf;
}

static bool parakeet_encode_internal(
        parakeet_context & pctx,
          parakeet_state & pstate,
              const int   mel_offset,
              const int   n_threads,
    ggml_abort_callback   abort_callback,
                   void * abort_callback_data) {
    const int64_t t_start_us = ggml_time_us();

    auto & sched = pstate.sched_encode.sched;

    ggml_cgraph * gf = parakeet_build_graph_encode(pctx, pstate);

    if (!ggml_backend_sched_alloc_graph(sched, gf)) {
        // should never happen as we pre-allocate the memory
        return false;
    }

    // set mel input
    {
        struct ggml_tensor * mel = ggml_graph_get_tensor(gf, "mel");

        const auto & mel_inp = pstate.mel;
        const int n_ctx      = pstate.n_audio_ctx > 0 ? pstate.n_audio_ctx : pctx.model.hparams.n_audio_ctx;

        assert(mel->type == GGML_TYPE_F32);
        assert(mel_inp.n_mel == pctx.model.hparams.n_mels);

        pstate.inp_mel.resize(ggml_nelements(mel));

        float * dst = pstate.inp_mel.data();
        memset(dst, 0, ggml_nbytes(mel));

        const int i0 = std::min(mel_offset,         mel_inp.n_len);
        const int i1 = std::min(mel_offset + n_ctx, mel_inp.n_len);

        memcpy(dst, mel_inp.data.data() + i0 * mel_inp.n_mel, (i1 - i0) * mel_inp.n_mel * sizeof(float));

        ggml_backend_tensor_set(mel, pstate.inp_mel.data(), 0, ggml_nelements(mel)*sizeof(float));
    }

    // set attention mask
    {
        struct ggml_tensor * attn_mask = ggml_graph_get_tensor(gf, "attn_mask");
        const int n_q = attn_mask->ne[1];
        const int n_k = attn_mask->ne[0];

        // VOICEOUR PATCH: causal downsampling emits `floor(L / 2) + 1` frames
        // per stage, one more than the non-causal `ceil(L / factor)`; the pad
        // mask has to count the frames NeMo's `calc_length` counts or it masks
        // the last real frame. Identical arithmetic for every non-causal file.
        const int n_tokens_real =
            parakeet_encoder_frame_count(pctx.model, pstate.mel.n_len_org);

        std::vector<float> mask_data(n_q * n_k);
        const float mask_value = -1e30f;

        if (n_k == n_q) {   // dense tensor, optionally context-masked
            const bool chunked     = pctx.model.spk_ff1_w != nullptr;
            const int  chunk       = PARAKEET_MULTITALKER_ATT_RIGHT + 1;
            const int  left_chunks = PARAKEET_MULTITALKER_ATT_LEFT / chunk;
            for (int q = 0; q < n_q; ++q) {
                const int q_chunk = q / chunk;
                for (int k = 0; k < n_k; ++k) {
                    const int chunk_diff = q_chunk - k / chunk;
                    const bool in_multitalker_context =
                            !chunked || (chunk_diff >= 0 && chunk_diff <= left_chunks);
                    mask_data[q * n_k + k] =
                        (k >= n_tokens_real || !in_multitalker_context) ? mask_value : 0.0f;
                }
            }
        } else {            // local attention
            const int att_left = n_k / 2;
            for (int q = 0; q < n_q; ++q) {
                for (int k = 0; k < n_k; ++k) {
                    const int key = q - att_left + k;
                    mask_data[q * n_k + k] = (key >= 0 && key < n_tokens_real) ? 0.0f : mask_value;
                }
            }
        }
        ggml_backend_tensor_set(attn_mask, mask_data.data(), 0, mask_data.size() * sizeof(float));
    }

    // set local attention skew mask
    if (struct ggml_tensor * local_mask = ggml_graph_get_tensor(gf, "local_mask")) {
        const int n_k = local_mask->ne[0];
        const int n_q = local_mask->ne[1];

        std::vector<float> mask_data(n_q * n_k);
        const int window_size = n_k - n_q + 1;
        for (int q = 0; q < n_q; ++q) {
            for (int k = 0; k < n_k; ++k) {
                const int rel = k - q;
                mask_data[q * n_k + k] = (rel >= 0 && rel < window_size) ? 1.0f : 0.0f;
            }
        }
        ggml_backend_tensor_set(local_mask, mask_data.data(), 0, mask_data.size() * sizeof(float));
    }

    // set positional frequency
    {
        struct ggml_tensor * pos_freqs_t = ggml_graph_get_tensor(gf, "pos_freqs");
        const int d_half      = pos_freqs_t->ne[0];
        const int n_state     = pctx.model.hparams.n_audio_state;
        const float log_10000 = logf(10000.0f);
        std::vector<float> freqs(d_half);
        for (int k = 0; k < d_half; ++k) {
            freqs[k] = expf(-(float(k * 2) * log_10000 / float(n_state)));
        }
        ggml_backend_tensor_set(pos_freqs_t, freqs.data(), 0, freqs.size() * sizeof(float));
    }

    // set relative position offsets
    {
        struct ggml_tensor * rel_pos_t = ggml_graph_get_tensor(gf, "rel_positions");
        const int window_size = rel_pos_t->ne[1];
        std::vector<float> pos(window_size);
        if (window_size == PARAKEET_LOCAL_ATTN_WINDOW * 2 + 1) {
            for (int t = 0; t < window_size; ++t) {
                pos[t] = float(PARAKEET_LOCAL_ATTN_WINDOW - t);
            }
        } else {
            const int n_time = (window_size + 1) / 2;
            for (int t = 0; t < window_size; ++t) {
                pos[t] = float(n_time - 1 - t);
            }
        }
        ggml_backend_tensor_set(rel_pos_t, pos.data(), 0, pos.size() * sizeof(float));
    }

    if (!ggml_graph_compute_helper(sched, gf, n_threads)) {
        return false;
    }


    pstate.t_encode_us += ggml_time_us() - t_start_us;
    pstate.n_encode++;

    return !(abort_callback && abort_callback(abort_callback_data));
}

static bool parakeet_ensure_encode_sched(
        parakeet_context & pctx,
          parakeet_state & pstate,
                    int    n_audio_ctx) {
    const int n_frames_max = parakeet_encoder_frame_count(pctx.model, n_audio_ctx);

    // VOICEOUR PATCH: the encoder reservation is a high-water mark, not an exact fit.
    //
    // Upstream compares the reserved context for equality, so an utterance whose mel length
    // differs from the one before it frees the encoder scheduler, reallocates its metadata,
    // rebuilds a ~1300-node measurement graph and allocates fresh Metal compute buffers.
    // Two dictations are never the same length, so that teardown ran on every single decode.
    //
    // A reservation measured at a longer context strictly dominates a shorter graph: every
    // encoder tensor's size grows monotonically with the mel length. `parakeet_init_state`
    // already reserves at the full `hparams.n_audio_ctx` — `parakeet_build_graph_encode`
    // falls back to it while `pstate.n_audio_ctx` is still zero — so for any utterance the
    // single-chunk path accepts, this now reserves once per process instead of once per
    // decode. `sched_encode_n_audio_ctx` only ever grows, and a failed rebuild resets it to
    // zero, so the next call reserves again.
    //
    // The graph that actually runs is still built from the exact `pstate.n_audio_ctx` set
    // here, so its nodes, shapes, kernels and fusion decisions are untouched.
    if (pstate.sched_encode.sched
            && pstate.sched_encode_n_audio_ctx >= n_audio_ctx
            && pstate.enc_out
            && n_frames_max <= pstate.enc_out->ne[1]) {
        pstate.n_audio_ctx = n_audio_ctx;
        return true;
    }

    parakeet_sched_free(pstate.sched_encode);

    const int32_t prev_n_audio_ctx = pstate.n_audio_ctx;
    pstate.n_audio_ctx = n_audio_ctx;

    if (n_frames_max > pstate.enc_out->ne[1]) {
        ggml_backend_buffer_free(pstate.enc_out_buffer);
        pstate.enc_out_buffer = nullptr;
        pstate.enc_out = nullptr;

        // VOICEOUR PATCH: a CPU tail keeps resized encoder output on its decode-state backend.
        if (!parakeet_enc_state_init(pstate, pstate.backend_decode_state, pctx.model.hparams.n_audio_state, n_frames_max)) {
            pstate.sched_encode_n_audio_ctx = 0;
            pstate.n_audio_ctx = prev_n_audio_ctx;
            return false;
        }
    }

    const bool ok = parakeet_sched_graph_init(pstate.sched_encode, pstate.backends,
            [&]() {
                return parakeet_build_graph_encode(pctx, pstate);
            });

    if (!ok) {
        pstate.sched_encode_n_audio_ctx = 0;
        pstate.n_audio_ctx = prev_n_audio_ctx;
        return false;
    }

    pstate.sched_encode_n_audio_ctx = n_audio_ctx;
    return true;
}

static struct ggml_tensor * parakeet_build_graph_lstm_layer(
        struct ggml_context * ctx0,
         struct ggml_cgraph * gf,
         struct ggml_tensor * x_t,       // the current input token embedding
         struct ggml_tensor * w_ih,      // input to hidden weights (4 weight tensors packed)
         struct ggml_tensor * w_hh,      // hidden to hidden weights (4 weight tensors packed)
         struct ggml_tensor * b_h,       // folded ih+hh bias (4 bias tensors packed)
         struct ggml_tensor * h_state,   // this layers hidden state
         struct ggml_tensor * c_state,   // this layers cell state
                        int   li) {      // layer index (for tensor naming)

    ggml_format_name(x_t, "lstm_layer_%d_x_t", li);
    ggml_format_name(h_state, "lstm_layer_%d_h_state", li);
    ggml_format_name(c_state, "lstm_layer_%d_c_state", li);

    // The 4 gates (i, f, o, c) are packed in the same weight tensor.
    struct ggml_tensor * inp_gates = ggml_mul_mat(ctx0, w_ih, x_t);

    // Hidden-to-Hidden Projections are also packed in the same weight tensor.
    // b_h holds the folded ih+hh bias (see parakeet_model_load), so it is
    // the only bias that needs to be added here.
    struct ggml_tensor * hid_gates = ggml_mul_mat(ctx0, w_hh, h_state);
    hid_gates = ggml_add(ctx0, hid_gates, b_h);

    // Combine the input and hidden contributions of the gates.
    struct ggml_tensor * gates = ggml_add(ctx0, inp_gates, hid_gates);
    ggml_format_name(gates, "lstm_layer_%d_gates", li);

    const int h_dim = h_state->ne[0];
    const size_t row_size = ggml_row_size(gates->type, h_dim);

    // The gates are packed as [i, f, o, c] (reordered at convert time, see
    // parakeet_model_load), so the three sigmoid-gated outputs (i, f, o) are
    // contiguous and can be computed with a single ggml_sigmoid call.
    struct ggml_tensor * ifo = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, gates, 3 * h_dim, 0));
    ggml_format_name(ifo, "lstm_layer_%d_ifo", li);

    // 1. Input Gate at time t.
    struct ggml_tensor * i_t = ggml_view_1d(ctx0, ifo, h_dim, 0 * row_size);
    ggml_format_name(i_t, "lstm_layer_%d_i_t", li);

    // Forget gate.
    struct ggml_tensor * f_t = ggml_view_1d(ctx0, ifo, h_dim, 1 * row_size);
    ggml_format_name(f_t, "lstm_layer_%d_f_t", li);

    // Output gate.
    struct ggml_tensor * o_t = ggml_view_1d(ctx0, ifo, h_dim, 2 * row_size);
    ggml_format_name(o_t, "lstm_layer_%d_o_t", li);

    // Cell gate.
    struct ggml_tensor * c_t = ggml_tanh(ctx0, ggml_view_1d(ctx0, gates, h_dim, 3 * row_size));
    ggml_format_name(c_t, "lstm_layer_%d_c_t", li);

    // Calculate the new cell state.
    struct ggml_tensor * c_new = ggml_add(ctx0,
        ggml_mul(ctx0, f_t, c_state), // apply forget gate to cell state.
        ggml_mul(ctx0, i_t, c_t));    // apply input gate to cell gate.
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, c_new, c_state));

    // Calculate the new hidden state.
    struct ggml_tensor * h_new = ggml_mul(ctx0, o_t, ggml_tanh(ctx0, c_new));
    ggml_set_output(h_new);
    ggml_format_name(h_new, "lstm_layer_%d_h_new", li);
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, h_new, h_state));

    return h_new;
}

// VOICEOUR PATCH: the prediction network as a reusable subgraph.
//
// Returns the `ggml_cpy` node that lands the projected output in `pstate.pred_out`. A caller
// that consumes the prediction in the same graph must read *that node* rather than
// `pstate.pred_out` itself, or ggml sees no dependency between the write and the read and is
// free to order the joint network's load before this store.
static struct ggml_tensor * parakeet_expand_prediction(
        struct ggml_context * ctx0,
         struct ggml_cgraph * gf,
           parakeet_context & pctx,
             parakeet_state & pstate,
       const parakeet_batch & batch) {
    const auto & model   = pctx.model;
    const auto & hparams = model.hparams;
    const int n_tokens   = batch.n_tokens;

    struct ggml_tensor * token = ggml_new_tensor_1d(ctx0, GGML_TYPE_I32, n_tokens);
    ggml_set_name(token, "token_inp");
    ggml_set_input(token);

    struct ggml_tensor * token_embd = ggml_get_rows(ctx0, model.prediction.embed_w, token);

    struct ggml_tensor * inpL = token_embd;

    for (int il = 0; il < hparams.n_pred_layers; ++il) {
        inpL = parakeet_build_graph_lstm_layer(ctx0, gf, inpL,
                model.prediction.lstm_layer[il].ih_w,
                model.prediction.lstm_layer[il].hh_w,
                model.prediction.lstm_layer[il].b_h,
                pstate.lstm_state.layer[il].h_state,
                pstate.lstm_state.layer[il].c_state,
                il);
    }

    struct ggml_tensor * pred_out = inpL;
    ggml_format_name(pred_out, "lstm_pred_out");

    // Project the prediction network output to the joint network hidden dimension.
    struct ggml_tensor * pred = ggml_mul_mat(ctx0, model.joint.pred_w, pred_out);
    pred = ggml_add(ctx0, pred, model.joint.pred_b);
    ggml_set_name(pred, "h_pred");

    return ggml_cpy(ctx0, pred, pstate.pred_out);
}

static struct ggml_cgraph * parakeet_build_graph_prediction(
         parakeet_context & pctx,
           parakeet_state & pstate,
     const parakeet_batch & batch,
                    bool   worst_case) {
    GGML_UNUSED(worst_case);

    struct ggml_init_params params = {
        /*.mem_size   =*/ pstate.sched_decode.meta.size(),
        /*.mem_buffer =*/ pstate.sched_decode.meta.data(),
        /*.no_alloc   =*/ true,
    };

    struct ggml_context * ctx0 = ggml_init(params);
    ggml_cgraph * gf = ggml_new_graph_custom(ctx0, PARAKEET_MAX_NODES, false);

    ggml_build_forward_expand(gf, parakeet_expand_prediction(ctx0, gf, pctx, pstate, batch));

    ggml_free(ctx0);

    return gf;
}

// VOICEOUR PATCH: one graph per decode step, holding the joint network and — when the previous
// step emitted a token — the prediction network that feeds it.
//
// The TDT loop alternates prediction and joint, and only the joint's output is read back: the
// CPU argmax sits between a joint and the *following* prediction, never between a prediction and
// the joint that consumes it. So those two always ran back to back with nothing in between, as
// two separate graph computes, and a graph compute costs about 170 us end to end here regardless
// of its size — measured by skipping every MUL_MAT in these graphs, after which the 8-node joint
// still took 167 us per call and the 30-node prediction 180 us. At thousands of emitted tokens
// per utterance that fixed cost, not the arithmetic, dominated the decode loop.
//
// Merging them halves the graph computes per emitted token. The ops, their order, their kernels
// and their inputs are identical, so results are bit-identical; the merged graph is 38 nodes,
// still inside the 64 the calling thread encodes into a single command buffer, so it also gains
// no command-buffer boundary.
static struct ggml_cgraph * parakeet_build_graph_step(
         parakeet_context & pctx,
           parakeet_state & pstate,
     const parakeet_batch & batch,
                     bool   with_prediction) {
    const auto & model   = pctx.model;
    const auto & hparams = model.hparams;

    struct ggml_init_params params = {
        /*.mem_size   =*/ pstate.sched_decode.meta.size(),
        /*.mem_buffer =*/ pstate.sched_decode.meta.data(),
        /*.no_alloc   =*/ true,
    };

    struct ggml_context * ctx0 = ggml_init(params);
    ggml_cgraph * gf = ggml_new_graph_custom(ctx0, PARAKEET_MAX_NODES, false);

    // Reading the copy node rather than `pstate.pred_out` is what orders this step's prediction
    // before its joint network. Without a prediction this step reuses the value the previous one
    // left there, which is the same tensor the unmerged code read.
    struct ggml_tensor * pred = with_prediction
        ? parakeet_expand_prediction(ctx0, gf, pctx, pstate, batch)
        : pstate.pred_out;
    ggml_format_name(pred, "pred");

    const int t_idx = batch.i_time[0];
    struct ggml_tensor * enc_out = ggml_view_1d(ctx0, pstate.enc_out, hparams.n_audio_state,
            (size_t) t_idx * pstate.enc_out->nb[1]);
    ggml_format_name(enc_out, "enc_out_view");

    // Project the encoder output to the joint network hidden dimension.
    struct ggml_tensor * enc  = ggml_mul_mat(ctx0, model.joint.enc_w, enc_out);
    enc = ggml_add(ctx0, enc, model.joint.enc_b);
    ggml_set_name(enc, "enc");

    struct ggml_tensor * joint = ggml_add(ctx0, enc, pred);
    ggml_set_name(joint, "joint");
    joint = ggml_relu(ctx0, joint);

    struct ggml_tensor * logits = ggml_mul_mat(ctx0, model.joint.net_w, joint);
    logits = ggml_add(ctx0, logits, model.joint.net_b);
    ggml_set_output(logits);
    ggml_set_name(logits, "logits");

    struct ggml_tensor * probs = ggml_soft_max(ctx0, logits);
    struct ggml_tensor * log_probs = ggml_log(ctx0, probs);
    ggml_set_output(log_probs);
    ggml_format_name(log_probs, "log_probs");

    ggml_build_forward_expand(gf, log_probs);

    ggml_free(ctx0);

    return gf;
}

static bool parakeet_predict(
        parakeet_context & pctx,
          parakeet_state & pstate,
    const parakeet_batch & batch,
               const int   n_threads,
     ggml_abort_callback   abort_callback,
                   void  * abort_callback_data) {

    const int n_tokens   = batch.n_tokens;

    const int64_t t_start_us = ggml_time_us();

    {
        auto & sched = pstate.sched_decode.sched;

        const int64_t t_build_start_us = ggml_time_us();
        ggml_cgraph * gf = parakeet_build_graph_prediction(pctx, pstate, batch, false);
        pstate.t_predict_build_us += ggml_time_us() - t_build_start_us;

        const int64_t t_alloc_start_us = ggml_time_us();
        if (!ggml_backend_sched_alloc_graph(sched, gf)) {
            // should never happen as we pre-allocate the memory
            return false;
        }
        pstate.t_predict_alloc_us += ggml_time_us() - t_alloc_start_us;

        // set the inputs
        {
            struct ggml_tensor * token_inp = ggml_graph_get_tensor(gf, "token_inp");
            ggml_backend_tensor_set(token_inp, batch.token, 0, n_tokens * ggml_element_size(token_inp));
        }

        const int64_t t_compute_start_us = ggml_time_us();
        if (!ggml_graph_compute_helper(sched, gf, n_threads)) {
            return false;
        }
        pstate.t_predict_compute_us += ggml_time_us() - t_compute_start_us;
    }

    pstate.t_predict_us += ggml_time_us() - t_start_us;
    pstate.n_predict++;

    return !(abort_callback && abort_callback(abort_callback_data));
}

// VOICEOUR PATCH: computes one decode step — the joint network, preceded in the same graph by
// the prediction network when `with_prediction` — and reads its logits back.
static bool parakeet_step(
         parakeet_context & pctx,
           parakeet_state & pstate,
     const parakeet_batch & batch,
                const int   n_threads,
                     bool   with_prediction,
                     bool   capture_raw_token_logits,
      ggml_abort_callback   abort_callback,
                     void * abort_callback_data) {
    const int64_t t_start_us = ggml_time_us();

    const auto & model   = pctx.model;
    const auto & hparams = model.hparams;
    const int n_tokens   = batch.n_tokens;

    auto & logits_out = pstate.logits;

    struct ggml_tensor * logits;

    // VOICEOUR PATCH (upstream ggml-org/whisper.cpp#3932): the graph's last node is
    // log_probs; the pre-softmax row is a named output of the same graph.
    struct ggml_tensor * logits_raw = nullptr;

    {
        auto & sched = pstate.sched_decode.sched;

        ggml_cgraph * gf = parakeet_build_graph_step(pctx, pstate, batch, with_prediction);

        if (!ggml_backend_sched_alloc_graph(sched, gf)) {
            // should never happen as we pre-allocate the memory
            return false;
        }

        logits     = ggml_graph_node(gf, -1);
        logits_raw = ggml_graph_get_tensor(gf, "logits");

        if (with_prediction) {
            struct ggml_tensor * token_inp = ggml_graph_get_tensor(gf, "token_inp");
            ggml_backend_tensor_set(token_inp, batch.token, 0, n_tokens * ggml_element_size(token_inp));
        }

        if (!ggml_graph_compute_helper(sched, gf, n_threads)) {
            return false;
        }

    }

    const int n_logits = hparams.n_vocab + hparams.n_tdt_durations + 1; // one for the blank token
    logits_out.resize(n_tokens * n_logits);
    for (int i = 0; i < n_tokens; i++) {
        if (batch.logits[i] == 0) {
            continue;
        }
        ggml_backend_tensor_get(logits, logits_out.data() + (n_logits*i), sizeof(float)*(n_logits*i), sizeof(float)*n_logits);
    }

    // VOICEOUR PATCH: the research callback needs finite pre-softmax token logits. Avoid the
    // extra device-to-host copy entirely when no observer is installed.
    if (capture_raw_token_logits && logits_raw) {
        const int n_token_logits = hparams.n_vocab + 1;
        pstate.token_logits_raw.resize(n_tokens * n_token_logits);
        for (int i = 0; i < n_tokens; i++) {
            if (batch.logits[i] == 0) {
                continue;
            }
            ggml_backend_tensor_get(logits_raw,
                    pstate.token_logits_raw.data() + (n_token_logits * i),
                    sizeof(float) * (size_t) (n_logits * i),
                    sizeof(float) * (size_t) n_token_logits);
        }
    }

    // VOICEOUR PATCH (upstream ggml-org/whisper.cpp#3932): keep raw TDT
    // duration slots so the decoder can argmax them without log-softmax
    // underflow. Plain RNNT has zero duration slots and clears this buffer.
    if (logits_raw && hparams.n_tdt_durations > 0) {
        pstate.duration_logits_raw.resize(n_tokens * hparams.n_tdt_durations);
        const size_t off = sizeof(float) * (size_t) (hparams.n_vocab + 1);
        for (int i = 0; i < n_tokens; i++) {
            if (batch.logits[i] == 0) {
                continue;
            }
            ggml_backend_tensor_get(logits_raw,
                    pstate.duration_logits_raw.data() + (hparams.n_tdt_durations * i),
                    sizeof(float) * (size_t) (n_logits * i) + off,
                    sizeof(float) * (size_t) hparams.n_tdt_durations);
        }
    } else {
        pstate.duration_logits_raw.clear();
    }

    if (batch.n_tokens == 1) {
        pstate.t_decode_us += ggml_time_us() - t_start_us;
        pstate.n_decode++;
        if (with_prediction) {
            pstate.n_predict++;
        }
    }

    return !(abort_callback && abort_callback(abort_callback_data));
}

static bool is_word_start_token(parakeet_vocab & vocab, parakeet_token token_id) {
    const std::string & token_str = vocab.id_to_token[token_id];
    // check if it starts with the SentencePiece meta-space "▁" (U+2581) or 3-byte UTF-8 character: 0xE2 0x96 0x81
    if (!token_str.empty()) {
        if (token_str.find("\xE2\x96\x81") == 0 || token_str[0] == '_') {
            return true;
        }
    }
    return false;
}

static bool is_punctuation_token(parakeet_vocab & vocab, parakeet_token token_id) {
    const std::string & token_str = vocab.id_to_token[token_id];
    static const std::string punct_chars = ".,!?;:'\"-()[]{}";

    if (token_str.empty()) {
        return false;
    }

    std::string clean_token = token_str;
    if (clean_token.find("\xE2\x96\x81") == 0) {
        clean_token = clean_token.substr(3); // Remove the 3-byte UTF-8 character
    } else if (clean_token[0] == '_') {
        clean_token = clean_token.substr(1);
    }

    return clean_token.length() == 1 && punct_chars.find(clean_token[0]) != std::string::npos;
}

// Collapse punctuation timestamps to match the original Parakeet model.
// Punctuations symbols like ',', '.' and others are not spoken words but the
// model will still produce a duration for these tokens. But since these are
// non-spoken we collapse the timestamps so that they don't have an time duration.
static void refine_timestamps_tdt(parakeet_vocab & vocab, std::vector<parakeet_token_data> & tokens) {
    if (tokens.empty()) {
        return;
    }

    int64_t last_non_punct_t1 = -1;

    for (size_t i = 0; i < tokens.size(); ++i) {
        if (is_punctuation_token(vocab, tokens[i].id)) {
            if (last_non_punct_t1 >= 0) {
                tokens[i].t0 = last_non_punct_t1;
                tokens[i].t1 = last_non_punct_t1;
            }
        } else {
            last_non_punct_t1 = tokens[i].t1;
        }
    }
}

static parakeet_token_data create_token_data(
            parakeet_context & pctx,
              parakeet_state & pstate,
               parakeet_token   token_id,
                          int   duration_idx,
                          int   duration_value,
                          int   frame_index,
                        float   token_logit,
                          int   n_vocab_logits) {

    float token_sum = 0.0f;
    for (int i = 0; i < n_vocab_logits; ++i) {
        token_sum += expf(pstate.logits[i]);
    }
    float token_p = expf(token_logit) / token_sum;

    parakeet_token_data token_data;
    token_data.id = token_id;
    token_data.duration_idx = duration_idx;
    token_data.duration_value = duration_value;
    token_data.frame_index = frame_index;
    token_data.p = token_p;
    token_data.plog = token_logit;
    token_data.t0 = frame_index * pctx.model.hparams.subsampling_factor;
    token_data.t1 = (frame_index + duration_value) * pctx.model.hparams.subsampling_factor;
    token_data.is_word_start = is_word_start_token(pctx.vocab, token_id);

    return token_data;
}

static bool parakeet_decode(
              parakeet_context & pctx,
                parakeet_state & pstate,
                parakeet_batch & batch,
                     const int   n_threads,
    const parakeet_full_params * params = nullptr) {
    const auto & hparams       = pctx.model.hparams;
    const auto & tdt_durations = pctx.model.tdt_durations;

    const int  n_tdt_durations          = hparams.n_tdt_durations;
    const int  n_frames                 = pstate.n_frames;
    const int  blank_id                 = pctx.vocab.token_blank;
    const int  n_vocab_logits           = blank_id + 1;
    const int  max_tokens_per_timestep = hparams.n_max_tokens;

    // time index into the encoder frame (current time frame)
    int t = 0;
    // number of symbols emitted for the current time frame
    int tokens_emitted = 0;

    // Start with the blank token (8192)
    parakeet_token last_token = blank_id;

    PARAKEET_LOG_DEBUG("parakeet_decode: starting decode with n_frames=%d\n", n_frames);

    batch.n_tokens  = 1;
    batch.token[0]  = last_token;
    batch.logits[0] = 1;
    batch.i_time[0] = 0;

    // VOICEOUR PATCH: the prediction network runs in the same graph as the joint network that
    // consumes it, so it is scheduled here rather than executed on its own.
    //
    // Upstream primed the predictor with the initial blank token before the loop and then ran a
    // prediction at the end of every iteration that emitted one. Nothing reads the predictor's
    // output on the CPU — it lands in `pstate.pred_out` and the LSTM state — so each of those
    // predictions was immediately followed by the joint network that consumes it, with no host
    // work in between, yet paid for its own graph compute. `pending_prediction` defers it to the
    // start of the next iteration, where it is merged into that iteration's single graph.
    //
    // The order in which ops execute is unchanged: prediction for the token emitted at step k-1,
    // then the joint network at step k.
    bool pending_prediction = true;

    // process all time frames of the encoder output
    while (t < n_frames) {
        batch.n_tokens  = 1;
        batch.i_time[0] = t;
        batch.logits[0] = 1;

        // Use the current encoder frame (t) and the output of the prediction to
        // generate probabilities for the next token and duration. batch.i_time
        // is used in to select the correct frame from the encoder output.
        // The joint network outputs logits for all the tokens in the vocabulary
        // plus the blank token, and also n_duration logits for the duration
        // tokens which contain information about how many frames to skip/advance forward.
        if (!parakeet_step(pctx, pstate, batch, n_threads, pending_prediction,
                params && params->decode_step_callback,
                params ? params->abort_callback           : nullptr,
                params ? params->abort_callback_user_data : nullptr)) {
            return false;
        }
        pending_prediction = false;

        const int64_t t_start_sample_us = ggml_time_us();

        // find the best token (greedy).
        // TODO: implement beam search?
        int best_token = 0;
        float max_logit = -1e10f;
        for (int i = 0; i < n_vocab_logits; ++i) {
            if (pstate.logits[i] > max_logit) {
                max_logit = pstate.logits[i];
                best_token = i;
            }
        }

        // TDT chooses a duration slot. Plain RNNT (`n_tdt_durations == 0`)
        // has the classic transducer rule: blank advances one encoder frame;
        // a nonblank token stays on the frame and advances the predictor.
        const float * duration_slots = nullptr;
        int best_duration_idx = 0;
        int duration = best_token == blank_id ? 1 : 0;
        if (n_tdt_durations > 0) {
            duration_slots = pstate.duration_logits_raw.empty()
                ? pstate.logits.data() + n_vocab_logits
                : pstate.duration_logits_raw.data();
            float best_duration_logit = duration_slots[0];
            for (int i = 1; i < n_tdt_durations; ++i) {
                if (duration_slots[i] > best_duration_logit) {
                    best_duration_logit = duration_slots[i];
                    best_duration_idx = i;
                }
            }
            duration = tdt_durations[best_duration_idx];
        }

        const float * token_slots = pstate.token_logits_raw.empty()
            ? pstate.logits.data()
            : pstate.token_logits_raw.data();
        // VOICEOUR PATCH: expose every greedy step for bounded research harvesting. The hook is
        // opt-in and observes the already-selected path without changing decoder state.
        if (params && params->decode_step_callback) {
            params->decode_step_callback(
                &pctx,
                &pstate,
                t,
                best_token,
                best_token == blank_id,
                best_duration_idx,
                token_slots,
                n_vocab_logits,
                duration_slots,
                n_tdt_durations,
                params->decode_step_callback_user_data);
        }

        if (best_token == blank_id) {
            if (duration == 0) {
                duration = 1;
            }
            // skip forward by duration time frames.
            t += duration;
            // reset symbols emitted counter
            tokens_emitted = 0;
            // continue without predicting.
            continue;
        }

        // Emit non-blank token at current frame t.
        pstate.decoded_tokens.push_back(best_token);
        pstate.t_sample_us += ggml_time_us() - t_start_sample_us;
        pstate.n_sample++;

        parakeet_token_data token_data = create_token_data(
            pctx, pstate, best_token, best_duration_idx, duration, t,
            max_logit, n_vocab_logits);

        pstate.decoded_token_data.push_back(token_data);

        // Call token callback if registered (for real-time streaming)
        if (params && params->new_token_callback) {
            params->new_token_callback(&pctx, &pstate, &token_data, params->new_token_callback_user_data);
        }

        last_token = best_token;

        // VOICEOUR PATCH: schedule the predictor advance into the next iteration's graph rather
        // than running it as a graph of its own. See `pending_prediction` above.
        batch.token[0] = last_token;
        pending_prediction = true;

        // if duration greater than 0, continue looping over the encoder frames
        // and skip to the updated time frame (t).
        if (duration > 0) {
            t += duration;
            tokens_emitted = 0;
            continue;
        }

        // if duration is zero we stay on the current time frame.
        tokens_emitted++;
        if (tokens_emitted >= max_tokens_per_timestep) {
            t += 1; // forced blank/time advance behavior
            tokens_emitted = 0;
        }
    }

    // VOICEOUR PATCH: the loop can exit with the last emitted token's predictor advance still
    // deferred. Upstream had already applied it, leaving the LSTM state and `pstate.pred_out`
    // one token ahead, so run it here to keep that observable.
    //
    // Nothing in this repository can see the difference — `parakeet_full` defaults `no_context`
    // to true, so `parakeet_reset_state` zeroes the LSTM state before the next utterance and the
    // next decode primes `pred_out` before reading it — but `parakeet_chunk` exists for callers
    // that carry state across chunks, and one graph per utterance is not worth a behaviour
    // change there.
    if (pending_prediction) {
        if (!parakeet_predict(pctx, pstate, batch, n_threads,
                params ? params->abort_callback           : nullptr,
                params ? params->abort_callback_user_data : nullptr)) {
            return false;
        }
    }

    return true;
}

//  500 -> 00:05.000
// 6000 -> 01:00.000
// naive Discrete Fourier Transform
// input is real-valued
// output is complex-valued
static void dft(const float* in, int N, float* out, const parakeet_mel_cache & cache) {
    const int sin_cos_step = cache.n_fft / N;

    for (int k = 0; k < N; k++) {
        float re = 0;
        float im = 0;

        for (int n = 0; n < N; n++) {
            int idx = (k * n * sin_cos_step) % cache.n_fft; // t = 2*M_PI*k*n/N
            re += in[n]*cache.cos_vals[idx]; // cos(t)
            im -= in[n]*cache.sin_vals[idx]; // sin(t)
        }

        out[k*2 + 0] = re;
        out[k*2 + 1] = im;
    }
}

// Cooley-Tukey FFT
// poor man's implementation - use something better
// input is real-valued
// output is complex-valued
static void fft(float* in, int N, float* out, const parakeet_mel_cache & cache) {
    if (N == 1) {
        out[0] = in[0];
        out[1] = 0;
        return;
    }

    const int half_N = N / 2;
    if (N - half_N*2 == 1) {
        dft(in, N, out, cache);
        return;
    }

    float* even = in + N;
    for (int i = 0; i < half_N; ++i) {
        even[i]= in[2*i];
    }
    float* even_fft = out + 2 * N;
    fft(even, half_N, even_fft, cache);

    float* odd = even;
    for (int i = 0; i < half_N; ++i) {
        odd[i] = in[2*i + 1];
    }
    float* odd_fft = even_fft + N;
    fft(odd, half_N, odd_fft, cache);

    const int sin_cos_step = cache.n_fft / N;
    for (int k = 0; k < half_N; k++) {
        int idx = k * sin_cos_step; // t = 2*M_PI*k/N
        float re = cache.cos_vals[idx]; // cos(t)
        float im = -cache.sin_vals[idx]; // sin(t)

        float re_odd = odd_fft[2*k + 0];
        float im_odd = odd_fft[2*k + 1];

        out[2*k + 0] = even_fft[2*k + 0] + re*re_odd - im*im_odd;
        out[2*k + 1] = even_fft[2*k + 1] + re*im_odd + im*re_odd;

        out[2*(k + half_N) + 0] = even_fft[2*k + 0] - re*re_odd + im*im_odd;
        out[2*(k + half_N) + 1] = even_fft[2*k + 1] - re*im_odd - im*re_odd;
    }
}

struct mel_worker_params {
    int ith;
    int window_size;
    int n_samples;
    int frame_size;
    int frame_step;
    int n_threads;
};

static void log_mel_spectrogram_worker_thread(
             mel_worker_params   params,
                   const float * window_func,
      const std::vector<float> & samples,
        const parakeet_filters & filters,
                  parakeet_mel & mel,
      const parakeet_mel_cache & cache) {
    std::vector<float> fft_in(params.frame_size * 2, 0.0);
    std::vector<float> fft_out(params.frame_size * 2 * 2 * 2);

    int n_fb = filters.n_fb;  // number of frequency bins
    int i = params.ith;

    // make sure n_fb == 1 + (frame_size / 2), bin_0 to bin_nyquist
    assert(n_fb == 1 + (params.frame_size / 2));

    const double eps = 5.960464477539063e-08;

    // calculate FFT only when fft_in are not all zero
    for (; i < std::min(params.n_samples / params.frame_step + 1, mel.n_len); i += params.n_threads) {
        const int offset = i * params.frame_step;

        const int window_pad_left = (params.frame_size - params.window_size) / 2;

        // Zero-pad left
        std::fill(fft_in.begin(), fft_in.begin() + window_pad_left, 0.0f);

        // Apply windowed samples in the center
        const int n_to_process = std::min({params.window_size, params.n_samples - offset});
        for (int j = 0; j < n_to_process; j++) {
            fft_in[window_pad_left + j] = window_func[j] * samples[offset + window_pad_left + j];
        }

        // Zero-pad right (and any samples we didn't have)
        std::fill(fft_in.begin() + window_pad_left + n_to_process, fft_in.begin() + params.frame_size, 0.0f);

        // FFT
        fft(fft_in.data(), params.frame_size, fft_out.data(), cache);

        // Calculate modulus^2 of complex numbers
        // Use pow(fft_out[2 * j + 0], 2) + pow(fft_out[2 * j + 1], 2) causes inference quality problem? Interesting.
        for (int j = 0; j < n_fb; j++) {
            fft_out[j] = (fft_out[2 * j + 0] * fft_out[2 * j + 0] + fft_out[2 * j + 1] * fft_out[2 * j + 1]);
        }

        // mel spectrogram
        for (int j = 0; j < mel.n_mel; j++) {
            double sum = 0.0;
            // unroll loop (suggested by GH user @lunixbochs)
            int k = 0;
            for (k = 0; k < n_fb - 3; k += 4) {
                sum +=
                        fft_out[k + 0] * filters.data[j * n_fb + k + 0] +
                        fft_out[k + 1] * filters.data[j * n_fb + k + 1] +
                        fft_out[k + 2] * filters.data[j * n_fb + k + 2] +
                        fft_out[k + 3] * filters.data[j * n_fb + k + 3];
            }
            // handle n_fb remainder
            for (; k < n_fb; k++) {
                sum += fft_out[k] * filters.data[j * n_fb + k];
            }

            mel.data[i * mel.n_mel + j] = std::log(sum + eps);
        }
    }

    // Otherwise fft_out are all zero - use log(eps) for consistency
    const double empty_sum = std::log(eps);
    for (; i < mel.n_len; i += params.n_threads) {
        for (int j = 0; j < mel.n_mel; j++) {
            mel.data[i * mel.n_mel + j] = empty_sum;
        }
    }
}

static bool log_mel_spectrogram(
                  parakeet_state & wstate,
                     const float * samples,
                       const int   n_samples,
                       const int   /*sample_rate*/,
                       const int   frame_size,
                       const int   frame_step,
                       const int   n_mel,
                       const int   n_threads,
          const parakeet_filters & filters,
                      const bool   debug,
                      const bool   normalize_per_feature,
                    parakeet_mel & mel,
        const parakeet_mel_cache & cache) {
    const int64_t t_start_us = ggml_time_us();

    const float * window_func = cache.window.empty() ? cache.hann_window.data() : cache.window.data();
    const int window_size = cache.window.empty() ? cache.n_fft : cache.window.size();

    std::vector<float> samples_preprocessed(samples, samples + n_samples);

    // Apply preemphasis filter (high-pass): x[i] = x[i] - 0.97 * x[i-1]
    {
        const float preemph = 0.97f;
        for (int i = n_samples - 1; i > 0; i--) {
            samples_preprocessed[i] = samples_preprocessed[i] - preemph * samples_preprocessed[i - 1];
        }
    }

    // Parakeet Pytorch implementation uses centered contant padding.
    const size_t pad = (size_t)(frame_size / 2);
    std::vector<float> samples_padded(n_samples + 2 * pad, 0.0f);
    std::copy(samples_preprocessed.begin(), samples_preprocessed.end(), samples_padded.begin() + pad);

    mel.n_mel = n_mel;
    mel.n_len = (samples_padded.size() - frame_size) / frame_step + 1;
    mel.n_len_org = mel.n_len;
    mel.data.resize(mel.n_mel * mel.n_len);

    // Worker Threads (STFT + Mel + Natural Log)
    {
        std::vector<std::thread> workers(n_threads - 1);
        const mel_worker_params mel_params { 0, window_size, (int)samples_padded.size(), frame_size, frame_step, n_threads };

        for (int iw = 0; iw < n_threads - 1; ++iw) {
            mel_worker_params params = mel_params;
            params.ith = iw + 1;
            workers[iw] = std::thread(log_mel_spectrogram_worker_thread,
                    params,
                    window_func,
                    std::cref(samples_padded),
                    std::cref(filters),
                    std::ref(mel),
                    std::cref(cache));
        }

        log_mel_spectrogram_worker_thread(
                mel_params,
                window_func,
                samples_padded,
                filters,
                mel,
                cache);

        for (int iw = 0; iw < n_threads - 1; ++iw) {
            workers[iw].join();
        }
    }

    // VOICEOUR PATCH: NeMo's `normalize: per_feature` utterance z-score. The
    // multitalker/streaming checkpoints configure `normalize: NA` and feed the
    // raw log-mel straight into the causal pre-encoder, so this block must not
    // run for them; a per-bin rescale there survives the whole encoder. Every
    // per_feature checkpoint keeps its exact arithmetic.
    if (normalize_per_feature) {
        const double eps = 1e-5;
        int valid_frames = n_samples / frame_step;

        for (int j = 0; j < mel.n_mel; j++) {
            double sum = 0.0;
            double sq_diff_sum = 0.0;

            // Calculate Mean ONLY on valid audio frames
            for (int i = 0; i < valid_frames; i++) {
                sum += (double)mel.data[i * mel.n_mel + j];
            }
            double mean = sum / valid_frames;

            // Calculate Variance ONLY on valid audio frames
            for (int i = 0; i < valid_frames; i++) {
                double diff = (double)mel.data[i * mel.n_mel + j] - mean;
                sq_diff_sum += diff * diff;
            }

            double std_dev = std::sqrt(sq_diff_sum / (valid_frames - 1.0));
            double denominator = std_dev + eps;

            // Apply to ALL frames (including the padded ones)
            for (int i = 0; i < mel.n_len; i++) {
                mel.data[i * mel.n_mel + j] = (float)((mel.data[i * mel.n_mel + j] - mean) / denominator);
            }
        }
    }

    wstate.t_mel_us += ggml_time_us() - t_start_us;

    if (debug) {
        std::ofstream outFile("log_mel_spectrogram.json");
        outFile << "[";
        for (uint64_t i = 0; i < mel.data.size() - 1; i++) {
            outFile << mel.data[i] << ", ";
        }
        outFile << mel.data[mel.data.size() - 1] << "]";
        outFile.close();
    }

    return true;
}

static std::vector<parakeet_vocab::id> tokenize(const parakeet_vocab & vocab, const std::string & text) {
    std::vector<parakeet_vocab::id> tokens;
    const std::string normalized = sentencepiece_normalize(text);

    size_t i = 0;
    while (i < normalized.size()) {
        const size_t remaining = normalized.size() - i;
        const size_t max_len = std::min(vocab.max_token_length, remaining);

        bool found = false;
        for (size_t len = max_len; len > 0; --len) {
            const auto it = vocab.token_to_id.find(normalized.substr(i, len));
            if (it != vocab.token_to_id.end() && !is_sentencepiece_control(it->first)) {
                tokens.push_back(it->second);
                i += len;
                found = true;
                break;
            }
        }

        if (!found) {
            if (vocab.token_unk >= 0) {
                tokens.push_back(vocab.token_unk);
            }

            const unsigned char c = static_cast<unsigned char>(normalized[i]);
            i += utf8_codepoint_len(c);
        }
    }

    return tokens;
}


//
// interface implementation
//

struct parakeet_state * parakeet_init_state(parakeet_context * ctx) {
    parakeet_state * state = new parakeet_state;

    state->backends = parakeet_backend_init(ctx->params);
    if (state->backends.empty()) {
        PARAKEET_LOG_ERROR("%s: parakeet_backend_init() failed\n", __func__);
        parakeet_free_state(state);
        return nullptr;
    }

    // VOICEOUR PATCH: the default path retains the original full list and first-backend state
    // placement. The opt-in path excludes Metal from decode and places every persistent decode
    // input on CPU so each scalar step has no cross-device state copy.
    const std::vector<ggml_backend_t> decode_backends =
        parakeet_backend_decode_list(ctx->params, state->backends);
    state->backend_decode_state =
        ctx->params.tail_backend_cpu ? decode_backends.back() : state->backends[0];
    if (ctx->params.tail_backend_cpu) {
        for (size_t i = 0; i < decode_backends.size(); ++i) {
            PARAKEET_LOG_INFO("%s: tail decode backend %zu: %s\n", __func__, i,
                    ggml_backend_dev_name(ggml_backend_get_device(decode_backends[i])));
        }
    }

    // VOICEOUR PATCH: opt-in persistent CPU threadpool. The TDT tail issues hundreds of
    // tiny graph computes per utterance and the disposable per-compute pool pays thread
    // create/join for each. One paused pool per state removes that churn; every kickoff
    // resumes it and the full-decode exit paths pause it again.
    if (ctx->params.persistent_cpu_pool_threads > 0) {
        struct ggml_threadpool_params tpp =
            ggml_threadpool_params_default(ctx->params.persistent_cpu_pool_threads);
        tpp.paused = true;
        state->cpu_pool = ggml_threadpool_new(&tpp);
        if (!state->cpu_pool) {
            PARAKEET_LOG_ERROR("%s: failed to create persistent CPU threadpool\n", __func__);
            parakeet_free_state(state);
            return nullptr;
        }
        ggml_backend_cpu_set_threadpool(state->backends.back(), state->cpu_pool);
        PARAKEET_LOG_INFO("%s: persistent CPU threadpool attached: %d threads\n", __func__,
                ctx->params.persistent_cpu_pool_threads);
    }

    const int batch_size = ctx->model.hparams.n_audio_ctx;

    state->logits.reserve(ctx->vocab.n_vocab * batch_size);

    state->batch = parakeet_batch_init(batch_size);

    {
        const int n_audio_state = ctx->model.hparams.n_audio_state;
        const int n_frames_max = parakeet_encoder_frame_count(ctx->model, batch_size);

        if (!parakeet_enc_state_init(*state, state->backend_decode_state, n_audio_state, n_frames_max)) {
            PARAKEET_LOG_ERROR("%s: parakeet_enc_state_init() failed\n", __func__);
            parakeet_free_state(state);
            return nullptr;
        }

        const size_t mem_enc_ctx = state->enc_out_buf.size();
        const size_t mem_enc_out_buf = ggml_backend_buffer_get_size(state->enc_out_buffer);
        PARAKEET_LOG_INFO("%s: enc_out state: %7.2f MB (meta) + %7.2f MB (data)\n", __func__,
                mem_enc_ctx / 1024.0 / 1024.0, mem_enc_out_buf / 1024.0 / 1024.0);
    }

    // conv/encoder allocator
    bool ok = parakeet_sched_graph_init(state->sched_encode, state->backends,
            [&]() {
                return parakeet_build_graph_encode(*ctx, *state);
            });

    if (!ok) {
        PARAKEET_LOG_ERROR("%s: failed to init encode allocator\n", __func__);
        parakeet_free_state(state);
        return nullptr;
    }
    state->sched_encode_n_audio_ctx = state->n_audio_ctx > 0 ? state->n_audio_ctx : ctx->model.hparams.n_audio_ctx;

    if (!parakeet_lstm_state_init(*state, state->backend_decode_state, ctx->model.hparams.n_pred_layers, ctx->model.hparams.n_pred_dim)) {
        PARAKEET_LOG_ERROR("%s: parakeet_lstm_states_init () failed\n", __func__);
        parakeet_free_state(state);
        return nullptr;
    }

    {
        const size_t mem_lstm_ctx = state->lstm_state.ctx_buf.size();
        const size_t mem_lstm_buf = ggml_backend_buffer_get_size(state->lstm_state.buffer);
        PARAKEET_LOG_INFO("%s: lstm state: %7.2f MB (meta) + %7.2f MB (data)\n", __func__,
                mem_lstm_ctx / 1024.0 / 1024.0, mem_lstm_buf / 1024.0 / 1024.0);
    }

    if (!parakeet_pred_state_init(*state, state->backend_decode_state, ctx->model.hparams.n_pred_dim)) {
        PARAKEET_LOG_ERROR("%s: parakeet_pred_state_init() failed\n", __func__);
        parakeet_free_state(state);
        return nullptr;
    }

    {
        const size_t mem_pred_ctx = state->pred_out_buf.size();
        const size_t mem_pred_out_buf = ggml_backend_buffer_get_size(state->pred_out_buffer);
        PARAKEET_LOG_INFO("%s: pred state: %7.2f MB (meta) + %7.2f MB (data)\n", __func__,
                mem_pred_ctx / 1024.0 / 1024.0, mem_pred_out_buf / 1024.0 / 1024.0);
    }

    if (ctx->params.tail_backend_cpu) {
        // VOICEOUR PATCH: make the no-cross-device per-step placement observable at startup.
        PARAKEET_LOG_INFO("%s: tail state buffers: enc_out=%s lstm=%s pred_out=%s\n", __func__,
                ggml_backend_buffer_name(state->enc_out_buffer),
                ggml_backend_buffer_name(state->lstm_state.buffer),
                ggml_backend_buffer_name(state->pred_out_buffer));
    }

    PARAKEET_LOG_INFO("%s: compute buffer (encode) = %7.2f MB\n", __func__, parakeet_sched_size(state->sched_encode) / 1e6);

    {
        // VOICEOUR PATCH: Metal is absent from this scheduler only when tail_backend_cpu is set.
        bool ok = parakeet_sched_graph_init(state->sched_decode, decode_backends,
                [&]() {
                    const auto & hparams = ctx->model.hparams;
                    const int n_tokens = hparams.n_audio_ctx; // Use audio ctx for Parakeet

                    parakeet_batch_prep_legacy(state->batch, nullptr, n_tokens, 0, 0);

                    return parakeet_build_graph_prediction(*ctx, *state, state->batch, true);
                });

        if (!ok) {
            PARAKEET_LOG_ERROR("%s: failed to init decoder allocator\n", __func__);
            parakeet_free_state(state);
            return nullptr;
        }

        PARAKEET_LOG_INFO("%s: compute buffer (decode) = %7.2f MB\n", __func__, parakeet_sched_size(state->sched_decode) / 1e6);
    }

    return state;
}

struct parakeet_context_params parakeet_context_default_params() {
    struct parakeet_context_params result = {
        /*.use_gpu              =*/ true,
        /*.gpu_device           =*/ 0,
        /*.tail_backend_cpu     =*/ false, // VOICEOUR PATCH: default remains the full backend list.
        /*.tail_quant_q8        =*/ false, // VOICEOUR PATCH: f16 tail by default.
        /*.persistent_cpu_pool_threads =*/ 0, // VOICEOUR PATCH: disposable pools by default.
    };
    return result;
}

// VOICEOUR PATCH: file loaders expose checked seek/tell so a validated warm arena can skip
// immutable tensor payloads while still parsing every model record.

static parakeet_context * parakeet_init_with_params_no_state_internal(
        parakeet_model_loader * loader,
        parakeet_context_params params,
        const char * path_weight_arena);

struct parakeet_file_loader_context {
    std::ifstream stream;
    int64_t size = -1;
};

static parakeet_context * parakeet_init_from_file_with_params_no_state_internal(
        const char * path_model,
        const char * path_weight_arena,
        parakeet_context_params params) {
    PARAKEET_LOG_INFO("%s: loading model from '%s'\n", __func__, path_model);
    parakeet_file_loader_context file;
#ifdef _MSC_VER
    // Convert UTF-8 path to wide string (UTF-16) for Windows, resolving character encoding issues.
    std::wstring_convert<std::codecvt_utf8<wchar_t>> converter;
    std::wstring path_model_wide = converter.from_bytes(path_model);
    file.stream.open(path_model_wide, std::ios::binary);
#else
    file.stream.open(path_model, std::ios::binary);
#endif
    if (!file.stream) {
        PARAKEET_LOG_ERROR("%s: failed to open '%s'\n", __func__, path_model);
        return nullptr;
    }
    file.stream.seekg(0, std::ios::end);
    const std::streamoff file_size = file.stream.tellg();
    if (file_size < 0 ||
            static_cast<uint64_t>(file_size) >
                static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        PARAKEET_LOG_ERROR("%s: cannot determine model size for '%s'\n", __func__, path_model);
        return nullptr;
    }
    file.size = static_cast<int64_t>(file_size);
    file.stream.seekg(0, std::ios::beg);

    parakeet_model_loader loader = {};
    loader.context = &file;
    loader.read = [](void * opaque, void * output, size_t read_size) {
        auto * context = static_cast<parakeet_file_loader_context *>(opaque);
        if (read_size > static_cast<size_t>(std::numeric_limits<std::streamsize>::max())) {
            return size_t(0);
        }
        context->stream.read(static_cast<char *>(output), static_cast<std::streamsize>(read_size));
        return static_cast<size_t>(context->stream.gcount());
    };
    loader.seek = [](void * opaque, int64_t offset, int whence) {
        auto * context = static_cast<parakeet_file_loader_context *>(opaque);
        int64_t base = 0;
        if (whence == SEEK_CUR) {
            const std::streamoff current = context->stream.tellg();
            if (current < 0 ||
                    static_cast<uint64_t>(current) >
                        static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
                return false;
            }
            base = static_cast<int64_t>(current);
        } else if (whence == SEEK_END) {
            base = context->size;
        } else if (whence != SEEK_SET) {
            return false;
        }
        if ((offset > 0 && base > std::numeric_limits<int64_t>::max() - offset) ||
                (offset < 0 &&
                    (offset == std::numeric_limits<int64_t>::min() || base < -offset))) {
            return false;
        }
        const int64_t target = base + offset;
        if (target < 0 || target > context->size) {
            return false;
        }
        context->stream.clear();
        context->stream.seekg(static_cast<std::streamoff>(target), std::ios::beg);
        return static_cast<bool>(context->stream);
    };
    loader.tell = [](void * opaque) {
        auto * context = static_cast<parakeet_file_loader_context *>(opaque);
        const std::streamoff current = context->stream.tellg();
        if (current < 0 ||
                static_cast<uint64_t>(current) >
                    static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
            return int64_t(-1);
        }
        return static_cast<int64_t>(current);
    };
    loader.eof = [](void * opaque) {
        return static_cast<parakeet_file_loader_context *>(opaque)->stream.eof();
    };
    loader.close = [](void * opaque) {
        static_cast<parakeet_file_loader_context *>(opaque)->stream.close();
    };

    parakeet_context * context =
        parakeet_init_with_params_no_state_internal(&loader, params, path_weight_arena);
    if (context) {
        context->path_model = path_model;
    }
    return context;
}

parakeet_context * parakeet_init_from_file_with_params_no_state(
        const char * path_model,
        parakeet_context_params params) {
    return parakeet_init_from_file_with_params_no_state_internal(path_model, nullptr, params);
}

struct parakeet_context * parakeet_init_from_buffer_with_params_no_state(void * buffer, size_t buffer_size, struct parakeet_context_params params) {
    struct buf_context {
        uint8_t* buffer;
        size_t size;
        size_t current_offset;
    };

    buf_context ctx = { reinterpret_cast<uint8_t*>(buffer), buffer_size, 0 };

    PARAKEET_LOG_INFO("%s: loading model from buffer\n", __func__);

    parakeet_model_loader loader = {};

    loader.context = &ctx;

    loader.read = [](void * ctx, void * output, size_t read_size) {
        buf_context * buf = reinterpret_cast<buf_context *>(ctx);
        const size_t remaining =
            buf->current_offset <= buf->size ? buf->size - buf->current_offset : 0;
        const size_t size_to_copy = std::min(read_size, remaining);
        memcpy(output, buf->buffer + buf->current_offset, size_to_copy);
        buf->current_offset += size_to_copy;
        return size_to_copy;
    };

    loader.seek = [](void * ctx, int64_t offset, int whence) {
        buf_context * buf = reinterpret_cast<buf_context *>(ctx);
        int64_t base = 0;
        if (whence == SEEK_CUR) {
            if (buf->current_offset > static_cast<size_t>(std::numeric_limits<int64_t>::max())) {
                return false;
            }
            base = static_cast<int64_t>(buf->current_offset);
        } else if (whence == SEEK_END) {
            if (buf->size > static_cast<size_t>(std::numeric_limits<int64_t>::max())) {
                return false;
            }
            base = static_cast<int64_t>(buf->size);
        } else if (whence != SEEK_SET) {
            return false;
        }
        if ((offset > 0 && base > std::numeric_limits<int64_t>::max() - offset) ||
                (offset < 0 &&
                    (offset == std::numeric_limits<int64_t>::min() || base < -offset))) {
            return false;
        }
        const int64_t target = base + offset;
        if (target < 0 || static_cast<uint64_t>(target) > static_cast<uint64_t>(buf->size)) {
            return false;
        }
        buf->current_offset = static_cast<size_t>(target);
        return true;
    };
    loader.tell = [](void * ctx) {
        const buf_context * buf = reinterpret_cast<const buf_context *>(ctx);
        return buf->current_offset <= static_cast<size_t>(std::numeric_limits<int64_t>::max())
            ? static_cast<int64_t>(buf->current_offset)
            : int64_t(-1);
    };

    loader.eof = [](void * ctx) {
        buf_context * buf = reinterpret_cast<buf_context *>(ctx);

        return buf->current_offset >= buf->size;
    };

    loader.close = [](void * /*ctx*/) { };

    return parakeet_init_with_params_no_state_internal(&loader, params, nullptr);
}

static parakeet_context * parakeet_init_with_params_no_state_internal(
        parakeet_model_loader * loader,
        parakeet_context_params params,
        const char * path_weight_arena) {
    ggml_time_init();

    PARAKEET_LOG_INFO("%s: use gpu    = %d\n", __func__, params.use_gpu);
    PARAKEET_LOG_INFO("%s: gpu_device = %d\n", __func__, params.gpu_device);
    PARAKEET_LOG_INFO("%s: devices    = %zu\n", __func__, ggml_backend_dev_count());
    PARAKEET_LOG_INFO("%s: backends   = %zu\n", __func__, ggml_backend_reg_count());

    parakeet_context * ctx = new parakeet_context;
    ctx->params = params;

    bool model_loaded = false;
    try {
        model_loaded = parakeet_model_load(loader, *ctx, path_weight_arena);
    } catch (const std::exception & e) {
        PARAKEET_LOG_ERROR("%s: exception during model load: %s\n", __func__, e.what());
    } catch (...) {
        PARAKEET_LOG_ERROR("%s: unknown exception during model load\n", __func__);
    }

    if (!model_loaded) {
        loader->close(loader->context);
        PARAKEET_LOG_ERROR("%s: failed to load model\n", __func__);
        parakeet_free(ctx);
        return nullptr;
    }

    loader->close(loader->context);

    // Initialize mel cache with model's FFT size
    ctx->mel_cache.init(ctx->model.hparams.n_fft);
    PARAKEET_LOG_INFO("%s: initialized mel cache with n_fft = %d\n", __func__, ctx->model.hparams.n_fft);

    return ctx;
}

parakeet_context * parakeet_init_with_params_no_state(
        parakeet_model_loader * loader,
        parakeet_context_params params) {
    return parakeet_init_with_params_no_state_internal(loader, params, nullptr);
}

struct parakeet_context * parakeet_init_from_file_with_params(const char * path_model, struct parakeet_context_params params) {
    parakeet_context * ctx = parakeet_init_from_file_with_params_no_state(path_model, params);
    if (!ctx) {
        return nullptr;
    }

    ctx->state = parakeet_init_state(ctx);
    if (!ctx->state) {
        parakeet_free(ctx);
        return nullptr;
    }

    return ctx;
}

// VOICEOUR PATCH: explicit production entry point for the derived weight arena.
parakeet_context * parakeet_init_from_file_with_params_and_weight_arena(
        const char * path_model,
        const char * path_weight_arena,
        parakeet_context_params params) {
    parakeet_context * ctx =
        parakeet_init_from_file_with_params_no_state_internal(path_model, path_weight_arena, params);
    if (!ctx) {
        return nullptr;
    }

    ctx->state = parakeet_init_state(ctx);
    if (!ctx->state) {
        parakeet_free(ctx);
        return nullptr;
    }
    return ctx;
}

bool parakeet_remove_weight_arena(const char * path_weight_arena) {
#ifndef _WIN32
    return
        path_weight_arena != nullptr &&
        path_weight_arena[0] != '\0' &&
        parakeet_remove_weight_arena_files(path_weight_arena);
#else
    GGML_UNUSED(path_weight_arena);
    return false;
#endif
}

struct parakeet_context * parakeet_init_from_buffer_with_params(void * buffer, size_t buffer_size, struct parakeet_context_params params) {
    parakeet_context * ctx = parakeet_init_from_buffer_with_params_no_state(buffer, buffer_size, params);
    if (!ctx) {
        return nullptr;
    }

    ctx->state = parakeet_init_state(ctx);
    if (!ctx->state) {
        parakeet_free(ctx);
        return nullptr;
    }

    return ctx;
}

struct parakeet_context * parakeet_init_with_params(struct parakeet_model_loader * loader, struct parakeet_context_params params) {
    parakeet_context * ctx = parakeet_init_with_params_no_state(loader, params);
    if (!ctx) {
        return nullptr;
    }

    ctx->state = parakeet_init_state(ctx);
    if (!ctx->state) {
        parakeet_free(ctx);
        return nullptr;
    }

    return ctx;
}

void parakeet_free_state(struct parakeet_state * state) {
    if (state) {
        // VOICEOUR PATCH: detach and join the persistent CPU pool before its backend dies.
        if (state->cpu_pool) {
            if (!state->backends.empty()) {
                ggml_backend_cpu_set_threadpool(state->backends.back(), nullptr);
            }
            ggml_threadpool_free(state->cpu_pool);
        }
        ggml_backend_buffer_free(state->lstm_state.buffer);
        ggml_backend_buffer_free(state->pred_out_buffer);
        ggml_backend_buffer_free(state->enc_out_buffer);

        parakeet_batch_free(state->batch);

        parakeet_sched_free(state->sched_encode);
        parakeet_sched_free(state->sched_decode);

        for (auto & backend : state->backends) {
            ggml_backend_free(backend);
        }

        delete state;
    }
}

void parakeet_free(struct parakeet_context * ctx) {
    if (ctx) {
        for (ggml_context * context : ctx->model.ctxs) {
            ggml_free(context);
        }

        for (ggml_backend_buffer_t buf : ctx->model.buffers) {
            ggml_backend_buffer_free(buf);
        }
#ifndef _WIN32
        // VOICEOUR PATCH: mapped buffer wrappers above own=false; release them before the map.
        parakeet_release_weight_arena_storage(ctx->model);
#endif

        parakeet_free_state(ctx->state);

        delete ctx;
    }
}

void parakeet_free_context_params(struct parakeet_context_params * params) {
    if (params) {
        delete params;
    }
}

void parakeet_free_params(struct parakeet_full_params * params) {
    if (params) {
        delete params;
    }
}

int parakeet_pcm_to_mel_with_state(struct parakeet_context * ctx, struct parakeet_state * state, const float * samples, int n_samples, int n_threads) {
    if (!log_mel_spectrogram(*state,
                samples,
                n_samples,
                PARAKEET_SAMPLE_RATE,
                ctx->model.hparams.n_fft,
                PARAKEET_HOP_LENGTH,
                ctx->model.filters.n_mel,
                n_threads,
                ctx->model.filters,
                false,                        // debug
                // VOICEOUR PATCH: `normalize: NA` for the speaker-kernel files.
                ctx->model.spk_ff1_w == nullptr,
                state->mel,
                ctx->mel_cache)) {
        PARAKEET_LOG_ERROR("%s: failed to compute mel spectrogram\n", __func__);
        return -1;
    }

    return 0;
}

int parakeet_pcm_to_mel(struct parakeet_context * ctx, const float * samples, int n_samples, int n_threads) {
    return parakeet_pcm_to_mel_with_state(ctx, ctx->state, samples, n_samples, n_threads);
}

// VOICEOUR PATCH: expose the native frontend output to an external encoder without copying it.
const float * parakeet_get_mel_data(struct parakeet_context * ctx) {
    if (!ctx || !ctx->state || ctx->state->mel.data.empty()) {
        return nullptr;
    }
    return ctx->state->mel.data.data();
}

int parakeet_set_mel_with_state(
        struct parakeet_context * ctx,
          struct parakeet_state * state,
                   const float * data,
                           int   n_len,
                           int   n_mel) {
    if (n_mel != ctx->model.filters.n_mel) {
        PARAKEET_LOG_ERROR("%s: invalid number of mel bands: %d (expected %d)\n", __func__, n_mel, ctx->model.filters.n_mel);
        return -1;
    }

    state->mel.n_len     = n_len;
    state->mel.n_len_org = n_len;
    state->mel.n_mel     = n_mel;

    state->mel.data.resize(n_len*n_mel);
    memcpy(state->mel.data.data(), data, n_len*n_mel*sizeof(float));

    return 0;
}

int parakeet_set_mel(
        struct parakeet_context * ctx,
        const float * data,
        int n_len,
        int n_mel) {
    return parakeet_set_mel_with_state(ctx, ctx->state, data, n_len, n_mel);
}

int parakeet_encode_with_state(struct parakeet_context * ctx, struct parakeet_state * state, int offset, int n_threads) {
    if (!parakeet_encode_internal(*ctx, *state, offset, n_threads, nullptr, nullptr)) {
        PARAKEET_LOG_ERROR("%s: failed to eval\n", __func__);
        return -1;
    }

    return 0;
}

int parakeet_encode(struct parakeet_context * ctx, int offset, int n_threads) {
    if (!parakeet_encode_internal(*ctx, *ctx->state, offset, n_threads, nullptr, nullptr)) {
        PARAKEET_LOG_ERROR("%s: failed to eval\n", __func__);
        return -1;
    }

    return 0;
}

int parakeet_tokenize(struct parakeet_context * ctx, const char * text, parakeet_token * tokens, int n_max_tokens) {
    const auto res = tokenize(ctx->vocab, text);

    if (n_max_tokens < (int) res.size()) {
        PARAKEET_LOG_ERROR("%s: too many resulting tokens: %d (max %d)\n", __func__, (int) res.size(), n_max_tokens);
        return -(int) res.size();
    }

    for (int i = 0; i < (int) res.size(); i++) {
        tokens[i] = res[i];
    }

    return res.size();
}

int parakeet_token_count(struct parakeet_context * ctx, const char * text) {
    return -parakeet_tokenize(ctx, text, NULL, 0);
}

int parakeet_model_n_vocab(struct parakeet_context * ctx) {
    return ctx->model.hparams.n_vocab;
}

int parakeet_model_n_audio_ctx(struct parakeet_context * ctx) {
    return ctx->model.hparams.n_audio_ctx;
}

int parakeet_model_n_audio_state(struct parakeet_context * ctx) {
    return ctx->model.hparams.n_audio_state;
}

int parakeet_model_n_audio_head(struct parakeet_context * ctx) {
    return ctx->model.hparams.n_audio_head;
}

int parakeet_model_n_audio_layer(struct parakeet_context * ctx) {
    return ctx->model.hparams.n_audio_layer;
}

int parakeet_model_n_mels(struct parakeet_context * ctx) {
    return ctx->model.hparams.n_mels;
}

int parakeet_model_ftype(struct parakeet_context * ctx) {
    return ctx->model.hparams.ftype;
}

int parakeet_n_len_from_state(struct parakeet_state * state) {
    return state->mel.n_len_org;
}

int parakeet_n_len(struct parakeet_context * ctx) {
    return ctx->state->mel.n_len_org;
}

int parakeet_n_vocab(struct parakeet_context * ctx) {
    return ctx->vocab.n_vocab;
}

int parakeet_n_audio_ctx(struct parakeet_context * ctx) {
    return ctx->model.hparams.n_audio_ctx;
}

float * parakeet_get_logits(struct parakeet_context * ctx) {
    return ctx->state->logits.data();
}

float * parakeet_get_logits_from_state(struct parakeet_state * state) {
    return state->logits.data();
}

const char * parakeet_token_to_str(struct parakeet_context * ctx, parakeet_token token) {
    return ctx->vocab.id_to_token.at(token).c_str();
}

int parakeet_token_to_text(const char * token_str, bool is_first, char * output, int max_len) {
    std::string text = sentencepiece_piece_to_text(token_str, is_first);

    if (output == nullptr) {
        return text.size();
    }

    int bytes_to_copy = std::min((int)text.size(), max_len - 1);
    if (bytes_to_copy > 0) {
        memcpy(output, text.c_str(), bytes_to_copy);
        output[bytes_to_copy] = '\0';
    } else if (max_len > 0) {
        output[0] = '\0';
    }

    return text.size();
}

parakeet_token parakeet_token_bos(struct parakeet_context * ctx) {
    return ctx->vocab.token_bos;
}

parakeet_token parakeet_token_unk(struct parakeet_context * ctx) {
    return ctx->vocab.token_unk;
}

parakeet_token parakeet_token_blank(struct parakeet_context * ctx) {
    return ctx->vocab.token_blank;
}

struct parakeet_timings * parakeet_get_timings(struct parakeet_context * ctx) {
    if (ctx->state == nullptr) {
        return nullptr;
    }
    parakeet_timings * timings = new parakeet_timings;
    timings->sample_ms = 1e-3f * ctx->state->t_sample_us / std::max(1, ctx->state->n_sample);
    timings->encode_ms = 1e-3f * ctx->state->t_encode_us / std::max(1, ctx->state->n_encode);
    timings->decode_ms = 1e-3f * ctx->state->t_decode_us / std::max(1, ctx->state->n_decode);
    return timings;
}

void parakeet_print_timings(struct parakeet_context * ctx) {
    const int64_t t_end_us = ggml_time_us();

    PARAKEET_LOG_INFO("\n");
    PARAKEET_LOG_INFO("%s:     load time = %8.2f ms\n", __func__, ctx->t_load_us / 1000.0f);
    if (ctx->state != nullptr) {

        const int32_t n_sample  = std::max(1, ctx->state->n_sample);
        const int32_t n_encode  = std::max(1, ctx->state->n_encode);
        const int32_t n_decode  = std::max(1, ctx->state->n_decode);
        const int32_t n_predict = std::max(1, ctx->state->n_predict);

        PARAKEET_LOG_INFO("%s:     fallbacks = %3d p / %3d h\n", __func__, ctx->state->n_fail_p, ctx->state->n_fail_h);
        PARAKEET_LOG_INFO("%s:      mel time = %8.2f ms\n", __func__, ctx->state->t_mel_us / 1000.0f);
        PARAKEET_LOG_INFO("%s:   sample time = %8.2f ms / %5d runs ( %8.2f ms per run)\n", __func__, 1e-3f * ctx->state->t_sample_us, n_sample, 1e-3f * ctx->state->t_sample_us / n_sample);
        PARAKEET_LOG_INFO("%s:   encode time = %8.2f ms / %5d runs ( %8.2f ms per run)\n", __func__, 1e-3f * ctx->state->t_encode_us, n_encode, 1e-3f * ctx->state->t_encode_us / n_encode);
        PARAKEET_LOG_INFO("%s:   decode time = %8.2f ms / %5d runs ( %8.2f ms per run)\n", __func__, 1e-3f * ctx->state->t_decode_us, n_decode, 1e-3f * ctx->state->t_decode_us / n_decode);
        PARAKEET_LOG_INFO("%s:  predict time = %8.2f ms / %5d runs ( %8.2f ms per run)\n", __func__, 1e-3f * ctx->state->t_predict_us, n_predict, 1e-3f * ctx->state->t_predict_us / n_predict);
        PARAKEET_LOG_INFO("%s:    - build     = %8.2f ms / %5d runs ( %8.2f ms per run)\n", __func__, 1e-3f * ctx->state->t_predict_build_us, n_predict, 1e-3f * ctx->state->t_predict_build_us / n_predict);
        PARAKEET_LOG_INFO("%s:    - alloc     = %8.2f ms / %5d runs ( %8.2f ms per run)\n", __func__, 1e-3f * ctx->state->t_predict_alloc_us, n_predict, 1e-3f * ctx->state->t_predict_alloc_us / n_predict);
        PARAKEET_LOG_INFO("%s:    - compute   = %8.2f ms / %5d runs ( %8.2f ms per run)\n", __func__, 1e-3f * ctx->state->t_predict_compute_us, n_predict, 1e-3f * ctx->state->t_predict_compute_us / n_predict);

    }
    PARAKEET_LOG_INFO("%s:    total time = %8.2f ms\n", __func__, (t_end_us - ctx->t_start_us)/1000.0f);
}

void parakeet_reset_timings(struct parakeet_context * ctx) {
    ctx->t_start_us = ggml_time_us();
    if (ctx->state != nullptr) {
        ctx->state->t_mel_us = 0;
        ctx->state->t_sample_us = 0;
        ctx->state->t_encode_us = 0;
        ctx->state->t_decode_us = 0;
        ctx->state->t_predict_us = 0;
        ctx->state->t_predict_build_us = 0;
        ctx->state->t_predict_alloc_us = 0;
        ctx->state->t_predict_compute_us = 0;

        ctx->state->n_sample = 0;
        ctx->state->n_encode = 0;
        ctx->state->n_decode = 0;
        ctx->state->n_predict = 0;
    }
}

const char * parakeet_print_system_info(void) {
    static std::string s;

    s  = "";
    s += "PARAKEET : ";

    for (size_t i = 0; i < ggml_backend_reg_count(); i++) {
        auto * reg = ggml_backend_reg_get(i);
        auto * get_features_fn = (ggml_backend_get_features_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_get_features");
        if (get_features_fn) {
            ggml_backend_feature * features = get_features_fn(reg);
            s += ggml_backend_reg_name(reg);
            s += " : ";
            for (; features->name; features++) {
                s += features->name;
                s += " = ";
                s += features->value;
                s += " | ";
            }
        }
    }
    return s.c_str();
}

struct parakeet_context_params * parakeet_context_default_params_by_ref(void) {
    struct parakeet_context_params params = parakeet_context_default_params();

    struct parakeet_context_params* result = new parakeet_context_params();
    *result = params;
    return result;
}

struct parakeet_full_params * parakeet_full_default_params_by_ref(enum parakeet_sampling_strategy strategy) {
    struct parakeet_full_params params = parakeet_full_default_params(strategy);

    struct parakeet_full_params* result = new parakeet_full_params();
    *result = params;
    return result;
}

struct parakeet_full_params parakeet_full_default_params(enum parakeet_sampling_strategy strategy) {
    struct parakeet_full_params result = {
        /*.strategy                         =*/ strategy,
        /*.n_threads                        =*/ std::min(4, (int32_t) std::thread::hardware_concurrency()),
        /*.offset_ms                        =*/ 0,
        /*.duration_ms                      =*/ 0,
        /*.no_context                       =*/ true,
        /*.audio_ctx                        =*/ 0,
        /*.new_token_callback               =*/ nullptr,
        /*.new_token_callback_user_data     =*/ nullptr,
        /*.decode_step_callback             =*/ nullptr,
        /*.decode_step_callback_user_data   =*/ nullptr,
        /*.new_segment_callback             =*/ nullptr,
        /*.new_segment_callback_user_data   =*/ nullptr,
        /*.progress_callback                =*/ nullptr,
        /*.progress_callback_user_data      =*/ nullptr,
        /*.encoder_begin_callback           =*/ nullptr,
        /*.encoder_begin_callback_user_data =*/ nullptr,
        /*.abort_callback                   =*/ nullptr,
        /*.abort_callback_user_data         =*/ nullptr,
    };

    return result;
}

static void parakeet_reset_state(struct parakeet_state * state) {
    state->decoded_tokens.clear();
    state->decoded_token_data.clear();

    if (state->lstm_state.buffer) {
        ggml_backend_buffer_clear(state->lstm_state.buffer, 0);
    }

}

// Encode and decode the mel spectrogram already in state, without recomputing it.
static int parakeet_chunk_with_state(
      struct parakeet_context   * ctx,
        struct parakeet_state   * state,
    struct parakeet_full_params   params) {
    return parakeet_chunk(ctx, state, params, nullptr, 0);
}

int parakeet_full_with_state(
        struct parakeet_context * ctx,
          struct parakeet_state * state,
    struct parakeet_full_params   params,
                    const float * samples,
                           int    n_samples) {
    state->result_all.clear();

    // VOICEOUR PATCH: quiesce the persistent CPU pool on every return path.
    parakeet_cpu_pool_quiescer cpu_pool_quiescer { state->cpu_pool };

    if (params.no_context) {
        parakeet_reset_state(state);
    }

    if (n_samples > 0) {
        if (parakeet_pcm_to_mel_with_state(ctx, state, samples, n_samples, params.n_threads) != 0) {
            PARAKEET_LOG_ERROR("%s: failed to compute log mel spectrogram\n", __func__);
            return -2;
        }
    }

    const int n_mel_total = state->mel.n_len;
    const int n_audio_ctx = ctx->model.hparams.n_audio_ctx;

    if (n_mel_total <= n_audio_ctx) {
        if (params.progress_callback) {
            params.progress_callback(ctx, state, 0, params.progress_callback_user_data);
        }
        return parakeet_chunk_with_state(ctx, state, params);
    }

    PARAKEET_LOG_DEBUG("%s: audio too long (%d mel > n_audio_ctx=%d), using dynamic encoder graph\n",
                       __func__, n_mel_total, n_audio_ctx);

    if (params.encoder_begin_callback) {
        if (!params.encoder_begin_callback(ctx, state, params.encoder_begin_callback_user_data)) {
            PARAKEET_LOG_ERROR("%s: encoder_begin_callback returned false\n", __func__);
            return -6;
        }
    }

    if (params.progress_callback) {
        params.progress_callback(ctx, state, 0, params.progress_callback_user_data);
    }

    if (!parakeet_ensure_encode_sched(*ctx, *state, n_mel_total)) {
        PARAKEET_LOG_ERROR("%s: failed to allocate dynamic encoder graph for %d mel frames\n",
                __func__, n_mel_total);
        return -6;
    }

    state->n_audio_ctx = n_mel_total;

    if (!parakeet_encode_internal(*ctx, *state, 0, params.n_threads,
                                  params.abort_callback, params.abort_callback_user_data)) {
        PARAKEET_LOG_ERROR("%s: failed to encode\n", __func__);
        return -6;
    }

    if (params.progress_callback) {
        params.progress_callback(ctx, state, 100, params.progress_callback_user_data);
    }

    const size_t tokens_before = state->decoded_tokens.size();

    if (!parakeet_decode(*ctx, *state, state->batch, params.n_threads, &params)) {
        PARAKEET_LOG_ERROR("%s: failed to decode\n", __func__);
        return -7;
    }

    const size_t tokens_after    = state->decoded_tokens.size();
    const size_t new_token_count = tokens_after - tokens_before;

    if (new_token_count > 0) {
        std::string text;
        std::vector<parakeet_token_data> result_tokens;

        for (size_t i = tokens_before; i < tokens_after; i++) {
            const auto token_id  = state->decoded_tokens[i];
            const char * tok_str = parakeet_token_to_str(ctx, token_id);
            if (tok_str) {
                const bool is_first = (tokens_before == 0) && text.empty();
                text += sentencepiece_piece_to_text(tok_str, is_first);
            }
            result_tokens.push_back(state->decoded_token_data[i]);
        }

        refine_timestamps_tdt(ctx->vocab, result_tokens);

        if (!text.empty()) {
            parakeet_segment seg;
            seg.t0     = 0;
            seg.t1     = state->n_frames;
            seg.text   = text;
            seg.tokens = result_tokens;
            state->result_all.push_back(std::move(seg));

            if (params.new_segment_callback) {
                params.new_segment_callback(ctx, state, 1, params.new_segment_callback_user_data);
            }
        }
    }

    return 0;
}

// VOICEOUR PATCH: inject an external encoder result, then run the existing greedy TDT tail and
// result construction. The ordinary parakeet_full path never calls this entry point.
int parakeet_full_with_external_encoder(
        struct parakeet_context * ctx,
    struct parakeet_full_params   params,
                    const float * samples,
                           int    n_samples,
                    const float * encoder_states,
                           int    n_encoder_frames,
                           int    n_encoder_state) {
    if (!ctx || !ctx->state) {
        PARAKEET_LOG_ERROR("%s: context has no default state\n", __func__);
        return -8;
    }

    struct parakeet_state * state = ctx->state;
    state->result_all.clear();

    // VOICEOUR PATCH: quiesce the persistent CPU pool on every return path.
    parakeet_cpu_pool_quiescer cpu_pool_quiescer { state->cpu_pool };

    if (params.no_context) {
        parakeet_reset_state(state);
    }

    if (n_samples > 0) {
        if (parakeet_pcm_to_mel_with_state(ctx, state, samples, n_samples, params.n_threads) != 0) {
            PARAKEET_LOG_ERROR("%s: failed to compute log mel spectrogram\n", __func__);
            return -2;
        }
    }

    const int subsampling_factor = ctx->model.hparams.subsampling_factor;
    const int expected_frames = (state->mel.n_len + subsampling_factor - 1) / subsampling_factor;
    if (!encoder_states || !state->enc_out || state->mel.n_len <= 0 ||
            n_encoder_frames != expected_frames ||
            n_encoder_state != ctx->model.hparams.n_audio_state ||
            state->enc_out->ne[0] != n_encoder_state ||
            n_encoder_frames > state->enc_out->ne[1]) {
        PARAKEET_LOG_ERROR(
            "%s: invalid external encoder shape: mel=%d expected=[%d,%d] got=[%d,%d] capacity=[%lld,%lld]\n",
            __func__,
            state->mel.n_len,
            expected_frames,
            ctx->model.hparams.n_audio_state,
            n_encoder_frames,
            n_encoder_state,
            state->enc_out ? (long long) state->enc_out->ne[1] : 0,
            state->enc_out ? (long long) state->enc_out->ne[0] : 0);
        return -8;
    }

    if (params.encoder_begin_callback) {
        if (!params.encoder_begin_callback(ctx, state, params.encoder_begin_callback_user_data)) {
            PARAKEET_LOG_ERROR("%s: encoder_begin_callback returned false\n", __func__);
            return -6;
        }
    }
    if (params.progress_callback) {
        params.progress_callback(ctx, state, 0, params.progress_callback_user_data);
    }
    if (params.abort_callback && params.abort_callback(params.abort_callback_user_data)) {
        return -6;
    }

    state->n_frames = n_encoder_frames;
    ggml_backend_tensor_set(
        state->enc_out,
        encoder_states,
        0,
        (size_t) n_encoder_frames * (size_t) n_encoder_state * sizeof(float));

    if (params.abort_callback && params.abort_callback(params.abort_callback_user_data)) {
        return -6;
    }
    if (params.progress_callback) {
        params.progress_callback(ctx, state, 100, params.progress_callback_user_data);
    }

    const size_t tokens_before = state->decoded_tokens.size();

    if (!parakeet_decode(*ctx, *state, state->batch, params.n_threads, &params)) {
        PARAKEET_LOG_ERROR("%s: failed to decode\n", __func__);
        return -7;
    }

    const size_t tokens_after    = state->decoded_tokens.size();
    const size_t new_token_count = tokens_after - tokens_before;

    if (new_token_count > 0) {
        std::string text;
        std::vector<parakeet_token_data> result_tokens;

        for (size_t i = tokens_before; i < tokens_after; i++) {
            const auto token_id  = state->decoded_tokens[i];
            const char * tok_str = parakeet_token_to_str(ctx, token_id);
            if (tok_str) {
                const bool is_first = (tokens_before == 0) && text.empty();
                text += sentencepiece_piece_to_text(tok_str, is_first);
            }
            result_tokens.push_back(state->decoded_token_data[i]);
        }

        refine_timestamps_tdt(ctx->vocab, result_tokens);

        if (!text.empty()) {
            parakeet_segment seg;
            seg.t0     = 0;
            seg.t1     = state->n_frames;
            seg.text   = text;
            seg.tokens = result_tokens;
            state->result_all.push_back(std::move(seg));

            if (params.new_segment_callback) {
                params.new_segment_callback(ctx, state, 1, params.new_segment_callback_user_data);
            }
        }
    }

    return 0;
}

int parakeet_full(
        struct parakeet_context * ctx,
    struct parakeet_full_params   params,
                    const float * samples,
                            int   n_samples) {
    return parakeet_full_with_state(ctx, ctx->state, params, samples, n_samples);
}

int parakeet_chunk(
        struct parakeet_context * ctx,
          struct parakeet_state * state,
    struct parakeet_full_params   params,
                    const float * samples,
                            int   n_samples) {

    // VOICEOUR PATCH: quiesce the persistent CPU pool on every return path.
    parakeet_cpu_pool_quiescer cpu_pool_quiescer { state->cpu_pool };

    if (params.no_context) {
        parakeet_reset_state(state);
    }

    if (n_samples > 0) {
        if (parakeet_pcm_to_mel_with_state(ctx, state, samples, n_samples, params.n_threads) != 0) {
            PARAKEET_LOG_ERROR("%s: failed to compute log mel spectrogram\n", __func__);
            return -2;
        }
    }

    if (params.audio_ctx == 0) {
        const int total_len = parakeet_n_len_from_state(state);
        const int model_max_ctx = parakeet_n_audio_ctx(ctx);
        params.audio_ctx = std::min(total_len, model_max_ctx);
        PARAKEET_LOG_DEBUG("Processing audio: total_frames=%d, chunk_size=%d\n", total_len, params.audio_ctx);
    }
    state->n_audio_ctx = params.audio_ctx;

    const int n_frames = parakeet_n_len_from_state(state);

    if (!parakeet_ensure_encode_sched(*ctx, *state, state->n_audio_ctx)) {
        PARAKEET_LOG_ERROR("%s: failed to allocate encoder graph for %d mel frames\n",
                __func__, state->n_audio_ctx);
        return -6;
    }

    if (params.encoder_begin_callback) {
        if (!params.encoder_begin_callback(ctx, state, params.encoder_begin_callback_user_data)) {
            PARAKEET_LOG_ERROR("%s: encoder_begin_callback returned false - aborting\n", __func__);
            return -6;
        }
    }
    if (!parakeet_encode_internal(*ctx, *state, 0, params.n_threads, params.abort_callback, params.abort_callback_user_data)) {
        PARAKEET_LOG_ERROR("%s: failed to encode\n", __func__);
        return -6;
    }

    const size_t tokens_before = state->decoded_tokens.size();

    if (!parakeet_decode(*ctx, *state, state->batch, params.n_threads, &params)) {
        PARAKEET_LOG_ERROR("%s: failed to decode\n", __func__);
        return -7;
    }

    const size_t tokens_after = state->decoded_tokens.size();
    const size_t new_token_count = tokens_after - tokens_before;

    if (new_token_count > 0) {
        std::string text;
        std::vector<parakeet_token_data> result_tokens;

        for (size_t i = tokens_before; i < tokens_after; i++) {
            const auto token_id = state->decoded_tokens[i];
            const char * token_str = parakeet_token_to_str(ctx, token_id);
            if (token_str) {
                const bool is_first_piece = (tokens_before == 0) && text.empty();
                text += sentencepiece_piece_to_text(token_str, is_first_piece);
            }

            // Use the stored token data from parakeet_decode
            result_tokens.push_back(state->decoded_token_data[i]);
        }

        refine_timestamps_tdt(ctx->vocab, result_tokens);

        if (!text.empty()) {
            parakeet_segment segment;
            segment.t0 = 0; // Caller tracks timing
            segment.t1 = n_frames;
            segment.text = text;
            segment.tokens = result_tokens;

            state->result_all.push_back(std::move(segment));

            if (params.new_segment_callback) {
                params.new_segment_callback(ctx, state, 1, params.new_segment_callback_user_data);
            }
        }
    }

    return 0;
}

int parakeet_full_n_segments_from_state(struct parakeet_state * state) {
    return state->result_all.size();
}

int parakeet_full_n_segments(struct parakeet_context * ctx) {
    return ctx->state->result_all.size();
}

int64_t parakeet_full_get_segment_t0_from_state(struct parakeet_state * state, int i_segment) {
    return state->result_all[i_segment].t0;
}

int64_t parakeet_full_get_segment_t1_from_state(struct parakeet_state * state, int i_segment) {
    return state->result_all[i_segment].t1;
}

int64_t parakeet_full_get_segment_t0(struct parakeet_context * ctx, int i_segment) {
    return parakeet_full_get_segment_t0_from_state(ctx->state, i_segment);
}

int64_t parakeet_full_get_segment_t1(struct parakeet_context * ctx, int i_segment) {
    return parakeet_full_get_segment_t1_from_state(ctx->state, i_segment);
}

const char * parakeet_full_get_segment_text_from_state(struct parakeet_state * state, int i_segment) {
    return state->result_all[i_segment].text.c_str();
}

const char * parakeet_full_get_segment_text(struct parakeet_context * ctx, int i_segment) {
    return ctx->state->result_all[i_segment].text.c_str();
}

int parakeet_full_n_tokens_from_state(struct parakeet_state * state, int i_segment) {
    return state->result_all[i_segment].tokens.size();
}

int parakeet_full_n_tokens(struct parakeet_context * ctx, int i_segment) {
    return ctx->state->result_all[i_segment].tokens.size();
}

const char * parakeet_full_get_token_text_from_state(struct parakeet_context * ctx, struct parakeet_state * state, int i_segment, int i_token) {
    return ctx->vocab.id_to_token[state->result_all[i_segment].tokens[i_token].id].c_str();
}

const char* parakeet_full_get_token_text(struct parakeet_context * ctx, int i_segment, int i_token) {
    return ctx->vocab.id_to_token[ctx->state->result_all[i_segment].tokens[i_token].id].c_str();
}

parakeet_token parakeet_full_get_token_id_from_state(struct parakeet_state * state, int i_segment, int i_token) {
    return state->result_all[i_segment].tokens[i_token].id;
}

parakeet_token parakeet_full_get_token_id(struct parakeet_context * ctx, int i_segment, int i_token) {
    return ctx->state->result_all[i_segment].tokens[i_token].id;
}

struct parakeet_token_data parakeet_full_get_token_data_from_state(struct parakeet_state * state, int i_segment, int i_token) {
    return state->result_all[i_segment].tokens[i_token];
}

struct parakeet_token_data parakeet_full_get_token_data(struct parakeet_context * ctx, int i_segment, int i_token) {
    return ctx->state->result_all[i_segment].tokens[i_token];
}

float parakeet_full_get_token_p_from_state(struct parakeet_state * state, int i_segment, int i_token) {
    return state->result_all[i_segment].tokens[i_token].p;
}

float parakeet_full_get_token_p(struct parakeet_context * ctx, int i_segment, int i_token) {
    return ctx->state->result_all[i_segment].tokens[i_token].p;
}

void parakeet_log_set(ggml_log_callback log_callback, void * user_data) {
    g_state.log_callback = log_callback ? log_callback : parakeet_log_callback_default;
    g_state.log_callback_user_data = user_data;
    ggml_log_set(g_state.log_callback, g_state.log_callback_user_data);
}

const char * parakeet_version(void) {
    return PARAKEET_VERSION;
}

GGML_ATTRIBUTE_FORMAT(2, 3)
static void parakeet_log_internal(ggml_log_level level, const char * format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[1024];
    int len = vsnprintf(buffer, 1024, format, args);
    if (len < 1024) {
        g_state.log_callback(level, buffer, g_state.log_callback_user_data);
    } else {
        char* buffer2 = new char[len+1];
        vsnprintf(buffer2, len+1, format, args);
        buffer2[len] = 0;
        g_state.log_callback(level, buffer2, g_state.log_callback_user_data);
        delete[] buffer2;
    }
    va_end(args);
}

static void parakeet_log_callback_default(ggml_log_level level, const char * text, void * user_data) {
    (void) level;
    (void) user_data;
#ifndef PARAKEET_DEBUG
    if (level == GGML_LOG_LEVEL_DEBUG) {
        return;
    }
#endif
    fputs(text, stderr);
    fflush(stderr);
}
