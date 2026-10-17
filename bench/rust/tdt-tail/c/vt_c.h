// C11 control for bet B1 (see vt_c.c). Internal to libtdt_tail: the Rust crate owns the weights
// (loaded from the model file) and passes pointers; nothing here is exported from the cdylib.
#ifndef VT_C_H
#define VT_C_H

#include <stddef.h>
#include <stdint.h>

#define VTC_MAX_LAYERS 4

typedef struct {
    size_t p;           // prediction / joint width (640)
    size_t s;           // encoder state width (1024)
    size_t n_tok;       // token slots incl. blank (8193)
    size_t blank;       // blank id (8192)
    size_t n_out;       // joint outputs (8198)
    size_t n_layers;    // LSTM layers (2)
    size_t max_symbols; // n_max_tokens (10)
    const int32_t *durations; // n_out - n_tok values
    const uint16_t *embed;    // fp16 [n_tok][p]
    const uint16_t *w_ih[VTC_MAX_LAYERS], *w_hh[VTC_MAX_LAYERS]; // fp16 [4p][p]
    const float *b_h[VTC_MAX_LAYERS];                             // [4p]
    const uint16_t *pred_w; const float *pred_b;                  // [p][p], [p]
    const uint16_t *enc_w; const float *enc_b;                    // [p][s], [p]
    const uint16_t *net_w; const float *net_b;                    // [n_out][p], [n_out]
} vtc_model;

typedef struct { int32_t id, frame_index, duration_idx, duration; float p, plog; } vtc_token;

typedef struct { size_t n_frames, n_tokens, n_steps, n_pred, n_cols; } vtc_work;

typedef struct vtc_engine vtc_engine;

// threads >= 1 participants (caller included); spec_k / spec_k_token frames per joint pass after a
// blank / after a prediction (1 = no speculation); spin_us worker spin before parking.
vtc_engine *vtc_engine_new(const vtc_model *m, size_t threads, size_t spec_k, size_t spec_k_token, uint64_t spin_us);

// Greedy TDT decode of enc [n_frames][s]. On success returns the token count and points *tokens
// at the engine-owned token array (valid until the next call); -1 on allocation failure.
int32_t vtc_decode(vtc_engine *e, const float *enc, size_t n_frames, const vtc_token **tokens, vtc_work *work);

void vtc_engine_free(vtc_engine *e);

#endif
