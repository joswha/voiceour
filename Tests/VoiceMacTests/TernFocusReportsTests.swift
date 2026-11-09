import Foundation
import Testing

@testable import VoiceMac

private let localHop = #"{"principal":"vlad","method":"local","from":"","host":"Mac","user":"vlad"}"#
private let remoteHop = #"{"principal":"vlad","method":"ssh","from":"10.0.0.2","host":"server","user":"vlad"}"#

/// Fixtures follow the shapes `tern` 0.9.13 prints, keys Voiceour never decodes
/// (argv, cwd, titles, hosts) included, so the tests also prove those are ignored.
@Suite("TernReports")
struct TernFocusReportsTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func block(_ id: UInt64, focused: Bool) -> String {
        #"{"id":\#(id),"program":"/bin/zsh","cwd":"/Users/v","title":"zsh","focused":\#(focused)}"#
    }

    private func tab(shown: Bool, blocks: [String]) -> String {
        #"{"id":1,"number":1,"name":null,"shown":\#(shown),"zoomed":false,"blocks":[\#(blocks.joined(separator: ","))],"splits":{}}"#
    }

    private func session(shown: Bool, tabs: [String]) -> String {
        #"{"id":1,"name":"Default","shown":\#(shown),"tabs":[\#(tabs.joined(separator: ","))]}"#
    }

    private func pane(_ id: UInt64, ompSessionFile: String? = nil, hops: [String]? = [localHop]) -> String {
        let file = ompSessionFile.map { #""\#($0)""# } ?? "null"
        let identity = hops.map { #","identity":{"hops":[\#($0.joined(separator: ","))]}"# } ?? ""
        return
            #"{"pane":\#(id),"program":"/bin/zsh","args":["-l"],"cwd":"/Users/v","title":"t","omp_session_file":\#(file)\#(identity),"quiet_ms":5,"working":false}"#
    }

    private func client(_ kind: String, hops: [String]? = [localHop]) -> String {
        let identity = hops.map { #","identity":{"hops":[\#($0.joined(separator: ","))]}"# } ?? ""
        return #"{"conn":2,"window":"","kind":"\#(kind)","since":1762700000000\#(identity)}"#
    }

    private func inspect(sessions: [String], panes: [String], clients: [String]) -> Data {
        data(
            #"{"sessions":[\#(sessions.joined(separator: ","))],"detached":[],"panes":[\#(panes.joined(separator: ","))],"clients":[\#(clients.joined(separator: ","))]}"#
        )
    }

    /// One local window showing the second of two tabs; every tab has its own
    /// focused block, and only the shown tab's counts.
    private var oneWindow: Data {
        inspect(
            sessions: [
                session(shown: false, tabs: [tab(shown: true, blocks: [block(1, focused: true)])]),
                session(
                    shown: true,
                    tabs: [
                        tab(shown: false, blocks: [block(10, focused: true)]),
                        tab(shown: true, blocks: [block(20, focused: false), block(21, focused: true)]),
                    ]
                ),
            ],
            panes: [
                pane(20),
                pane(21, ompSessionFile: "/Users/v/.omp/agent/sessions/-x/2026-11-09T17-51-32-000Z_01a1c16f.jsonl"),
            ],
            clients: [client("cli"), client("window")]
        )
    }

    @Test func processReportReadsPaneShellAndForeground() throws {
        let json = #"""
            {"pane":884763263026,"child":{"pid":60121,"name":"zsh","argv":["-zsh"],"cwd":"/Users/v"},
             "group":61208,"foreground":{"pid":61208,"name":"claude","argv":["claude","secret prompt"],"cwd":"/Users/v"}}
            """#
        let report = try #require(TernReports.process(from: data(json)))
        #expect(report == TernProcessReport(pane: 884_763_263_026, shellPid: 60121, foregroundPid: 61208))
    }

    @Test func processReportWithoutForegroundIsNil() {
        let json = #"{"pane":1,"child":{"pid":2}}"#
        #expect(TernReports.process(from: data(json)) == nil)
    }

    @Test func processReportWithStringPaneIsNil() {
        let json = #"{"pane":"1","child":{"pid":2},"foreground":{"pid":3}}"#
        #expect(TernReports.process(from: data(json)) == nil)
    }

    @Test func oneLocalWindowYieldsTheShownTabsFocusedBlock() throws {
        let report = try #require(TernReports.inspect(from: oneWindow))
        #expect(report.windowClientCount == 1)
        #expect(report.windowClientsAreLocal)
        #expect(report.shownFocusedBlock == 21)
        #expect(report.panes[20] == TernPaneReport(ompSessionFile: nil, isLocal: true))
        #expect(
            report.panes[21]
                == TernPaneReport(
                    ompSessionFile: "/Users/v/.omp/agent/sessions/-x/2026-11-09T17-51-32-000Z_01a1c16f.jsonl",
                    isLocal: true
                )
        )
    }

    @Test func twoWindowClientsAreCounted() throws {
        let json = inspect(
            sessions: [session(shown: true, tabs: [tab(shown: true, blocks: [block(1, focused: true)])])],
            panes: [pane(1)],
            clients: [client("window"), client("window"), client("script")]
        )
        let report = try #require(TernReports.inspect(from: json))
        #expect(report.windowClientCount == 2)
    }

    @Test func remoteHopsAreNotLocal() throws {
        let json = inspect(
            sessions: [session(shown: true, tabs: [tab(shown: true, blocks: [block(1, focused: true)])])],
            panes: [pane(1, hops: [localHop, remoteHop])],
            clients: [client("window", hops: [remoteHop])]
        )
        let report = try #require(TernReports.inspect(from: json))
        #expect(report.windowClientCount == 1)
        #expect(!report.windowClientsAreLocal)
        #expect(report.panes[1]?.isLocal == false)
    }

    @Test func identityThatIsMissingOrEmptyIsNotLocal() throws {
        let json = inspect(
            sessions: [session(shown: true, tabs: [tab(shown: true, blocks: [block(1, focused: true)])])],
            panes: [pane(1, hops: nil), pane(2, hops: [])],
            clients: [client("window", hops: nil)]
        )
        let report = try #require(TernReports.inspect(from: json))
        #expect(report.windowClientCount == 1)
        #expect(!report.windowClientsAreLocal)
        #expect(report.panes[1]?.isLocal == false)
        #expect(report.panes[2]?.isLocal == false)
    }

    @Test func noFocusedBlockInTheShownTabIsNil() throws {
        let json = inspect(
            sessions: [
                session(
                    shown: true,
                    tabs: [
                        tab(shown: true, blocks: [block(1, focused: false)]),
                        tab(shown: false, blocks: [block(2, focused: true)]),
                    ]
                )
            ],
            panes: [pane(1), pane(2)],
            clients: [client("window")]
        )
        let report = try #require(TernReports.inspect(from: json))
        #expect(report.shownFocusedBlock == nil)
    }

    @Test func twoFocusedBlocksInTheShownTabIsNil() throws {
        let json = inspect(
            sessions: [
                session(
                    shown: true,
                    tabs: [tab(shown: true, blocks: [block(1, focused: true), block(2, focused: true)])]
                )
            ],
            panes: [pane(1), pane(2)],
            clients: [client("window")]
        )
        let report = try #require(TernReports.inspect(from: json))
        #expect(report.shownFocusedBlock == nil)
    }

    @Test func twoShownSessionsOrTabsAreNil() throws {
        let shownTab = tab(shown: true, blocks: [block(1, focused: true)])
        let twoSessions = inspect(
            sessions: [session(shown: true, tabs: [shownTab]), session(shown: true, tabs: [shownTab])],
            panes: [pane(1)],
            clients: [client("window")]
        )
        let twoTabs = inspect(
            sessions: [session(shown: true, tabs: [shownTab, shownTab])],
            panes: [pane(1)],
            clients: [client("window")]
        )
        let sessionsReport = try #require(TernReports.inspect(from: twoSessions))
        let tabsReport = try #require(TernReports.inspect(from: twoTabs))
        #expect(sessionsReport.shownFocusedBlock == nil)
        #expect(tabsReport.shownFocusedBlock == nil)
    }

    @Test func absentSessionFileKeyReadsAsNil() throws {
        let json = data(
            #"{"sessions":[],"panes":[{"pane":7,"identity":{"hops":[\#(localHop)]}}],"clients":[]}"#
        )
        let report = try #require(TernReports.inspect(from: json))
        #expect(report.panes[7] == TernPaneReport(ompSessionFile: nil, isLocal: true))
        #expect(report.windowClientCount == 0)
        #expect(report.shownFocusedBlock == nil)
    }

    @Test func duplicatePaneIdsAreNil() {
        let json = inspect(
            sessions: [session(shown: true, tabs: [tab(shown: true, blocks: [block(1, focused: true)])])],
            panes: [pane(1), pane(1, ompSessionFile: "/tmp/other.jsonl")],
            clients: [client("window")]
        )
        #expect(TernReports.inspect(from: json) == nil)
    }

    @Test(arguments: [
        #"{"panes":[],"clients":[]}"#,
        #"{"sessions":[],"clients":[]}"#,
        #"{"sessions":[],"panes":[]}"#,
        #"{"sessions":[{"tabs":[]}],"panes":[],"clients":[]}"#,
        #"{"sessions":[{"shown":true,"tabs":[{"shown":true,"blocks":[{"id":1}]}]}],"panes":[],"clients":[]}"#,
        #"{"sessions":[],"panes":[{"omp_session_file":null}],"clients":[]}"#,
        #"{"sessions":[],"panes":[],"clients":[{"identity":{"hops":[]}}]}"#,
    ])
    func missingRequiredKeysAreNil(json: String) {
        #expect(TernReports.inspect(from: data(json)) == nil)
    }

    @Test(arguments: ["", "not json", "[]", "null", #"{"sessions":"#, "\u{0}\u{1}"])
    func garbageIsNil(text: String) {
        #expect(TernReports.process(from: data(text)) == nil)
        #expect(TernReports.inspect(from: data(text)) == nil)
    }
}
