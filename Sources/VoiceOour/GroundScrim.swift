import SwiftUI

/// The console's one on-ground text substrate, and the ink the titlebar taper
/// has always used.
///
/// Text sitting straight on the window material has whatever contrast the user's
/// desktop gives it — in the harness the header eyebrow measured 2.1:1 and the
/// rail's IDLE 2.9:1 against the flat tint that stands in for behind-window
/// glass, and in production the number is not low so much as *undefined*
/// (`lg-standard` rule 5: a permanently transparent ground needs a dimming
/// layer). Compositing `Ink.void` at 0.88 bounds the ground at the pure-white
/// worst case of sRGB(0.138, 0.146, 0.164), so the dimmest tier the header and
/// the rail use, `Text.low`, can never fall below **4.66:1** and reads 6.12:1
/// over `Ink.void` itself. 0.87 is the arithmetic floor for AA 4.5:1 at that
/// tier; 0.88 is the value already in the vocabulary, so no second one is
/// introduced.
///
/// Never interactive, never an accessibility element (§1.2).
struct GroundScrim: View {
    /// Fade-out at the bottom edge, for the one edge that meets content rather
    /// than a window boundary. Zero elsewhere: a scrim that fades under its own
    /// text is not a floor.
    var taper: CGFloat = 0

    static let ink = VoiceOourPalette.Ink.void.opacity(0.88)

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Self.ink)

            if taper > 0 {
                LinearGradient(
                    colors: [Self.ink, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: taper)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
