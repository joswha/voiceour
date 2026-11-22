// qwen3.cpp — public C API: model lifetime, backends, weight mapping, the KV cache, greedy generation with
// n-gram self-drafting and guided generation over a candidate trie.
//
// Adapted from llama.cpp (MIT, Copyright (c) 2023-2026 The ggml authors) b12606 at
// e412c6f468b7b9e0f16f2540244236f8ad68e9ae: src/llama-model.cpp and src/llama-model-loader.cpp (backend
// selection, read-only mapping wrapped by buffer_from_host_ptr, per-tensor placement, upload fallback),
// src/llama-kv-cache.cpp (F16 cache allocation and clearing, n_kv padding, causal mask, seq_rm rollback),
// src/llama-context.cpp (graph reuse, ubatch split, logits readout), common/ngram-map.cpp
// (common_ngram_simple_draft) and the polish-lab harness's decode loop over libllama. Logging mirrors
// Vendor/granite's sink. Guided generation (the candidate trie and its constrained greedy loop) is Voiceour's
// own and has no upstream counterpart. See Vendor/qwen3/LICENSE and Vendor/qwen3/NOTICE.md.
#include "qwen3-impl.h"

#include "ggml-alloc.h"
#include "gguf.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>

// ---------------------------------------------------------------------------------------------------------
// Logging

namespace {

std::mutex         g_log_mutex;
qwen3_log_callback g_log_callback  = nullptr;
void *             g_log_user_data = nullptr;

}  // namespace

void qwen3_log_set(qwen3_log_callback callback, void * user_data) {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_log_callback  = callback;
    g_log_user_data = user_data;
}

namespace qwen3 {

void log(qwen3_log_level level, const char * fmt, ...) {
    char    text[1024];
    int     prefix = std::snprintf(text, sizeof(text), "qwen3: ");
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

}  // namespace qwen3

// ---------------------------------------------------------------------------------------------------------
// Context

using qwen3::log;

namespace {

// llama_context's n_ubatch: a prompt is evaluated in batches of at most this many tokens.
constexpr int32_t kUbatch = 512;

// llama_kv_cache::get_n_kv pads the attended cells to a multiple of 256 so graphs can be reused.
constexpr int32_t kKvPad = 256;

using Clock = std::chrono::steady_clock;

double ms_between(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

}  // namespace

namespace qwen3 {

// A node of the guided-generation trie: the token that leads to it, its children as a sibling list sorted by
// token id, and the candidate that ends at it (-1 when none does). Node 0 is the root.
struct GuideNode {
    int32_t token        = -1;
    int32_t first_child  = -1;
    int32_t next_sibling = -1;
    int32_t candidate    = -1;
};

}  // namespace qwen3

struct qwen3_context {
    qwen3::HParams hp;
    qwen3::Weights weights;
    qwen3::Vocab   vocab;
    qwen3::KVCache kv;

    int         n_threads   = 1;
    const char *weight_type = "";

    // Backends in scheduler order: [GPU], ACCEL..., CPU. `primary` holds weights and the KV cache.
    std::vector<ggml_backend_t> backends;
    ggml_backend_t              primary = nullptr;
    ggml_backend_sched_t        sched   = nullptr;

    ggml_context *        ctx_meta      = nullptr;  // weight tensor metadata
    ggml_backend_buffer_t mapped_buffer = nullptr;  // wraps the read-only file mapping
    ggml_backend_buffer_t copy_buffer   = nullptr;  // weights that could not be mapped
    void *                map_addr      = nullptr;
    size_t                map_size      = 0;
    int                   fd            = -1;

    ggml_context *        kv_ctx    = nullptr;
    ggml_backend_buffer_t kv_buffer = nullptr;
    int32_t               kv_cleared = 0;  // cells [0, kv_cleared) have been zeroed or written

    // The current graph, kept across evaluations of the same shape.
    ggml_context * graph_ctx = nullptr;
    qwen3::Graph   graph;

    // Per-call scratch and results.
    std::vector<int32_t>        history;
    std::vector<int32_t>        batch;
    std::vector<int32_t>        draft;
    std::vector<int32_t>        positions;
    std::vector<int64_t>        cells;
    std::vector<ggml_fp16_t>    mask;
    std::vector<int32_t>        out_ids;
    std::vector<float>          logits;
    std::vector<int32_t>        output;
    std::vector<qwen3_decision> decisions;
    qwen3_timings               timings = {};

    // Guided generation: the candidate trie, the tokens appended since the last evaluation, and the results.
    std::vector<qwen3::GuideNode>  guide;
    std::vector<int32_t>           pending;
    std::vector<qwen3_guided_step> guided_steps;
    int32_t                        guided_candidate = -1;
};

namespace {

void release_graph(qwen3_context * ctx) {
    if (ctx->sched != nullptr) {
        ggml_backend_sched_reset(ctx->sched);
    }
    if (ctx->graph_ctx != nullptr) {
        ggml_free(ctx->graph_ctx);
        ctx->graph_ctx = nullptr;
    }
    ctx->graph = qwen3::Graph();
}

// Teardown in dependency order: graph and scheduler, KV buffer, weight buffer wrappers, munmap/close, ggml
// contexts, backends. Wrappers must go before the mapping they reference.
void destroy(qwen3_context * ctx) {
    release_graph(ctx);
    if (ctx->sched != nullptr) {
        ggml_backend_sched_free(ctx->sched);
        ctx->sched = nullptr;
    }
    if (ctx->kv_buffer != nullptr) {
        ggml_backend_buffer_free(ctx->kv_buffer);
        ctx->kv_buffer = nullptr;
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
    if (ctx->kv_ctx != nullptr) {
        ggml_free(ctx->kv_ctx);
        ctx->kv_ctx = nullptr;
    }
    if (ctx->ctx_meta != nullptr) {
        ggml_free(ctx->ctx_meta);
        ctx->ctx_meta = nullptr;
    }
    for (auto it = ctx->backends.rbegin(); it != ctx->backends.rend(); ++it) {
        ggml_backend_free(*it);
    }
    ctx->backends.clear();
    ctx->primary = nullptr;
    delete ctx;
}

struct ContextGuard {
    qwen3_context * ctx;
    ~ContextGuard() {
        if (ctx != nullptr) {
            destroy(ctx);
        }
    }
    qwen3_context * release() {
        qwen3_context * out = ctx;
        ctx                 = nullptr;
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

// GPU (when requested and present) -> accelerators (Accelerate BLAS) -> mandatory CPU, the order llama.cpp
// hands its scheduler.
bool init_backends(qwen3_context * ctx, bool use_gpu) {
    ggml_backend_t gpu = nullptr;
    if (use_gpu) {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t         dev  = ggml_backend_dev_get(i);
            enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
            if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                gpu = ggml_backend_dev_init(dev, nullptr);
                if (gpu == nullptr) {
                    log(QWEN3_LOG_WARN, "failed to initialize %s; using the CPU", ggml_backend_dev_name(dev));
                }
                break;
            }
        }
        if (gpu == nullptr) {
            log(QWEN3_LOG_INFO, "no GPU device; using the CPU");
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
                log(QWEN3_LOG_WARN, "failed to initialize %s", ggml_backend_dev_name(dev));
                continue;
            }
            ctx->backends.push_back(backend);
        }
    }
    ggml_backend_t cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (cpu == nullptr) {
        log(QWEN3_LOG_ERROR, "failed to initialize the CPU backend");
        return false;
    }
    ctx->backends.push_back(cpu);
    ctx->primary = gpu != nullptr ? gpu : cpu;
    log(QWEN3_LOG_INFO, "primary backend %s", ggml_backend_name(ctx->primary));
    return true;
}

// Places every tensor whose file bytes are usable as-is directly at its address in a read-only mapping of the
// whole GGUF. Leaves tensors that do not qualify (and everything, when mapping is impossible) for the copy
// path. Only a hard backend rejection is an error.
bool map_weights(qwen3_context * ctx, const gguf_context * gguf, size_t & n_mapped, size_t & mapped_bytes) {
    ggml_backend_dev_t     dev   = ggml_backend_get_device(ctx->primary);
    ggml_backend_dev_props props = {};
    ggml_backend_dev_get_props(dev, &props);
    if (!props.caps.buffer_from_host_ptr) {
        log(QWEN3_LOG_INFO, "%s keeps weights in its own memory; copying weights", ggml_backend_dev_name(dev));
        return true;
    }

    struct stat st = {};
    if (fstat(ctx->fd, &st) != 0 || st.st_size <= 0) {
        log(QWEN3_LOG_WARN, "cannot stat the model file (%s); copying weights", std::strerror(errno));
        return true;
    }
    const size_t file_size = static_cast<size_t>(st.st_size);
    void *       addr      = mmap(nullptr, file_size, PROT_READ, MAP_SHARED, ctx->fd, 0);
    if (addr == MAP_FAILED) {
        log(QWEN3_LOG_WARN, "cannot memory-map the model (%s); copying weights", std::strerror(errno));
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
        log(QWEN3_LOG_INFO, "no tensor is stored as-is in the file; copying weights");
        return true;
    }

    // Wrap the whole page-aligned mapping, not just the data section.
    ggml_backend_buffer_t buffer = ggml_backend_dev_buffer_from_host_ptr(dev, addr, file_size, max_tensor_size);
    if (buffer == nullptr) {
        log(QWEN3_LOG_WARN, "%s cannot wrap the mapping; copying weights", ggml_backend_dev_name(dev));
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
            log(QWEN3_LOG_ERROR, "%s rejected mapped tensor \"%s\"", ggml_backend_dev_name(dev),
                ggml_get_name(c.tensor));
            ctx->mapped_buffer = buffer;  // tensors may point into it; freed by destroy()
            return false;
        }
        ++n_mapped;
        mapped_bytes += nbytes;
    }
    if (n_mapped == 0) {
        ggml_backend_buffer_free(buffer);
        log(QWEN3_LOG_INFO, "no tensor is aligned for the device; copying weights");
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

// Allocates every tensor the mapping did not take on the primary backend and uploads its bytes, staging device
// buffers in <= 16 MiB chunks.
bool copy_weights(qwen3_context * ctx, const gguf_context * gguf, size_t & n_copied, size_t & copied_bytes) {
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
        log(QWEN3_LOG_ERROR, "weight buffer allocation failed");
        return false;
    }
    ggml_backend_buffer_set_usage(ctx->copy_buffer, GGML_BACKEND_BUFFER_USAGE_WEIGHTS);

    constexpr size_t     kStageChunk = size_t(16) << 20;
    const size_t         data_offset = gguf_get_data_offset(gguf);
    std::vector<uint8_t> staging;
    for (ggml_tensor * t = ggml_get_first_tensor(ctx->ctx_meta); t != nullptr;
         t               = ggml_get_next_tensor(ctx->ctx_meta, t)) {
        // Everything not placed in the read-only mapping was allocated above, possibly across several
        // sub-buffers when it exceeds the device's maximum buffer size.
        if (t->buffer == nullptr || (ctx->mapped_buffer != nullptr && t->buffer == ctx->mapped_buffer)) {
            continue;
        }
        const int64_t idx = gguf_find_tensor(gguf, ggml_get_name(t));
        if (idx < 0) {
            log(QWEN3_LOG_ERROR, "tensor \"%s\" has no data in the file", ggml_get_name(t));
            return false;
        }
        const size_t nbytes = ggml_nbytes(t);
        const off_t  offset = static_cast<off_t>(data_offset + gguf_get_tensor_offset(gguf, idx));
        if (ggml_backend_buffer_is_host(t->buffer)) {
            if (!read_exact(ctx->fd, t->data, nbytes, offset)) {
                log(QWEN3_LOG_ERROR, "short read for tensor \"%s\"", ggml_get_name(t));
                return false;
            }
        } else {
            staging.resize(std::min(nbytes, kStageChunk));
            for (size_t done = 0; done < nbytes;) {
                const size_t n = std::min(nbytes - done, staging.size());
                if (!read_exact(ctx->fd, staging.data(), n, offset + static_cast<off_t>(done))) {
                    log(QWEN3_LOG_ERROR, "short read for tensor \"%s\"", ggml_get_name(t));
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

// llama_kv_cache: one F16 K and V tensor per layer on the primary backend. Upstream clears the whole buffer;
// here clear_attended() zeroes cells the first time a graph attends to them, so every attended cell past the
// written ones holds a finite value under the -inf mask and untouched cells cost no memory.
bool init_kv_cache(qwen3_context * ctx, int32_t n_ctx) {
    const size_t     n_layer = static_cast<size_t>(ctx->hp.n_layer);
    ggml_init_params params  = { 2 * n_layer * ggml_tensor_overhead(), nullptr, /*no_alloc=*/true };
    ctx->kv_ctx              = ggml_init(params);
    if (ctx->kv_ctx == nullptr) {
        log(QWEN3_LOG_ERROR, "KV cache context allocation failed");
        return false;
    }
    const int64_t n_embd_gqa = static_cast<int64_t>(ctx->hp.n_embd_head) * ctx->hp.n_head_kv;
    ctx->kv.n_ctx            = n_ctx;
    for (size_t il = 0; il < n_layer; ++il) {
        ggml_tensor * k = ggml_new_tensor_2d(ctx->kv_ctx, GGML_TYPE_F16, n_embd_gqa, n_ctx);
        ggml_tensor * v = ggml_new_tensor_2d(ctx->kv_ctx, GGML_TYPE_F16, n_embd_gqa, n_ctx);
        ggml_format_name(k, "cache_k_l%zu", il);
        ggml_format_name(v, "cache_v_l%zu", il);
        ctx->kv.k.push_back(k);
        ctx->kv.v.push_back(v);
    }
    ctx->kv_buffer = ggml_backend_alloc_ctx_tensors(ctx->kv_ctx, ctx->primary);
    if (ctx->kv_buffer == nullptr) {
        log(QWEN3_LOG_ERROR, "KV cache allocation failed");
        return false;
    }
    ctx->kv_cleared = 0;
    log(QWEN3_LOG_INFO, "KV cache: %d cells, %zu layers, %.1f MiB (F16)", n_ctx, n_layer,
        static_cast<double>(ggml_backend_buffer_get_size(ctx->kv_buffer)) / (1024.0 * 1024.0));
    return true;
}

qwen3_context * init_from_file(const char * path, qwen3_context_params params) {
    if (path == nullptr) {
        log(QWEN3_LOG_ERROR, "model path is NULL");
        return nullptr;
    }
    if (params.n_threads < 1 || params.n_ctx < 1) {
        log(QWEN3_LOG_ERROR, "n_threads and n_ctx must be >= 1 (got %d, %d)", params.n_threads, params.n_ctx);
        return nullptr;
    }
    const int64_t t_start = ggml_time_us();

    ContextGuard    guard{ new qwen3_context() };
    qwen3_context * ctx = guard.ctx;
    ctx->n_threads      = params.n_threads;

    gguf_init_params gparams = { /*no_alloc=*/true, /*ctx=*/&ctx->ctx_meta };
    GgufGuard        gguf{ gguf_init_from_file(path, gparams) };
    if (gguf.gguf == nullptr) {
        log(QWEN3_LOG_ERROR, "cannot read GGUF %s", path);
        return nullptr;
    }
    if (!qwen3::read_hparams(gguf.gguf, ctx->hp) || !qwen3::load_vocab(gguf.gguf, ctx->vocab) ||
        !qwen3::bind_weights(gguf.gguf, ctx->ctx_meta, ctx->hp, ctx->weights)) {
        return nullptr;
    }
    if (ctx->vocab.pieces.size() != static_cast<size_t>(ctx->hp.n_vocab)) {
        log(QWEN3_LOG_ERROR, "vocabulary has %zu tokens, the output head has %d rows", ctx->vocab.pieces.size(),
            ctx->hp.n_vocab);
        return nullptr;
    }
    ctx->weight_type = ggml_type_name(ctx->weights.layers.front().wq->type);

    if (!init_backends(ctx, params.use_gpu)) {
        return nullptr;
    }

    ctx->fd = open(path, O_RDONLY | O_CLOEXEC);
    if (ctx->fd < 0) {
        log(QWEN3_LOG_ERROR, "cannot open %s (%s)", path, std::strerror(errno));
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
    log(QWEN3_LOG_INFO, "weights: %zu tensors (%.1f MiB) mapped, %zu tensors (%.1f MiB) copied", n_mapped,
        static_cast<double>(mapped_bytes) / (1024.0 * 1024.0), n_copied,
        static_cast<double>(copied_bytes) / (1024.0 * 1024.0));

    if (!init_kv_cache(ctx, params.n_ctx)) {
        return nullptr;
    }

    ctx->sched = ggml_backend_sched_new(ctx->backends.data(), nullptr, static_cast<int>(ctx->backends.size()),
                                        /*graph_size=*/4096, /*parallel=*/false, /*op_offload=*/true);
    if (ctx->sched == nullptr) {
        log(QWEN3_LOG_ERROR, "ggml_backend_sched_new failed");
        return nullptr;
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

    log(QWEN3_LOG_INFO, "loaded %s in %.0f ms (%d layers, n_embd %d, vocab %d, %s)", path,
        static_cast<double>(ggml_time_us() - t_start) / 1000.0, ctx->hp.n_layer, ctx->hp.n_embd, ctx->hp.n_vocab,
        ctx->weight_type);
    return guard.release();
}

bool poll(qwen3_abort_callback abort_callback, void * user_data) {
    return abort_callback != nullptr && abort_callback(user_data);
}

int32_t padded_n_kv(int32_t n_ctx, int32_t used) {
    const int32_t padded = (used + kKvPad - 1) / kKvPad * kKvPad;
    return std::min(n_ctx, std::max(kKvPad, padded));
}

// Zeroes the cells a graph over n_kv cells attends to for the first time.
void clear_attended(qwen3_context * ctx, int32_t n_kv) {
    if (n_kv <= ctx->kv_cleared) {
        return;
    }
    for (size_t il = 0; il < ctx->kv.k.size(); ++il) {
        for (ggml_tensor * t : { ctx->kv.k[il], ctx->kv.v[il] }) {
            const size_t row = t->nb[1];
            ggml_backend_tensor_memset(t, 0, static_cast<size_t>(ctx->kv_cleared) * row,
                                       static_cast<size_t>(n_kv - ctx->kv_cleared) * row);
        }
    }
    ctx->kv_cleared = n_kv;
}

// One graph evaluation: tokens ctx->batch at positions n_past.., writing their cells, with logits for the last
// token (n_outputs == 1), every token (n_outputs == n_tokens) or none.
qwen3_status eval(qwen3_context * ctx, int32_t n_past, int32_t n_outputs, qwen3_abort_callback abort_callback,
                  void * abort_user_data) {
    const int32_t n_tokens = static_cast<int32_t>(ctx->batch.size());
    const int32_t n_kv     = padded_n_kv(ctx->kv.n_ctx, n_past + n_tokens);
    clear_attended(ctx, n_kv);

    if (ctx->graph.gf == nullptr || ctx->graph.n_tokens != n_tokens || ctx->graph.n_outputs != n_outputs ||
        ctx->graph.n_kv != n_kv) {
        release_graph(ctx);
        ggml_init_params ip = { qwen3::graph_context_size(), nullptr, /*no_alloc=*/true };
        ctx->graph_ctx      = ggml_init(ip);
        if (ctx->graph_ctx == nullptr) {
            log(QWEN3_LOG_ERROR, "graph context allocation failed");
            return QWEN3_ERR_BACKEND;
        }
        if (!qwen3::build_graph(ctx->graph_ctx, ctx->hp, ctx->weights, ctx->kv, n_tokens, n_outputs, n_kv,
                                ctx->graph)) {
            release_graph(ctx);
            return QWEN3_ERR_BACKEND;
        }
        if (!ggml_backend_sched_alloc_graph(ctx->sched, ctx->graph.gf)) {
            log(QWEN3_LOG_ERROR, "graph allocation failed (n_tokens=%d, n_kv=%d)", n_tokens, n_kv);
            release_graph(ctx);
            return QWEN3_ERR_BACKEND;
        }
    }

    ctx->positions.resize(static_cast<size_t>(n_tokens));
    ctx->cells.resize(static_cast<size_t>(n_tokens));
    for (int32_t i = 0; i < n_tokens; ++i) {
        ctx->positions[static_cast<size_t>(i)] = n_past + i;
        ctx->cells[static_cast<size_t>(i)]     = n_past + i;
    }
    // Causal mask over cells: cell j is visible to the token at position p when j <= p.
    const ggml_fp16_t keep = ggml_fp32_to_fp16(0.0f);
    const ggml_fp16_t drop = ggml_fp32_to_fp16(-INFINITY);
    ctx->mask.resize(static_cast<size_t>(n_kv) * static_cast<size_t>(n_tokens));
    for (int32_t i = 0; i < n_tokens; ++i) {
        ggml_fp16_t * row = ctx->mask.data() + static_cast<size_t>(i) * static_cast<size_t>(n_kv);
        const int32_t p   = n_past + i;
        for (int32_t j = 0; j < n_kv; ++j) {
            row[j] = j <= p ? keep : drop;
        }
    }
    const qwen3::Graph & g = ctx->graph;
    ggml_backend_tensor_set(g.tokens, ctx->batch.data(), 0, ctx->batch.size() * sizeof(int32_t));
    ggml_backend_tensor_set(g.pos, ctx->positions.data(), 0, ctx->positions.size() * sizeof(int32_t));
    ggml_backend_tensor_set(g.kv_idxs, ctx->cells.data(), 0, ctx->cells.size() * sizeof(int64_t));
    ggml_backend_tensor_set(g.kq_mask, ctx->mask.data(), 0, ctx->mask.size() * sizeof(ggml_fp16_t));
    if (n_outputs > 0) {
        ctx->out_ids.resize(static_cast<size_t>(n_outputs));
        for (int32_t i = 0; i < n_outputs; ++i) {
            ctx->out_ids[static_cast<size_t>(i)] = n_tokens - n_outputs + i;
        }
        ggml_backend_tensor_set(g.out_ids, ctx->out_ids.data(), 0, ctx->out_ids.size() * sizeof(int32_t));
    }

    // No abort callback ever reaches the Metal backend; cancellation is polled here, between evaluations.
    if (poll(abort_callback, abort_user_data)) {
        return QWEN3_ERR_CANCELLED;
    }
    if (ggml_backend_sched_graph_compute(ctx->sched, g.gf) != GGML_STATUS_SUCCESS) {
        log(QWEN3_LOG_ERROR, "graph compute failed");
        release_graph(ctx);
        return QWEN3_ERR_BACKEND;
    }
    return QWEN3_OK;
}

// Greedy choice over output row `row` of the last evaluation: the first maximum, as the harness's argmax, and
// the best other token.
qwen3_decision decide(qwen3_context * ctx, int32_t row) {
    const size_t n_vocab = static_cast<size_t>(ctx->hp.n_vocab);
    ctx->logits.resize(n_vocab);
    ggml_backend_tensor_get(ctx->graph.logits, ctx->logits.data(), static_cast<size_t>(row) * n_vocab * sizeof(float),
                            n_vocab * sizeof(float));
    const float * l      = ctx->logits.data();
    int32_t       best   = 0;
    int32_t       second = -1;
    for (size_t t = 1; t < n_vocab; ++t) {
        if (l[t] > l[best]) {
            second = best;
            best   = static_cast<int32_t>(t);
        } else if (second < 0 || l[t] > l[second]) {
            second = static_cast<int32_t>(t);
        }
    }
    qwen3_decision d;
    d.token           = best;
    d.logit           = l[best];
    d.runner_up       = second;
    d.runner_up_logit = second >= 0 ? l[second] : -std::numeric_limits<float>::infinity();
    return d;
}

// common_ngram_simple_draft: the pattern is the last size_ngram - 1 tokens of `tokens` plus `sampled`; the
// latest earlier occurrence (position 0 excluded, the current one skipped) drafts the tokens after it, at most
// size_mgram and only when at least size_ngram are available.
void ngram_simple_draft(const std::vector<int32_t> & tokens, int32_t sampled, size_t n, size_t m,
                        std::vector<int32_t> & draft) {
    draft.clear();
    const size_t cur_len = tokens.size();
    if (cur_len <= n + m + 1) {
        return;
    }
    size_t match_pos = 0;
    for (size_t j = cur_len - n - 1; j > 0; --j) {
        bool match = true;
        for (size_t k = 0; k < n; ++k) {
            const int32_t want = k + 1 < n ? tokens[cur_len - n + 1 + k] : sampled;
            if (tokens[j + k] != want) {
                match = false;
                break;
            }
        }
        if (match) {
            match_pos = j;
            break;
        }
    }
    if (match_pos == 0) {
        return;
    }
    const size_t copy_max = std::min(m, cur_len - (match_pos + n));
    if (copy_max < n) {
        return;
    }
    for (size_t j = 0; j < copy_max; ++j) {
        draft.push_back(tokens[match_pos + n + j]);
    }
}

// Feeds tokens[0, n) at positions n_past.. in batches of at most kUbatch tokens; only the last batch produces
// logits, for its last token.
qwen3_status feed(qwen3_context * ctx, const int32_t * tokens, int32_t n, int32_t n_past,
                  qwen3_abort_callback abort_callback, void * abort_user_data) {
    for (int32_t start = 0; start < n; start += kUbatch) {
        const int32_t count = std::min(kUbatch, n - start);
        const bool    last  = start + count == n;
        ctx->batch.assign(tokens + start, tokens + start + count);
        const qwen3_status status = eval(ctx, n_past + start, last ? 1 : 0, abort_callback, abort_user_data);
        if (status != QWEN3_OK) {
            return status;
        }
    }
    return QWEN3_OK;
}

qwen3_status generate(qwen3_context * ctx, const int32_t * prompt, int32_t n_prompt, qwen3_generate_params params,
                      qwen3_abort_callback abort_callback, void * abort_user_data) {
    const auto t0 = Clock::now();
    ctx->history.assign(prompt, prompt + n_prompt);
    const int32_t eos = ctx->vocab.eos_id;

    // Prefill in ubatches; only the last one produces logits, for its last token.
    const qwen3_status prefilled = feed(ctx, prompt, n_prompt, 0, abort_callback, abort_user_data);
    if (prefilled != QWEN3_OK) {
        return prefilled;
    }
    qwen3_decision d = decide(ctx, 0);
    ctx->decisions.push_back(d);
    int32_t tok          = d.token;
    const auto t_prefill = Clock::now();

    const bool    drafting = params.ngram_n > 0;
    const int32_t max_new  = params.max_new_tokens;
    int32_t       n_past   = n_prompt;
    while (tok != eos) {
        ctx->output.push_back(tok);
        if (static_cast<int32_t>(ctx->output.size()) >= max_new) {
            break;
        }
        ctx->draft.clear();
        if (drafting) {
            ngram_simple_draft(ctx->history, tok, static_cast<size_t>(params.ngram_n),
                               static_cast<size_t>(params.ngram_m), ctx->draft);
            const size_t room = static_cast<size_t>(max_new - static_cast<int32_t>(ctx->output.size()));
            if (ctx->draft.size() > room) {
                ctx->draft.resize(room);
            }
        }
        ctx->batch.clear();
        ctx->batch.push_back(tok);
        ctx->batch.insert(ctx->batch.end(), ctx->draft.begin(), ctx->draft.end());
        const int32_t      n_tokens = static_cast<int32_t>(ctx->batch.size());
        const qwen3_status status   = eval(ctx, n_past, n_tokens, abort_callback, abort_user_data);
        if (status != QWEN3_OK) {
            return status;
        }
        ctx->timings.n_evals++;
        ctx->timings.n_drafted += static_cast<int32_t>(ctx->draft.size());
        ctx->history.push_back(tok);
        n_past++;

        d             = decide(ctx, 0);
        int32_t next  = d.token;
        size_t  i     = 0;
        bool    done  = false;
        while (i < ctx->draft.size() && next == ctx->draft[i]) {
            // draft[i] is the greedy choice: keep it (its cell is already written).
            if (next == eos) {
                break;
            }
            ctx->decisions.push_back(d);
            ctx->output.push_back(next);
            ctx->history.push_back(next);
            n_past++;
            ctx->timings.n_accepted++;
            if (static_cast<int32_t>(ctx->output.size()) >= max_new) {
                done = true;
                break;
            }
            ++i;
            d    = decide(ctx, static_cast<int32_t>(i));
            next = d.token;
        }
        // Cells from n_past on hold rejected drafts: the next evaluation overwrites them and the causal mask
        // hides them until then (llama_memory_seq_rm upstream).
        if (done) {
            break;
        }
        ctx->decisions.push_back(d);
        tok = next;
    }
    const auto t_end = Clock::now();

    ctx->timings.prefill_ms = ms_between(t0, t_prefill);
    ctx->timings.decode_ms  = ms_between(t_prefill, t_end);
    ctx->timings.n_prompt   = n_prompt;
    ctx->timings.n_output   = static_cast<int32_t>(ctx->output.size());
    return QWEN3_OK;
}

// Builds ctx->guide, the trie of the candidates' token sequences, each child list sorted by token id. Returns
// false, logged, when two candidates are equal.
bool build_guide(qwen3_context * ctx, const int32_t * tokens, const int32_t * lengths, int32_t n_candidates) {
    std::vector<qwen3::GuideNode> & g = ctx->guide;
    g.clear();
    g.emplace_back();
    const int32_t * candidate = tokens;
    for (int32_t c = 0; c < n_candidates; ++c) {
        int32_t node = 0;
        for (int32_t k = 0; k < lengths[c]; ++k) {
            const int32_t token = candidate[k];
            int32_t       prev  = -1;
            int32_t       child = g[static_cast<size_t>(node)].first_child;
            while (child >= 0 && g[static_cast<size_t>(child)].token < token) {
                prev  = child;
                child = g[static_cast<size_t>(child)].next_sibling;
            }
            if (child < 0 || g[static_cast<size_t>(child)].token != token) {
                qwen3::GuideNode added;
                added.token        = token;
                added.next_sibling = child;
                const int32_t id   = static_cast<int32_t>(g.size());
                g.push_back(added);
                if (prev < 0) {
                    g[static_cast<size_t>(node)].first_child = id;
                } else {
                    g[static_cast<size_t>(prev)].next_sibling = id;
                }
                child = id;
            }
            node = child;
        }
        candidate += lengths[c];
        if (g[static_cast<size_t>(node)].candidate >= 0) {
            log(QWEN3_LOG_ERROR, "guided candidate %d repeats candidate %d", c, g[static_cast<size_t>(node)].candidate);
            return false;
        }
        g[static_cast<size_t>(node)].candidate = c;
    }
    return true;
}

// The child of trie node `node` reached by `token`, or -1.
int32_t guide_child(const qwen3_context * ctx, int32_t node, int32_t token) {
    const std::vector<qwen3::GuideNode> & g = ctx->guide;
    for (int32_t c = g[static_cast<size_t>(node)].first_child; c >= 0; c = g[static_cast<size_t>(c)].next_sibling) {
        if (g[static_cast<size_t>(c)].token >= token) {
            return g[static_cast<size_t>(c)].token == token ? c : -1;
        }
    }
    return -1;
}

// The guided choice at trie node `node` from output row `row` of the last evaluation: the allowed option (the
// node's children, and the EOS where a candidate ends) with the highest logit, the lowest id among equal
// logits; the best other allowed option; and the unconstrained argmax beside them.
qwen3_guided_step guided_step(qwen3_context * ctx, int32_t node, int32_t row, int32_t position) {
    const qwen3_decision unconstrained = decide(ctx, row);  // reads the row into ctx->logits
    const float *        l             = ctx->logits.data();
    qwen3_guided_step    s;
    s.position            = position;
    s.n_options           = 0;
    s.token               = -1;
    s.runner_up           = -1;
    s.unconstrained_token = unconstrained.token;
    s.logit               = -std::numeric_limits<float>::infinity();
    s.runner_up_logit     = -std::numeric_limits<float>::infinity();
    s.unconstrained_logit = unconstrained.logit;
    const auto consider   = [&s, l](int32_t t) {
        const float v = l[t];
        ++s.n_options;
        if (s.token < 0 || v > s.logit || (v == s.logit && t < s.token)) {
            s.runner_up       = s.token;
            s.runner_up_logit = s.logit;
            s.token           = t;
            s.logit           = v;
        } else if (s.runner_up < 0 || v > s.runner_up_logit || (v == s.runner_up_logit && t < s.runner_up)) {
            s.runner_up       = t;
            s.runner_up_logit = v;
        }
    };
    const std::vector<qwen3::GuideNode> & g = ctx->guide;
    for (int32_t c = g[static_cast<size_t>(node)].first_child; c >= 0; c = g[static_cast<size_t>(c)].next_sibling) {
        consider(g[static_cast<size_t>(c)].token);
    }
    if (g[static_cast<size_t>(node)].candidate >= 0) {
        consider(ctx->vocab.eos_id);
    }
    return s;
}

// Greedy generation over ctx->guide. Every step's choice is an allowed option, so the walk descends one trie level
// per output token and ends at a candidate's end: the depth bound (max_new_tokens) and the context bound
// (n_prompt + max_new_tokens <= n_ctx) checked by the caller hold throughout.
qwen3_status generate_guided(qwen3_context * ctx, const int32_t * prompt, int32_t n_prompt, bool batch_forced,
                             qwen3_abort_callback abort_callback, void * abort_user_data) {
    const auto                            t0  = Clock::now();
    const int32_t                         eos = ctx->vocab.eos_id;
    const std::vector<qwen3::GuideNode> & g   = ctx->guide;

    const qwen3_status prefilled = feed(ctx, prompt, n_prompt, 0, abort_callback, abort_user_data);
    if (prefilled != QWEN3_OK) {
        return prefilled;
    }
    int32_t node = 0;
    ctx->guided_steps.push_back(guided_step(ctx, node, 0, 0));
    const auto t_prefill = Clock::now();

    int32_t n_past = n_prompt;
    while (ctx->guided_steps.back().token != eos) {
        // Append the chosen token; with batch_forced, also every following token that is its node's only option.
        ctx->pending.clear();
        int32_t tok = ctx->guided_steps.back().token;
        for (;;) {
            node = guide_child(ctx, node, tok);
            ctx->output.push_back(tok);
            ctx->pending.push_back(tok);
            const qwen3::GuideNode & n = g[static_cast<size_t>(node)];
            const bool only_child =
                n.candidate < 0 && n.first_child >= 0 && g[static_cast<size_t>(n.first_child)].next_sibling < 0;
            if (!batch_forced || !only_child) {
                break;
            }
            tok = g[static_cast<size_t>(n.first_child)].token;
        }
        if (batch_forced && g[static_cast<size_t>(node)].first_child < 0) {
            break;  // a candidate's end with no longer candidate through it: the EOS is the only option
        }
        const int32_t      n_fed  = static_cast<int32_t>(ctx->pending.size());
        const qwen3_status status = feed(ctx, ctx->pending.data(), n_fed, n_past, abort_callback, abort_user_data);
        if (status != QWEN3_OK) {
            return status;
        }
        ctx->timings.n_evals += (n_fed + kUbatch - 1) / kUbatch;
        n_past += n_fed;
        ctx->guided_steps.push_back(guided_step(ctx, node, 0, static_cast<int32_t>(ctx->output.size())));
    }
    const auto t_end = Clock::now();

    ctx->guided_candidate   = g[static_cast<size_t>(node)].candidate;
    ctx->timings.prefill_ms = ms_between(t0, t_prefill);
    ctx->timings.decode_ms  = ms_between(t_prefill, t_end);
    ctx->timings.n_prompt   = n_prompt;
    ctx->timings.n_output   = static_cast<int32_t>(ctx->output.size());
    return QWEN3_OK;
}

void clear_results(qwen3_context * ctx) {
    ctx->output.clear();
    ctx->decisions.clear();
    ctx->guided_steps.clear();
    ctx->guided_candidate = -1;
    ctx->timings          = {};
}

// Checks the request fields qwen3_generate and qwen3_generate_guided share; logs the first violation.
bool valid_prompt(const qwen3_context * ctx, const int32_t * prompt, int32_t n_prompt, int32_t max_new_tokens) {
    if (prompt == nullptr || n_prompt < 1 || max_new_tokens < 1 ||
        static_cast<int64_t>(n_prompt) + max_new_tokens > ctx->kv.n_ctx) {
        log(QWEN3_LOG_ERROR, "invalid generation request (n_prompt=%d, max_new_tokens=%d, n_ctx=%d)", n_prompt,
            max_new_tokens, ctx->kv.n_ctx);
        return false;
    }
    for (int32_t i = 0; i < n_prompt; ++i) {
        if (prompt[i] < 0 || prompt[i] >= ctx->hp.n_vocab) {
            log(QWEN3_LOG_ERROR, "prompt token %d is outside the vocabulary", prompt[i]);
            return false;
        }
    }
    return true;
}

// Checks the guided candidate arrays against qwen3_generate_guided's rules, except uniqueness, which
// build_guide checks; logs the first violation.
bool valid_candidates(const qwen3_context * ctx, const int32_t * tokens, const int32_t * lengths,
                      int32_t n_candidates, int32_t max_new_tokens) {
    if (tokens == nullptr || lengths == nullptr || n_candidates < 1) {
        log(QWEN3_LOG_ERROR, "guided generation needs at least one candidate (n_candidates=%d)", n_candidates);
        return false;
    }
    int64_t total = 0;
    for (int32_t c = 0; c < n_candidates; ++c) {
        if (lengths[c] < 1 || lengths[c] > max_new_tokens) {
            log(QWEN3_LOG_ERROR, "guided candidate %d has %d tokens; each needs 1 to max_new_tokens (%d)", c,
                lengths[c], max_new_tokens);
            return false;
        }
        total += lengths[c];
    }
    if (total >= std::numeric_limits<int32_t>::max()) {
        log(QWEN3_LOG_ERROR, "guided candidates hold too many tokens (%lld)", static_cast<long long>(total));
        return false;
    }
    for (int64_t i = 0; i < total; ++i) {
        const int32_t t = tokens[i];
        if (t < 0 || t >= ctx->hp.n_vocab || t == ctx->vocab.eos_id ||
            static_cast<size_t>(t) >= ctx->vocab.types.size() ||
            ctx->vocab.types[static_cast<size_t>(t)] != QWEN3_TOKEN_NORMAL) {
            log(QWEN3_LOG_ERROR, "guided candidate token %d is not a normal vocabulary token", t);
            return false;
        }
    }
    return true;
}

}  // namespace

qwen3_context_params qwen3_context_default_params(void) {
    qwen3_context_params params;
    params.use_gpu     = true;
    params.n_threads   = 4;
    params.map_weights = true;
    params.n_ctx       = 2048;
    return params;
}

qwen3_context * qwen3_init_from_file(const char * path, qwen3_context_params params) {
    try {
        return init_from_file(path, params);
    } catch (const std::bad_alloc &) {
        log(QWEN3_LOG_ERROR, "out of memory while loading");
    } catch (...) {
        log(QWEN3_LOG_ERROR, "unexpected exception while loading");
    }
    return nullptr;
}

void qwen3_free(qwen3_context * ctx) {
    if (ctx != nullptr) {
        destroy(ctx);
    }
}

int32_t qwen3_n_vocab(const qwen3_context * ctx) {
    return ctx != nullptr ? ctx->hp.n_vocab : 0;
}

const char * qwen3_vocab_piece(const qwen3_context * ctx, int32_t id, size_t * length) {
    if (length != nullptr) {
        *length = 0;
    }
    if (ctx == nullptr || id < 0 || static_cast<size_t>(id) >= ctx->vocab.pieces.size()) {
        return nullptr;
    }
    const std::string & piece = ctx->vocab.pieces[static_cast<size_t>(id)];
    if (length != nullptr) {
        *length = piece.size();
    }
    return piece.data();
}

int32_t qwen3_vocab_type(const qwen3_context * ctx, int32_t id) {
    if (ctx == nullptr || id < 0 || static_cast<size_t>(id) >= ctx->vocab.types.size()) {
        return 0;
    }
    return ctx->vocab.types[static_cast<size_t>(id)];
}

int32_t qwen3_n_merges(const qwen3_context * ctx) {
    return ctx != nullptr ? static_cast<int32_t>(ctx->vocab.merges.size()) : 0;
}

const char * qwen3_merge(const qwen3_context * ctx, int32_t i, size_t * length) {
    if (length != nullptr) {
        *length = 0;
    }
    if (ctx == nullptr || i < 0 || static_cast<size_t>(i) >= ctx->vocab.merges.size()) {
        return nullptr;
    }
    const std::string & merge = ctx->vocab.merges[static_cast<size_t>(i)];
    if (length != nullptr) {
        *length = merge.size();
    }
    return merge.data();
}

int32_t qwen3_eos_token_id(const qwen3_context * ctx) {
    return ctx != nullptr ? ctx->vocab.eos_id : -1;
}

int32_t qwen3_n_ctx(const qwen3_context * ctx) {
    return ctx != nullptr ? ctx->kv.n_ctx : 0;
}

const char * qwen3_weight_type(const qwen3_context * ctx) {
    return ctx != nullptr ? ctx->weight_type : "";
}

const char * qwen3_backend_name(const qwen3_context * ctx) {
    return ctx != nullptr && ctx->primary != nullptr ? ggml_backend_name(ctx->primary) : "";
}

qwen3_generate_params qwen3_generate_default_params(void) {
    qwen3_generate_params params;
    params.max_new_tokens = 512;
    params.ngram_n        = 2;
    params.ngram_m        = 8;
    return params;
}

qwen3_status qwen3_generate(qwen3_context * ctx, const int32_t * prompt, int32_t n_prompt,
                            qwen3_generate_params params, qwen3_abort_callback abort_callback,
                            void * abort_user_data) {
    if (ctx == nullptr) {
        return QWEN3_ERR_INVALID_ARGUMENT;
    }
    clear_results(ctx);
    if (params.ngram_n < 0 || (params.ngram_n > 0 && params.ngram_m < 1)) {
        log(QWEN3_LOG_ERROR, "invalid n-gram drafting (ngram %d/%d)", params.ngram_n, params.ngram_m);
        return QWEN3_ERR_INVALID_ARGUMENT;
    }
    if (!valid_prompt(ctx, prompt, n_prompt, params.max_new_tokens)) {
        return QWEN3_ERR_INVALID_ARGUMENT;
    }
    qwen3_status status = QWEN3_ERR_BACKEND;
    try {
        status = generate(ctx, prompt, n_prompt, params, abort_callback, abort_user_data);
    } catch (const std::bad_alloc &) {
        log(QWEN3_LOG_ERROR, "out of memory while generating");
    } catch (...) {
        log(QWEN3_LOG_ERROR, "unexpected exception while generating");
    }
    if (status != QWEN3_OK) {
        clear_results(ctx);
    }
    return status;
}

qwen3_guided_params qwen3_guided_default_params(void) {
    qwen3_guided_params params;
    params.max_new_tokens = 512;
    params.batch_forced   = true;
    return params;
}

qwen3_status qwen3_generate_guided(qwen3_context * ctx, const int32_t * prompt, int32_t n_prompt,
                                   const int32_t * candidate_tokens, const int32_t * candidate_lengths,
                                   int32_t n_candidates, qwen3_guided_params params,
                                   qwen3_abort_callback abort_callback, void * abort_user_data) {
    if (ctx == nullptr) {
        return QWEN3_ERR_INVALID_ARGUMENT;
    }
    clear_results(ctx);
    if (!valid_prompt(ctx, prompt, n_prompt, params.max_new_tokens) ||
        !valid_candidates(ctx, candidate_tokens, candidate_lengths, n_candidates, params.max_new_tokens)) {
        return QWEN3_ERR_INVALID_ARGUMENT;
    }
    qwen3_status status = QWEN3_ERR_BACKEND;
    try {
        if (!build_guide(ctx, candidate_tokens, candidate_lengths, n_candidates)) {
            status = QWEN3_ERR_INVALID_ARGUMENT;
        } else {
            status = generate_guided(ctx, prompt, n_prompt, params.batch_forced, abort_callback, abort_user_data);
        }
    } catch (const std::bad_alloc &) {
        log(QWEN3_LOG_ERROR, "out of memory while generating");
    } catch (...) {
        log(QWEN3_LOG_ERROR, "unexpected exception while generating");
    }
    if (status != QWEN3_OK) {
        clear_results(ctx);
    }
    return status;
}

int32_t qwen3_guided_candidate(const qwen3_context * ctx) {
    return ctx != nullptr ? ctx->guided_candidate : -1;
}

int32_t qwen3_n_guided_steps(const qwen3_context * ctx) {
    return ctx != nullptr ? static_cast<int32_t>(ctx->guided_steps.size()) : 0;
}

qwen3_guided_step qwen3_get_guided_step(const qwen3_context * ctx, int32_t i) {
    if (ctx == nullptr || i < 0 || static_cast<size_t>(i) >= ctx->guided_steps.size()) {
        qwen3_guided_step none   = {};
        none.token               = -1;
        none.runner_up           = -1;
        none.unconstrained_token = -1;
        return none;
    }
    return ctx->guided_steps[static_cast<size_t>(i)];
}

int32_t qwen3_n_output(const qwen3_context * ctx) {
    return ctx != nullptr ? static_cast<int32_t>(ctx->output.size()) : 0;
}

const int32_t * qwen3_output(const qwen3_context * ctx) {
    return ctx != nullptr && !ctx->output.empty() ? ctx->output.data() : nullptr;
}

int32_t qwen3_n_decisions(const qwen3_context * ctx) {
    return ctx != nullptr ? static_cast<int32_t>(ctx->decisions.size()) : 0;
}

qwen3_decision qwen3_get_decision(const qwen3_context * ctx, int32_t i) {
    if (ctx == nullptr || i < 0 || static_cast<size_t>(i) >= ctx->decisions.size()) {
        qwen3_decision none = {};
        none.token          = -1;
        none.runner_up      = -1;
        return none;
    }
    return ctx->decisions[static_cast<size_t>(i)];
}

qwen3_timings qwen3_get_timings(const qwen3_context * ctx) {
    return ctx != nullptr ? ctx->timings : qwen3_timings{};
}
