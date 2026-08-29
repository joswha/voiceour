import CoreGraphics

/// Every constant the mercury body is made of, in one place.
///
/// The recording island is one procedural liquid-metal organism: a scalar field the
/// rasterizer, the drag predicate and the cursor region all read. Nothing about it is
/// authored art, so every number here is either a physical constant expressed in the
/// island's own points, a measured envelope, or a tuned time constant — never a
/// highlight position, a gradient stop, or a silhouette.
///
/// Units are the island's own points at 72 pt/inch and seconds.
enum MercuryMetrics {
    // MARK: Envelope

    /// The longest the body may ever draw, inside the 180 pt island. The 6 pt each side
    /// is the margin the island's own rounded ends used to occupy.
    static let maxLength: CGFloat = 168
    /// Half the island's height. `MercurySimulation` proves the drawn body stays inside
    /// this through an exact containment gauge rather than a per-frame clamp.
    static let maxHalfHeight: CGFloat = 17
    /// Stations the edges are sampled at. The field reads `columns + 1` samples with
    /// linear interpolation, so this is the only geometry representation that exists.
    static let columns = 96
    /// Mode count per family. Eight is where `m^-1.5` autonomous variance has fallen to
    /// 4 % of the fundamental and the crest spacing at the speaking pose is 20 pt.
    static let modeCount = 8

    /// How far outside the body the rasterized rect reaches, so the coverage ramp is
    /// never cut. Always intersected with the island rect: the envelope is absolute.
    static let bleed: CGFloat = 1.5

    /// Extra reach around the silhouette for the drag predicate, in points. Small on
    /// purpose — the whole contract is that a click outside the visible body falls
    /// through to the app underneath.
    static let dragSlop: CGFloat = 3

    // MARK: Shape law

    /// The mean envelope's value at both ends: `G(a) = 1 - (1 - gEnd) * (2a - 1)^2`.
    /// Its second derivative is a non-zero constant everywhere, so no straight flank
    /// and no stadium is reachable by any amplitude.
    static let gEnd: Double = 0.46
    /// Group lag between the two edges for the varicose family, a linear phase in `m`.
    /// Without it the thickness mode arrives at both edges at once and the body reads
    /// as a breathing pill.
    static let snakeLag: Double = 0.11
    /// Global slow-down applied to every mode frequency. Real capillary-gravity waves
    /// on a 27 pt-deep pool are far too fast to read at this size.
    static let tempo: Double = 0.32

    // MARK: Fluid constants, in points per second

    /// 9.81 m/s² at 72 pt/inch.
    static let gravity: Double = 27798
    /// Mercury's surface tension over its density, at 72 pt/inch.
    static let surfaceTensionOverDensity: Double = 818_700
    /// `sqrt((sigma/rho) / g)`. The wavelength where capillarity takes over from
    /// gravity, and the scale the contact-line damping law is written against.
    static let capillaryLength: Double = 5.4262

    /// Contact-line drag at zero wavenumber. `zeta_m = zeta0 / (1 + (k_m * l_c)^2)`:
    /// the drag dies once the line is pinned, so long waves are damped and the visible
    /// band is free. A flat or `sqrt(m)` law deletes the lobes.
    static let zeta0: Double = 0.42

    /// Stationary rms of one autonomous mode component, in points of edge displacement
    /// at the fundamental. Also the rms of the body's own static rest asymmetry, which
    /// is what keeps a motionless body off the mirror-symmetric capsule.
    ///
    /// Raised from 0.42: at that value a body with no voice on it barely moved, and the
    /// island spends most of its life listening rather than hearing speech.
    static let restRMS: Double = 0.62

    /// The meter's own buffer duration: 11 samples at 25 Hz. Advecting the voice
    /// forcing at exactly this period makes the phase rotation between two model ticks
    /// equal the one-sample shift the next tick performs, so the crest train travels
    /// continuously instead of stepping.
    static let bufferPeriod: Double = 0.44

    /// Single pole the length and half-height follow their target pose through.
    static let poseTau: Double = 0.26

    // MARK: Integration

    /// Fixed simulation substep. Every oscillator uses the exact closed-form propagator
    /// for this step, so there is no Euler integration anywhere.
    static let substep: Double = 1.0 / 120.0
    /// A stalled frame must not fast-forward the body.
    static let maxSubstepsPerFrame = 4
    /// Presentation is deliberately 30 Hz. Physics remains 120 Hz; a cached `CGImage`
    /// is returned on the intervening Timeline ticks. Measured 60 Hz raster cost was
    /// 9.5% of one M-series core; 30 Hz is 4.8% and visually smooth at this scale.
    static let presentationInterval: Double = 1.0 / 30.0

    /// One-shot velocity impulses, in inverse seconds, applied exactly once when an
    /// outcome gesture latches. Both are inside the containment gauge.
    ///
    /// `lurch` kicks the contact-line fundamental: one lateral lean and rebound.
    /// `collapse` kicks the varicose fundamental: a damped vertical tremor.
    static let lurchImpulse: Double = 1.1
    static let collapseImpulse: Double = 1.0

    // MARK: Environment

    /// Equirectangular radiance tables, one per roughness level.
    ///
    /// The parameterization is deliberately *x-polar*: `v` is the angle from the body's
    /// own long axis and `u` wraps around it. An ordinary z-polar table puts its pole
    /// exactly where a near-flat crest's reflected direction lives, and that pole prints
    /// a pinwheel crease through the broadest, calmest part of the body.
    static let environmentWidth = 96
    static let environmentHeight = 48
    /// Roughness the three tables are prefiltered at, ascending.
    static let environmentRoughness: [Float] = [0.03, 0.09, 0.25]
    /// Substeps between table rebuilds: 20 Hz.
    static let environmentRebuildInterval = 6
    /// The table's own band limit, as a roughness. A texel subtends 2*pi/96 radians;
    /// a box filter that wide has standard deviation `w / sqrt(12)`, and a spherical
    /// Gaussian of that width is `alpha = 1 / sqrt(lambda)`. Every bake adds this in
    /// quadrature, so no lobe is ever sharper than the grid can carry.
    static let environmentGridRoughness: Double = 0.019

    // MARK: Room of Ten

    /// Enough stratified area sources that every random room intersects the reflected
    /// manifold, without washing the material into a softbox. Selected by the isolated
    /// sweep and verified over 4,096 seeds.
    static let roomLobeCount = 32
    /// Spherical-Gaussian sharpnesses: roughly 3–18 degree sources, from hard lamps to
    /// ceiling panels. The draw remains log-uniform.
    static let roomLambdaMin: Double = 20
    static let roomLambdaMax: Double = 600
    /// Bounded log-intensity range. Every source lies in `[exp(-range), exp(+range)]`;
    /// there is no unbounded lognormal tail and no time-varying intensity.
    static let roomLogIntensityRange: Double = 0.55
    /// Neutral diffuse room bounce. Thirty percent is the lowest value that left zero
    /// crushed-black failures in the 4,096-seed material corpus while preserving real
    /// black-card bands.
    static let roomBounceFraction: Double = 0.30
    /// Maximum luminance-free source tint. Seven percent is visible in reflections but
    /// remains below the benchmark's 12% local-saturation and 6% whole-body-cast bounds.
    static let roomChromaStrength: Double = 0.07

    // MARK: Spectral Weather

    static let weatherMaxDegree = 12
    static let weatherKappaSquared: Double = 30
    static let weatherSlope: Double = 3.8
    /// Pointwise standard deviation of the log-radiance field, in nats.
    static let weatherSigma: Double = 1.45

    // MARK: Shading

    /// Fixed raster scale, not `displayScale`.
    ///
    /// Two reasons, both load-bearing. A committed golden must not encode whether the
    /// rendering Mac has a Retina display, and a 2x raster supersampled down to a 1x
    /// display is strictly better than a 1x raster. The whole body is 24,480 device
    /// pixels either way.
    static let rasterScale: CGFloat = 2

    /// Finite eye distance in points, so the highlight sweeps along the body as the
    /// body moves instead of sitting at a fixed station.
    static let eyeDistance: Double = 1400

    /// Atomic mercury is effectively smooth at this scale. The generated room tables
    /// carry the fixed pixel-footprint band limit; no second material-roughness model is
    /// mixed into the exact smooth-conductor Fresnel path.
    static let baseRoughness: Double = 0.03

    /// Liquid mercury's optical constants at sRGB primaries.
    static let mercuryN = (r: 1.85901, g: 1.55229, b: 1.11003)
    static let mercuryK = (r: 5.0793, g: 4.65101, b: 3.94276)

    /// Fixed vertical aspect of the half-elliptic crown. Independent capillarity and
    /// reflected-coverage derivations both land inside 0.75...0.80; the 4,096-seed
    /// material benchmark uses 0.78.
    static let crownAspect: Double = 0.78
    /// Smooth-positive field regularization, as a fraction of one device pixel. Coverage
    /// remains the original field; this only keeps the crown's analytic limb finite.
    static let crownFilterFraction: Double = 0.25

    /// Increase Contrast re-solves the same scene anchors instead of clipping the mapped
    /// result. The response remains strictly below the same ceiling.
    static let increasedContrastMedian: Double = 0.30
    static let increasedContrastHighlight: Double = 0.90

    // MARK: Calibration targets

    /// Median peak-to-trough excursion of the top edge about its own mean envelope, at
    /// the speaking pose, in points. `MercuryCalibration` solves `driveGain` for it.
    ///
    /// 2.6 pt was the first value and it was too quiet: on a 23 pt body that is a 10 %
    /// ripple, which reads as a lozenge that shimmers rather than a liquid that moves.
    static let targetCrestProminence: Double = 5.0
    /// Largest acceptable Pearson correlation between the top edge and the negated
    /// bottom edge, after the shared even envelope is removed, at the listening pose.
    /// A pill is exactly +1.0. `MercuryCalibration` solves `snakeGain` for it.
    static let targetMirrorCorrelation: Double = 0.2
    /// In-body luminance anchors for the bounded response, pooled over listening and
    /// speaking. Two anchors solve its two parameters exactly.
    static let targetDisplayLuminance: Double = 0.32
    static let targetHighlightLuminance: Double = 0.87
    /// Strict linear-light ceiling. Finite radiance approaches but never reaches it.
    static let displayCeiling: Double = 0.94

    // MARK: Seeds

    /// The world a body gets when nothing installed one: "QUICKSLV" as eight bytes.
    /// `RecordingOverlayController` installs a fresh random seed for every session, and
    /// the harness pins this exact value.
    static let defaultSeed: UInt64 = 0x5155_4943_4B53_4C56
}
