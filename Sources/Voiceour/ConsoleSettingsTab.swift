import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Settings: everything the reader can change about dictation, then everything
/// this Mac has to allow for those choices to hold, then what is kept on disk
/// and how to unkeep it.
///
/// One section per page, chosen in a sidebar the way System Settings is read.
/// The sidebar keeps the contract order — preferences lead and readouts
/// follow, because that is the order the questions arrive in: a reader opens this
/// tab to change something, and only reads the readiness pages when what they
/// changed did not happen. A readiness page whose readout is not healthy marks
/// its sidebar item, so the reason a switch had no effect is visible from the
/// page the switch is on.
///
/// Section names stay distinct on purpose. **Dictation** owns the round trip
/// (trigger, hands-free stop, the cleanup pass before insertion) and **Audio**
/// owns the sound hardware around a capture — which microphone records, and the
/// one thing capture does to the rest of the Mac — while **Capture** owns the OS
/// grants the key tap and synthetic paste depend on. Two sections both called
/// "Capture" would leave a heading that is a lie for half its rows.
///
/// **Appearance** and **Island** are the two preferences about looks, and they
/// stay apart: Appearance themes the console and the menu, while the recording
/// island keeps its own looks. Island is the only preference drawn as a picture:
/// how the recording island looks, previewed in a showroom of its own rather
/// than on the real panel, because a visible island means a live microphone.
///
/// Every OS grant this app asks for is reported exactly once, in the row for the
/// capability it gates — microphone by **Microphone**, Accessibility by **Fn/Globe
/// capture** for the key tap and by **Insertion** for synthetic paste. There is no
/// second permissions section restating those grants: a grant reported twice is a
/// grant a reader has to reconcile. Remediation rides the row it remedies, and
/// only when the grant is actually missing.
struct ConsoleSettingsTab: View {
    private let coordinator: DictationCoordinator

    /// Real TCC state in production. The offscreen UI harness pins a fixed
    /// snapshot (`RenderOverrides.permissions`) so a golden never encodes this
    /// Mac's privacy grants, and so both the granted and the denied treatments can
    /// be captured.
    private let permissions: PermissionsChecking = RenderOverrides.permissions ?? SystemPermissions()
    private var a11y = A11y()

    /// The page on screen. The tab opens on Dictation every time and never
    /// persists the choice: the page a reader left last time is rarely the
    /// question they open Settings with next.
    @State private var section: SettingsSection = .dictation
    /// True while the tab is narrower than `Kit.Metrics.railBelow`, so the sidebar
    /// folds to its rail of glyphs and the page keeps its reading width.
    @State private var isNarrow = false

    @State private var microphone: PermissionState = .notDetermined
    @State private var synthPaste: PermissionState = .notDetermined
    @State private var accessibility: PermissionState = .notDetermined

    /// The input devices the microphone picker offers. Real HAL enumeration in
    /// production; the offscreen harness pins a fixed list
    /// (`RenderOverrides.availableMicrophones`) so a golden never encodes which
    /// microphones this Mac has. Held here because the Audio item's attention
    /// reads it as well as the Audio page.
    @State private var availableMicrophones: [CoreAudioInputDevice.AvailableMicrophone] = []

    /// The page toast every copy confirms through.
    @State private var flash = Kit.Flash()
    /// The erases in flight, held by the tab so a clear keeps its guard and its
    /// outcome while the reader visits another page.
    @State private var erasure = SettingsErasure()

    /// The pages this launch offers. Backend appears only with the debug panes:
    /// Granite is the one recognizer a release launch selects, so a release build
    /// has nothing to choose between.
    private static let sections = SettingsSection.allCases.filter {
        $0 != .backend || LaunchOptions.showsDebugPanes
    }

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Kit.Screen {
            HStack(spacing: 0) {
                // The sidebar sizes itself: its column, or its rail while compact.
                sidebar
                    .environment(\.kitCompactControls, isNarrow)

                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .kitToast(flash, identifier: "settings.copied")
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < Kit.Metrics.railBelow
        } action: { narrow in
            isNarrow = narrow
        }
        // The window's default size is this tab's ideal size, so an update anywhere in the
        // tab never makes the console's tab view measure the whole page for it. Without it,
        // every Island control step re-measured every row: measured at about 12 ms of the
        // 22 ms a step cost with all four Island folds open. Proposed sizes, and with them
        // the window's minimum and every laid-out row, are unchanged.
        .frame(
            idealWidth: VoiceourMetrics.Window.defaultWidth,
            idealHeight: VoiceourMetrics.Window.defaultHeight
        )
        .onAppear {
            coordinator.refreshBackendHealth()
            refreshPermissions(animated: false)
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions(animated: true)
            refreshMicrophones()
        }
        .onDisappear {
            flash.dismiss()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Kit.Sidebar {
            ForEach(Self.sections) { item in
                Kit.SidebarItem(
                    item.title,
                    systemImage: item.systemImage,
                    isSelected: section == item,
                    attention: attention(for: item)
                ) {
                    section = item
                }
                .accessibilityIdentifier("settings.section.\(item.rawValue)")
            }
        }
    }

    /// The worst rung among a page's readouts, for the pages that hold readouts.
    /// A neutral or healthy page carries nothing, so an item that is marked is
    /// one a reader should open.
    private func attention(for item: SettingsSection) -> Kit.SidebarItem.Attention? {
        let severities: [ConsoleReadout.Severity]
        switch item {
        case .readiness:
            severities = [
                ConsoleReadiness.backend(coordinator).severity,
                ConsoleReadiness.microphone(coordinator, microphone).severity,
            ]
        case .capture:
            severities = [
                ConsoleReadiness.capture(accessibility).severity,
                ConsoleReadiness.insertion(synthPaste).severity,
            ]
        case .audio:
            severities = SettingsAudioPage.severities(coordinator, availableMicrophones: availableMicrophones)
        case .dictation, .model, .backend, .appearance, .island, .privacy, .memory, .danger:
            return nil
        }
        if severities.contains(.crit) { return .critical }
        if severities.contains(.warn) { return .caution }
        return nil
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch section {
        case .dictation:
            SettingsDictationPage(coordinator: coordinator)
        case .audio:
            SettingsAudioPage(coordinator: coordinator, availableMicrophones: availableMicrophones)
        case .model:
            SettingsModelPage()
        case .backend:
            SettingsBackendPage(coordinator: coordinator)
        case .appearance:
            SettingsAppearancePage(coordinator: coordinator)
        case .island:
            SettingsPage(.island) {
                ConsoleIslandSection(coordinator: coordinator)
            }
        case .readiness:
            SettingsReadinessPage(coordinator: coordinator, microphone: microphone)
        case .capture:
            SettingsCapturePage(accessibility: accessibility, synthPaste: synthPaste)
        case .privacy:
            SettingsPrivacyPage(
                coordinator: coordinator,
                microphone: microphone,
                accessibility: accessibility,
                synthPaste: synthPaste,
                flash: flash
            )
        case .memory:
            SettingsMemoryPage(coordinator: coordinator, flash: flash)
        case .danger:
            SettingsDangerPage(coordinator: coordinator, erasure: erasure)
        }
    }

    // MARK: Refresh

    /// The user returning from System Settings is this tab's most important state
    /// change: three readouts change word and hue and up to three remediation
    /// buttons leave. Animating it means the grant visibly resolves instead of
    /// jump-cutting the rows that carry them.
    private func refreshPermissions(animated: Bool) {
        guard animated, !a11y.reduceMotion else {
            microphone = permissions.microphone()
            synthPaste = permissions.synthPaste()
            accessibility = permissions.accessibility()
            return
        }
        withAnimation(VoiceourMotion.deliberate) {
            microphone = permissions.microphone()
            synthPaste = permissions.synthPaste()
            accessibility = permissions.accessibility()
        }
    }

    private func refreshMicrophones() {
        availableMicrophones = RenderOverrides.availableMicrophones ?? CoreAudioInputDevice.availableMicrophones()
    }
}

/// One Settings page, in the order the sidebar lists them. The raw value names
/// the sidebar item's identifier, `settings.section.<rawValue>`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation
    case audio
    case model
    case backend
    case appearance
    case island
    case readiness
    case capture
    case privacy
    case memory
    case danger

    var id: Self { self }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .audio: "Audio"
        case .model: "Model"
        case .backend: "Backend"
        case .appearance: "Appearance"
        case .island: "Island"
        case .readiness: "Readiness"
        case .capture: "Capture"
        case .privacy: "Privacy"
        case .memory: "Memory"
        case .danger: "Danger"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "mic"
        case .audio: "speaker.wave.2"
        case .model: "cpu"
        case .backend: "server.rack"
        case .appearance: "circle.lefthalf.filled"
        case .island: "capsule"
        case .readiness: "checkmark.seal"
        case .capture: "keyboard"
        case .privacy: "hand.raised"
        case .memory: "brain"
        case .danger: "trash"
        }
    }

    /// What the page governs, in one plain sentence under its title.
    var sentence: String {
        switch self {
        case .dictation:
            "How a dictation starts, when it stops, and what happens to the words before they are inserted."
        case .audio:
            "Which microphone records, and what the rest of the Mac's sound does while it does."
        case .model:
            "The speech model Voiceour transcribes with, on this Mac."
        case .backend:
            "The recognizer a development launch transcribes with."
        case .appearance:
            "How the console and the menu look. The recording island keeps its own looks."
        case .island:
            "How the recording island looks while you dictate."
        case .readiness:
            "Whether the speech model and the microphone are ready for a real dictation."
        case .capture:
            "The macOS permissions the Fn/Globe key and pasting depend on."
        case .privacy:
            "What Voiceour keeps on this Mac, and how dictations link to your agent sessions."
        case .memory:
            "The folder of dictations Voiceour keeps for coding agents, and how its entries are sorted."
        case .danger:
            "Erase what Voiceour keeps. Each erase asks before it runs."
        }
    }
}
