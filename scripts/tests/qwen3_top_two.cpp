// Standalone differential test for the bench-only CQwen3 selector (no model or ggml required).
#include "qwen3-top-two.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <random>
#include <vector>

static qwen3_decision stock(const float * l, int32_t n) {
    int32_t best = 0;
    int32_t second = -1;
    for (int32_t id = 1; id < n; ++id) {
        if (l[id] > l[best]) {
            second = best;
            best = id;
        } else if (second < 0 || l[id] > l[second]) {
            second = id;
        }
    }
    return { best, second, l[best], second >= 0 ? l[second] : -INFINITY };
}

static void check(const float * row, int32_t n) {
    const auto expected = stock(row, n);
    const auto actual = qwen3::top_two(row, n);
    if (expected.token != actual.token || expected.runner_up != actual.runner_up ||
        std::memcmp(&expected.logit, &actual.logit, sizeof(float)) != 0 ||
        std::memcmp(&expected.runner_up_logit, &actual.runner_up_logit, sizeof(float)) != 0) {
        std::fprintf(stderr, "n=%d: expected ids (%d, %d), got (%d, %d) or changed logit bits\n",
                     n, expected.token, expected.runner_up, actual.token, actual.runner_up);
        std::abort();
    }
}

static void small(std::initializer_list<float> row) {
    check(row.begin(), static_cast<int32_t>(row.size()));
}

int main() {
    const float qnan = std::numeric_limits<float>::quiet_NaN();
    const float snan = std::numeric_limits<float>::signaling_NaN();
    small({ -INFINITY });
    small({ 0.0f, -0.0f });
    small({ -0.0f, 0.0f });
    small({ qnan, 1.0f, 2.0f });
    small({ 0.0f, snan, 0.0f, 1.0f });
    small({ qnan, snan, INFINITY });

    // Exercise a vector's first/last lanes, a block edge and the scalar tail; repeat the maximum
    // at a later id to ensure no block supersedes an equal earlier candidate.
    for (int32_t n : { 16, 17, 18, 19, 33, 34, 35, 65 }) {
        std::vector<float> row(n, -INFINITY);
        check(row.data(), n);
        for (int32_t i = 0; i < n; ++i) {
            row[i] = INFINITY;
            row[n - 1] = INFINITY;
            check(row.data(), n);
            row[i] = 1.0f;
            check(row.data(), n);
            row[i] = qnan;
            check(row.data(), n);
            row[i] = snan;
            check(row.data(), n);
            row[i] = row[n - 1] = -INFINITY;
        }
    }

    // Low-cardinality random scores make ties common; this also exercises unaligned rows and all
    // tail lengths. Mix in arbitrary float bits to cover infinities, signed zeros and NaN payloads.
    std::mt19937 rng(291);
    std::vector<float> storage(151936 + 4);
    for (int32_t trial = 0; trial < 6000; ++trial) {
        const int32_t n = trial < 5900 ? 1 + trial % 513 : 151936 - (trial % 32);
        float * row = storage.data() + trial % 4;
        for (int32_t i = 0; i < n; ++i) {
            const uint32_t bits = rng();
            if ((trial % 2) == 0) {
                row[i] = static_cast<float>(bits % 31) - 15.0f;
            } else {
                std::memcpy(row + i, &bits, sizeof(float));
            }
        }
        check(row, n);
    }
    std::puts("exact top-two tests passed");
}