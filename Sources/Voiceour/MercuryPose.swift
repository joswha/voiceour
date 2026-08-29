import CoreGraphics

/// Where the body is asked to be, as a function of the session alone.
///
/// The pose is the *only* channel between session state and shape: there is no glyph,
/// no word, and no hue. A reader distinguishes warming from listening from working from
/// an unclean delivery by how much mercury there is and what it is doing, and a
/// VoiceOver reader distinguishes them by the status element's value, which is
/// unchanged.
struct MercuryPose: Equatable {
    /// Points, along the island's long axis.
    var length: CGFloat
    /// Points. The mean envelope's value at the body's centre.
    var halfHeight: CGFloat
    /// Points. Only the `lurch` gesture leaves the island's centre line.
    var lateralOffset: CGFloat
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

    /// The exact ladder, all inside the 180x34 island.
    ///
    /// Warming is a small calm lens rather than a flat capsule, because the state it
    /// reports — capture requested, no audio yet — held for 1422 ms on a cold AirPods
    /// Max link, and a body that looks like a listening body during it is how a user
    /// speaks into the hole. Speaking is the widest and deepest the body ever gets;
    /// working is short and tall, which reads as gathered rather than open.
    @MainActor
    static func target(for model: RecordingOverlayModel) -> MercuryPose {
        if let gesture = model.outcome?.gesture {
            switch gesture {
            case .gathered:
                return MercuryPose(length: 70, halfHeight: 11.0, lateralOffset: 0, driveScale: 0, gesture: gesture)
            case .lurch:
                return MercuryPose(length: 78, halfHeight: 11.0, lateralOffset: 8, driveScale: 0, gesture: gesture)
            case .collapse:
                return MercuryPose(length: 92, halfHeight: 6.6, lateralOffset: 0, driveScale: 0, gesture: gesture)
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
            // the body necks and swells the way a driven liquid ridge does.
            return model.isSpeaking
                ? MercuryPose(length: 160, halfHeight: 11.5, lateralOffset: 0, driveScale: 1, gesture: nil)
                : MercuryPose(length: 130, halfHeight: 8.0, lateralOffset: 0, driveScale: 1, gesture: nil)
        }
        if model.isProcessing {
            return MercuryPose(length: 84, halfHeight: 12.5, lateralOffset: 0, driveScale: 0, gesture: nil)
        }
        return .idle
    }
}
