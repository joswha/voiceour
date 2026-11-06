// granite.h — Voiceour's native Granite Speech 5 TurboCTC inference (offline, one utterance per call).
//
// Adapted from transcribe.cpp (MIT) src/arch/granite5_ctc at 5700f127e38dd53c4735ea23ef743b4b538eacd4,
// built against the ggml vendored in Vendor/parakeet/ggml (0.19.0). See Vendor/granite/NOTICE.md.
#ifndef GRANITE_H
#define GRANITE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct granite_context;

enum granite_status {
    GRANITE_OK = 0,
    // Null context/PCM with a positive length, negative length, or non-finite PCM.
    GRANITE_ERR_INVALID_ARGUMENT = 1,
    // The abort callback returned true at a stage boundary.
    GRANITE_ERR_CANCELLED = 2,
    // Graph construction, allocation or compute failed.
    GRANITE_ERR_BACKEND = 3,
};

enum granite_log_level {
    GRANITE_LOG_DEBUG = 1,
    GRANITE_LOG_INFO = 2,
    GRANITE_LOG_WARN = 3,
    GRANITE_LOG_ERROR = 4,
};

typedef void (*granite_log_callback)(enum granite_log_level level, const char * text, void * user_data);

// Process-wide sink for native diagnostics. NULL restores the default (stderr). Never stdout.
void granite_log_set(granite_log_callback callback, void * user_data);

struct granite_context_params {
    bool use_gpu;       // prefer the Metal device; CPU-only when false or when no GPU device exists
    int32_t n_threads;  // CPU threads for CPU-resident graph work and the frontend (>= 1)
    bool map_weights;   // map the GGUF read-only into backend buffers when the device accepts host pointers
};

// use_gpu = true, n_threads = 6, map_weights = true.
struct granite_context_params granite_context_default_params(void);

// Loads and validates a granite_speech5_ctc GGUF. Returns NULL on failure; the reason is logged.
struct granite_context * granite_init_from_file(const char * path, struct granite_context_params params);

// Frees everything the context owns, in dependency order. NULL is a no-op.
void granite_free(struct granite_context * ctx);

// Polled only at stage boundaries: before the frontend, before graph compute, after graph compute and
// before CTC decoding. Never polled inside a Metal command buffer. Returning true ends the run with
// GRANITE_ERR_CANCELLED and clears the previous run's results.
typedef bool (*granite_abort_callback)(void * user_data);

// Recognizes one utterance of mono 16 kHz float PCM in [-1, 1].
// - n_samples == 0 succeeds with zero tokens.
// - Inputs shorter than the minimum that yields one encoder frame after both subsampling blocks are
//   right-padded with zeros to exactly that minimum (1,120 samples for the pinned model).
// Results replace the previous run's, including on failure (which leaves zero tokens).
enum granite_status granite_transcribe(struct granite_context * ctx,
                                       const float * pcm,
                                       int32_t n_samples,
                                       granite_abort_callback abort_callback,
                                       void * abort_user_data);

struct granite_token {
    int32_t id;           // vocabulary id; the CTC blank never appears
    int32_t frame_begin;  // first encoder frame of this token's CTC run
    int32_t frame_end;    // one past the last encoder frame of the run
    float p;              // softmax probability of `id` at frame_begin
    bool is_special;      // a tokenizer special token (control/user, e.g. <|nospeech|>), never transcript text
};

int32_t granite_n_tokens(const struct granite_context * ctx);

// i in [0, granite_n_tokens). Returns a zeroed token (id -1) when out of range.
struct granite_token granite_get_token(const struct granite_context * ctx, int32_t i);

// Decoded bytes of token i alone: SentencePiece U+2581 -> ' ', <0xHH> byte pieces -> that byte, or the
// GPT-2 byte map, per the GGUF's tokenizer.ggml.model. May be a partial UTF-8 sequence; concatenating
// consecutive tokens' bytes equals the full-sequence decode. Valid until the next transcribe or free.
// Sets *length; returns NULL with *length = 0 when out of range.
const char * granite_token_bytes(const struct granite_context * ctx, int32_t i, size_t * length);

// Encoder frame duration in milliseconds (hop length x temporal subsampling; 80 for the pinned model).
int32_t granite_ms_per_frame(const struct granite_context * ctx);

// Vocabulary id whose piece is exactly "<|nospeech|>", or -1 when the vocabulary has none.
int32_t granite_nospeech_token_id(const struct granite_context * ctx);

// Encoder frames produced by the last successful run (0 before any run).
int32_t granite_n_frames(const struct granite_context * ctx);

// CTC output dimension, the blank included (16,384 for the pinned model). 0 for NULL.
int32_t granite_n_vocab(const struct granite_context * ctx);

// Vocabulary id of the CTC blank. -1 for NULL.
int32_t granite_blank_id(const struct granite_context * ctx);

// The last run's CTC logits before softmax, frame-major: granite_n_frames rows of granite_n_vocab floats.
// NULL when that run produced no frame (zero samples, a failure, or no run yet). Valid until the next
// transcribe or free.
const float * granite_logits(const struct granite_context * ctx);

// Raw GGUF piece of vocabulary id `id`: U+2581 marks a word start, <0xHH> a byte-fallback piece. Not
// NUL-terminated. Sets *length; returns NULL with *length = 0 when out of range.
const char * granite_vocab_piece(const struct granite_context * ctx, int32_t id, size_t * length);

// BPE merges from tokenizer.ggml.merges in rank order; 0 when the GGUF carries none.
int32_t granite_n_merges(const struct granite_context * ctx);

// Merge i as stored: the left piece, one ASCII space, the right piece. Not NUL-terminated. Sets *length;
// returns NULL with *length = 0 when out of range.
const char * granite_merge(const struct granite_context * ctx, int32_t i, size_t * length);

#ifdef __cplusplus
}
#endif

#endif  // GRANITE_H
