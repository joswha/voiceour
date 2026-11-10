import AppKit
import SwiftUI

// Harness instrumentation for these tokens lives in DesignTokenInstrumentation.swift.

/// The console's faces, one per `TextRole`. SF throughout; monospaced only where the content
/// is code-like (a term, a path, a model id) or the greeting's display voice, and figures get
/// monospaced digits so a changing count never jitters its column.
enum VoiceourTypography {
    /// Home's greeting only.
    static let hero = Font.system(size: 44, weight: .light, design: .monospaced)
    /// Settings page titles.
    static let display = Font.system(size: 26, weight: .semibold, design: .default)
    /// A detail page's title: the thread, the day, the topic the page is about.
    static let title = Font.system(size: 22, weight: .semibold, design: .default)
    /// A page's title when the page is about a code value: a glossary term's spelling.
    static let codeTitle = Font.system(size: 22, weight: .semibold, design: .monospaced)
    /// List-column titles, section headers, card titles, empty-state titles.
    static let heading = Font.system(size: 15, weight: .semibold, design: .default)
    /// The line a reader scans a list by: row titles, the sidebar's selected item.
    static let rowTitle = Font.system(size: 13, weight: .semibold, design: .default)
    /// Everything else, at the macOS default size.
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    /// Text set to be read rather than scanned: transcripts, notes, reading rows.
    static let reading = Font.system(size: 15, weight: .regular, design: .default)
    /// A code value on its own line: term names, paths, model ids.
    static let code = Font.system(size: 13, weight: .medium, design: .monospaced)
    /// Captions, row metadata, descriptions.
    static let meta = Font.system(size: 12, weight: .regular, design: .default)
    /// Group headers, pill words, counts, sidebar section headers. Sentence case.
    static let label = Font.system(size: 11, weight: .medium, design: .default)
    /// Keycaps and chart axes only: 10 pt is the macOS floor.
    static let micro = Font.system(size: 10, weight: .medium, design: .default)
    /// Stat tile values.
    static let figure = Font.system(size: 28, weight: .medium, design: .default).monospacedDigit()
    /// Small figures and meter-row values.
    static let figureSmall = Font.system(size: 17, weight: .semibold, design: .default).monospacedDigit()

    /// The extra leading between `reading` lines: a little air for paragraphs read whole,
    /// on top of the face's own line height.
    static let readingLineSpacing: CGFloat = 2
}

/// The console's type roles. A role fixes the face and the default colour, which comes from
/// the environment theme, so the same role reads correctly in every appearance.
enum TextRole {
    case hero
    case display
    case title
    case codeTitle
    case heading
    case rowTitle
    case body
    case reading
    case code
    case meta
    case label
    case micro
    case figure
    case figureSmall

    var font: Font {
        switch self {
        case .hero: VoiceourTypography.hero
        case .display: VoiceourTypography.display
        case .title: VoiceourTypography.title
        case .codeTitle: VoiceourTypography.codeTitle
        case .heading: VoiceourTypography.heading
        case .rowTitle: VoiceourTypography.rowTitle
        case .body: VoiceourTypography.body
        case .reading: VoiceourTypography.reading
        case .code: VoiceourTypography.code
        case .meta: VoiceourTypography.meta
        case .label: VoiceourTypography.label
        case .micro: VoiceourTypography.micro
        case .figure: VoiceourTypography.figure
        case .figureSmall: VoiceourTypography.figureSmall
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .hero: 44
        case .figure: 28
        case .display: 26
        case .title, .codeTitle: 22
        case .figureSmall: 17
        case .heading, .reading: 15
        case .rowTitle, .body, .code: 13
        case .meta: 12
        case .label: 11
        case .micro: 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .hero: .light
        case .display, .title, .codeTitle, .heading, .rowTitle, .figureSmall: .semibold
        case .code, .label, .micro, .figure: .medium
        case .body, .reading, .meta: .regular
        }
    }

    /// Extra leading between lines; only `reading` sets any.
    var lineSpacing: CGFloat {
        self == .reading ? VoiceourTypography.readingLineSpacing : 0
    }

    var isBold: Bool {
        Self.isBold(weight)
    }

    static func isBold(_ weight: Font.Weight?) -> Bool {
        weight == .bold || weight == .heavy || weight == .black
    }

    /// The role's default colour in `theme`: text1 for what is read, text2 for what
    /// describes it, text3 for keycaps and axes.
    func foreground(in theme: Theme) -> Color {
        switch self {
        case .hero, .display, .title, .codeTitle, .heading, .rowTitle, .body, .reading, .code, .figure,
            .figureSmall:
            theme.text1
        case .meta, .label:
            theme.text2
        case .micro:
            theme.text3
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
    @Environment(\.theme) private var theme

    let role: TextRole
    var color: Color?

    func body(content: Content) -> some View {
        let foreground = color ?? role.foreground(in: theme)
        content
            .font(role.font)
            .foregroundStyle(foreground)
            .lineSpacing(for: role)
            .recordTextRole(role, foreground: foreground)
    }
}

/// Keeps the `Text`-specific modifier chain intact so a colour or font-weight
/// applied after `.roleStyle(_:)` still overrides the role default, while adding
/// the harness-only geometry probe at the point where the text becomes a view.
struct RoleStyledText: View {
    @Environment(\.theme) private var theme

    /// The text in the role's face, still uncoloured. `Text` keeps the first
    /// foreground it is given, so the colour is applied once, in `body`, and
    /// `foregroundStyle(_:)` replaces it rather than stacking a second one the
    /// first would shadow.
    private let base: Text
    private let role: TextRole
    /// An explicit colour; nil paints the role's default from the environment theme,
    /// which is only known in `body`.
    private let foreground: Color?

    init(_ text: Text, role: TextRole) {
        self.init(base: text.font(role.font), role: role, foreground: nil)
    }

    private init(base: Text, role: TextRole, foreground: Color?) {
        self.base = base
        self.role = role
        self.foreground = foreground
    }

    var body: some View {
        let resolved = foreground ?? role.foreground(in: theme)
        base.foregroundStyle(resolved)
            .lineSpacing(for: role)
            .recordTextRole(role, foreground: resolved)
    }

    func foregroundStyle(_ color: Color) -> RoleStyledText {
        RoleStyledText(base: base, role: role, foreground: color)
    }

    func monospacedDigit() -> RoleStyledText {
        RoleStyledText(base: base.monospacedDigit(), role: role, foreground: foreground)
    }
}

@MainActor
extension View {
    /// The role's leading, and nothing for roles that set none, so a caller's own
    /// `lineSpacing` further out still reaches every other role.
    @ViewBuilder
    fileprivate func lineSpacing(for role: TextRole) -> some View {
        if role.lineSpacing > 0 {
            lineSpacing(role.lineSpacing)
        } else {
            self
        }
    }
}

@MainActor
extension View {
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

@MainActor
extension Text {
    func roleStyle(_ role: TextRole) -> RoleStyledText {
        RoleStyledText(self, role: role)
    }
}

/// Metrics shared beyond the kit (`Kit.Metrics` owns the console's own measures): the 4 pt
/// spacing ladder the recording island also lays out on, the window's sizes, and a few
/// purpose-sized widths.
enum VoiceourMetrics {
    enum Control {
        /// The smallest interactive height: the lint's reference control.
        static let mini: CGFloat = 24
    }

    /// The explicit width for a short, purpose-sized field such as a millisecond
    /// counter, so a four-digit number never claims the full content column.
    /// Fields that hold free-form text (URLs, model ids, keys) stay flexible up
    /// to the column.
    enum Field {
        static let short: CGFloat = 120
        /// A slider's trailing value readout: wide enough for "10700 K" in monospaced
        /// digits, so every Island slider in a column ends on the same edge whatever it reads.
        static let readout: CGFloat = 64
    }

    enum Stroke {
        /// A drawn hairline, heavier under Increase Contrast.
        static func hairline(_ contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? 1.0 : 0.5
        }
    }

    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Icon {
        /// A glyph set inside a line of small type.
        static let mark: CGFloat = 10
    }

    enum Window {
        /// The smallest window the console lays out in: the Journal's sidebar folded to its
        /// rail, the list column and a page still wide enough to read.
        static let minWidth: CGFloat = 800
        static let minHeight: CGFloat = 560
        /// First-launch size: sidebar, list and page side by side, with the page's reading
        /// measure inside its padding.
        static let defaultWidth: CGFloat = 1164
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
