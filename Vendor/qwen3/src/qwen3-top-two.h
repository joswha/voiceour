// qwen3-top-two.h — Voiceour's exact greedy selection from an already computed row of F32 logits.
// Original to Voiceour; see Vendor/qwen3/NOTICE.md.
#ifndef QWEN3_TOP_TWO_H
#define QWEN3_TOP_TWO_H

#include "qwen3.h"

#include <limits>

#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace qwen3 {

// The row is nonempty. Strict comparisons in token-id order keep the lowest id on ties.
static inline qwen3_decision top_two(const float * logits, int32_t n_vocab) {
    qwen3_decision d = { 0, -1, logits[0], -std::numeric_limits<float>::infinity() };
    const auto consider = [&d, logits](int32_t id) {
        const float value = logits[id];
        if (value > d.logit) {
            d.runner_up       = d.token;
            d.runner_up_logit = d.logit;
            d.token           = id;
            d.logit           = value;
        } else if (d.runner_up < 0 || value > d.runner_up_logit) {
            d.runner_up       = id;
            d.runner_up_logit = value;
        }
    };

    if (n_vocab == 1) {
        return d;
    }
    consider(1);
    int32_t id = 2;
#if defined(__aarch64__) && defined(__ARM_NEON)
    constexpr int32_t block = 16;
    for (; id <= n_vocab - block; id += block) {
        const float * row = logits + id;
        const float32x4_t lo = vmaxq_f32(vld1q_f32(row), vld1q_f32(row + 4));
        const float32x4_t hi = vmaxq_f32(vld1q_f32(row + 8), vld1q_f32(row + 12));
        const float max = vmaxvq_f32(vmaxq_f32(lo, hi));
        // A block at or below the runner-up cannot change either choice. Use NaN-propagating max and
        // skip only on an ordered <=, so NaNs here or in the runner-up retain the scalar behavior.
        if (max <= d.runner_up_logit) {
            continue;
        }
        for (int32_t i = 0; i < block; ++i) {
            consider(id + i);
        }
    }
#endif
    for (; id < n_vocab; ++id) {
        consider(id);
    }
    return d;
}

}  // namespace qwen3

#endif  // QWEN3_TOP_TWO_H
