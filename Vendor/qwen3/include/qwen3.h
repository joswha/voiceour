// qwen3.h — Voiceour's native Qwen3 decoder for the bench-only polish runner: greedy generation with
// optional n-gram self-drafting, or greedy generation restricted to a finite set of candidate completions, one
// request per call.
//
// Adapted from llama.cpp (MIT) b12606 at e412c6f468b7b9e0f16f2540244236f8ad68e9ae, built against the ggml
// vendored in Vendor/ggml (0.19.0). See Vendor/qwen3/NOTICE.md. Nothing in the app or the sidecar links it.
#ifndef QWEN3_H
#define QWEN3_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct qwen3_context;

enum qwen3_status {
    QWEN3_OK = 0,
    // Null context, an empty prompt, a token id outside the vocabulary, a prompt plus max_new_tokens that
    // does not fit the context, out-of-range generation parameters, or a guided candidate set that breaks
    // qwen3_generate_guided's rules.
    QWEN3_ERR_INVALID_ARGUMENT = 1,
    // The abort callback returned true before a graph evaluation.
    QWEN3_ERR_CANCELLED = 2,
    // Graph construction, allocation or compute failed.
    QWEN3_ERR_BACKEND = 3,
};

enum qwen3_log_level {
    QWEN3_LOG_DEBUG = 1,
    QWEN3_LOG_INFO = 2,
    QWEN3_LOG_WARN = 3,
    QWEN3_LOG_ERROR = 4,
};

typedef void (*qwen3_log_callback)(enum qwen3_log_level level, const char * text, void * user_data);

// Process-wide sink for native diagnostics. NULL restores the default (stderr). Never stdout.
void qwen3_log_set(qwen3_log_callback callback, void * user_data);

struct qwen3_context_params {
    bool use_gpu;       // prefer the Metal device; CPU-only when false or when no GPU device exists
    int32_t n_threads;  // CPU threads for CPU-resident graph work (>= 1)
    bool map_weights;   // map the GGUF read-only into backend buffers when the device accepts host pointers
    int32_t n_ctx;      // KV cache positions, F16 K and V (>= 1)
};

// use_gpu = true, n_threads = 4, map_weights = true, n_ctx = 2048.
struct qwen3_context_params qwen3_context_default_params(void);

// Loads and validates a qwen3 GGUF (llama.cpp tensor and key conventions, gpt2/qwen2 tokenizer). Returns NULL
// on failure; the reason is logged.
struct qwen3_context * qwen3_init_from_file(const char * path, struct qwen3_context_params params);

// Frees everything the context owns, in dependency order. NULL is a no-op.
void qwen3_free(struct qwen3_context * ctx);

// Token types: tokenizer.ggml.token_type, with llama.cpp's end-of-generation texts (e.g. "</s>") stored as
// NORMAL raised to CONTROL.
enum qwen3_token_type {
    QWEN3_TOKEN_NORMAL = 1,
    QWEN3_TOKEN_UNKNOWN = 2,
    QWEN3_TOKEN_CONTROL = 3,
    QWEN3_TOKEN_USER_DEFINED = 4,
    QWEN3_TOKEN_UNUSED = 5,
    QWEN3_TOKEN_BYTE = 6,
};

// Vocabulary size: the tokenizer's entries, equal to the output head's rows. 0 for NULL.
int32_t qwen3_n_vocab(const struct qwen3_context * ctx);

// Raw GGUF piece of vocabulary id `id` (GPT-2 byte-mapped). Not NUL-terminated. Sets *length; returns NULL with
// *length = 0 when out of range.
const char * qwen3_vocab_piece(const struct qwen3_context * ctx, int32_t id, size_t * length);

// Type of vocabulary id `id`; 0 when out of range.
int32_t qwen3_vocab_type(const struct qwen3_context * ctx, int32_t id);

// BPE merges from tokenizer.ggml.merges in rank order.
int32_t qwen3_n_merges(const struct qwen3_context * ctx);

// Merge i as stored: the left piece, one ASCII space, the right piece. Not NUL-terminated. Sets *length;
// returns NULL with *length = 0 when out of range.
const char * qwen3_merge(const struct qwen3_context * ctx, int32_t i, size_t * length);

// tokenizer.ggml.eos_token_id: generation stops when it is the greedy choice. -1 for NULL.
int32_t qwen3_eos_token_id(const struct qwen3_context * ctx);

// KV cache positions the context was created with. 0 for NULL.
int32_t qwen3_n_ctx(const struct qwen3_context * ctx);

// ggml type name of the layer matrices (e.g. "q8_0"), and the backend that holds the weights and runs the
// graph (e.g. "MTL0"). Static strings; "" for NULL.
const char * qwen3_weight_type(const struct qwen3_context * ctx);
const char * qwen3_backend_name(const struct qwen3_context * ctx);

struct qwen3_generate_params {
    int32_t max_new_tokens;  // >= 1; generation stops after this many output tokens
    int32_t ngram_n;         // n-gram drafting: the last ngram_n tokens are looked up; 0 disables drafting
    int32_t ngram_m;         // n-gram drafting: up to ngram_m following tokens are drafted (>= 1 when drafting)
};

// max_new_tokens = 512, ngram_n = 2, ngram_m = 8.
struct qwen3_generate_params qwen3_generate_default_params(void);

// Polled before every graph evaluation: the prompt's evaluations, then each decode step. Never polled inside a
// Metal command buffer. Returning true ends the call with QWEN3_ERR_CANCELLED.
typedef bool (*qwen3_abort_callback)(void * user_data);

// Greedy generation for one prompt, which is fed as given (no BOS, no template). The prompt is evaluated from
// position 0 in batches of at most 512 tokens; then the argmax token is appended and fed back until it is the
// EOS token (not appended) or max_new_tokens tokens are out. With drafting, each step looks the last ngram_n
// tokens (prompt and output) up in the earlier history, drafts up to ngram_m tokens that followed the latest
// earlier occurrence, verifies the fed token and every draft in one graph evaluation, keeps the longest draft
// prefix that equals the argmax at each position, and rolls the KV cache back past the rest; the output equals
// the undrafted output up to numerical differences between batch sizes.
// Requires n_prompt >= 1 and n_prompt + max_new_tokens <= n_ctx: a fully accepted draft writes the cell after the
// last output token's. Results (outputs, decisions, timings) replace the previous call's, including on failure,
// which leaves zero outputs and decisions.
enum qwen3_status qwen3_generate(struct qwen3_context * ctx,
                                 const int32_t * prompt,
                                 int32_t n_prompt,
                                 struct qwen3_generate_params params,
                                 qwen3_abort_callback abort_callback,
                                 void * abort_user_data);

// Output tokens of the last call, EOS excluded: the greedy output, or the chosen candidate's tokens after
// qwen3_generate_guided. Valid until the next generate or free; NULL when empty.
int32_t qwen3_n_output(const struct qwen3_context * ctx);
const int32_t * qwen3_output(const struct qwen3_context * ctx);

// One greedy choice: decision i picked output token i, or the EOS when i == qwen3_n_output. `runner_up` is the
// highest-scoring other token, so logit - runner_up_logit is the margin the choice was made by.
struct qwen3_decision {
    int32_t token;
    int32_t runner_up;
    float logit;
    float runner_up_logit;
};

// Decisions of the last qwen3_generate call: qwen3_n_output, plus one when it stopped at the EOS token. 0 after
// qwen3_generate_guided, which records steps instead.
int32_t qwen3_n_decisions(const struct qwen3_context * ctx);

// i in [0, qwen3_n_decisions). Returns a zeroed decision (token -1) when out of range.
struct qwen3_decision qwen3_get_decision(const struct qwen3_context * ctx, int32_t i);

struct qwen3_timings {
    double prefill_ms;   // prompt evaluation through the first argmax
    double decode_ms;    // the decode loop after it
    int32_t n_prompt;    // prompt tokens
    int32_t n_output;    // output tokens
    int32_t n_evals;     // decode-loop graph evaluations
    int32_t n_drafted;   // drafted tokens fed for verification (0 after qwen3_generate_guided)
    int32_t n_accepted;  // drafted tokens kept (0 after qwen3_generate_guided)
};

// Timings of the last call; zeroed for NULL or before any call.
struct qwen3_timings qwen3_get_timings(const struct qwen3_context * ctx);

// ---------------------------------------------------------------------------------------------------------
// Guided generation: greedy decoding restricted to a finite set of candidate completions.

struct qwen3_guided_params {
    int32_t max_new_tokens;  // >= 1 and >= every candidate's length: guided generation never truncates
    bool    batch_forced;    // feed each run of tokens that are their trie node's only option in one evaluation
};

// max_new_tokens = 512, batch_forced = true.
struct qwen3_guided_params qwen3_guided_default_params(void);

// Greedy generation for one prompt, fed as qwen3_generate feeds it, over the token trie of n_candidates
// completions built for this call. Candidate i is candidate_lengths[i] token ids, stored back to back in
// candidate_tokens. Every candidate needs 1..max_new_tokens tokens, each a NORMAL vocabulary token (never the
// EOS, a control, user-defined, unknown, unused or byte token), and no two candidates may be equal. Validity is
// token-level only: the call knows nothing about whether a candidate is a good output.
//
// At every trie node the allowed options are the node's child tokens plus the EOS when a candidate ends there.
// The choice is the allowed option with the highest logit, the lowest id among equal logits, so the output is
// always one whole candidate followed by the EOS: never truncated, never a prefix, never anything else. No
// n-gram draft is fed. With batch_forced, a token that is its node's only option is appended without reading
// logits and fed in one evaluation with the tokens before it (prompt-sized ubatches), and a candidate end where
// nothing but the EOS is allowed ends the call without another evaluation; batches of different sizes can differ
// numerically, as drafting can. Without it, every output token and the EOS are chosen from the logits of the
// evaluation that fed the token before them, one token per evaluation, as qwen3_generate without drafting.
//
// Requires n_prompt >= 1 and n_prompt + max_new_tokens <= n_ctx. Results replace the previous call's, including
// on failure, which leaves no outputs, steps or candidate. After success the outputs are the chosen candidate's
// tokens, qwen3_guided_candidate is its index, there is one step per choice read from logits, and the timings
// count prefill, decode and decode-loop evaluations.
enum qwen3_status qwen3_generate_guided(struct qwen3_context * ctx,
                                        const int32_t * prompt,
                                        int32_t n_prompt,
                                        const int32_t * candidate_tokens,
                                        const int32_t * candidate_lengths,
                                        int32_t n_candidates,
                                        struct qwen3_guided_params params,
                                        qwen3_abort_callback abort_callback,
                                        void * abort_user_data);

// Index of the candidate the last call produced: -1 after qwen3_generate, a failure or for NULL.
int32_t qwen3_guided_candidate(const struct qwen3_context * ctx);

// One guided choice read from logits. Output positions without a step were their node's only option and were
// appended under batch_forced; so was the EOS when no step has position == qwen3_n_output.
struct qwen3_guided_step {
    int32_t position;             // output index the step chose; qwen3_n_output for the EOS
    int32_t n_options;            // allowed options at the step's node, the EOS included where a candidate ends
    int32_t token;                // the chosen option
    int32_t runner_up;            // the best other allowed option; -1 when n_options == 1
    int32_t unconstrained_token;  // the argmax over the whole vocabulary, qwen3_generate's choice from these logits
    float   logit;
    float   runner_up_logit;      // -INFINITY when runner_up == -1
    float   unconstrained_logit;
};

// Steps of the last call; 0 after qwen3_generate.
int32_t qwen3_n_guided_steps(const struct qwen3_context * ctx);

// i in [0, qwen3_n_guided_steps). Returns a zeroed step (tokens -1) when out of range.
struct qwen3_guided_step qwen3_get_guided_step(const struct qwen3_context * ctx, int32_t i);

#ifdef __cplusplus
}
#endif

#endif  // QWEN3_H
