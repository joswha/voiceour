import SwiftUI
import VoiceCore

/// The console's pane contract in one place.
///
/// The label, eyebrow, subtitle, symbol, header measure, content inset, rail
/// placement and body used to be eight exhaustive switches over
/// `ConsoleSection` inside `ConsoleView`. Adding a pane meant finding and
/// editing every one of them, and missing one was a silent inconsistency rather
/// than a compile error. Registering a descriptor here covers all of it.
///
/// `ConsoleSection` stays the identity type: `ConsoleSectionTests` asserts
/// against it and the development-only `--console-section=<name>` flag parses
/// into it.

struct ConsolePaneDescriptor: Identifiable {
    let id: ConsoleSection
    let label: String
    let eyebrow: String
    let subtitle: String
    let symbol: String
    let headerMeasure: CGFloat?
    let contentBottomInset: CGFloat
    let railPlacement: ConsolePaneRailPlacement
    let headerMetadata: ConsolePaneHeaderMetadata
    let content: @MainActor (DictationCoordinator) -> AnyView
}

enum ConsolePaneRegistry {
    static let descriptors: [ConsolePaneDescriptor] = [
        ConsolePaneDescriptor(
            id: .home,
            label: "Home",
            eyebrow: "LOCAL · OVERVIEW",
            subtitle: "What speaking instead of typing buys you.",
            symbol: "gauge",
            headerMeasure: nil,
            contentBottomInset: 0,
            railPlacement: .primary,
            headerMetadata: .recentSessionCount(singular: "KEPT SESSION", plural: "KEPT SESSIONS"),
            content: { coordinator in
                AnyView(HomePane(coordinator: coordinator).scrollEdge(.hard, for: .top))
            }
        ),
        ConsolePaneDescriptor(
            id: .sessions,
            label: "Sessions",
            eyebrow: "LOCAL · HISTORY",
            subtitle: "Recent transcripts kept on this Mac.",
            symbol: "rectangle.stack",
            headerMeasure: nil,
            contentBottomInset: VoiceourMetrics.Space.xl,
            railPlacement: .standard,
            headerMetadata: .recentSessionCount(singular: "SESSION", plural: "SESSIONS"),
            content: { AnyView(SessionsPane(coordinator: $0)) }
        ),
        ConsolePaneDescriptor(
            id: .voice,
            label: "Voice",
            eyebrow: "LOCAL BACKEND",
            subtitle: "Local backend and audio input source.",
            symbol: "waveform",
            headerMeasure: VoiceourMetrics.Content.form,
            contentBottomInset: 0,
            railPlacement: .standard,
            headerMetadata: .backendID,
            content: { AnyView(VoicePane(coordinator: $0)) }
        ),
        ConsolePaneDescriptor(
            id: .glossary,
            label: "Glossary",
            eyebrow: "CANONICAL TERMS",
            subtitle: "Canonical terms and how speech-to-text detected them.",
            symbol: "text.book.closed",
            headerMeasure: VoiceourMetrics.Content.table,
            contentBottomInset: 0,
            railPlacement: .standard,
            headerMetadata: .glossaryCount,
            content: { AnyView(GlossaryPane(coordinator: $0)) }
        ),
        ConsolePaneDescriptor(
            id: .system,
            label: "System",
            eyebrow: "ACCESS",
            subtitle: "Microphone access and audio isolation.",
            symbol: "lock.shield",
            headerMeasure: VoiceourMetrics.Content.form,
            contentBottomInset: 0,
            railPlacement: .standard,
            headerMetadata: .systemReadiness,
            content: { AnyView(SystemPane(coordinator: $0)) }
        ),
        ConsolePaneDescriptor(
            id: .diagnostics,
            label: "Diagnostics",
            eyebrow: "LOCAL",
            subtitle: "Runtime facts about the local install.",
            symbol: "slider.horizontal.3",
            headerMeasure: VoiceourMetrics.Content.form,
            contentBottomInset: 0,
            railPlacement: .debug,
            headerMetadata: .diagnosticsStatus,
            content: { AnyView(DiagnosticsPane(coordinator: $0)) }
        ),
    ]

    static let primaryRailDescriptor: ConsolePaneDescriptor = {
        let matches = descriptors.filter { $0.railPlacement == .primary }
        precondition(matches.count == 1, "Console pane registry must have exactly one primary rail pane")
        return matches[0]
    }()

    static let standardRailDescriptors = descriptors.filter { $0.railPlacement == .standard }

    /// Appended after the standard entries when the rail reveals them, so a debug
    /// launch adds to the navigation rather than reordering it.
    static let debugRailDescriptors = descriptors.filter { $0.railPlacement == .debug }

    static func isDebug(_ section: ConsoleSection) -> Bool {
        descriptor(for: section).railPlacement == .debug
    }

    private static let descriptorsByID: [ConsoleSection: ConsolePaneDescriptor] = {
        precondition(
            descriptors.count == ConsoleSection.allCases.count,
            "Console pane registry must describe every section exactly once"
        )
        return Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }()

    static func descriptor(for section: ConsoleSection) -> ConsolePaneDescriptor {
        guard let descriptor = descriptorsByID[section] else {
            preconditionFailure("Missing console pane descriptor for \(section.rawValue)")
        }
        return descriptor
    }
}
