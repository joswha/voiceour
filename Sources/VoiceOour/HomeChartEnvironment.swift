import SwiftUI

/// Plot geometry shared by the dashboard's charts. `DesignTokens` carries no
/// size scale for a plot band, so the figure the Home charts are built on is
/// named here once instead of being re-derived as spacing arithmetic at each
/// call site.
enum HomeChart {
    /// Height of the shared plot band: the hour strip and the day strip draw
    /// the same band so the shelf's baselines agree.
    static let band: CGFloat = VoiceOourMetrics.Space.section * 3
}

/// Whether a capture is live on the surface the Home charts are drawn on.
private struct HomeCaptureLiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set once by the dashboard; read by every chart that carries a tint.
    var homeCaptureIsLive: Bool {
        get { self[HomeCaptureLiveKey.self] }
        set { self[HomeCaptureLiveKey.self] = newValue }
    }
}

/// The tint a Home chart mark carries.
///
/// `Signal.cyan` marks the one live element in a view. While a capture runs the
/// LISTENING badge is that element, so every chart accent underneath steps back
/// to `Signal.wash`: the same hue at a fifth of the luminance (0.137 against
/// 0.652 composited on `Ink.surface`), which leaves it separated from the
/// neutral `meterRest` marks around it by hue rather than by weight. Increase
/// Contrast is the exception — there `meterRest` is raised to white 0.55, well
/// past the wash, and a demoted accent would rank *below* the bars it leads.
struct HomeAccent: DynamicProperty {
    @Environment(\.homeCaptureIsLive) private var captureIsLive
    private var a11y = A11y()

    var color: Color {
        captureIsLive && a11y.contrast != .increased
            ? VoiceOourPalette.Signal.wash
            : VoiceOourPalette.Signal.cyan
    }
}
