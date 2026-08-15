import SwiftUI

// Harness instrumentation for these tokens lives in DesignTokenInstrumentation.swift.

/// Shared design vocabulary for Voiceour's glass console and recording overlay.
/// Keep literal colors, font sizes, spacing, radii, and motion timings here so view
/// files compose tokens instead of inventing one-off styling.
enum VoiceourPalette {
    enum Ink {
        static let void = Color(.sRGB, red: 0.02, green: 0.03, blue: 0.05, opacity: 1.00)
        static let scrim = void.opacity(0.88)
        /// The opaque stand-in for the glass ground under Reduce Transparency.
        /// It has to be *lighter* than `surface`, not darker: the vibrancy ground
        /// rasterises above the content plane (measured (47,48,51) at mid-window,
        /// (96,96,96) near the titlebar, against a (14,17,22) card), so filling
        /// with `void` inverts figure and ground and flattens the console to
        /// 1.06:1. This value continues the family's tint rule (r, r+0.010,
        /// r+0.030) and lands at **1.50:1 against `surface`** — the same step the
        /// live glass makes across the middle of the window.
        static let frost = Color(.sRGB, red: 0.190, green: 0.200, blue: 0.220, opacity: 1.00)
        static let pane = Color(.sRGB, red: 0.06, green: 0.07, blue: 0.09, opacity: 0.62)
        static let rimDark = Color(.sRGB, red: 0.00, green: 0.00, blue: 0.00, opacity: 0.34)
        static let surface = Color(.sRGB, red: 0.055, green: 0.065, blue: 0.085, opacity: 1.00)
        static let well = Color(.sRGB, red: 0.030, green: 0.036, blue: 0.048, opacity: 1.00)
    }

    enum Plate {
        static let rest = Color.white.opacity(0.05)
        static let hover = Color.white.opacity(0.09)
        static let pressed = Color.white.opacity(0.14)
    }

    enum Text {
        static let high = Color(.sRGB, red: 0.89, green: 0.91, blue: 0.95, opacity: 1.00)
        static let mid = Color(.sRGB, red: 0.64, green: 0.71, blue: 0.80, opacity: 1.00)
        static let low = Color(.sRGB, red: 0.51, green: 0.56, blue: 0.64, opacity: 1.00)
        static let mono = Color(.sRGB, red: 0.64, green: 0.75, blue: 0.86, opacity: 1.00)
        static let monoStrong = Color(.sRGB, red: 0.84, green: 0.92, blue: 0.98, opacity: 1.00)
    }

    enum Mark {
        static let faint = Color(.sRGB, red: 0.38, green: 0.42, blue: 0.48, opacity: 1.00)
    }

    enum Line {
        static let rule = Color.white.opacity(0.13)
        static let edge = Color.white.opacity(0.18)
        static let control = Color.white.opacity(0.35)
        static let controlHover = Color.white.opacity(0.48)
        static let focus = Signal.cyan
    }

    enum Contrast {
        static let lineRule = Color.white.opacity(0.24)
        static let lineEdge = Color.white.opacity(0.30)
        static let lineControl = Color.white.opacity(0.55)
        static let meterRest = Color.white.opacity(0.55)
    }

    enum Meter {
        static let rest = Color.white.opacity(0.35)
        static let accent = Signal.cyan
    }

    enum Signal {
        static let cyan = Color(.sRGB, red: 0.62, green: 0.86, blue: 1.00, opacity: 1.00)
        static let cyanDeep = Color(.sRGB, red: 0.32, green: 0.60, blue: 0.92, opacity: 1.00)
        static let mint = Color(.sRGB, red: 0.66, green: 0.96, blue: 0.82, opacity: 1.00)
        static let amber = Color(.sRGB, red: 0.98, green: 0.78, blue: 0.42, opacity: 1.00)
        static let crimson = Color(.sRGB, red: 0.98, green: 0.44, blue: 0.44, opacity: 1.00)
        static let wash = cyan.opacity(0.45)
        static let focusHalo = cyan.opacity(0.25)
    }

    static let specularRim = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.55), location: 0.00),
            .init(color: Color.white.opacity(0.16), location: 0.38),
            .init(color: Color.white.opacity(0.06), location: 0.62),
            .init(color: Color.white.opacity(0.22), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let glassTint = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.05), location: 0.00),
            .init(color: Ink.pane, location: 0.38),
            .init(color: Color.black.opacity(0.28), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum VoiceourTypography {
    static let eyebrow = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let title = Font.system(size: 17, weight: .semibold, design: .default)
    static let label = Font.system(size: 13, weight: .medium, design: .default)
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let bodyMono = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let caption = Font.system(size: 12, weight: .regular, design: .default)
    static let micro = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let metric = Font.system(size: 32, weight: .light, design: .monospaced)
    /// Widget-tile readout for word values (READY, GRANTED, MLX): smaller
    /// than `metric` numerals but still unmistakably the tile's payload.
    static let tileValue = Font.system(size: 20, weight: .medium, design: .monospaced)
    /// Oversized numerical readout. Larger than `metric`; pair with
    /// `.monospacedDigit()` at the call site.
    static let heroMetric = Font.system(size: 64, weight: .thin, design: .monospaced)
    /// Empty-state glyph role. Decorative instances remain accessibility-hidden.
    static let emptyGlyph = Font.system(size: 48, weight: .thin, design: .default)
}

enum TextRole {
    case heroMetric
    case metric
    case tileValue
    case title
    case label
    case body
    case bodyMono
    case caption
    case eyebrow
    case micro
    case emptyGlyph

    var font: Font {
        switch self {
        case .heroMetric: VoiceourTypography.heroMetric
        case .metric: VoiceourTypography.metric
        case .tileValue: VoiceourTypography.tileValue
        case .title: VoiceourTypography.title
        case .label: VoiceourTypography.label
        case .body: VoiceourTypography.body
        case .bodyMono: VoiceourTypography.bodyMono
        case .caption: VoiceourTypography.caption
        case .eyebrow: VoiceourTypography.eyebrow
        case .micro: VoiceourTypography.micro
        case .emptyGlyph: VoiceourTypography.emptyGlyph
        }
    }

    var tracking: CGFloat {
        switch self {
        case .eyebrow: 1.4
        case .micro: 0.8
        default: 0
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .heroMetric: 64
        case .metric: 32
        case .tileValue: 20
        case .title: 17
        case .label, .body, .bodyMono: 13
        case .caption: 12
        case .eyebrow: 11
        case .micro: 10
        case .emptyGlyph: 48
        }
    }

    var weight: Font.Weight {
        switch self {
        case .heroMetric, .emptyGlyph: .thin
        case .metric: .light
        case .tileValue, .label, .micro: .medium
        case .title, .eyebrow: .semibold
        case .body, .bodyMono, .caption: .regular
        }
    }

    var isBold: Bool {
        Self.isBold(weight)
    }

    static func isBold(_ weight: Font.Weight?) -> Bool {
        weight == .bold || weight == .heavy || weight == .black
    }

    var foreground: Color {
        switch self {
        case .heroMetric, .metric, .title, .label, .body:
            VoiceourPalette.Text.high
        case .tileValue:
            VoiceourPalette.Text.monoStrong
        case .bodyMono:
            VoiceourPalette.Text.mono
        case .caption, .eyebrow, .micro:
            VoiceourPalette.Text.low
        case .emptyGlyph:
            VoiceourPalette.Mark.faint
        }
    }
}

enum ControlState: Equatable {
    case rest
    case hover
    case pressed
    case focused
    case selected
    case disabled
    case inFlight

    /// Resolves the shared interaction ladder in its single, documented order.
    /// A harness override is authoritative so every otherwise-unreachable state
    /// can be rendered deterministically offscreen.
    static func resolve(
        harnessState: ControlState? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isFocused: Bool = false,
        isPressed: Bool = false,
        isHovering: Bool = false,
        isInFlight: Bool = false
    ) -> ControlState {
        if let harnessState {
            return harnessState
        }
        if isInFlight {
            return .inFlight
        }
        if !isEnabled {
            return .disabled
        }
        if isSelected {
            return .selected
        }
        if isFocused {
            return .focused
        }
        if isPressed {
            return .pressed
        }
        if isHovering {
            return .hover
        }
        return .rest
    }
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole
    var color: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let foreground = color ?? role.foreground
        let styled =
            content
            .font(role.font)
            .tracking(role.tracking)
            .foregroundStyle(foreground)
        if let recorder = RenderOverrides.textRoleRecorder {
            styled.modifier(
                TextRoleRecordingModifier(
                    role: role,
                    foreground: foreground,
                    isBold: role.isBold,
                    recorder: recorder
                )
            )
        } else {
            styled
        }
    }
}

/// Keeps the `Text`-specific modifier chain intact so a colour or font-weight
/// applied after `.roleStyle(_:)` still overrides the role default, while adding
/// the harness-only geometry probe at the point where the text becomes a view.
struct RoleStyledText: View {
    private let text: Text
    private let role: TextRole
    private let foreground: Color
    private let isBold: Bool

    init(_ text: Text, role: TextRole) {
        self.text =
            text
            .font(role.font)
            .tracking(role.tracking)
            .foregroundStyle(role.foreground)
        self.role = role
        self.foreground = role.foreground
        self.isBold = role.isBold
    }

    private init(text: Text, role: TextRole, foreground: Color, isBold: Bool) {
        self.text = text
        self.role = role
        self.foreground = foreground
        self.isBold = isBold
    }

    @ViewBuilder
    var body: some View {
        if let recorder = RenderOverrides.textRoleRecorder {
            text.modifier(
                TextRoleRecordingModifier(
                    role: role,
                    foreground: foreground,
                    isBold: isBold,
                    recorder: recorder
                )
            )
        } else {
            text
        }
    }

    func foregroundStyle(_ color: Color) -> RoleStyledText {
        RoleStyledText(
            text: text.foregroundStyle(color),
            role: role,
            foreground: color,
            isBold: isBold
        )
    }

    func fontWeight(_ weight: Font.Weight?) -> RoleStyledText {
        RoleStyledText(
            text: text.fontWeight(weight),
            role: role,
            foreground: foreground,
            isBold: role.isBold || TextRole.isBold(weight)
        )
    }

    func monospacedDigit() -> RoleStyledText {
        RoleStyledText(
            text: text.monospacedDigit(),
            role: role,
            foreground: foreground,
            isBold: isBold
        )
    }
}

extension View {
    func roleStyle(_ role: TextRole) -> some View {
        modifier(TextRoleModifier(role: role))
    }

    /// A role plus a state colour, for a non-`Text` label (a `ButtonStyle`'s
    /// `configuration.label`) whose colour changes with the control's state.
    ///
    /// It has to be one modifier. `TextRoleModifier` sets `foregroundStyle`
    /// directly on the content, so a caller writing `.roleStyle(.micro)` and
    /// *then* `.foregroundStyle(state)` sets the outer value, which the role's
    /// inner one shadows: the state colour never lands, and the harness text
    /// recorder reports the role default rather than what actually rendered.
    /// `Text` needs no equivalent — `RoleStyledText.foregroundStyle(_:)` already
    /// rebuilds the chain in place.
    func roleStyle(_ role: TextRole, color: Color) -> some View {
        modifier(TextRoleModifier(role: role, color: color))
    }

    /// Adds the harness-only geometry probe to text whose existing explicit
    /// font, tracking and foreground must remain byte-for-byte unchanged.
    @ViewBuilder
    func recordTextRole(
        _ role: TextRole,
        foreground: Color
    ) -> some View {
        if let recorder = RenderOverrides.textRoleRecorder {
            modifier(
                TextRoleRecordingModifier(
                    role: role,
                    foreground: foreground,
                    isBold: role.isBold,
                    recorder: recorder
                )
            )
        } else {
            self
        }
    }
}

extension Text {
    func roleStyle(_ role: TextRole) -> RoleStyledText {
        RoleStyledText(self, role: role)
    }

    /// Canvas requires a concrete `Text`. The defaulted second parameter keeps
    /// the source spelling unchanged while contextual overload resolution picks
    /// this path only for `GraphicsContext.draw`.
    func roleStyle(_ role: TextRole, canvas: Bool = true) -> Text {
        font(role.font)
            .tracking(role.tracking)
            .foregroundStyle(role.foreground)
    }
}

enum VoiceourMetrics {
    enum Radius {
        static let window: CGFloat = 16
        static let card: CGFloat = 20
        static let row: CGFloat = 8
        static let chip: CGFloat = 6
        static let keycap: CGFloat = 4

        /// System `concentric(minimum:)` semantics for painted nested shapes.
        static func nested(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(outer - inset, 0)
        }
    }

    enum Column {
        static let rail: CGFloat = 176
        static let settingsLabel: CGFloat = 176
        static let glossaryCanonical: CGFloat = 176
        static let glossaryAliases: CGFloat = 320
        static let glossaryPolicy: CGFloat = 64
        static let glossaryScopeMin: CGFloat = 140
        static let rowAction: CGFloat = Control.medium
    }

    /// Capped column widths so pane content sits on a fixed measure instead of
    /// stretching edge-to-edge with the window. Every pane is left-flush against
    /// this column; tables get more room than simple label/control forms.
    enum Content {
        static let form: CGFloat = 760
        static let table: CGFloat = 940
        static let grid: CGFloat = 1360
    }

    enum Control {
        /// The one declared exception: compact status chips are marks, not controls.
        static let compactMark: CGFloat = 20
        static let mini: CGFloat = 24
        static let small: CGFloat = 28
        static let medium: CGFloat = 32
        static let large: CGFloat = 40
        static let pressedScale: CGFloat = 0.985

        enum Toggle {
            static let trackWidth: CGFloat = 42
            static let trackHeight: CGFloat = Control.mini
            static let knob: CGFloat = 20
            static let knobInset: CGFloat = Space.hair
            static let travel: CGFloat = trackWidth - knob - knobInset * 2
            static let hitWidth: CGFloat = 44
            static let hitHeight: CGFloat = Control.small
        }
    }

    /// Explicit widths for short, purpose-sized fields such as millisecond counters,
    /// so a four-digit number never claims the full content column. Fields that hold
    /// free-form text (URLs, model ids, keys) stay flexible up to the column.
    enum Field {
        static let short: CGFloat = 120
        static let medium: CGFloat = 280
    }

    enum Stroke {
        static let specular: CGFloat = 0.75
        static let hairline: CGFloat = 0.5

        static func hairline(_ contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? 1.0 : 0.5
        }

        static func selected(_ contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? 2.0 : 1.5
        }
    }

    enum Space {
        static let hair: CGFloat = 2
        static let titlebar: CGFloat = 32
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 40
    }

    enum Row {
        static let nav: CGFloat = 32
        static let table: CGFloat = 40
        static let settings: CGFloat = 44
        static let list: CGFloat = 64
    }

    enum Button {
        static let horizontal: CGFloat = 12
    }

    enum Chip {
        static let horizontal: CGFloat = 10
    }

    enum TextField {
        static let horizontal: CGFloat = 12
    }

    enum Icon {
        static let mark: CGFloat = 10
        static let row: CGFloat = 13
        static let nav: CGFloat = 13
        /// The navigation glyph's layout slot.
        static let navSlot: CGFloat = Space.lg
        static let empty: CGFloat = 48
    }

    enum Dot {
        static let live: CGFloat = 6
    }

    enum Shadow {
        /// The recording overlay island ONLY. Nothing on the content layer casts a shadow.
        static let overlayOuter: (color: Color, radius: CGFloat, y: CGFloat) =
            (Color.black.opacity(0.26), 18, 6)
        static let overlayInner: (color: Color, radius: CGFloat, y: CGFloat) =
            (Color.black.opacity(0.18), 4, 1)
    }

    enum Window {
        static let minWidth: CGFloat = Column.rail + Space.xl * 2 + Content.table
        static let minHeight: CGFloat = 560
        /// First-launch size. Width IS `minWidth`: the widest measure (the
        /// Glossary table) fits the region exactly and the form measure sits
        /// with symmetric 90pt gutters, so the console opens at its tightest
        /// legal, geometrically fitted size instead of floating its column in
        /// spare glass. Growing the window only grows the gutters evenly.
        static let defaultWidth: CGFloat = minWidth
        static let defaultHeight: CGFloat = 820
    }
}

enum VoiceourMotion {
    static let quickDuration: Double = 0.14
    static let standardDuration: Double = 0.18
    static let deliberateDuration: Double = 0.22
    static let livePulseDuration: Double = 1.6

    static let quick = Animation.easeInOut(duration: quickDuration)
    static let standard = Animation.easeInOut(duration: standardDuration)
    static let deliberate = Animation.easeInOut(duration: deliberateDuration)
    static let meter = Animation.easeOut(duration: 0.12)
}
