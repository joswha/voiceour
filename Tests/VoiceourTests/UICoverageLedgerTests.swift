// Exercises the offscreen UI harness, which is compiled out unless `UI_HARNESS`
// is defined. `make test` and CI pass `-Xswiftc -DUI_HARNESS`; a bare
// `swift test` compiles this file away rather than failing to resolve the harness.
#if UI_HARNESS

    import Foundation
    import Testing
    @testable import Voiceour

    struct UICoverageLedgerTests {
        @Test func passingClaimCoversARequiredKeyAndNoClaimFails() throws {
            let key = UICoverageKey.journey(.home, "dictate")
            let requirement = UICoverageRequirement(key, "Dictate from Home")

            let covered = UICoverageLedger.evaluate(
                requirements: [requirement],
                passingClaims: [key: ["home.dictate"]],
                selectedClaims: [key],
                allClaims: [key: ["home.dictate"]],
                sceneIDs: []
            )
            let coveredEntry = try #require(covered.entries.first)
            #expect(coveredEntry.status == .covered)
            #expect(coveredEntry.claimants == ["home.dictate"])
            #expect(!covered.failing)

            let uncovered = UICoverageLedger.evaluate(
                requirements: [requirement],
                passingClaims: [:],
                selectedClaims: [],
                allClaims: [:],
                sceneIDs: []
            )
            let uncoveredEntry = try #require(uncovered.entries.first)
            #expect(uncoveredEntry.status == .uncovered)
            #expect(uncovered.failing)
        }

        @Test func claimsFromOnlyFailingFlowsDoNotCoverAKey() throws {
            let key = UICoverageKey.journey(.sessions, "clear-history")
            let report = UICoverageLedger.evaluate(
                requirements: [UICoverageRequirement(key, "Clear session history")],
                passingClaims: [:],
                selectedClaims: [key],
                allClaims: [key: ["sessions.clear-history"]],
                sceneIDs: []
            )

            let entry = try #require(report.entries.first)
            #expect(entry.status == .uncovered)
            #expect(report.failing)
        }

        @Test func snapshotOnlyRequiresAnExistingScene() throws {
            let realKey = UICoverageKey.state(.menu, "idle")
            let brokenKey = UICoverageKey.state(.menu, "missing")
            let report = UICoverageLedger.evaluate(
                requirements: [
                    UICoverageRequirement(realKey, "Idle menu", .snapshotOnly(sceneID: "menu.idle")),
                    UICoverageRequirement(brokenKey, "Missing menu", .snapshotOnly(sceneID: "menu.missing")),
                ],
                passingClaims: [:],
                selectedClaims: [],
                allClaims: [:],
                sceneIDs: ["menu.idle"]
            )

            let real = try #require(report.entries.first { $0.requirement.key == realKey })
            #expect(real.status == .snapshot)
            let broken = try #require(report.entries.first { $0.requirement.key == brokenKey })
            #expect(broken.status == .broken)
            #expect(broken.problem == "snapshot scene menu.missing is not in the catalog")
            #expect(report.failing)
        }

        @Test func notVerifiableRequirementNeverFails() throws {
            let key = UICoverageKey.journey(.menu, "host-dismissal")
            let report = UICoverageLedger.evaluate(
                requirements: [
                    UICoverageRequirement(key, "Dismiss system menu host", .notVerifiable(.menuHostChrome))
                ],
                passingClaims: [:],
                selectedClaims: [],
                allClaims: [:],
                sceneIDs: []
            )

            let entry = try #require(report.entries.first)
            #expect(entry.status == .notVerifiable)
            #expect(!report.failing)
        }

        @Test func undeclaredClaimIsReportedAndFails() {
            let key = UICoverageKey.journey(.overlay, "undeclared")
            let report = UICoverageLedger.evaluate(
                requirements: [],
                passingClaims: [key: ["overlay.flow"]],
                selectedClaims: [key],
                allClaims: [key: ["overlay.flow"]],
                sceneIDs: []
            )

            #expect(report.undeclared == [key.description])
            #expect(report.failing)
        }

        @Test func excludedClaimantsProduceNotSelectedRatherThanUncovered() throws {
            let key = UICoverageKey.journey(.voice, "switch-backend")
            let report = UICoverageLedger.evaluate(
                requirements: [UICoverageRequirement(key, "Switch speech backend")],
                passingClaims: [:],
                selectedClaims: [],
                allClaims: [key: ["voice.switch-backend"]],
                sceneIDs: []
            )

            let entry = try #require(report.entries.first)
            #expect(entry.status == .notSelected)
            #expect(!report.failing)
        }

        @MainActor
        @Test func registryIsUniqueCompleteAndReferencesRealScenes() {
            let requirements = UICoverageRegistry.requirements
            let keys = requirements.map(\.key)
            #expect(Set(keys).count == keys.count)

            let sceneIDs = Set(UISceneCatalog.everything().map(\.id))
            for requirement in requirements {
                let title = requirement.title.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!title.isEmpty, "empty coverage title for \(requirement.key)")
                #expect(!title.hasSuffix("."), "coverage title has a trailing period: \(requirement.key)")
                if case .snapshotOnly(let sceneID) = requirement.disposition {
                    #expect(
                        sceneIDs.contains(sceneID),
                        "coverage key \(requirement.key) references missing scene \(sceneID)")
                }
            }

            let declaredSurfaces = Set(requirements.map { $0.key.surface })
            for surface in UISurface.allCases {
                #expect(declaredSurfaces.contains(surface), "coverage registry omits surface \(surface.rawValue)")
            }
        }
    }

    struct UICoverageBaselineTests {
        @Test func uncoveredReturnsOnlySortedUncoveredEntries() {
            let report = report([
                entry(.state(.sessions, "covered"), status: .covered),
                entry(.state(.menu, "alpha"), status: .uncovered),
                entry(.state(.voice, "snapshot"), status: .snapshot),
                entry(.state(.glossary, "not-verifiable"), status: .notVerifiable),
                entry(.journey(.home, "zeta"), status: .uncovered),
                entry(.state(.sessions, "not-selected"), status: .notSelected),
                entry(.state(.system, "broken"), status: .broken),
            ])

            #expect(
                UICoverageBaseline.uncovered(in: report) == [
                    "journey:home:zeta",
                    "state:menu:alpha",
                ])
        }

        @Test func readSkipsCommentsAndBlankLinesAndTrimsWhitespace() throws {
            try withTemporaryRequest { request in
                let text = """
                          # generated baseline

                          journey:home:dictate
                    \t
                        state:menu:open-menu \t
                         # another comment
                    """
                try text.write(
                    to: UICoverageBaseline.url(request),
                    atomically: true,
                    encoding: .utf8
                )

                #expect(
                    UICoverageBaseline.read(request) == [
                        "journey:home:dictate",
                        "state:menu:open-menu",
                    ])
            }
        }

        @Test func matchingBaselineHasNoRegressionsOrStaleEntries() throws {
            try withTemporaryRequest { request in
                let first = UICoverageKey.journey(.home, "dictate")
                let second = UICoverageKey.state(.menu, "open-menu")
                try writeBaseline([second.description, first.description], request: request)
                let current = report([
                    entry(second, status: .uncovered),
                    entry(.state(.sessions, "populated"), status: .covered),
                    entry(first, status: .uncovered),
                ])

                let verdict = UICoverageBaseline.evaluate(current, request: request)

                #expect(verdict.regressions.isEmpty)
                #expect(verdict.stale.isEmpty)
                #expect(verdict.deferred == 0)
                #expect(!verdict.missing)
                #expect(!verdict.failing)
            }
        }

        @Test func uncoveredKeyAbsentFromBaselineIsARegression() throws {
            try withTemporaryRequest { request in
                let key = UICoverageKey.journey(.voice, "switch-backend")
                try writeBaseline([], request: request)

                let verdict = UICoverageBaseline.evaluate(
                    report([entry(key, status: .uncovered)]),
                    request: request
                )

                #expect(verdict.regressions == [key.description])
                #expect(verdict.stale.isEmpty)
                #expect(verdict.failing)
            }
        }

        @Test func coveredBaselineKeyIsStale() throws {
            try withTemporaryRequest { request in
                let key = UICoverageKey.journey(.sessions, "delete")
                try writeBaseline([key.description], request: request)

                let verdict = UICoverageBaseline.evaluate(
                    report([entry(key, status: .covered)]),
                    request: request
                )

                #expect(verdict.regressions.isEmpty)
                #expect(verdict.stale == [key.description])
                #expect(verdict.failing)
            }
        }

        @Test func unjudgedBaselineKeyIsDeferredRatherThanRegressedOrStale() throws {
            try withTemporaryRequest(only: ["sessions"]) { request in
                let key = UICoverageKey.journey(.voice, "switch-backend")
                try writeBaseline([key.description], request: request)

                let verdict = UICoverageBaseline.evaluate(
                    report([entry(key, status: .notSelected)]),
                    request: request
                )

                #expect(verdict.deferred == 1)
                #expect(verdict.regressions.isEmpty)
                #expect(verdict.stale.isEmpty)
                #expect(!verdict.failing)
            }
        }

        @Test func missingBaselineIsReportedWithoutFailing() throws {
            try withTemporaryRequest { request in
                let key = UICoverageKey.journey(.home, "dictate")

                let verdict = UICoverageBaseline.evaluate(
                    report([entry(key, status: .uncovered)]),
                    request: request
                )

                #expect(verdict.missing)
                #expect(verdict.regressions.isEmpty)
                #expect(verdict.stale.isEmpty)
                #expect(!verdict.failing)
            }
        }

        @Test func writeRefusesFilteredRequestAndAppendsWarning() throws {
            try withTemporaryRequest(only: ["sessions"]) { request in
                let sentinel = "# existing baseline\njourney:voice:switch-backend\n"
                try sentinel.write(
                    to: UICoverageBaseline.url(request),
                    atomically: true,
                    encoding: .utf8
                )
                var warnings: [String] = []

                let wrote = UICoverageBaseline.write(
                    report([entry(.journey(.sessions, "delete"), status: .uncovered)]),
                    request: request,
                    warnings: &warnings
                )

                #expect(!wrote)
                #expect(warnings.count == 1)
                #expect(warnings[0].contains("filtered run"))
                #expect(
                    try String(contentsOf: UICoverageBaseline.url(request), encoding: .utf8)
                        == sentinel
                )
            }
        }

        @Test func writeEmitsHeaderAndSortedKeysAndDoesNotTouchUnchangedFile() throws {
            try withTemporaryRequest { request in
                let current = report([
                    entry(.state(.menu, "zebra"), status: .uncovered),
                    entry(.journey(.home, "alpha"), status: .uncovered),
                ])
                var warnings: [String] = []

                #expect(UICoverageBaseline.write(current, request: request, warnings: &warnings))
                #expect(warnings.isEmpty)
                let destination = UICoverageBaseline.url(request)
                let expected =
                    [
                        "# Required coverage keys with no flow claiming them, one per line, sorted.",
                        "#",
                        "# This file is a ratchet, not a to-do list. `make ui-flow` fails when an uncovered key",
                        "# is missing from here (a regression) AND when a key listed here is now covered (a",
                        "# stale entry). It can therefore only ever get shorter.",
                        "#",
                        "# Regenerate with `make ui-flow-update`. A removed line is a gap you closed; an added",
                        "# line is coverage you dropped.",
                        "journey:home:alpha",
                        "state:menu:zebra",
                    ].joined(separator: "\n") + "\n"
                #expect(try String(contentsOf: destination, encoding: .utf8) == expected)

                let oldDate = Date(timeIntervalSince1970: 1_000_000)
                try FileManager.default.setAttributes(
                    [.modificationDate: oldDate],
                    ofItemAtPath: destination.path
                )
                let beforeAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let beforeDate = try #require(beforeAttributes[.modificationDate] as? Date)

                #expect(!UICoverageBaseline.write(current, request: request, warnings: &warnings))
                let afterAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let afterDate = try #require(afterAttributes[.modificationDate] as? Date)
                #expect(afterDate == beforeDate)
                #expect(warnings.isEmpty)
            }
        }

        @Test func writeThenReadRoundTripsCurrentUncoveredKeys() throws {
            try withTemporaryRequest { request in
                let current = report([
                    entry(.state(.menu, "covered"), status: .covered),
                    entry(.state(.system, "beta"), status: .uncovered),
                    entry(.journey(.home, "alpha"), status: .uncovered),
                ])
                var warnings: [String] = []

                #expect(UICoverageBaseline.write(current, request: request, warnings: &warnings))
                #expect(UICoverageBaseline.read(request) == UICoverageBaseline.uncovered(in: current))
                #expect(warnings.isEmpty)
            }
        }

        @Test func committedBaselineContainsOnlySortedUniqueRequiredRegistryKeys() throws {
            let root = try #require(repositoryRoot())
            let directory = root.appendingPathComponent("fixtures/ui", isDirectory: true)
            let request = try #require(
                UIHarnessRequest(arguments: [
                    UIHarnessRequest.flag,
                    "--golden", directory.path,
                ]))
            let baseline = try #require(UICoverageBaseline.read(request))
            let requiredKeys = Set(
                UICoverageRegistry.requirements.compactMap { requirement in
                    switch requirement.disposition {
                    case .required:
                        return requirement.key.description
                    case .snapshotOnly, .notVerifiable:
                        return nil
                    }
                })

            #expect(baseline == baseline.sorted())
            #expect(Set(baseline).count == baseline.count)
            for key in baseline {
                #expect(requiredKeys.contains(key), "baseline names undeclared or non-required key \(key)")
            }
        }

        private func entry(
            _ key: UICoverageKey,
            status: UICoverageEntry.Status
        ) -> UICoverageEntry {
            UICoverageEntry(
                requirement: UICoverageRequirement(key, key.description),
                status: status,
                claimants: [],
                problem: status == .broken ? "invalid test requirement" : nil
            )
        }

        private func report(_ entries: [UICoverageEntry]) -> UICoverageReport {
            UICoverageReport(entries: entries, undeclared: [])
        }

        private func writeBaseline(_ keys: [String], request: UIHarnessRequest) throws {
            let text = keys.isEmpty ? "\n" : keys.joined(separator: "\n") + "\n"
            try text.write(
                to: UICoverageBaseline.url(request),
                atomically: true,
                encoding: .utf8
            )
        }

        private func withTemporaryRequest(
            only: [String] = [],
            _ body: (UIHarnessRequest) throws -> Void
        ) throws {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("Voiceour-UICoverageBaseline-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }

            var arguments = [
                UIHarnessRequest.flag,
                "--golden", directory.path,
            ]
            if !only.isEmpty {
                arguments.append(contentsOf: ["--only", only.joined(separator: ",")])
            }
            let request = try #require(UIHarnessRequest(arguments: arguments))
            try body(request)
        }

    }

#endif
