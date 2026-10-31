import Foundation
import Synchronization
import VoiceCore

/// What the island is made of: a metal, an optional coat, and that coat's film thickness or
/// dye colour. Every colour it produces is the metal's own reflectance, a film's
/// interference or a lacquer's absorption; nothing is painted on.
struct MercuryPaint: Hashable, Sendable {
    var metal: IslandMetal
    var coat: IslandCoat
    /// Film thickness for pearl, anodized, oil slick and chameleon.
    var filmNanometers: Int
    /// Candy dye: linear-light round-trip transmittance per channel at normal incidence;
    /// (1, 1, 1) unless the coat is candy.
    var candy: SIMD3<Double>

    /// Liquid mercury, uncoated: the shipped material.
    static let stock = MercuryPaint(
        metal: .mercury,
        coat: .none,
        filmNanometers: 0,
        candy: SIMD3(repeating: 1)
    )

    /// The same paint with every field its coat ignores at its stock value, so equivalent
    /// paints share one table and uncoated mercury is exactly stock.
    var canonical: MercuryPaint {
        var paint = self
        switch coat {
        case .none, .clear:
            paint.filmNanometers = Self.stock.filmNanometers
            paint.candy = Self.stock.candy
        case .candy:
            paint.filmNanometers = Self.stock.filmNanometers
        case .pearl, .anodized, .oilSlick, .chameleon:
            paint.candy = Self.stock.candy
        }
        return paint
    }
}

extension MercuryPaint {
    /// The exact reflectance a paint's table samples, prepared once per paint and then
    /// evaluated per cosine. Dense tests bound every table against it.
    ///
    /// Stock is `MercuryOptics.exactFresnel`, the spectral mercury oracle the shipped table
    /// samples, so the stock look stays byte-identical. Every other paint integrates through
    /// the same observer, `MercurySpectral`'s, and ends in the gamut floor rather than
    /// stock's clamp at zero (`MercurySpectra.gamutFloor` says why; for mercury neither
    /// binds). Uncoated mercury of any other kind cannot exist, because `canonical` makes it
    /// stock; under a coat, mercury is the stock oracle's own `n + ik`. Coats:
    /// - none: the bare metal;
    /// - clear and candy: `MercuryLacquer`, clear with `T₀ = 1`;
    /// - pearl and anodized: a titania film;
    /// - oil slick: a silica film, whose low index gives the strongest angle shift;
    /// - chameleon: air | chromium | silica | metal, an absorber–spacer–mirror Fabry–Pérot
    ///   cavity, the only coat that colours silver and aluminum.
    struct Oracle {
        /// Chameleon absorber: a semi-transparent chromium mirror, as in the stacks of
        /// optically variable pigments.
        static let chameleonAbsorberNanometers: Double = 8

        private enum Model {
            case stock
            case stack(MercuryOpticalStack)
            case lacquer(MercuryLacquer)
        }

        private let model: Model

        init(_ paint: MercuryPaint) {
            let paint = paint.canonical
            let metal = MercurySpectra.Material.metal(paint.metal)
            let film = Double(Swift.max(0, paint.filmNanometers))
            switch paint.coat {
            case .none:
                model =
                    paint == .stock
                    ? .stock
                    : .stack(MercuryOpticalStack(films: [], substrate: metal))
            case .clear:
                model = .lacquer(
                    MercuryLacquer(metal: paint.metal, transmittance: SIMD3(repeating: 1))
                )
            case .candy:
                model = .lacquer(MercuryLacquer(metal: paint.metal, transmittance: paint.candy))
            case .pearl, .anodized:
                model = .stack(
                    MercuryOpticalStack(
                        films: [MercurySpectra.Layer(material: .titania, nanometers: film)],
                        substrate: metal
                    )
                )
            case .oilSlick:
                model = .stack(
                    MercuryOpticalStack(
                        films: [MercurySpectra.Layer(material: .silica, nanometers: film)],
                        substrate: metal
                    )
                )
            case .chameleon:
                model = .stack(
                    MercuryOpticalStack(
                        films: [
                            MercurySpectra.Layer(
                                material: .metal(.chromium),
                                nanometers: Self.chameleonAbsorberNanometers
                            ),
                            MercurySpectra.Layer(material: .silica, nanometers: film),
                        ],
                        substrate: metal
                    )
                )
            }
        }

        func reflectance(cosine: Double) -> SIMD3<Double> {
            switch model {
            case .stock:
                MercuryOptics.exactFresnel(cosine: cosine)
            case .stack(let stack):
                MercurySpectra.gamutFloor(stack.rgb(cosine: cosine))
            case .lacquer(let lacquer):
                MercurySpectra.gamutFloor(lacquer.rgb(cosine: cosine))
            }
        }
    }
}

/// One paint's μ → RGB reflectance, sampled at 1,024 cosines and linearly interpolated: the
/// only material term the rasterizer evaluates per pixel, so a look changes no per-pixel
/// cost.
///
/// The table lives in raw storage that `init` allocates and fills before the instance is
/// published and `deinit` frees. The rasterizer takes ``table`` once per frame, and each
/// pixel's lookup is then two reads and a lerp, with no array bounds check or buffer retain
/// inside the raster loop. Nothing writes the storage after `init`, which is what makes the
/// unchecked `Sendable` sound.
final class MercuryPaintLookup: @unchecked Sendable {
    static let count = 1_024
    static let minimumCosine = 1e-4
    /// Room for the live look, a showroom draft and recent browsing; one table is 16 KiB.
    private static let cacheCapacity = 8

    /// The shipped liquid-mercury table: mercury's conductor response over `μ ∈ [1e-4, 1]`,
    /// the 1,024 node cosines through `MercuryOptics.exactFresnel`, each channel rounded to
    /// `Float`. That is 1,024 × 81 exact Fresnel evaluations, about a millisecond in a release
    /// build, and the only table of liquid mercury: `MercuryOptics.fresnel(cosine:)` reads
    /// it too.
    static let stock = MercuryPaintLookup(paint: .stock) { cosine in
        MercuryOptics.exactFresnel(cosine: cosine)
    }

    /// Most recently used last. Tables do not depend on the room, so one paint is one
    /// table for the whole process.
    private static let cache = Mutex<[MercuryPaintLookup]>([])

    /// The canonical paint this table samples.
    let paint: MercuryPaint
    /// Rec.709 luminance of the normal-incidence (μ = 1) entry: the material brightness a
    /// look's display response is metered against.
    let albedo: Double
    private let storage: UnsafeMutablePointer<SIMD3<Float>>

    private init(paint: MercuryPaint, reflectance: (Double) -> SIMD3<Double>) {
        let storage = UnsafeMutablePointer<SIMD3<Float>>.allocate(capacity: Self.count)
        for index in 0..<Self.count {
            let value = reflectance(Self.cosine(at: index))
            (storage + index).initialize(to: SIMD3(Float(value.x), Float(value.y), Float(value.z)))
        }
        let normal = storage[Self.count - 1]
        self.paint = paint
        self.storage = storage
        albedo = MercuryDisplayResponse.luminance(
            SIMD3(Double(normal.x), Double(normal.y), Double(normal.z))
        )
    }

    deinit {
        storage.deallocate()
    }

    /// The table for `paint`. Equivalent paints share one table; stock returns `stock`
    /// itself, and any other paint is built once and kept in a small process-wide cache.
    static func lookup(for paint: MercuryPaint) -> MercuryPaintLookup {
        let paint = paint.canonical
        guard paint != .stock else { return stock }
        if let cached = cache.withLock({ entries in Self.promote(paint, in: &entries) }) {
            return cached
        }
        // Built outside the lock: a racing builder of the same paint costs one table,
        // never a wait.
        let oracle = MercuryPaint.Oracle(paint)
        let built = MercuryPaintLookup(paint: paint) { oracle.reflectance(cosine: $0) }
        return cache.withLock { entries in
            if let raced = Self.promote(paint, in: &entries) { return raced }
            entries.append(built)
            if entries.count > Self.cacheCapacity { entries.removeFirst() }
            return built
        }
    }

    /// The cosine of table node `index`.
    static func cosine(at index: Int) -> Double {
        minimumCosine + (1 - minimumCosine) * Double(index) / Double(count - 1)
    }

    /// The stored value of table node `index`.
    func entry(_ index: Int) -> SIMD3<Float> {
        precondition((0..<Self.count).contains(index), "paint table node out of range")
        return storage[index]
    }

    /// The table's storage as a frame reads it. See ``Table``.
    var table: Table {
        Table(entries: UnsafePointer(storage))
    }

    @inline(__always)
    func fresnel(cosine: Double) -> SIMD3<Double> {
        table.fresnel(cosine: cosine)
    }

    /// The table as the rasterizer reads it for one frame: the storage's address, taken once,
    /// as `MercuryOptics.tables` is, so every pixel's lerp reads straight through it.
    ///
    /// It borrows the lookup's storage and is valid only while the lookup lives. The
    /// rasterizer holds the lookup it was handed for the whole render, and nothing keeps a
    /// `Table` past one.
    ///
    /// `@unchecked Sendable` for the lookup's own reason: nothing writes the storage after
    /// the lookup's `init`.
    struct Table: @unchecked Sendable {
        private let entries: UnsafePointer<SIMD3<Float>>

        fileprivate init(entries: UnsafePointer<SIMD3<Float>>) {
            self.entries = entries
        }

        /// The reflectance at `cosine`, clamped into `[minimumCosine, 1]`: the two nodes
        /// around it, mixed in `Float` by its fraction between them.
        @inline(__always)
        func fresnel(cosine: Double) -> SIMD3<Double> {
            let clamped = Swift.min(Swift.max(cosine, MercuryPaintLookup.minimumCosine), 1)
            let scaled =
                (clamped - MercuryPaintLookup.minimumCosine)
                * Double(MercuryPaintLookup.count - 1)
                / (1 - MercuryPaintLookup.minimumCosine)
            let lower = Int(scaled)
            let upper = Swift.min(lower + 1, MercuryPaintLookup.count - 1)
            let fraction = Float(scaled - Double(lower))
            let value = entries[lower] + (entries[upper] - entries[lower]) * fraction
            return SIMD3(Double(value.x), Double(value.y), Double(value.z))
        }
    }

    /// Moves `paint`'s table, if cached, to the most-recent end and returns it.
    private static func promote(
        _ paint: MercuryPaint,
        in entries: inout [MercuryPaintLookup]
    ) -> MercuryPaintLookup? {
        guard let index = entries.firstIndex(where: { $0.paint == paint }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry
    }
}
