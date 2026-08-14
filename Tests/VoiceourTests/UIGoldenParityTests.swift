// Exercises the offscreen UI harness, which is compiled out unless `UI_HARNESS`
// is defined. `make test` and CI pass `-Xswiftc -DUI_HARNESS`; a bare
// `swift test` compiles this file away rather than failing to resolve the harness.
#if UI_HARNESS

    import Foundation
    import Testing
    @testable import Voiceour

    @MainActor
    struct UIGoldenParityTests {
        @Test func everySceneHasExactlyOneAccessibilityAndPixelGolden() throws {
            let root = try #require(repositoryRoot())
            let directory = root.appendingPathComponent("fixtures/ui", isDirectory: true)
            guard
                let names = try generatedGoldenNames(
                    in: directory,
                    suffixes: [".ax.txt", ".png.sha256"]
                )
            else { return }

            let accessibilityIDs = names.compactMap { removingSuffix(".ax.txt", from: $0) }
            let pixelIDs = names.compactMap { removingSuffix(".png.sha256", from: $0) }
            for id in UISceneCatalog.everything().map(\.id) {
                #expect(
                    accessibilityIDs.filter { $0 == id }.count == 1,
                    "scene \(id) must have exactly one .ax.txt golden")
                #expect(
                    pixelIDs.filter { $0 == id }.count == 1,
                    "scene \(id) must have exactly one .png.sha256 golden")
            }
        }

        @Test func sceneGoldenDirectoryContainsNoOrphans() throws {
            let root = try #require(repositoryRoot())
            let directory = root.appendingPathComponent("fixtures/ui", isDirectory: true)
            guard
                let names = try generatedGoldenNames(
                    in: directory,
                    suffixes: [".ax.txt", ".png.sha256"]
                )
            else { return }

            let catalogIDs = Set(UISceneCatalog.everything().map(\.id))
            let accessibilityIDs = Set(names.compactMap { removingSuffix(".ax.txt", from: $0) })
            let pixelIDs = Set(names.compactMap { removingSuffix(".png.sha256", from: $0) })

            #expect(
                accessibilityIDs.subtracting(catalogIDs).isEmpty,
                "orphan .ax.txt scene goldens: \(accessibilityIDs.subtracting(catalogIDs).sorted())")
            #expect(
                pixelIDs.subtracting(catalogIDs).isEmpty,
                "orphan .png.sha256 scene goldens: \(pixelIDs.subtracting(catalogIDs).sorted())")
        }

        @Test func everyFlowHasExactlyOneJournalAndNoOrphanJournals() throws {
            let root = try #require(repositoryRoot())
            let directory = root.appendingPathComponent("fixtures/ui/flows", isDirectory: true)
            guard
                let names = try generatedGoldenNames(
                    in: directory,
                    suffixes: [".flow.txt", ".ax.txt", ".png.sha256"]
                )
            else { return }

            let journalIDs = names.compactMap { removingSuffix(".flow.txt", from: $0) }
            let flowIDs = UIFlowCatalog.everything().map(\.id)
            let catalogIDs = Set(flowIDs)
            for id in flowIDs {
                #expect(
                    journalIDs.filter { $0 == id }.count == 1,
                    "flow \(id) must have exactly one .flow.txt golden")
            }

            let orphans = Set(journalIDs).subtracting(catalogIDs)
            #expect(orphans.isEmpty, "orphan .flow.txt goldens: \(orphans.sorted())")
        }

        @Test func presentFlowFrameGoldensMatchDeclaredCaptures() throws {
            let root = try #require(repositoryRoot())
            let directory = root.appendingPathComponent("fixtures/ui/flows", isDirectory: true)
            guard
                let names = try generatedGoldenNames(
                    in: directory,
                    suffixes: [".flow.txt", ".ax.txt", ".png.sha256"]
                )
            else { return }

            let declared = Set(
                UIFlowCatalog.everything().flatMap { flow in
                    flow.steps.compactMap { step -> String? in
                        guard case .capture(let frame) = step else { return nil }
                        return "\(flow.id).\(frame)"
                    }
                })
            let accessibilityIDs = Set(names.compactMap { removingSuffix(".ax.txt", from: $0) })
            let pixelIDs = Set(names.compactMap { removingSuffix(".png.sha256", from: $0) })

            let accessibilityOrphans = accessibilityIDs.subtracting(declared)
            let pixelOrphans = pixelIDs.subtracting(declared)
            #expect(
                accessibilityOrphans.isEmpty,
                "flow .ax.txt goldens without a matching capture: \(accessibilityOrphans.sorted())")
            #expect(
                pixelOrphans.isEmpty,
                "flow .png.sha256 goldens without a matching capture: \(pixelOrphans.sorted())")
        }

        private func generatedGoldenNames(
            in directory: URL,
            suffixes: [String]
        ) throws -> [String]? {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            guard exists else {
                return nil
            }
            #expect(isDirectory.boolValue, "golden path is not a directory: \(directory.lastPathComponent)")
            guard isDirectory.boolValue else { return nil }

            let names = try fileManager.contentsOfDirectory(atPath: directory.path)
            let generated = names.filter { name in suffixes.contains { name.hasSuffix($0) } }
            guard !generated.isEmpty else {
                return nil
            }
            return generated
        }

        private func removingSuffix(_ suffix: String, from name: String) -> String? {
            guard name.hasSuffix(suffix) else { return nil }
            return String(name.dropLast(suffix.count))
        }
    }

#endif
