import AppKit
import SwiftUI

// Canonical design tokens live in DesignTokens.swift.
struct TextRoleRecordingModifier: ViewModifier {
    @Environment(\.surfaceGround) private var ground

    let role: TextRole
    let foreground: Color
    let isBold: Bool
    let recorder: TextRoleRecorder

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                if let sample = TextRoleSample.resolve(
                    role: role,
                    foreground: foreground,
                    ground: ground,
                    isBold: isBold,
                    frame: proxy.frame(in: .global)
                ) {
                    TextRoleRecordingProbe(sample: sample, recorder: recorder)
                }
            }
        }
    }
}

private struct TextRoleRecordingProbe: View {
    @State private var id = UUID()

    let sample: TextRoleSample
    let recorder: TextRoleRecorder

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                recorder.record(sample, id: id)
            }
            .onChange(of: sample) { _, updated in
                recorder.record(updated, id: id)
            }
            .onDisappear {
                recorder.remove(id: id)
            }
    }
}
/// Ordered paint stack below role-styled text. Opaque surfaces start a new
/// stack; translucent controls append their fill so the recorder resolves the
/// same composition SwiftUI paints instead of flattening alpha over `Ink.void`.
struct SurfaceGround {
    fileprivate let layers: [Color]

    init(_ color: Color) {
        layers = [color]
    }

    private init(layers: [Color]) {
        self.layers = layers
    }

    func painting(_ color: Color) -> SurfaceGround {
        SurfaceGround(layers: layers + [color])
    }
}

private struct SurfaceGroundKey: EnvironmentKey {
    static let defaultValue = SurfaceGround(VoiceOourPalette.Ink.void)
}

extension EnvironmentValues {
    /// Paint stack beneath text, used to verify role contrast in the UI harness.
    var surfaceGround: SurfaceGround {
        get { self[SurfaceGroundKey.self] }
        set { self[SurfaceGroundKey.self] = newValue }
    }
}

extension TextRoleSample {
    fileprivate static func resolve(
        role: TextRole,
        foreground: Color,
        ground: SurfaceGround,
        isBold: Bool,
        frame: CGRect
    ) -> TextRoleSample? {
        guard let void = ResolvedTextColor(VoiceOourPalette.Ink.void),
            let rawForeground = ResolvedTextColor(foreground)
        else {
            return nil
        }
        var opaqueGround = void
        for layer in ground.layers {
            guard let resolvedLayer = ResolvedTextColor(layer) else { return nil }
            opaqueGround = resolvedLayer.composited(over: opaqueGround)
        }
        let opaqueForeground = rawForeground.composited(over: opaqueGround)
        return TextRoleSample(
            role: String(describing: role),
            foreground: opaqueForeground.rgb,
            ground: opaqueGround.rgb,
            pointSize: role.pointSize,
            isBold: isBold,
            frame: frame
        )
    }
}

private struct ResolvedTextColor {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init?(_ color: Color) {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        red = Double(resolved.redComponent)
        green = Double(resolved.greenComponent)
        blue = Double(resolved.blueComponent)
        alpha = Double(resolved.alphaComponent)
    }

    private init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var rgb: (r: Double, g: Double, b: Double) {
        (red, green, blue)
    }

    func composited(over background: ResolvedTextColor) -> ResolvedTextColor {
        ResolvedTextColor(
            red: alpha * red + (1 - alpha) * background.red,
            green: alpha * green + (1 - alpha) * background.green,
            blue: alpha * blue + (1 - alpha) * background.blue,
            alpha: 1
        )
    }
}
