// granite.cpp — public C API: model lifetime, backends, weight mapping, one-utterance runs and greedy CTC.
//
// Adapted from transcribe.cpp (MIT, Copyright (c) 2026 The transcribe.cpp authors) at
// 5700f127e38dd53c4735ea23ef743b4b538eacd4: src/arch/granite5_ctc/model.cpp (load, BN fusion, run_encoder,
// encode_and_decode), src/arch/granite5_ctc/decoder.cpp (greedy CTC collapse, softmax probability,
// ms_per_encoder_frame), src/transcribe-load-common.cpp (backend plan, map_weights, stream_tensor_data)
// and src/transcribe-log.h (log sink). See Vendor/granite/LICENSE and Vendor/granite/NOTICE.md.
#include "granite-impl.h"

#include "ggml-alloc.h"
#include "gguf.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>

// ---------------------------------------------------------------------------------------------------------
// Logging

namespace {

std::mutex           g_log_mutex;
granite_log_callback g_log_callback  = nullptr;
void *               g_log_user_data = nullptr;

}  // namespace

void granite_log_set(granite_log_callback callback, void * user_data) {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_log_callback  = callback;
    g_log_user_data = user_data;
}

namespace granite {

void log(granite_log_level level, const char * fmt, ...) {
    char    text[1024];
    int     prefix = std::snprintf(text, sizeof(text), "granite: ");
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(text + prefix, sizeof(text) - static_cast<size_t>(prefix) - 1, fmt, args);
    va_end(args);
    const size_t len = std::strlen(text);
    text[len]        = '\n';
    text[len + 1]    = '\0';

    std::lock_guard<std::mutex> lock(g_log_mutex);
    if (g_log_callback != nullptr) {
        g_log_callback(level, text, g_log_user_data);
    } else {
        std::fputs(text, stderr);
    }
}

}  // namespace granite

// ---------------------------------------------------------------------------------------------------------
// Context

using granite::log;

struct granite_context {
    granite::HParams  hp;
    granite::Weights  weights;
    granite::Vocab    vocab;
    granite::Frontend frontend;

    int     n_threads   = 1;
    int64_t min_samples = 0;

    // Backends in scheduler order: [GPU], ACCEL..., CPU. `primary` holds weights and BN tensors.
    std::vector<ggml_backend_t> backends;
    ggml_backend_t              primary = nullptr;
    ggml_backend_sched_t        sched   = nullptr;

    ggml_context *        ctx_meta      = nullptr;  // weight tensor metadata
    ggml_backend_buffer_t mapped_buffer = nullptr;  // wraps the read-only file mapping
    ggml_backend_buffer_t copy_buffer   = nullptr;  // weights that could not be mapped
    void *                map_addr      = nullptr;
    size_t                map_size      = 0;
    int                   fd            = -1;

    ggml_context *        bn_ctx    = nullptr;
    ggml_backend_buffer_t bn_buffer = nullptr;

    std::vector<int32_t> pos_rows;

    // Per-run scratch and results.
    std::vector<float>         pcm_padded;
    std::vector<float>         feats;
    std::vector<float>         logits;
    std::vector<granite_token> tokens;
    int32_t                    n_frames = 0;
};

namespace {

// Teardown in dependency order: scheduler, BN buffer, weight buffer wrappers, munmap/close, ggml contexts,
// backends. Wrappers must go before the mapping they reference.
void destroy(granite_context * ctx) {
    if (ctx->sched != nullptr) {
        ggml_backend_sched_free(ctx->sched);
        ctx->sched = nullptr;
    }
    if (ctx->bn_buffer != nullptr) {
        ggml_backend_buffer_free(ctx->bn_buffer);
        ctx->bn_buffer = nullptr;
    }
    if (ctx->mapped_buffer != nullptr) {
        ggml_backend_buffer_free(ctx->mapped_buffer);
        ctx->mapped_buffer = nullptr;
    }
    if (ctx->copy_buffer != nullptr) {
        ggml_backend_buffer_free(ctx->copy_buffer);
        ctx->copy_buffer = nullptr;
    }
    if (ctx->map_addr != nullptr) {
        munmap(ctx->map_addr, ctx->map_size);
        ctx->map_addr = nullptr;
        ctx->map_size = 0;
    }
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    if (ctx->ctx_meta != nullptr) {
        ggml_free(ctx->ctx_meta);
        ctx->ctx_meta = nullptr;
    }
    if (ctx->bn_ctx != nullptr) {
        ggml_free(ctx->bn_ctx);
        ctx->bn_ctx = nullptr;
    }
    for (auto it = ctx->backends.rbegin(); it != ctx->backends.rend(); ++it) {
        ggml_backend_free(*it);
    }
    ctx->backends.clear();
    ctx->primary = nullptr;
    granite::frontend_free(ctx->frontend);
    delete ctx;
}

struct ContextGuard {
    granite_context * ctx;
    ~ContextGuard() {
        if (ctx != nullptr) {
            destroy(ctx);
        }
    }
    granite_context * release() {
        granite_context * out = ctx;
        ctx                   = nullptr;
        return out;
    }
};

struct GgufGuard {
    gguf_context * gguf;
    ~GgufGuard() {
        if (gguf != nullptr) {
            gguf_free(gguf);
        }
    }
};

// GPU (when requested and present) -> accelerators (Accelerate BLAS) -> mandatory CPU, as Parakeet.
bool init_backends(granite_context * ctx, bool use_gpu) {
    ggml_backend_t gpu = nullptr;
    if (use_gpu) {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t         dev  = ggml_backend_dev_get(i);
            enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
            if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                gpu = ggml_backend_dev_init(dev, nullptr);
                if (gpu == nullptr) {
                    log(GRANITE_LOG_WARN, "failed to initialize %s; using the CPU", ggml_backend_dev_name(dev));
                }
                break;
            }
        }
        if (gpu == nullptr) {
            log(GRANITE_LOG_INFO, "no GPU device; using the CPU");
        }
    }
    if (gpu != nullptr) {
        ctx->backends.push_back(gpu);
    }
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_ACCEL) {
            ggml_backend_t backend = ggml_backend_dev_init(dev, nullptr);
            if (backend == nullptr) {
                log(GRANITE_LOG_WARN, "failed to initialize %s", ggml_backend_dev_name(dev));
                continue;
            }
            ctx->backends.push_back(backend);
        }
    }
    ggml_backend_t cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (cpu == nullptr) {
        log(GRANITE_LOG_ERROR, "failed to initialize the CPU backend");
        return false;
    }
    ctx->backends.push_back(cpu);
    ctx->primary = gpu != nullptr ? gpu : cpu;
    log(GRANITE_LOG_INFO, "primary backend %s", ggml_backend_name(ctx->primary));
    return true;
}

// Places every tensor whose file bytes are usable as-is directly at its address in a read-only mapping of
// the whole GGUF. Leaves tensors that do not qualify (and everything, when mapping is impossible) for the
// copy path. Only a hard backend rejection is an error.
bool map_weights(granite_context * ctx, const gguf_context * gguf, size_t & n_mapped, size_t & mapped_bytes) {
    ggml_backend_dev_t     dev   = ggml_backend_get_device(ctx->primary);
    ggml_backend_dev_props props = {};
    ggml_backend_dev_get_props(dev, &props);
    if (!props.caps.buffer_from_host_ptr) {
        log(GRANITE_LOG_INFO, "%s keeps weights in its own memory; copying weights", ggml_backend_dev_name(dev));
        return true;
    }

    struct stat st = {};
    if (fstat(ctx->fd, &st) != 0 || st.st_size <= 0) {
        log(GRANITE_LOG_WARN, "cannot stat the model file (%s); copying weights", std::strerror(errno));
        return true;
    }
    const size_t file_size = static_cast<size_t>(st.st_size);
    void *       addr      = mmap(nullptr, file_size, PROT_READ, MAP_SHARED, ctx->fd, 0);
    if (addr == MAP_FAILED) {
        log(GRANITE_LOG_WARN, "cannot memory-map the model (%s); copying weights", std::strerror(errno));
        return true;
    }
    ctx->map_addr = addr;
    ctx->map_size = file_size;

    struct Candidate {
        ggml_tensor * tensor;
        char *        addr;
    };
    std::vector<Candidate> candidates;
    size_t                 max_tensor_size = 0;
    const size_t           data_offset     = gguf_get_data_offset(gguf);
    char *                 base            = static_cast<char *>(addr);
    if (data_offset <= file_size) {
        for (ggml_tensor * t = ggml_get_first_tensor(ctx->ctx_meta); t != nullptr;
             t               = ggml_get_next_tensor(ctx->ctx_meta, t)) {
            const int64_t idx = gguf_find_tensor(gguf, ggml_get_name(t));
            if (idx < 0) {
                continue;
            }
            const size_t nbytes  = ggml_nbytes(t);
            const size_t toffset = gguf_get_tensor_offset(gguf, idx);
            if (gguf_get_tensor_type(gguf, idx) != t->type || gguf_get_tensor_size(gguf, idx) != nbytes ||
                !ggml_is_contiguous(t) || toffset > file_size - data_offset ||
                nbytes > file_size - data_offset - toffset) {
                continue;
            }
            candidates.push_back({ t, base + data_offset + toffset });
            max_tensor_size = std::max(max_tensor_size, nbytes);
        }
    }
    if (candidates.empty()) {
        log(GRANITE_LOG_INFO, "no tensor is stored as-is in the file; copying weights");
        return true;
    }

    // Wrap the whole page-aligned mapping, not just the data section.
    ggml_backend_buffer_t buffer = ggml_backend_dev_buffer_from_host_ptr(dev, addr, file_size, max_tensor_size);
    if (buffer == nullptr) {
        log(GRANITE_LOG_WARN, "%s cannot wrap the mapping; copying weights", ggml_backend_dev_name(dev));
        return true;
    }
    const size_t alignment = ggml_backend_buffer_get_alignment(buffer);
    for (const Candidate & c : candidates) {
        const size_t nbytes = ggml_nbytes(c.tensor);
        if ((alignment > 1 && reinterpret_cast<uintptr_t>(c.addr) % alignment != 0) ||
            ggml_backend_buffer_get_alloc_size(buffer, c.tensor) != nbytes) {
            continue;
        }
        if (ggml_backend_tensor_alloc(buffer, c.tensor, c.addr) != GGML_STATUS_SUCCESS) {
            log(GRANITE_LOG_ERROR, "%s rejected mapped tensor \"%s\"", ggml_backend_dev_name(dev),
                ggml_get_name(c.tensor));
            ctx->mapped_buffer = buffer;  // tensors may point into it; freed by destroy()
            return false;
        }
        ++n_mapped;
        mapped_bytes += nbytes;
    }
    if (n_mapped == 0) {
        ggml_backend_buffer_free(buffer);
        log(GRANITE_LOG_INFO, "no tensor is aligned for the device; copying weights");
        return true;
    }
    ggml_backend_buffer_set_usage(buffer, GGML_BACKEND_BUFFER_USAGE_WEIGHTS);
    ctx->mapped_buffer = buffer;
    return true;
}

bool read_exact(int fd, void * dst, size_t size, off_t offset) {
    char * out = static_cast<char *>(dst);
    while (size > 0) {
        const ssize_t n = pread(fd, out, size, offset);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            return false;
        }
        out += n;
        size -= static_cast<size_t>(n);
        offset += n;
    }
    return true;
}

// Allocates every tensor the mapping did not take on the primary backend and uploads its bytes, staging
// device buffers in <= 16 MiB chunks.
bool copy_weights(granite_context * ctx, const gguf_context * gguf, size_t & n_copied, size_t & copied_bytes) {
    bool any_unallocated = false;
    for (ggml_tensor * t = ggml_get_first_tensor(ctx->ctx_meta); t != nullptr;
         t               = ggml_get_next_tensor(ctx->ctx_meta, t)) {
        if (t->data == nullptr && t->view_src == nullptr) {
            any_unallocated = true;
            break;
        }
    }
    if (!any_unallocated) {
        return true;
    }
    ctx->copy_buffer = ggml_backend_alloc_ctx_tensors(ctx->ctx_meta, ctx->primary);
    if (ctx->copy_buffer == nullptr) {
        log(GRANITE_LOG_ERROR, "weight buffer allocation failed");
        return false;
    }
    ggml_backend_buffer_set_usage(ctx->copy_buffer, GGML_BACKEND_BUFFER_USAGE_WEIGHTS);

    constexpr size_t     kStageChunk = size_t(16) << 20;
    const size_t         data_offset = gguf_get_data_offset(gguf);
    std::vector<uint8_t> staging;
    for (ggml_tensor * t = ggml_get_first_tensor(ctx->ctx_meta); t != nullptr;
         t               = ggml_get_next_tensor(ctx->ctx_meta, t)) {
        // Everything not placed in the read-only mapping was allocated above, possibly across
        // several sub-buffers when it exceeds the device's maximum buffer size.
        if (t->buffer == nullptr || (ctx->mapped_buffer != nullptr && t->buffer == ctx->mapped_buffer)) {
            continue;
        }
        const int64_t idx = gguf_find_tensor(gguf, ggml_get_name(t));
        if (idx < 0) {
            log(GRANITE_LOG_ERROR, "tensor \"%s\" has no data in the file", ggml_get_name(t));
            return false;
        }
        const size_t nbytes = ggml_nbytes(t);
        const off_t  offset = static_cast<off_t>(data_offset + gguf_get_tensor_offset(gguf, idx));
        if (ggml_backend_buffer_is_host(t->buffer)) {
            if (!read_exact(ctx->fd, t->data, nbytes, offset)) {
                log(GRANITE_LOG_ERROR, "short read for tensor \"%s\"", ggml_get_name(t));
                return false;
            }
        } else {
            staging.resize(std::min(nbytes, kStageChunk));
            for (size_t done = 0; done < nbytes;) {
                const size_t n = std::min(nbytes - done, staging.size());
                if (!read_exact(ctx->fd, staging.data(), n, offset + static_cast<off_t>(done))) {
                    log(GRANITE_LOG_ERROR, "short read for tensor \"%s\"", ggml_get_name(t));
                    return false;
                }
                ggml_backend_tensor_set(t, staging.data(), done, n);
                done += n;
            }
        }
        ++n_copied;
        copied_bytes += nbytes;
    }
    return true;
}

// scale = gamma / sqrt(var + eps), bias = beta - mean * scale, in F32 host arithmetic, into a separate
// buffer on the primary backend (never into the read-only mapping).
bool fuse_batch_norm(granite_context * ctx) {
    constexpr float kBnEps = 1e-5f;
    const size_t    n      = ctx->weights.blocks.size();
    const int64_t   inner  = static_cast<int64_t>(ctx->hp.hidden) * ctx->hp.conv_expansion;
    const size_t    bytes  = static_cast<size_t>(inner) * sizeof(float);

    ggml_init_params params = { n * 2 * ggml_tensor_overhead() + 256, nullptr, /*no_alloc=*/true };
    ctx->bn_ctx             = ggml_init(params);
    if (ctx->bn_ctx == nullptr) {
        log(GRANITE_LOG_ERROR, "BatchNorm context allocation failed");
        return false;
    }
    for (granite::Block & b : ctx->weights.blocks) {
        b.bn_scale = ggml_new_tensor_1d(ctx->bn_ctx, GGML_TYPE_F32, inner);
        b.bn_bias  = ggml_new_tensor_1d(ctx->bn_ctx, GGML_TYPE_F32, inner);
    }
    ctx->bn_buffer = ggml_backend_alloc_ctx_tensors(ctx->bn_ctx, ctx->primary);
    if (ctx->bn_buffer == nullptr) {
        log(GRANITE_LOG_ERROR, "BatchNorm buffer allocation failed");
        return false;
    }

    std::vector<float> gamma(static_cast<size_t>(inner)), beta(static_cast<size_t>(inner));
    std::vector<float> mean(static_cast<size_t>(inner)), var(static_cast<size_t>(inner));
    std::vector<float> scale(static_cast<size_t>(inner)), bias(static_cast<size_t>(inner));
    for (granite::Block & b : ctx->weights.blocks) {
        ggml_backend_tensor_get(b.conv_bn_w, gamma.data(), 0, bytes);
        ggml_backend_tensor_get(b.conv_bn_b, beta.data(), 0, bytes);
        ggml_backend_tensor_get(b.conv_bn_mean, mean.data(), 0, bytes);
        ggml_backend_tensor_get(b.conv_bn_var, var.data(), 0, bytes);
        for (size_t c = 0; c < static_cast<size_t>(inner); ++c) {
            const float s = gamma[c] / std::sqrt(var[c] + kBnEps);
            scale[c]      = s;
            bias[c]       = beta[c] - mean[c] * s;
        }
        ggml_backend_tensor_set(b.bn_scale, scale.data(), 0, bytes);
        ggml_backend_tensor_set(b.bn_bias, bias.data(), 0, bytes);
    }
    return true;
}

granite_context * init_from_file(const char * path, granite_context_params params) {
    if (path == nullptr) {
        log(GRANITE_LOG_ERROR, "model path is NULL");
        return nullptr;
    }
    if (params.n_threads < 1) {
        log(GRANITE_LOG_ERROR, "n_threads must be >= 1 (got %d)", params.n_threads);
        return nullptr;
    }
    const int64_t t_start = ggml_time_us();

    ContextGuard guard{ new granite_context() };
    granite_context * ctx = guard.ctx;
    ctx->n_threads        = params.n_threads;

    gguf_init_params gparams = { /*no_alloc=*/true, /*ctx=*/&ctx->ctx_meta };
    GgufGuard        gguf{ gguf_init_from_file(path, gparams) };
    if (gguf.gguf == nullptr) {
        log(GRANITE_LOG_ERROR, "cannot read GGUF %s", path);
        return nullptr;
    }
    if (!granite::read_hparams(gguf.gguf, ctx->hp) || !granite::load_vocab(gguf.gguf, ctx->vocab) ||
        !granite::bind_weights(gguf.gguf, ctx->ctx_meta, ctx->hp, ctx->weights)) {
        return nullptr;
    }
    if (ctx->vocab.bytes.size() != static_cast<size_t>(ctx->hp.output_dim)) {
        log(GRANITE_LOG_ERROR, "vocabulary has %zu tokens, CTC head has %d outputs", ctx->vocab.bytes.size(),
            ctx->hp.output_dim);
        return nullptr;
    }
    ctx->min_samples = granite::min_samples_for(ctx->hp);
    if (ctx->min_samples <= 0) {
        log(GRANITE_LOG_ERROR, "no input length yields an encoder frame");
        return nullptr;
    }

    if (!init_backends(ctx, params.use_gpu)) {
        return nullptr;
    }

    ctx->fd = open(path, O_RDONLY | O_CLOEXEC);
    if (ctx->fd < 0) {
        log(GRANITE_LOG_ERROR, "cannot open %s (%s)", path, std::strerror(errno));
        return nullptr;
    }
    size_t n_mapped = 0, mapped_bytes = 0, n_copied = 0, copied_bytes = 0;
    if (params.map_weights && !map_weights(ctx, gguf.gguf, n_mapped, mapped_bytes)) {
        return nullptr;
    }
    if (!copy_weights(ctx, gguf.gguf, n_copied, copied_bytes)) {
        return nullptr;
    }
    if (ctx->mapped_buffer == nullptr) {
        // Nothing references the file any more: release the mapping attempt and the descriptor now.
        if (ctx->map_addr != nullptr) {
            munmap(ctx->map_addr, ctx->map_size);
            ctx->map_addr = nullptr;
            ctx->map_size = 0;
        }
        close(ctx->fd);
        ctx->fd = -1;
    }
    log(GRANITE_LOG_INFO, "weights: %zu tensors (%.1f MiB) mapped, %zu tensors (%.1f MiB) copied", n_mapped,
        static_cast<double>(mapped_bytes) / (1024.0 * 1024.0), n_copied,
        static_cast<double>(copied_bytes) / (1024.0 * 1024.0));

    if (!fuse_batch_norm(ctx)) {
        return nullptr;
    }

    {
        const int64_t      n_freq = ctx->hp.n_fft / 2 + 1;
        std::vector<float> filterbank(static_cast<size_t>(n_freq) * static_cast<size_t>(ctx->hp.num_mels));
        std::vector<float> window(static_cast<size_t>(ctx->hp.win_length));
        ggml_backend_tensor_get(ctx->weights.mel_filterbank, filterbank.data(), 0, filterbank.size() * sizeof(float));
        ggml_backend_tensor_get(ctx->weights.window, window.data(), 0, window.size() * sizeof(float));
        if (!granite::frontend_init(ctx->hp, filterbank.data(), window.data(), ctx->frontend)) {
            return nullptr;
        }
    }
    ctx->pos_rows = granite::precompute_pos_rows(ctx->hp.context_size, ctx->hp.max_pos_emb);

    ctx->sched = ggml_backend_sched_new(ctx->backends.data(), nullptr, static_cast<int>(ctx->backends.size()),
                                        /*graph_size=*/16384, /*parallel=*/false, /*op_offload=*/true);
    if (ctx->sched == nullptr) {
        log(GRANITE_LOG_ERROR, "ggml_backend_sched_new failed");
        return nullptr;
    }

    log(GRANITE_LOG_INFO, "loaded %s in %.0f ms (%d layers, vocab %d, min input %lld samples)", path,
        static_cast<double>(ggml_time_us() - t_start) / 1000.0, ctx->hp.n_layers, ctx->hp.output_dim,
        static_cast<long long>(ctx->min_samples));
    return guard.release();
}

int argmax_row(const float * row, int n) {
    int   best   = 0;
    float best_v = row[0];
    for (int i = 1; i < n; ++i) {
        if (row[i] > best_v) {
            best_v = row[i];
            best   = i;
        }
    }
    return best;
}

float softmax_prob(const float * row, int n, int idx, float max_v) {
    double sum = 0.0;
    for (int i = 0; i < n; ++i) {
        sum += std::exp(static_cast<double>(row[i] - max_v));
    }
    if (sum <= 0.0) {
        return 0.0f;
    }
    return static_cast<float>(std::exp(static_cast<double>(row[idx] - max_v)) / sum);
}

// Group-by then drop blank: [A, A] -> [A], [A, blank, A] -> [A, A]. Each token keeps its run's frame span and
// the softmax probability at the run's first frame.
void ctc_greedy_collapse(granite_context * ctx, int t_len, int vocab) {
    int  prev     = -1;
    bool retained = false;
    for (int t = 0; t < t_len; ++t) {
        const float * row   = ctx->logits.data() + static_cast<size_t>(t) * static_cast<size_t>(vocab);
        const int     label = argmax_row(row, vocab);
        if (label == prev) {
            if (retained) {
                ctx->tokens.back().frame_end = t + 1;
            }
            continue;
        }
        prev     = label;
        retained = label != ctx->hp.blank_id;
        if (!retained) {
            continue;
        }
        granite_token token;
        token.id          = label;
        token.frame_begin = t;
        token.frame_end   = t + 1;
        token.p           = softmax_prob(row, vocab, label, row[label]);
        token.is_special  = ctx->vocab.special[static_cast<size_t>(label)] != 0;
        ctx->tokens.push_back(token);
    }
}

struct RunScratch {
    granite_context * ctx;
    ggml_context *    compute = nullptr;
    ~RunScratch() {
        ggml_backend_sched_reset(ctx->sched);
        if (compute != nullptr) {
            ggml_free(compute);
        }
    }
};

bool poll(granite_abort_callback abort_callback, void * user_data) {
    return abort_callback != nullptr && abort_callback(user_data);
}

granite_status run(granite_context * ctx, const float * pcm, int64_t n_samples, granite_abort_callback abort_callback,
                   void * abort_user_data) {
    // Stage boundary 1: before the frontend.
    if (poll(abort_callback, abort_user_data)) {
        return GRANITE_ERR_CANCELLED;
    }
    if (n_samples == 0) {
        return GRANITE_OK;
    }
    if (n_samples < ctx->min_samples) {
        ctx->pcm_padded.assign(static_cast<size_t>(ctx->min_samples), 0.0f);
        std::memcpy(ctx->pcm_padded.data(), pcm, static_cast<size_t>(n_samples) * sizeof(float));
        pcm       = ctx->pcm_padded.data();
        n_samples = ctx->min_samples;
    }

    int t_enc = 0;
    if (!granite::compute_features(ctx->frontend, ctx->hp, pcm, n_samples, ctx->n_threads, ctx->feats, t_enc)) {
        return GRANITE_ERR_BACKEND;
    }

    RunScratch       scratch{ ctx };
    ggml_init_params ip = { size_t(16) << 20, nullptr, /*no_alloc=*/true };
    scratch.compute     = ggml_init(ip);
    if (scratch.compute == nullptr) {
        log(GRANITE_LOG_ERROR, "compute context allocation failed");
        return GRANITE_ERR_BACKEND;
    }
    granite::EncoderGraph eg;
    if (!granite::build_encoder_graph(scratch.compute, ctx->weights, ctx->hp, t_enc, eg)) {
        return GRANITE_ERR_BACKEND;
    }
    if (!ggml_backend_sched_alloc_graph(ctx->sched, eg.graph)) {
        log(GRANITE_LOG_ERROR, "encoder graph allocation failed (T_enc=%d)", t_enc);
        return GRANITE_ERR_BACKEND;
    }

    ggml_backend_tensor_set(eg.feats_in, ctx->feats.data(), 0, ctx->feats.size() * sizeof(float));
    ggml_backend_tensor_set(eg.pos_rows, ctx->pos_rows.data(), 0, ctx->pos_rows.size() * sizeof(int32_t));
    for (const granite::AttnStage & stage : eg.stages) {
        const std::vector<float> mask = granite::precompute_pad_mask(ctx->hp.context_size, stage.t_len);
        ggml_backend_tensor_set(stage.pad_mask, mask.data(), 0, mask.size() * sizeof(float));
        if (stage.zero_pad != nullptr) {
            const std::vector<float> zeros(static_cast<size_t>(ggml_nelements(stage.zero_pad)), 0.0f);
            ggml_backend_tensor_set(stage.zero_pad, zeros.data(), 0, zeros.size() * sizeof(float));
        }
    }
    for (ggml_backend_t backend : ctx->backends) {
        ggml_backend_dev_t dev = ggml_backend_get_device(backend);
        ggml_backend_reg_t reg = dev != nullptr ? ggml_backend_dev_backend_reg(dev) : nullptr;
        auto * set_n_threads   = reg != nullptr ? reinterpret_cast<ggml_backend_set_n_threads_t>(
                                                    ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_n_threads"))
                                                : nullptr;
        if (set_n_threads != nullptr) {
            set_n_threads(backend, ctx->n_threads);
        }
    }

    // Stage boundary 2: before graph compute. No abort callback ever reaches the Metal backend.
    if (poll(abort_callback, abort_user_data)) {
        return GRANITE_ERR_CANCELLED;
    }
    if (ggml_backend_sched_graph_compute(ctx->sched, eg.graph) != GGML_STATUS_SUCCESS) {
        log(GRANITE_LOG_ERROR, "graph compute failed");
        return GRANITE_ERR_BACKEND;
    }
    // Stage boundary 3: after graph compute, before CTC decoding.
    if (poll(abort_callback, abort_user_data)) {
        return GRANITE_ERR_CANCELLED;
    }

    const int t_out = static_cast<int>(eg.ctc_logits->ne[1]);
    const int vocab = static_cast<int>(eg.ctc_logits->ne[0]);
    ctx->logits.resize(static_cast<size_t>(t_out) * static_cast<size_t>(vocab));
    ggml_backend_tensor_get(eg.ctc_logits, ctx->logits.data(), 0, ctx->logits.size() * sizeof(float));
    ctc_greedy_collapse(ctx, t_out, vocab);
    ctx->n_frames = t_out;
    return GRANITE_OK;
}

}  // namespace

granite_context_params granite_context_default_params(void) {
    granite_context_params params;
    params.use_gpu     = true;
    params.n_threads   = 6;
    params.map_weights = true;
    return params;
}

granite_context * granite_init_from_file(const char * path, granite_context_params params) {
    try {
        return init_from_file(path, params);
    } catch (const std::bad_alloc &) {
        log(GRANITE_LOG_ERROR, "out of memory while loading");
    } catch (...) {
        log(GRANITE_LOG_ERROR, "unexpected exception while loading");
    }
    return nullptr;
}

void granite_free(granite_context * ctx) {
    if (ctx != nullptr) {
        destroy(ctx);
    }
}

granite_status granite_transcribe(granite_context * ctx, const float * pcm, int32_t n_samples,
                                  granite_abort_callback abort_callback, void * abort_user_data) {
    if (ctx == nullptr) {
        return GRANITE_ERR_INVALID_ARGUMENT;
    }
    ctx->tokens.clear();
    ctx->n_frames = 0;
    if (n_samples < 0 || (n_samples > 0 && pcm == nullptr)) {
        return GRANITE_ERR_INVALID_ARGUMENT;
    }
    for (int32_t i = 0; i < n_samples; ++i) {
        if (!std::isfinite(pcm[i])) {
            return GRANITE_ERR_INVALID_ARGUMENT;
        }
    }
    granite_status status = GRANITE_ERR_BACKEND;
    try {
        status = run(ctx, pcm, n_samples, abort_callback, abort_user_data);
    } catch (const std::bad_alloc &) {
        log(GRANITE_LOG_ERROR, "out of memory during transcription");
    } catch (...) {
        log(GRANITE_LOG_ERROR, "unexpected exception during transcription");
    }
    if (status != GRANITE_OK) {
        ctx->tokens.clear();
        ctx->n_frames = 0;
    }
    return status;
}

int32_t granite_n_tokens(const granite_context * ctx) {
    return ctx != nullptr ? static_cast<int32_t>(ctx->tokens.size()) : 0;
}

granite_token granite_get_token(const granite_context * ctx, int32_t i) {
    if (ctx == nullptr || i < 0 || static_cast<size_t>(i) >= ctx->tokens.size()) {
        granite_token token = {};
        token.id            = -1;
        return token;
    }
    return ctx->tokens[static_cast<size_t>(i)];
}

const char * granite_token_bytes(const granite_context * ctx, int32_t i, size_t * length) {
    if (ctx == nullptr || i < 0 || static_cast<size_t>(i) >= ctx->tokens.size()) {
        if (length != nullptr) {
            *length = 0;
        }
        return nullptr;
    }
    const std::string & bytes = ctx->vocab.bytes[static_cast<size_t>(ctx->tokens[static_cast<size_t>(i)].id)];
    if (length != nullptr) {
        *length = bytes.size();
    }
    return bytes.data();
}

int32_t granite_ms_per_frame(const granite_context * ctx) {
    if (ctx == nullptr) {
        return 0;
    }
    int64_t samples = static_cast<int64_t>(ctx->hp.hop_length) * ctx->hp.stack_factor;
    for (size_t i = 0; i < ctx->hp.subsample_layers.size(); ++i) {
        samples *= 2;
    }
    return static_cast<int32_t>(samples * 1000 / ctx->hp.sample_rate);
}

int32_t granite_nospeech_token_id(const granite_context * ctx) {
    return ctx != nullptr ? ctx->vocab.nospeech_id : -1;
}

int32_t granite_n_frames(const granite_context * ctx) {
    return ctx != nullptr ? ctx->n_frames : 0;
}
