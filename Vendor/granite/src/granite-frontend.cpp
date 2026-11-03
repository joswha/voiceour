// granite-frontend.cpp — PCM -> log-mel -> deltas -> stacked encoder features (host, Accelerate).
//
// Adapted from transcribe.cpp (MIT, Copyright (c) 2026 The transcribe.cpp authors) at
// 5700f127e38dd53c4735ea23ef743b4b538eacd4: src/arch/granite5_ctc/encoder.cpp (frame budget,
// compute_encoder_input) and src/transcribe-mel.cpp (MelFrontend constructor and compute(): the
// power-of-two vDSP double FFT, cblas filterbank and per_utterance normalization paths only).
// See Vendor/granite/LICENSE and Vendor/granite/NOTICE.md.
#include "granite-impl.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <system_error>
#include <thread>

namespace granite {

bool frontend_init(const HParams & hp, const float * filterbank, const float * window, Frontend & fe) {
    const int n_freq = hp.n_fft / 2 + 1;

    // The baked F32 window, promoted to double and centred in a zero-filled n_fft buffer.
    fe.window.assign(static_cast<size_t>(hp.n_fft), 0.0);
    const int left_pad = (hp.n_fft - hp.win_length) / 2;
    for (int i = 0; i < hp.win_length; ++i) {
        fe.window[static_cast<size_t>(left_pad + i)] = static_cast<double>(window[i]);
    }
    fe.filterbank.assign(filterbank, filterbank + static_cast<size_t>(hp.num_mels) * static_cast<size_t>(n_freq));

    fe.log2n = 0;
    for (int tmp = hp.n_fft; tmp > 1; tmp >>= 1) {
        ++fe.log2n;
    }
    // Twiddle factors only: one setup is shared read-only by every frame worker.
    fe.fft_setup = vDSP_create_fftsetupD(static_cast<vDSP_Length>(fe.log2n), FFT_RADIX2);
    if (fe.fft_setup == nullptr) {
        log(GRANITE_LOG_ERROR, "vDSP_create_fftsetupD(%d) failed", fe.log2n);
        return false;
    }
    return true;
}

void frontend_free(Frontend & fe) {
    if (fe.fft_setup != nullptr) {
        vDSP_destroy_fftsetupD(fe.fft_setup);
        fe.fft_setup = nullptr;
    }
}

int64_t frames_after_subsampling(const HParams & hp, int64_t t_enc) {
    int64_t t = t_enc;
    for (size_t i = 0; i < hp.subsample_layers.size(); ++i) {
        t /= 2;
        if (t <= 0) {
            return 0;
        }
    }
    return t;
}

namespace {

// Sample count the STFT actually sees: the waveform is right-padded with zeros so the frame budget
// num_frames = stack * ceil(floor(n / hop) / stack) is covered (reference _extract_features).
int64_t stft_samples_for(const HParams & hp, int64_t n_samples, int64_t & num_frames) {
    const int64_t hop        = hp.hop_length;
    const int64_t stack      = hp.stack_factor;
    const int64_t mel_frames = n_samples / hop;
    num_frames               = stack * ((mel_frames + stack - 1) / stack);
    const int64_t need       = (num_frames - 1) * hop + 1;
    return std::max(n_samples, need);
}

}  // namespace

int64_t min_samples_for(const HParams & hp) {
    const int64_t pad   = hp.n_fft / 2;
    const int64_t limit = static_cast<int64_t>(hp.sample_rate) * 60;
    for (int64_t n = 1; n <= limit; ++n) {
        if (n / hp.hop_length <= 0) {
            continue;
        }
        int64_t       num_frames = 0;
        const int64_t n_stft     = stft_samples_for(hp, n, num_frames);
        const int64_t f_stft     = n_stft / hp.hop_length + 1;
        if (n_stft < pad + 1 || f_stft < 2 || num_frames > f_stft) {
            continue;
        }
        const int64_t t_enc = num_frames / hp.stack_factor;
        if (t_enc > 0 && frames_after_subsampling(hp, t_enc) > 0) {
            return n;
        }
    }
    return -1;
}

bool compute_features(const Frontend & fe, const HParams & hp, const float * pcm, int64_t n_samples, int n_threads,
                      std::vector<float> & feats, int & t_enc) {
    const int hop    = hp.hop_length;
    const int stack  = hp.stack_factor;
    const int n_fft  = hp.n_fft;
    const int n_freq = n_fft / 2 + 1;
    const int n_mels = hp.num_mels;
    const int pad    = n_fft / 2;

    if (n_samples / hop <= 0) {
        log(GRANITE_LOG_ERROR, "frontend: %lld samples yield no mel frame", static_cast<long long>(n_samples));
        return false;
    }
    int64_t       num_frames_64 = 0;
    const int64_t n_stft        = stft_samples_for(hp, n_samples, num_frames_64);
    const int64_t n_frames_64   = n_stft / hop + 1;
    if (n_stft < pad + 1 || n_frames_64 < 2 || num_frames_64 <= 0 || num_frames_64 > n_frames_64 ||
        n_frames_64 > std::numeric_limits<int>::max() / std::max(n_freq, n_mels)) {
        log(GRANITE_LOG_ERROR, "frontend: %lld samples cannot be framed", static_cast<long long>(n_samples));
        return false;
    }
    const int    n_frames = static_cast<int>(n_frames_64);
    const int    n_out    = static_cast<int>(num_frames_64);
    const size_t n        = static_cast<size_t>(n_stft);

    // Centred reflect padding in double. Samples past the original length are the waveform zero-pad.
    std::vector<double> padded(n + 2 * static_cast<size_t>(pad), 0.0);
    for (int64_t i = 0; i < n_samples; ++i) {
        padded[static_cast<size_t>(pad + i)] = static_cast<double>(pcm[i]);
    }
    for (int i = 0; i < pad; ++i) {
        padded[static_cast<size_t>(i)] = padded[static_cast<size_t>(2 * pad - i)];
    }
    for (int i = 0; i < pad; ++i) {
        padded[static_cast<size_t>(pad) + n + static_cast<size_t>(i)] =
            padded[static_cast<size_t>(pad) + n - 2 - static_cast<size_t>(i)];
    }

    // STFT power: vDSP real FFT in double. Its output is 2x the DFT, hence the 0.25 power factor.
    std::vector<float> power(static_cast<size_t>(n_frames) * static_cast<size_t>(n_freq));
    const int          workers = std::max(1, std::min(n_threads, n_frames));
    const size_t       half_n  = static_cast<size_t>(n_fft / 2);
    std::vector<double> scratch(2 * half_n * static_cast<size_t>(workers));
    auto worker = [&](int tid) {
        double *              re    = scratch.data() + 2 * half_n * static_cast<size_t>(tid);
        double *              im    = re + half_n;
        DSPDoubleSplitComplex split = { re, im };
        for (int t = tid; t < n_frames; t += workers) {
            const size_t start = static_cast<size_t>(t) * static_cast<size_t>(hop);
            for (size_t k = 0; k < half_n; ++k) {
                re[k] = padded[start + 2 * k] * fe.window[2 * k];
                im[k] = padded[start + 2 * k + 1] * fe.window[2 * k + 1];
            }
            vDSP_fft_zripD(fe.fft_setup, &split, 1, static_cast<vDSP_Length>(fe.log2n), FFT_FORWARD);
            float * row      = power.data() + static_cast<size_t>(t) * static_cast<size_t>(n_freq);
            row[0]           = static_cast<float>(re[0] * re[0] * 0.25);
            row[n_fft / 2]   = static_cast<float>(im[0] * im[0] * 0.25);
            for (size_t k = 1; k < half_n; ++k) {
                row[k] = static_cast<float>((re[k] * re[k] + im[k] * im[k]) * 0.25);
            }
        }
    };
    if (workers == 1) {
        worker(0);
    } else {
        std::vector<std::thread> threads;
        threads.reserve(static_cast<size_t>(workers - 1));
        int launched = 1;  // worker 0 is this thread
        try {
            for (int tid = 1; tid < workers; ++tid) {
                threads.emplace_back(worker, tid);
                launched = tid + 1;
            }
        } catch (const std::system_error &) {
            // A worker that cannot start leaves its frames to this thread: every worker owns a
            // disjoint scratch slice, so running it here is equivalent, and the joinable threads
            // already started must be joined rather than destroyed (std::terminate).
        }
        worker(0);
        for (int tid = launched; tid < workers; ++tid) {
            worker(tid);
        }
        for (std::thread & th : threads) {
            th.join();
        }
    }
    std::vector<double>().swap(padded);

    // mel[m, t] = filterbank[m, :] . power[t, :], then log10(max(x, 1e-10)).
    std::vector<float> log_mel(static_cast<size_t>(n_mels) * static_cast<size_t>(n_frames));
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, n_mels, n_frames, n_freq, 1.0f, fe.filterbank.data(), n_freq,
                power.data(), n_freq, 0.0f, log_mel.data(), n_frames);
    for (float & v : log_mel) {
        double x = static_cast<double>(v);
        if (x < 1.0e-10) {
            x = 1.0e-10;
        }
        v = static_cast<float>(std::log10(x));
    }

    // per_utterance over exactly the emitted frames: floor at (max - 8), then (x + 4) / 4.
    double global_max = -std::numeric_limits<double>::infinity();
    for (int m = 0; m < n_mels; ++m) {
        const float * src = log_mel.data() + static_cast<size_t>(m) * static_cast<size_t>(n_frames);
        for (int t = 0; t < n_out; ++t) {
            global_max = std::max(global_max, static_cast<double>(src[t]));
        }
    }
    const double       floor_val = global_max - 8.0;
    std::vector<float> mel(static_cast<size_t>(n_mels) * static_cast<size_t>(n_out));
    for (int m = 0; m < n_mels; ++m) {
        const float * src = log_mel.data() + static_cast<size_t>(m) * static_cast<size_t>(n_frames);
        float *       dst = mel.data() + static_cast<size_t>(m) * static_cast<size_t>(n_out);
        for (int t = 0; t < n_out; ++t) {
            double v = static_cast<double>(src[t]);
            if (v < floor_val) {
                v = floor_val;
            }
            dst[t] = static_cast<float>((v + 4.0) / 4.0);
        }
    }

    // First-order deltas (torchaudio compute_deltas, win_length 3, replicate edges).
    const int          T       = n_out;
    const int          n_delta = hp.deltas ? n_mels : 0;
    std::vector<float> deltas(static_cast<size_t>(n_delta) * static_cast<size_t>(T));
    for (int m = 0; m < n_delta; ++m) {
        const float * src = mel.data() + static_cast<size_t>(m) * static_cast<size_t>(T);
        float *       dst = deltas.data() + static_cast<size_t>(m) * static_cast<size_t>(T);
        for (int t = 0; t < T; ++t) {
            const float next = src[(t + 1 < T) ? (t + 1) : (T - 1)];
            const float prev = src[(t > 0) ? (t - 1) : 0];
            dst[t]           = 0.5f * (next - prev);
        }
    }

    // Channel concat then time stack: row t = [mel(2t) | delta(2t) | mel(2t+1) | delta(2t+1)].
    const int mel_ch    = n_mels + n_delta;
    const int input_dim = mel_ch * stack;
    t_enc               = T / stack;
    if (t_enc <= 0) {
        log(GRANITE_LOG_ERROR, "frontend: no stacked frame");
        return false;
    }
    feats.assign(static_cast<size_t>(t_enc) * static_cast<size_t>(input_dim), 0.0f);
    for (int t = 0; t < t_enc; ++t) {
        float * row = feats.data() + static_cast<size_t>(t) * static_cast<size_t>(input_dim);
        for (int s = 0; s < stack; ++s) {
            const int frame = t * stack + s;
            float *   dst   = row + static_cast<size_t>(s) * static_cast<size_t>(mel_ch);
            for (int m = 0; m < n_mels; ++m) {
                dst[m] = mel[static_cast<size_t>(m) * static_cast<size_t>(T) + static_cast<size_t>(frame)];
            }
            for (int m = 0; m < n_delta; ++m) {
                dst[n_mels + m] = deltas[static_cast<size_t>(m) * static_cast<size_t>(T) + static_cast<size_t>(frame)];
            }
        }
    }
    return true;
}

}  // namespace granite
