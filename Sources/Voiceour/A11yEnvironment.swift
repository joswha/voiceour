import SwiftUI

/// The accessibility environment this app renders against, as one value.
///
/// It mirrors the four SDK environment values the views actually adapt to —
/// Reduce Transparency, Reduce Motion, Differentiate Without Color and Increase
/// Contrast — through `RenderOverrides`, because the SDK exposes them get-only and
/// the offscreen harness has to be able to render an adaptation this Mac is not
/// configured for. Colours are not here: the theme (`\.theme`) resolves them,
/// Increase Contrast included.

@MainActor
struct A11y: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var envDifferentiate
    @Environment(\.colorSchemeContrast) private var envContrast

    var reduceTransparency: Bool {
        RenderOverrides.reduceTransparency ?? envReduceTransparency
    }

    var reduceMotion: Bool {
        RenderOverrides.reduceMotion ?? envReduceMotion
    }

    var differentiateWithoutColor: Bool {
        RenderOverrides.differentiateWithoutColor ?? envDifferentiate
    }

    var contrast: ColorSchemeContrast {
        (RenderOverrides.increasedContrast ?? (envContrast == .increased))
            ? .increased
            : .standard
    }
}
