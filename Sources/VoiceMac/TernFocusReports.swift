import Foundation

/// `tern process @focused --json`, reduced to the three numbers binding needs.
struct TernProcessReport: Equatable, Sendable {
    /// The focused pane's block id.
    var pane: UInt64
    /// The pane's shell (`child.pid`), whose tty is the pane's root tty.
    var shellPid: Int32
    /// Leader of the pane terminal's foreground process group (`foreground.pid`).
    var foregroundPid: Int32
}

/// One pane of `tern inspect --json`.
struct TernPaneReport: Equatable, Sendable {
    /// The session file omp last announced to Tern for this pane, or nil.
    var ompSessionFile: String?
    /// True only when the pane has at least one identity hop and every hop is `local`.
    var isLocal: Bool
}

/// `tern inspect --json`, reduced to focus, window clients and pane identity.
struct TernInspectReport: Equatable, Sendable {
    /// Attached clients of kind `window`.
    var windowClientCount: Int
    /// True only when every window client has at least one identity hop and
    /// every hop is `local`. Vacuously true with no window client, which
    /// `windowClientCount` rules out on its own.
    var windowClientsAreLocal: Bool
    /// The focused block of the shown tab of the shown session, or nil unless
    /// exactly one session is shown, exactly one of its tabs is shown, and
    /// exactly one block of that tab is focused.
    var shownFocusedBlock: UInt64?
    var panes: [UInt64: TernPaneReport]
}

/// Decodes `tern` output into the reports above (docs/runtime.md › Agent session
/// binding).
///
/// The wire structs declare only the keys binding reads, so argv, working
/// directories, titles, hosts and user names in the same output are never
/// decoded or kept. Tern does not document its JSON as a stable schema: a
/// missing required key, a wrong type, a duplicate pane or bytes that are not
/// JSON all read as nil — no binding — and never as an error. Identity is
/// optional on the wire and fails closed: no identity is not local.
enum TernReports {
    static func process(from data: Data) -> TernProcessReport? {
        guard let wire = try? JSONDecoder().decode(ProcessWire.self, from: data) else { return nil }
        return TernProcessReport(pane: wire.pane, shellPid: wire.child.pid, foregroundPid: wire.foreground.pid)
    }

    static func inspect(from data: Data) -> TernInspectReport? {
        guard let wire = try? JSONDecoder().decode(InspectWire.self, from: data) else { return nil }

        let windowClients = wire.clients.filter { $0.kind == "window" }
        var panes: [UInt64: TernPaneReport] = [:]
        for pane in wire.panes {
            // Two entries for one pane are two answers; neither can be trusted.
            guard panes[pane.pane] == nil else { return nil }
            panes[pane.pane] = TernPaneReport(
                ompSessionFile: pane.ompSessionFile,
                isLocal: isLocal(pane.identity)
            )
        }
        return TernInspectReport(
            windowClientCount: windowClients.count,
            windowClientsAreLocal: windowClients.allSatisfy { isLocal($0.identity) },
            shownFocusedBlock: shownFocusedBlock(in: wire.sessions),
            panes: panes
        )
    }

    private static func shownFocusedBlock(in sessions: [SessionWire]) -> UInt64? {
        let shownSessions = sessions.filter(\.shown)
        guard shownSessions.count == 1 else { return nil }
        let shownTabs = shownSessions[0].tabs.filter(\.shown)
        guard shownTabs.count == 1 else { return nil }
        let focusedBlocks = shownTabs[0].blocks.filter(\.focused)
        guard focusedBlocks.count == 1 else { return nil }
        return focusedBlocks[0].id
    }

    private static func isLocal(_ identity: IdentityWire?) -> Bool {
        guard let hops = identity?.hops, !hops.isEmpty else { return false }
        return hops.allSatisfy { $0.method == "local" }
    }

    // MARK: Wire

    private struct ProcessWire: Decodable {
        struct Member: Decodable {
            var pid: Int32
        }

        var pane: UInt64
        var child: Member
        var foreground: Member
    }

    private struct InspectWire: Decodable {
        var sessions: [SessionWire]
        var panes: [PaneWire]
        var clients: [ClientWire]
    }

    private struct SessionWire: Decodable {
        struct Tab: Decodable {
            var shown: Bool
            var blocks: [Block]
        }

        struct Block: Decodable {
            var id: UInt64
            var focused: Bool
        }

        var shown: Bool
        var tabs: [Tab]
    }

    private struct PaneWire: Decodable {
        var pane: UInt64
        var ompSessionFile: String?
        var identity: IdentityWire?

        enum CodingKeys: String, CodingKey {
            case pane
            case ompSessionFile = "omp_session_file"
            case identity
        }
    }

    private struct ClientWire: Decodable {
        var kind: String
        var identity: IdentityWire?
    }

    private struct IdentityWire: Decodable {
        struct Hop: Decodable {
            var method: String?
        }

        var hops: [Hop]?
    }
}
