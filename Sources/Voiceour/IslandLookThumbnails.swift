import CoreGraphics
import VoiceCore

/// Still renders of the twelve island looks for the Settings look gallery.
///
/// They exist so a look can be chosen by how it looks: each card shows the production body in
/// that look, drawn by the production engine, room and rasterizer, never a painted swatch. One
/// still per look and contrast setting is enough, so the gallery runs no display link of its
/// own; every card is the speaking body settled 600 substeps — the substep the overlay goldens
/// and the Reduce Motion showroom pin — on the island layout at the production raster scale,
/// 392×68 px, in room 1 of the showroom's sequence (`RenderOverrides.mercurySeed`, else
/// `MercuryMetrics.defaultSeed`).
///
/// One engine draws them all and the stills are kept, so a gallery that re-renders reads a
/// cache. A first render of a look pays what a showroom's first pinned frame of it pays: a
/// 600-substep settle when its tune is new to the engine, and a room bake and a metering when
/// its room and paint are not in the process-wide caches, tens of milliseconds at worst. That
/// is why ``warm(increasedContrast:)`` spreads the misses over main-actor turns.
@MainActor
enum IslandLookThumbnails {
    private struct Key: Hashable {
        var look: IslandLook
        var increasedContrast: Bool
        var seed: UInt64
    }

    private static let step = 600
    /// The gallery's own region: the engine publishes every field it draws, and nothing may
    /// route the pointer by a thumbnail's.
    private static let hitRegion = MercuryHitRegion()
    private static var engine: MercuryEngine?
    private static var speakingDrive: MercurySimulation.Drive?
    /// A render that produced no image is kept as nil, so it is not retried every read.
    private static var stills: [Key: CGImage?] = [:]

    /// The still of `look`, rendered now if it is not kept yet.
    static func image(for look: IslandLook, increasedContrast: Bool) -> CGImage? {
        let key = Key(look: look, increasedContrast: increasedContrast, seed: seed)
        if let kept = stills[key] { return kept }
        let rendered = render(key)
        stills[key] = .some(rendered)
        return rendered
    }

    /// Renders every look not kept yet for this contrast setting, one per main-actor turn, so
    /// the window keeps drawing between them. Returns early when its task is cancelled.
    static func warm(increasedContrast: Bool) async {
        for look in IslandLook.allCases {
            guard !Task.isCancelled else { return }
            guard stills[Key(look: look, increasedContrast: increasedContrast, seed: seed)] == nil else { continue }
            await Task.yield()
            guard !Task.isCancelled else { return }
            _ = image(for: look, increasedContrast: increasedContrast)
        }
    }

    private static var seed: UInt64 {
        RenderOverrides.mercurySeed ?? MercuryMetrics.defaultSeed
    }

    private static func render(_ key: Key) -> CGImage? {
        let look = MercuryLook(island: key.look.appearance)
        let renderer = Self.engine ?? MercuryEngine(seed: key.seed, look: look, hitRegion: hitRegion)
        Self.engine = renderer
        return renderer.pinnedFrame(
            step: step,
            seed: key.seed,
            look: look,
            drive: speaking(),
            appearance: MercuryAppearance(increasedContrast: key.increasedContrast),
            layout: .island
        )
    }

    /// The showroom's speaking drive, built once from the pose's fixed model.
    private static func speaking() -> MercurySimulation.Drive {
        if let speakingDrive { return speakingDrive }
        let built = MercurySimulation.Drive.target(for: IslandShowroomPose.speaking.model(), reduceMotion: false)
        speakingDrive = built
        return built
    }
}
