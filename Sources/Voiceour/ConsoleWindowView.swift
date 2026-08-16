import AppKit
import SwiftUI

/// The console's four destinations.
///
/// Identity type for the window's tab selection and for the development-only
/// `--console-section=<name>` deep link, so both spell a destination the same
/// way. Ordered as the tab bar renders them.
enum ConsoleTab: String, CaseIterable, Hashable {
    case general
    case glossary
    case history
    case system

    var label: String {
        switch self {
        case .general: "General"
        case .glossary: "Glossary"
        case .history: "History"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .glossary: "text.book.closed"
        case .history: "clock.arrow.circlepath"
        case .system: "lock.shield"
        }
    }
}

/// The console window: a native `TabView` over four grouped `Form`s.
///
/// This replaces a bespoke shell — a left rail, a pane registry, glass window
/// chrome and a private row/segment/confirm component library — that spent
/// ~2200 lines drawing surfaces AppKit already draws, and drawing them in a way
/// VoiceOver and Full Keyboard Access had to be taught about row by row. The
/// content is unchanged; every setting, readout, remediation and destructive
/// action the rail's five panes carried is on one of these four tabs.
///
/// The window keeps its scene id (`main`), so the menu-bar item's
/// `openWindow(id:)` and the `--show-console` launch notification still reach
/// it, and it keeps the appearance the user chose: the panes this replaces
/// pinned a dark scheme because their palette had no light values, which is
/// exactly the kind of override a native window has no business making.
struct ConsoleWindowView: View {
    var coordinator: DictationCoordinator
    @State private var tab: ConsoleTab
    private let externalTab: Binding<ConsoleTab>?
    /// True only for the ordinary app window (no explicit tab): harness scenes,
    /// flows and `--console-section=` launches pass an explicit tab and must
    /// never write the user's (or the developer's) stored selection.
    private let persistsSelection: Bool

    /// `initialTab` nil means "no override": the window opens on the last-used
    /// tab, falling back to `.general` on first launch, and persists every
    /// selection change.
    init(coordinator: DictationCoordinator, initialTab: ConsoleTab?) {
        self.coordinator = coordinator
        _tab = State(initialValue: initialTab ?? Self.storedTab() ?? .general)
        externalTab = nil
        persistsSelection = (initialTab == nil)
    }

    /// The offscreen flow runner cannot make its prohibited, never-key window
    /// active, so AppKit refuses both AX press and synthetic mouse selection on
    /// native tab buttons. This binding keeps the real TabView hierarchy under
    /// test while the runner changes the same selection value the control owns.
    init(coordinator: DictationCoordinator, selection: Binding<ConsoleTab>) {
        self.coordinator = coordinator
        _tab = State(initialValue: selection.wrappedValue)
        externalTab = selection
        persistsSelection = false
    }

    // MARK: Tab persistence

    static let lastTabKey = "console.last-tab"

    static func storedTab(in defaults: UserDefaults = .standard) -> ConsoleTab? {
        defaults.string(forKey: lastTabKey).flatMap(ConsoleTab.init(rawValue:))
    }

    static func storeTab(_ tab: ConsoleTab, in defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: lastTabKey)
    }

    var body: some View {
        TabView(selection: externalTab ?? $tab) {
            ConsoleGeneralTab(coordinator: coordinator)
                .tabItem { tabLabel(.general) }
                .tag(ConsoleTab.general)

            ConsoleGlossaryTab(coordinator: coordinator)
                .tabItem { tabLabel(.glossary) }
                .tag(ConsoleTab.glossary)

            ConsoleHistoryTab(coordinator: coordinator)
                .tabItem { tabLabel(.history) }
                .tag(ConsoleTab.history)

            ConsoleSystemTab(coordinator: coordinator)
                .tabItem { tabLabel(.system) }
                .tag(ConsoleTab.system)
        }
        .onChange(of: tab) {
            guard persistsSelection else { return }
            Self.storeTab(tab)
        }
        .onAppear {
            // `.accessory` (no Dock icon, absent from Cmd+Tab — see
            // VoiceourApp.init) is right for the idle menu-bar-only state, but
            // this console is a real window a user expects to treat like a
            // normal app window: reachable via Cmd+Tab, not swallowed behind
            // other windows with no way back except re-clicking the menu bar
            // icon. Promote to `.regular` for as long as this window is open;
            // `onDisappear` drops back to `.accessory` once it actually closes.
            guard Self.managesActivationPolicy else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            guard Self.managesActivationPolicy else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// One tab item, with an identifier of our own.
    ///
    /// `Label(_:systemImage:)` alone leaves the SF Symbol name as the tab's
    /// accessibility identifier (`slider.horizontal.3`), so a flow selecting a tab
    /// would be selecting on a glyph choice — rename the icon and the selector
    /// breaks. `console.tab.<case>` is the tab's identity.
    private func tabLabel(_ tab: ConsoleTab) -> some View {
        Label(tab.label, systemImage: tab.symbol)
            .accessibilityIdentifier("console.tab.\(tab.rawValue)")
    }

    /// False for the two callers that must never take the user's screen: the
    /// offscreen UI harness, which pins `.prohibited` in
    /// `UIHarnessRuntime.prepareProcess()` and hosts this very view offscreen,
    /// and any launch passing `--no-activate`. Both branches above are no-ops
    /// then, so the harness cannot promote the app to `.regular`, and teardown
    /// cannot demote `.prohibited` to the self-activating `.accessory`. A normal
    /// user launch matches neither and behaves as before.
    @MainActor
    private static var managesActivationPolicy: Bool {
        !LaunchOptions.suppressActivation && NSApp.activationPolicy() != .prohibited
    }
}

// MARK: - Shared row shapes

/// A control (or a `LabeledContent` readout) and the sentence that explains it.
///
/// The caption is a *sibling* of the control, never part of its accessibility
/// label: a settings row that folded its explanation into the control's label
/// would make every flow that addresses a control by label match a paragraph.
/// One primitive so the gap between a control and its explanation is decided
/// once for the whole window.
struct ConsoleRow<Content: View>: View {
    private let caption: String?
    private let captionColor: Color?
    private let content: Content

    init(
        caption: String? = nil,
        captionColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.caption = caption
        self.captionColor = captionColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            content
            if let caption {
                ConsoleCaption(caption, color: captionColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The window's explanatory voice: one sentence, never truncated mid-clause.
struct ConsoleCaption: View {
    private let text: String
    private let color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color ?? Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A state word and the severity it carries.
///
/// The severity ladder is the one the System pane kept, unchanged:
///
/// * `.crit` — the app cannot do its job at all. Microphone denied is the only
///   state in this window that qualifies: with no audio in, no amount of
///   retrying produces a transcript.
/// * `.warn` — it works, degraded. A key tap macOS also reacts to, a transcript
///   that lands on the clipboard instead of in the field, a model that
///   cold-loads on first use, a grant that has not been asked for yet.
///
/// Accessibility denied is deliberately *not* `.crit`. It is the default state
/// of a freshly installed app (`AXIsProcessTrusted()` is false until the user
/// adds the app), and both capabilities it gates degrade rather than stop: the
/// Fn tap falls back to passive, insertion falls back to copy-only. Painting a
/// fresh install crimson would flatten the ladder from the other end.
///
/// Differentiate Without Color adds the mode's symbol, exactly as the glass
/// chip this replaces did — the state word is already a non-colour carrier, and
/// the symbol is the second one for readers who need it.
struct ConsoleStateMark: View {
    enum Severity {
        case neutral
        case ok
        case warn
        case crit

        var symbol: String? {
            switch self {
            case .neutral: nil
            case .ok: "checkmark"
            case .warn: "exclamationmark.triangle.fill"
            case .crit: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .neutral: .secondary
            case .ok: .green
            case .warn: .orange
            case .crit: .red
            }
        }
    }

    private let label: String
    private let severity: Severity
    private var a11y = A11y()

    init(_ label: String, _ severity: Severity) {
        self.label = label
        self.severity = severity
    }

    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.xs) {
            if a11y.differentiateWithoutColor, let symbol = severity.symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(severity.color)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(label)
    }
}

/// The app's one global gesture, stated wherever a reader needs to know how to
/// start. `KeyboardShortcutsBinder` toggles on RELEASE of a solitary Fn/Globe
/// tap, so the verb is TAP: holding Fn and speaking starts nothing.
///
/// The word `or` carries its own weight — it is the only thing distinguishing
/// "Fn or Globe" from "Fn then Globe".
struct ConsoleHotkeyHint: View {
    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.xs) {
            Text("Tap")
            Text("Fn").fontWeight(.semibold)
            Text("or")
            Text("Globe").fontWeight(.semibold)
            Text("to dictate")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tap Fn or Globe to dictate")
    }
}
