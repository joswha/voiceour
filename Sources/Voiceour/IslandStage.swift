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
    /// The stage's whole height at full size: the spotlit air, the body, its reflection and a
    /// strip of floor.
    static let height: CGFloat = bodyTop + floorSize.height + floorBottom
    /// Where the floor meets the back wall at full size: the body's base row.
    static let horizon: CGFloat = bodyTop + bodySize.height
    /// The narrowest stage drawn at full size: the 392 pt floor with 16 pt of studio either
    /// side. Narrower, the whole stage scales down and keeps its aspect, so the body never
    /// overflows the card it sits in.
    static let fullSizeWidth: CGFloat = floorSize.width + 32
    /// The studio's corners inside the card's 16 pt padding.
    static let cornerRadius: CGFloat = 8
}

/// The studio's own colours: the stage is a dark room in every console appearance, because
/// the island it previews floats over the desktop in its own light, never the console's
/// theme. The look gallery's wells show their stills on the same ground.
enum IslandStudio {
    /// The studio's ground, under the spotlight and behind every gallery still.
    static let ground = Color(.sRGB, red: 0.030, green: 0.036, blue: 0.048, opacity: 1)
}

/// Sizes the stage to the width it is offered and the height that width allows: full height
/// from ``IslandStageMetrics/fullSizeWidth`` up, and proportionally less below it, so the
/// stage scales as a whole instead of clipping the body or overflowing.
///
/// The child fills the frame; it reads its scale from the width it is given through
/// ``scale(width:fullSizeWidth:)``, the same rule this layout sizes by.
struct IslandStageFrame: Layout {
    let fullSizeWidth: CGFloat
    let fullHeight: CGFloat

    /// The stage's scale at `width`: 1 from the full-size width up, less below it.
    static func scale(width: CGFloat, fullSizeWidth: CGFloat) -> CGFloat {
        guard width.isFinite, fullSizeWidth > 0 else { return 1 }
        return min(1, max(0, width) / fullSizeWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // No proposal asks for the ideal: the full-size stage at its narrowest.
        let width = proposal.width.map { max($0, 0) } ?? fullSizeWidth
        let scale = Self.scale(width: width, fullSizeWidth: fullSizeWidth)
        return CGSize(width: width, height: fullHeight * scale)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// The lit studio behind the showroom body: a spotlight from above in the look's white
/// balance, the horizon the body stands on, the floor band in front of it, and the underglow's
/// pool on that floor when the look has one.
///
/// Drawn from the look's own light inputs (`ShowroomStage.Lighting`), never from the room the
/// body reflects, and only around the body: nothing here paints the body's own pixels. Its
/// ground and horizon are the studio's constants, never the console theme's, so the stage is
/// the same dark room in every appearance. Plain fills and gradients in one `Canvas`, so the
/// offscreen harness captures the backdrop as it renders on screen. Decorative, so hidden from
/// accessibility.
struct IslandStageBackdrop: View, Equatable {
    let lighting: ShowroomStage.Lighting
    /// Where the floor meets the back wall, at the stage's current scale.
    let horizon: CGFloat
    /// The stage's scale against its full size; the underglow pool shrinks with it.
    let scale: CGFloat
    let increasedContrast: Bool

    /// How far the spotlight's cone carries above the horizon, as a share of the stage width.
    private static let spotReach: CGFloat = 0.55
    /// The underglow pool's half-width at full size, and how flat its ellipse lies on the
    /// floor.
    private static let poolRadius: CGFloat = 240
    private static let poolSquash: CGFloat = 0.18
    /// The studio's ground.
    private static let ground = IslandStudio.ground
    /// The horizon at its brightest, white over the studio ground; brighter under Increase
    /// Contrast.
    private static let horizonLine = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.18)
    private static let horizonLineIncreased = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.30)

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lighting == rhs.lighting && lhs.horizon == rhs.horizon && lhs.scale == rhs.scale
            && lhs.increasedContrast == rhs.increasedContrast
    }

    var body: some View {
        let lighting = lighting
        let horizon = horizon
        let horizonLine = increasedContrast ? Self.horizonLineIncreased : Self.horizonLine
        let hairline = VoiceourMetrics.Stroke.hairline(increasedContrast ? .increased : .standard)
        let spotReach = Self.spotReach
        let radius = Self.poolRadius * scale
        let squash = Self.poolSquash
        let ground = Self.ground
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
            if let glow = lighting.underglow, radius > 0 {
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
