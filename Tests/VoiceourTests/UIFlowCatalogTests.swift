// Exercises the offscreen UI harness, which is compiled out unless `UI_HARNESS`
// is defined. `make test` and CI pass `-Xswiftc -DUI_HARNESS`; a bare
// `swift test` compiles this file away rather than failing to resolve the harness.
#if UI_HARNESS

    import Foundation
    import Testing
    @testable import Voiceour

    @MainActor
    struct UIFlowCatalogTests {
        @Test func flowIdsAreUniqueLowercaseDotSeparatedFilesystemSafeBasenames() {
            let flows = UIFlowCatalog.everything()
            let ids = flows.map(\.id)
            #expect(Set(ids).count == ids.count)

            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
            for flow in flows {
                #expect(!flow.id.isEmpty, "empty flow id")
                #expect(flow.id == flow.id.lowercased(), "uppercase artifact basename: \(flow.id)")
                #expect(flow.id.allSatisfy(allowed.contains), "unsafe artifact basename: \(flow.id)")
                #expect(
                    flow.id.split(separator: ".", omittingEmptySubsequences: false).count >= 2,
                    "flow id is not dot-separated: \(flow.id)")
                #expect(!flow.id.hasPrefix("."), "flow id begins with a dot: \(flow.id)")
                #expect(!flow.id.hasSuffix("."), "flow id ends with a dot: \(flow.id)")
                #expect(!flow.id.contains(".."), "flow id has an empty component: \(flow.id)")
            }
        }

        @Test func everyFlowAssertsAtLeastOneExpectationAtACheckpoint() {
            for flow in UIFlowCatalog.everything() {
                #expect(flow.checkpointCount > 0, "flow has no checkpoint: \(flow.id)")
                #expect(flow.expectationCount > 0, "flow asserts nothing: \(flow.id)")
            }
        }

        @Test func everyArmedGateIsReleasedAndEveryReleaseNamesAnArmedGate() {
            for flow in UIFlowCatalog.everything() {
                let armed = flow.fixture.armedGates
                let released = Set(
                    flow.steps.compactMap { step -> UIGate? in
                        guard case .release(let gate) = step else { return nil }
                        return gate
                    })

                for gate in released.sorted(by: { $0.rawValue < $1.rawValue }) {
                    #expect(armed.contains(gate), "flow \(flow.id) releases unarmed gate \(gate)")
                }
                for gate in armed.sorted(by: { $0.rawValue < $1.rawValue }) {
                    #expect(released.contains(gate), "flow \(flow.id) never releases armed gate \(gate)")
                }
            }
        }

        @Test func catalogHonorsOnlyAndExceptFilters() throws {
            let all = UIFlowCatalog.everything()
            let sample = try #require(all.first)

            let onlyRequest = try #require(
                UIHarnessRequest(arguments: [
                    "Voiceour", "--ui-harness", "--flow-check", "--only", sample.id,
                ]))
            let onlyExpected = all.filter { matches(sample.id, id: $0.id, tags: $0.tags) }
            #expect(UIFlowCatalog.all(request: onlyRequest).map(\.id) == onlyExpected.map(\.id))

            let exceptRequest = try #require(
                UIHarnessRequest(arguments: [
                    "Voiceour", "--ui-harness", "--flow-check", "--except", sample.id,
                ]))
            let exceptExpected = all.filter { !matches(sample.id, id: $0.id, tags: $0.tags) }
            #expect(UIFlowCatalog.all(request: exceptRequest).map(\.id) == exceptExpected.map(\.id))

            let combinedRequest = try #require(
                UIHarnessRequest(arguments: [
                    "Voiceour", "--ui-harness", "--flow-check", "--only", sample.id, "--except", sample.id,
                ]))
            #expect(UIFlowCatalog.all(request: combinedRequest).isEmpty)
        }

        @Test func defaultCatalogExcludesOS26Flows() throws {
            let request = try #require(
                UIHarnessRequest(arguments: ["Voiceour", "--ui-harness", "--flow-check"]))
            #expect(request.except == ["os26"])
            let selected = UIFlowCatalog.all(request: request)
            let expected = UIFlowCatalog.everything().filter { !matches("os26", id: $0.id, tags: $0.tags) }

            #expect(selected.map(\.id) == expected.map(\.id))
            #expect(selected.allSatisfy { !matches("os26", id: $0.id, tags: $0.tags) })
        }

        private func matches(_ needle: String, id: String, tags: [String]) -> Bool {
            id.contains(needle) || tags.contains(needle)
        }
    }

#endif
