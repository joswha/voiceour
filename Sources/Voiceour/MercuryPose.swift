import CoreGraphics

/// What the controller knows about the pointer, the frontmost window and a hand-off between displays
/// that changes how far the collar reaches. The island's ladder reads only `draining`.
struct MercuryPoseContext: Equatable, Sendable {
    /// The pointer is in the menu-bar band beside the housing. The speaking body gives the walls back,
    /// so no film lies in the band the user is reaching into for a menu or a status item.
    var pointerInBand = false
    /// The frontmost window fills the display, so the band beside the notch is empty black. The
    /// speaking body spreads its film along the ears into it.
    var fullScreen = false
    /// The body is being handed to another display, and the panel moves only once it is empty. Both
    /// ladders ask for nothing, so the body swallows itself into the edge it is leaving.
    var draining = false
}

/// Where the body is asked to be, as a function of the session alone.
///
/// The pose is the *only* channel between session state and shape: there is no glyph,
/// no word, and no hue. A reader distinguishes warming from listening from working from
/// an unclean delivery by how much mercury there is and what it is doing, and a
/// VoiceOver reader distinguishes them by the status element's value, which is
/// unchanged.
struct MercuryPose: Equatable {
    /// Points, along the spine.
    var length: CGFloat
    /// Points. The mean envelope's value at the body's centre, before a neck pinches it.
    var halfHeight: CGFloat
    /// Points along the spine from its rest centre. Only the `lurch` gesture asks for one;
    /// the controller's lean adds its own on top.
    var lateralOffset: CGFloat
    /// Lopsidedness of the mean envelope, −0.6…0.6. The envelope is scaled by `1 + skew (2a − 1)`
    /// along the material coordinate `a`, which keeps its area and makes 0.4 a 70/30 split
    /// between the two ends.
    var skew: CGFloat = 0
    /// Depth of a waist pinch, 0…0.85. The envelope is scaled by `1 − neck exp(−((a − 0.5) / w)²)`;
    /// at the deepest the waist keeps 15 % of its thickness, so the body is never cut in two.
    var neck: CGFloat = 0
    /// Scales voice forcing. Zero disconnects it, which is what makes warming and
    /// working calm while listening is alive.
    var driveScale: CGFloat
    /// The outcome gesture this pose belongs to, or nil for a live session.
    ///
    /// Carried on the pose rather than on the drive because a gesture's one-shot
    /// impulse is a pose-entry event: the simulation applies it exactly once, when this
    /// value transitions from nil, and the pose is the only thing that knows which
    /// gesture arrived.
    var gesture: MercuryOutcomeGesture?

    static let idle = MercuryPose(length: 0, halfHeight: 0, lateralOffset: 0, driveScale: 0, gesture: nil)

    /// The exact ladder: on the island when `regions` is nil, every pose inside the 180x34
    /// envelope; on the collar, measured along the housing outline `regions` describes.
    ///
    /// Warming is a small calm bead rather than a flat capsule, because the state it
    /// reports — capture requested, no audio yet — held for 1422 ms on a cold AirPods
    /// Max link, and a body that looks like a listening body during it is how a user
    /// speaks into the hole. Listening is a lip: long, thin and alive to the voice.
    /// Speaking is the longest live body, deeper than the lip, and on the collar it climbs
    /// the housing's walls. Processing is a held gathered pose: short and tall, with the
    /// voice disconnected, which reads as gathered rather than open.
    ///
    /// The island's depths are measured against the chrome benchmark under live speech. The
    /// speaking body is 9.5 pt deep: raster cost follows the body's area, not its crests, and at
    /// 11.5 pt its live crests held it against the 34 pt ceiling, where a frame cost 0.58–0.63 ms
    /// against the 0.55 ms gate; at 9.5 pt it costs 0.50–0.53 ms. The listening lip is 140 × 9.3: in
    /// rooms that are one uniform wall but for a few sources, a thin lip's reflections can miss
    /// every source, and its 95th percentile then falls short of separating it from a mid-grey
    /// ground. Across twelve instants of the crest cycle such rooms failed 1.75 times per instant
    /// at 130 × 8, 1.33 at 130 × 8.6 and 1.17 at 140 × 9.3, of 4,096. A residual tail of these
    /// uniform-room listening failures remains, as it did under the legacy liquid law at 0.9 per
    /// instant; the benchmark's gate at 600 substeps is the designed single draw from it, and it
    /// draws none. The collar's lip is 8.6 pt deep, which brought its darkest room's listening
    /// collar from 26 % crushed to 23 %, under the 25 % bound, and its speaking body keeps 11.5 pt:
    /// a collar raster already costs 0.46 ms, and shallower collars darkened their medians below
    /// the 0.18 bound.
    ///
    /// The collar takes its lengths from the outline's bottom run `B` and, per side, its
    /// corner `C`, wall `W`, fillet `F` and ear `E`:
    ///
    /// - Listening lies along the bottom and most of both corners, `B + 1.7 C`.
    /// - Speaking takes both corners and nine tenths of each wall, `B + 2 C + 1.8 W`. With the
    ///   pointer in the menu-bar band it gives the walls back, `B + 2 C`. Over a full-screen app,
    ///   where the band beside the notch is empty black, it also turns both fillets and runs
    ///   seven tenths along each ear, `+ 2 F + 1.4 E`. On the 185x32 notch these are 196, 227,
    ///   202 and 320 of the spine's 356 pt.
    /// - The error collapse spans eight tenths of the bottom, so both of its drips hang under the
    ///   housing. The copy-only bead is a little shorter and taller than the island's, a drop
    ///   under the notch for its gesture's kick to jiggle. Warming, processing and the lurch
    ///   keep the island's lengths, which already fit inside the bottom run.
    ///
    /// On both ladders the lurch also carries `skew` 0.4, a lopsided 70/30 lean, and the
    /// collapse `neck` 0.7, which pinches it into two drips joined by a thread.
    ///
    /// Both ladders ask for nothing while the body drains toward another display and while the
    /// panel fades out, whatever the session holds, an outcome's gesture included. Either way the
    /// body swallows itself into the notch or the top edge, so a panel that moves or vanishes never
    /// carries a whole body with it.
    @MainActor
    static func target(
        for model: RecordingOverlayModel,
        regions: MercurySpine.Regions? = nil,
        context: MercuryPoseContext = .init()
    ) -> MercuryPose {
        if context.draining || model.isDismissing {
            return .idle
        }
        if let gesture = model.outcome?.gesture {
            switch gesture {
            case .gathered:
                return regions == nil
                    ? MercuryPose(length: 70, halfHeight: 11.0, lateralOffset: 0, driveScale: 0, gesture: gesture)
                    : MercuryPose(length: 64, halfHeight: 12.0, lateralOffset: 0, driveScale: 0, gesture: gesture)
            case .lurch:
                return MercuryPose(
                    length: 78,
                    halfHeight: 11.0,
                    lateralOffset: 8,
                    skew: 0.4,
                    driveScale: 0,
                    gesture: gesture
                )
            case .collapse:
                return MercuryPose(
                    length: regions.map { CGFloat(0.8 * $0.bottom) } ?? 92,
                    halfHeight: 6.6,
                    lateralOffset: 0,
                    neck: 0.7,
                    driveScale: 0,
                    gesture: gesture
                )
            }
        }
        if model.isWarmingUp {
            // A compact nucleating bead, not the long live-microphone lens. The warm-up
            // window can last 1.4 seconds on Bluetooth and must differ in kind at a glance.
            return MercuryPose(length: 58, halfHeight: 8.5, lateralOffset: 0, driveScale: 0, gesture: nil)
        }
        if model.isListening {
            // The speaking body is deliberately not the tallest one it could be. The
            // containment budget is `ln(maxHalfHeight / H0)`, so every point of mean
            // thickness is amplitude the crests cannot have: at 13.6 the budget was 0.22
            // and the crests were a 10 % ripple on a fat lozenge. At 11.5 it is 0.39, and
            // the body necks and swells the way a driven liquid ridge does; the island's
            // 9.5, which its raster cost sets, leaves 0.58.
            let speaking =
                regions.map {
                    MercuryPose(
                        length: speakingLength(along: $0, context: context),
                        halfHeight: 11.5,
                        lateralOffset: 0,
                        driveScale: 1,
                        gesture: nil
                    )
                } ?? MercuryPose(length: 160, halfHeight: 9.5, lateralOffset: 0, driveScale: 1, gesture: nil)
            let listening =
                regions.map {
                    MercuryPose(
                        length: CGFloat($0.bottom + 1.7 * $0.corner),
                        halfHeight: 8.6,
                        lateralOffset: 0,
                        driveScale: 1,
                        gesture: nil
                    )
                } ?? MercuryPose(length: 140, halfHeight: 9.3, lateralOffset: 0, driveScale: 1, gesture: nil)
            return model.isSpeaking ? speaking : listening
        }
        if model.isProcessing {
            return MercuryPose(length: 84, halfHeight: 12.5, lateralOffset: 0, driveScale: 0, gesture: nil)
        }
        return .idle
    }

    /// The collar's speaking length: the chin, both corners, and as much of the walls, fillets
    /// and ears as the pointer and the frontmost window leave it.
    private static func speakingLength(along regions: MercurySpine.Regions, context: MercuryPoseContext) -> CGFloat {
        let reach: Double = context.pointerInBand ? 0 : 0.9
        var length = regions.bottom + 2 * regions.corner + 2 * reach * regions.wall
        if context.fullScreen, !context.pointerInBand {
            length += 2 * regions.fillet + 1.4 * regions.ear
        }
        return CGFloat(length)
    }
}
