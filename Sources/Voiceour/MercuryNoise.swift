import Foundation

/// Counter-based deterministic randomness.
///
/// No generator state, so any `(seed, stream, counter)` triple is replayable: two
/// simulations advanced the same number of substeps produce bit-identical geometry
/// regardless of how the advance was batched, and a pinned harness frame is stable
/// across processes and machines. Nothing here reads a clock, a system generator, or
/// `Foundation`'s randomness.
///
/// The mixer is the standard SplitMix64 finalizer, which passes BigCrush and needs no
/// warm-up — the whole point of a counter-based design is that the nth draw costs the
/// same as the first.
struct MercuryNoise {
    let seed: UInt64

    /// Uniform on `[0, 1)`, from the top 53 bits — the exact width of a `Double`'s
    /// significand, so every representable value in the range is reachable once.
    @inline(__always)
    func uniform(stream: UInt32, counter: UInt64) -> Double {
        Double(bits(stream: stream, counter: counter) >> 11) * 0x1p-53
    }

    /// Two independent standard normals, Box-Muller over two consecutive counters.
    ///
    /// Both are returned because the transform produces them together and discarding
    /// one would double the cost of the simulation's per-substep noise, which draws two
    /// components for every mode of every family.
    @inline(__always)
    func gaussianPair(stream: UInt32, counter: UInt64) -> SIMD2<Double> {
        let first = uniform(stream: stream, counter: counter &* 2)
        let second = uniform(stream: stream, counter: counter &* 2 &+ 1)
        // `uniform` is half-open at 1, so `1 - first` is half-open at 0: the log is finite.
        let radius = (-2 * Foundation.log(1 - first)).squareRoot()
        let angle = 2 * Double.pi * second
        return SIMD2(radius * Foundation.cos(angle), radius * Foundation.sin(angle))
    }

    /// Uniform on the sphere: `z` uniform on `[-1, 1)` and the azimuth uniform, which is
    /// the only pair that is area-preserving. Sampling two angles uniformly instead
    /// would pile draws at the poles.
    @inline(__always)
    func unitVector(stream: UInt32, counter: UInt64) -> SIMD3<Double> {
        let height = 2 * uniform(stream: stream, counter: counter &* 2) - 1
        let angle = 2 * Double.pi * uniform(stream: stream, counter: counter &* 2 &+ 1)
        let radius = Swift.max(0, 1 - height * height).squareRoot()
        return SIMD3(radius * Foundation.cos(angle), radius * Foundation.sin(angle), height)
    }

    @inline(__always)
    private func bits(stream: UInt32, counter: UInt64) -> UInt64 {
        var state = seed ^ (UInt64(stream) &<< 40) ^ counter
        state = (state ^ (state >> 30)) &* 0xbf58_476d_1ce4_e5b9
        state = (state ^ (state >> 27)) &* 0x94d0_49bb_1331_11eb
        return state ^ (state >> 31)
    }
}

/// Stream identifiers, so two consumers can never collide on one `(seed, counter)`.
///
/// counter on `(family, mode, substep)` inside one stream, and generated rooms key
/// independent static draws inside theirs.
enum MercuryNoiseStream {
    /// Per-substep velocity increments for the varicose family.
    static let varicoseForcing: UInt32 = 1
    /// Per-substep velocity increments for the contact-line family.
    static let snakeForcing: UInt32 = 2
    /// The body's own static rest asymmetry, drawn once per seed.
    static let restShape: UInt32 = 3
    /// Room source draws: sharpness, equal-area band and azimuth.
    static let roomLobes: UInt32 = 4
    /// Spectral Weather's static coefficient draw.
    static let weatherCoefficients: UInt32 = 6
    /// Room source intensity draws. A stream of its own because `gaussianPair` consumes
    /// two uniform counters per call, so sharing streams aliases unrelated variables.
    static let roomIntensity: UInt32 = 7
    /// Low-saturation opponent axis and balanced source coefficients in the generated room.
    static let roomChroma: UInt32 = 8
}
