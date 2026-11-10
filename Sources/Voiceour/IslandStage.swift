import SwiftUI

/// The geometry of the Island page's stage: the showroom body magnified twice over, standing
/// on a horizon, with the floor it casts below that.
@MainActor
enum IslandStageMetrics {
    /// How many times larger than the island the stage draws the body.
    static let magnification: CGFloat = 2
    /// The island's 196×34 pt canvas, magnified.
    static let bodySize = CGSize(
        width: RecordingOverlayLayout.island.canvasRect.width * magnification,
        height: RecordingOverlayLayout.island.canvasRect.height * magnification
    )
    /// The floor image covers the body canvas and as much again below it: the contact shadow
    /// sits on the canvas's base row and the reflection mirrors the body down from there.
    static let floorSize = CGSize(width: bodySize.width, height: bodySize.height * 2)
    /// The room above the body, where the spotlight falls.
    static let bodyTop: CGFloat = 56
    /// The floor below the reflection.
    static let floorBottom: CGFloat = 12
    /// The stage's whole height: the spotlit air, the body, its reflection and a strip of floor.
    static let height: CGFloat = bodyTop + floorSize.height + floorBottom
    /// Where the floor meets the back wall: the body's base row.
    static let horizon: CGFloat = bodyTop + bodySize.height
}

/// The lit studio behind the showroom body: a spotlight from above in the look's white
/// balance, the horizon the body stands on, the floor band in front of it, and the underglow's
/// pool on that floor when the look has one.
///
/// Drawn from the look's own light inputs (`ShowroomStage.Lighting`), never from the room the
/// body reflects, and only around the body: nothing here paints the body's own pixels. Plain
/// fills and gradients in one `Canvas`, so the offscreen harness captures the backdrop as it
/// renders on screen. Decorative, so hidden from accessibility.
struct IslandStageBackdrop: View, Equatable {
    let lighting: ShowroomStage.Lighting
    let horizon: CGFloat
    let increasedContrast: Bool

    /// How far the spotlight's cone carries above the horizon, as a share of the stage width.
    private static let spotReach: CGFloat = 0.55
    /// The underglow pool's half-width, and how flat its ellipse lies on the floor.
    private static let poolRadius: CGFloat = 240
    private static let poolSquash: CGFloat = 0.18

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lighting == rhs.lighting && lhs.horizon == rhs.horizon
            && lhs.increasedContrast == rhs.increasedContrast
    }

    var body: some View {
        let lighting = lighting
        let horizon = horizon
        let horizonLine =
            increasedContrast
            ? VoiceourPalette.Contrast.lineEdge
            : VoiceourPalette.Line.edge
        let hairline = VoiceourMetrics.Stroke.hairline(increasedContrast ? .increased : .standard)
        let spotReach = Self.spotReach
        let radius = Self.poolRadius
        let squash = Self.poolSquash
        let ground = VoiceourPalette.Ink.well
        Canvas { context, size in
            let horizonY = min(horizon, size.height)
            let center = size.width / 2

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ground))

            // The spotlight: a cone of the look's white light from the top of the stage.
            context.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: lighting.spot.opacity(0.30), location: 0),
                        .init(color: lighting.spot.opacity(0.10), location: 0.55),
                        .init(color: lighting.spot.opacity(0), location: 1),
                    ]),
                    center: CGPoint(x: center, y: 0),
                    startRadius: 0,
                    endRadius: max(horizonY * 1.4, size.width * spotReach)
                )
            )

            // The floor band: the same light, fading toward the viewer.
            context.fill(
                Path(CGRect(x: 0, y: horizonY, width: size.width, height: size.height - horizonY)),
                with: .linearGradient(
                    Gradient(colors: [lighting.spot.opacity(0.09), lighting.spot.opacity(0)]),
                    startPoint: CGPoint(x: center, y: horizonY),
                    endPoint: CGPoint(x: center, y: size.height)
                )
            )

            // The underglow's pool, centred under the body on the floor.
            if let glow = lighting.underglow {
                let strength = min(max(lighting.underglowStrength, 0), 1)
                var pool = context
                pool.translateBy(x: center, y: horizonY)
                pool.scaleBy(x: 1, y: squash)
                pool.fill(
                    Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        Gradient(colors: [glow.opacity(0.55 * strength), glow.opacity(0)]),
                        center: .zero,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }

            // The horizon, brightest under the spotlight and gone at the stage's edges.
            context.fill(
                Path(CGRect(x: 0, y: horizonY - hairline / 2, width: size.width, height: hairline)),
                with: .linearGradient(
                    Gradient(colors: [horizonLine.opacity(0), horizonLine, horizonLine.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: horizonY),
                    endPoint: CGPoint(x: size.width, y: horizonY)
                )
            )
        }
        .accessibilityHidden(true)
    }
}
