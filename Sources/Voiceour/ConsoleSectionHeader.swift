import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

struct SectionHeader: View {
    var section: ConsoleSection
    var coordinator: DictationCoordinator

    private var a11y = A11y()

    /// The same grant source the System pane reads — the harness seam offscreen,
    /// real TCC in production — snapshotted on the same events the pane snapshots
    /// on, so the chip and the rows beneath it cannot report different grants.
    /// Calling into TCC from a computed property would re-enter it on every
    /// layout pass, which is why `SystemPane` holds a snapshot and so does this.
    private let permissions: PermissionsChecking = RenderOverrides.permissions ?? SystemPermissions()
    @State private var microphone: PermissionState = .notDetermined
    @State private var synthPaste: PermissionState = .notDetermined
    @State private var accessibility: PermissionState = .notDetermined

    init(section: ConsoleSection, coordinator: DictationCoordinator) {
        self.section = section
        self.coordinator = coordinator
    }

    /// The trailing slot, typed by what it has to say rather than by one shape
    /// that says everything. Chip grammar — tinted fill, hairline rim, control
    /// height, parked where macOS puts toolbar buttons — is a state mark, and
    /// spending it on `9 KEPT SESSIONS` dressed a static label as a control.
    private enum Metadata {
        /// An inert fact: a count, a backend id. Plain tracked mono on the header
        /// substrate, on the eyebrow's baseline and in the eyebrow's tier.
        case fact(String)
        /// A live state readout. The chip's tint and rim ARE the mark.
        case state(String, StatusChip.Mode)
        /// Nothing worth saying. A `0 KEPT SESSIONS` plate 400pt above
        /// `No dictations yet` contradicts the empty state it heads;
        /// `SessionsPane` suppresses its zero TOTALS card for the same reason.
        case silent
    }

    private var metadata: Metadata {
        switch section.descriptor.headerMetadata {
        case .recentSessionCount(let singular, let plural):
            return count(coordinator.recentSessions.count, singular, plural)
        case .backendID:
            return .fact(coordinator.settings.asrBackend.uppercased())
        case .glossaryCount:
            return count(coordinator.settings.glossary.count, "TERM", "TERMS")
        case .systemReadiness:
            return systemReadiness
        case .diagnosticsStatus:
            // Was the literal "LOCAL" — the pane's own eyebrow, printed twice on one
            // baseline. The pane exists to report runtime facts, so the slot reports
            // the headline one, in the words the pane's own Status row uses.
            switch coordinator.backendHealth?.backendStatus {
            case .ready:
                return .state("READY", .ok)
            case .modelMissing:
                return .state("MODEL MISSING", .warn)
            case .backendUnavailable:
                return .state("BACKEND UNAVAILABLE", .warn)
            case nil:
                return .state("UNKNOWN", .warn)
            }
        }
    }

    private func count(_ value: Int, _ singular: String, _ plural: String) -> Metadata {
        switch value {
        case 0: .silent
        case 1: .fact("1 \(singular)")
        default: .fact("\(value) \(plural)")
        }
    }

    /// Worst-of over exactly what the System pane renders beneath this header.
    /// The slot used to answer SYSTEM READY unless system audio happened to be
    /// muted, so a pane reading CHECK NEEDED / DENIED / PASSIVE FALLBACK /
    /// COPY-ONLY RISK under three DENIED permission tiles was headed by a green
    /// chip that no permission could perturb. Diagnostics below already derives
    /// from real state; this is the same, over more inputs. The order IS the
    /// severity ladder, which is what keeps the muted-audio note a note.
    private var systemReadiness: Metadata {
        let grants = [microphone, synthPaste, accessibility]
        if grants.contains(.denied) {
            return .state("PERMISSIONS NEEDED", .crit)
        }
        switch backendReadiness {
        case .checking:
            // The probe starts from the pane's own onAppear, so "no verdict yet"
            // is a loading state, not a fault — the Backend row paints it neutral
            // and so does this.
            return .state("CHECKING…", .neutral)
        case .needsAttention:
            return .state("CHECK NEEDED", .warn)
        case .ready:
            break
        }
        if grants.contains(.notDetermined) {
            // Not a wall, but not clear either: FN / GLOBE CAPTURE and INSERTION
            // both read a fallback until the grant actually lands.
            return .state("PERMISSIONS PENDING", .warn)
        }
        if coordinator.isSystemAudioMuted {
            return .state("AUDIO MUTED", .warn)
        }
        return .state("SYSTEM READY", .ok)
    }

    private enum BackendReadiness {
        case ready
        case checking
        case needsAttention
    }

    /// Projects `SystemPane.backendReadout` onto the three readiness states below:
    /// the dev backend is `.ready`, while both warning readouts collapse to `.needsAttention`.
    private var backendReadiness: BackendReadiness {
        if coordinator.activeBackend == "fake" {
            return .ready
        }
        if coordinator.backendHealth?.cacheOk == true, coordinator.backendHealth?.ready == true {
            return .ready
        }
        if coordinator.backendHealth == nil, coordinator.backendHealthError == nil {
            return .checking
        }
        return .needsAttention
    }

    private func refreshGrants(animated: Bool) {
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

    /// The trailing slot, always `Control.mini` tall.
    ///
    /// A chip is a 24pt plate riding a 14pt eyebrow line, so under
    /// `.firstTextBaseline` it — not the eyebrow — is what sets the header
    /// block's top edge. Reserving that same height when the slot holds bare
    /// type or nothing keeps the eyebrow, title and subtitle of all seven panes
    /// on one y; without it, navigating from a counted pane to a state pane
    /// shifts the whole block 5pt.
    @ViewBuilder
    private var trailing: some View {
        switch metadata {
        case .fact(let text):
            Text(text)
                .roleStyle(.micro)
                .foregroundStyle(a11y.textLow)
                .lineLimit(1)
                .frame(height: VoiceourMetrics.Control.mini)
        case .state(let text, let mode):
            StatusChip(label: text, mode: mode)
        case .silent:
            Text(verbatim: " ")
                .roleStyle(.micro)
                .hidden()
                .frame(width: 0, height: VoiceourMetrics.Control.mini)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.xl) {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                Text(section.eyebrow)
                    .roleStyle(.eyebrow)

                Text(section.label)
                    .roleStyle(.title)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                Text(section.subtitle)
                    .roleStyle(.caption)
                    .foregroundStyle(VoiceourPalette.Text.mid)
                    .lineLimit(1)
            }

            Spacer(minLength: VoiceourMetrics.Space.lg)

            trailing
        }
        // The header caps to the same measure as the body beneath it and centres
        // with it, so both declare one left AND one right edge at any window
        // width. Uncapped panes fall through to the region, where centring a
        // maxWidth-infinity frame is the identity.
        .frame(maxWidth: section.headerMeasure ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, VoiceourMetrics.Space.titlebar)
        // SOLE owner of the header-to-content gap. Every per-pane scroll top padding
        // is deleted; two owners produced three different gaps (32 / 16 / 18pt).
        .padding(.bottom, VoiceourMetrics.Space.xl)
        .onAppear { refreshGrants(animated: false) }
        // The pane re-reads TCC from its own onAppear every time it is navigated
        // to; this header is mounted once for the life of the window, so it takes
        // the same reading at the same moment.
        .onChange(of: section) { _, _ in refreshGrants(animated: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshGrants(animated: true)
        }
    }
}
