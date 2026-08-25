import SwiftUI

/// The accessibility environment this app renders against, as one value.
///
/// Two jobs in one place. It mirrors the four SDK environment values the views
/// actually adapt to — Reduce Transparency, Reduce Motion, Differentiate Without
/// Color and Increase Contrast — through `RenderOverrides`, because the SDK
/// exposes them get-only and the offscreen harness has to be able to render an
/// adaptation this Mac is not configured for. And it resolves the escalated
/// colour ladder those adaptations share, so a surface cannot adapt to one
/// setting and forget the other.

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

    var textLow: Color {
        contrast == .increased ? VoiceourPalette.Text.mid : VoiceourPalette.Text.low
    }

    var textMid: Color {
        contrast == .increased ? VoiceourPalette.Text.high : VoiceourPalette.Text.mid
    }

    var markFaint: Color {
        contrast == .increased ? VoiceourPalette.Text.low : VoiceourPalette.Mark.faint
    }

    /// Reduce Transparency deletes the material that was drawing every boundary
    /// for us, so the painted rules have to draw them instead. Both adaptations
    /// land on one escalated ladder rather than inventing a third set of values:
    /// Increase Contrast asks for a contrasting border, Reduce Transparency asks
    /// for a border where a gradient used to be, and the answer is the same line.
    private var escalatedLines: Bool {
        contrast == .increased || reduceTransparency
    }

    var lineRule: Color {
        escalatedLines ? VoiceourPalette.Contrast.lineRule : VoiceourPalette.Line.rule
    }

    var lineEdge: Color {
        escalatedLines ? VoiceourPalette.Contrast.lineEdge : VoiceourPalette.Line.edge
    }

    var lineControl: Color {
        escalatedLines ? VoiceourPalette.Contrast.lineControl : VoiceourPalette.Line.control
    }

    var surface: Color {
        contrast == .increased ? VoiceourPalette.Ink.void : VoiceourPalette.Ink.surface
    }

    var meterRest: Color {
        contrast == .increased ? VoiceourPalette.Contrast.meterRest : VoiceourPalette.Meter.rest
    }
}
