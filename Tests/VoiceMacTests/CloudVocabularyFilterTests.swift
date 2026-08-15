import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("CloudVocabularyFilterTests", .serialized, .timeLimit(.minutes(1)))
struct CloudVocabularyFilterTests {
    /// The cloud prompt must provably exclude every ineligible term:
    /// project-scoped terms, `cloudEligible == false` terms, and tombstoned
    /// terms never cross the network boundary, while global/bundle cloud terms do.
    ///
    /// The subject is the message OMP is handed, because that message is the
    /// whole payload: Voiceour no longer builds a request body, and OMP
    /// forwards what it is given.
    @Test func cloudPromptOmitsIneligibleGlossaryTerms() {
        let glossary: [ProtectedTerm] = [
            ProtectedTerm(
                canonical: "AlphaGlobalTerm", spokenAliases: ["alpha global"], scope: .global, cloudEligible: true),
            ProtectedTerm(
                canonical: "BetaBundleTerm", spokenAliases: ["beta bundle"], scope: .bundleID("com.example.app"),
                cloudEligible: true),
            ProtectedTerm(
                canonical: "GammaProjectTerm", spokenAliases: ["gamma project"], scope: .projectID("proj-42"),
                cloudEligible: true),
            ProtectedTerm(
                canonical: "DeltaLocalTerm", spokenAliases: ["delta local"], scope: .global, cloudEligible: false),
            ProtectedTerm(
                canonical: "EpsilonDeadTerm", spokenAliases: ["epsilon dead"], scope: .global, cloudEligible: true,
                tombstonedAt: Date(timeIntervalSince1970: 0)),
        ]

        let cloudMessage = RefinerPolicy.ompUserMessage(
            raw: "the meeting notes",
            glossary: RefinerPolicy.cloudEligible(glossary),
            style: .standard
        )

        // Cloud-eligible global and bundle-scoped terms reach the prompt, with
        // the aliases the model needs to repair a mishearing.
        #expect(cloudMessage.contains("AlphaGlobalTerm"))
        #expect(cloudMessage.contains("alpha global"))
        #expect(cloudMessage.contains("BetaBundleTerm"))
        #expect(cloudMessage.contains("beta bundle"))
        // Project-scoped, cloudEligible==false, and tombstoned terms are gone,
        // and so are their aliases: an alias names the term just as plainly.
        for excluded in [
            "GammaProjectTerm", "gamma project",
            "DeltaLocalTerm", "delta local",
            "EpsilonDeadTerm", "epsilon dead",
        ] {
            #expect(!cloudMessage.contains(excluded), "\(excluded) reached the cloud prompt")
        }
        #expect(cloudMessage.contains("the meeting notes"))

        // Negative control: the same builder fed the unfiltered glossary does
        // emit every one of those terms. Without this the assertions above would
        // still pass if the prompt had simply stopped carrying vocabulary at all.
        let unfilteredMessage = RefinerPolicy.ompUserMessage(
            raw: "the meeting notes",
            glossary: glossary,
            style: .standard
        )
        for included in ["GammaProjectTerm", "DeltaLocalTerm", "EpsilonDeadTerm"] {
            #expect(unfilteredMessage.contains(included))
        }
    }

    /// The filter is a pure subset selection: it drops exactly the ineligible
    /// terms and preserves the full set for local backends (which call it never).
    @Test func cloudEligibleDropsIneligibleAndPreservesLocalSet() {
        let glossary: [ProtectedTerm] = [
            ProtectedTerm(canonical: "AlphaGlobalTerm", spokenAliases: [], scope: .global, cloudEligible: true),
            ProtectedTerm(
                canonical: "BetaBundleTerm", spokenAliases: [], scope: .bundleID("com.example.app"), cloudEligible: true
            ),
            ProtectedTerm(
                canonical: "GammaProjectTerm", spokenAliases: [], scope: .projectID("proj-42"), cloudEligible: true),
            ProtectedTerm(canonical: "DeltaLocalTerm", spokenAliases: [], scope: .global, cloudEligible: false),
            ProtectedTerm(
                canonical: "EpsilonDeadTerm", spokenAliases: [], scope: .global, cloudEligible: true,
                tombstonedAt: Date(timeIntervalSince1970: 0)),
        ]

        let coreEligible = RefinerPrivacy.cloudEligible(glossary)
        let policyEligible = RefinerPolicy.cloudEligible(glossary)

        #expect(coreEligible.map(\.canonical) == ["AlphaGlobalTerm", "BetaBundleTerm"])
        #expect(policyEligible == coreEligible)
        // Local backends operate on the untouched full glossary.
        #expect(glossary.count == 5)
    }

    @Test func ompRequestOmitsIneligibleTermsWhileOnDevicePromptKeepsThem() async throws {
        let directory = try makeOmpRpcStubDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("requests.jsonl")

        let glossary: [ProtectedTerm] = [
            ProtectedTerm(
                canonical: "AlphaCloudTerm",
                spokenAliases: ["alpha cloud alias"],
                scope: .global,
                cloudEligible: true
            ),
            ProtectedTerm(
                canonical: "BetaProjectTerm",
                spokenAliases: ["beta project alias"],
                scope: .projectID("proj-42"),
                cloudEligible: true
            ),
            ProtectedTerm(
                canonical: "GammaLocalTerm",
                spokenAliases: ["gamma local alias"],
                scope: .global,
                cloudEligible: false
            ),
            ProtectedTerm(
                canonical: "DeltaDeadTerm",
                spokenAliases: ["delta dead alias"],
                scope: .global,
                cloudEligible: true,
                tombstonedAt: Date(timeIntervalSince1970: 0)
            ),
        ]
        let refiner = OmpRpcRefiner(
            configuration: OmpRpcRefinerConfiguration(
                enabled: true,
                executableURL: ompRpcStubURL(),
                argumentPrefix: ["capture-requests", capture.path, "The meeting notes."],
                model: "test",
                timeoutMs: 4_000
            ),
            environment: [:],
            deterministicFallback: { $0 }
        )

        let outcome = await refiner.refine(
            "The meeting notes.",
            glossary: glossary,
            safety: .normalText,
            style: .standard
        )

        #expect(outcome == .refined("The meeting notes."))
        let cloudPrompt = try capturedOmpPrompt(at: capture)
        #expect(cloudPrompt.contains("AlphaCloudTerm"))
        #expect(cloudPrompt.contains("alpha cloud alias"))
        for excluded in [
            "BetaProjectTerm", "beta project alias",
            "GammaLocalTerm", "gamma local alias",
            "DeltaDeadTerm", "delta dead alias",
        ] {
            #expect(!cloudPrompt.contains(excluded))
        }

        if #available(macOS 26.0, *) {
            let onDevicePrompt = FoundationModelsRefiner.userMessage(
                raw: "The meeting notes.",
                glossary: glossary,
                style: .standard
            )
            for retained in [
                "AlphaCloudTerm", "alpha cloud alias",
                "BetaProjectTerm", "beta project alias",
                "GammaLocalTerm", "gamma local alias",
                "DeltaDeadTerm", "delta dead alias",
            ] {
                #expect(onDevicePrompt.contains(retained))
            }
        }
    }

    private func makeOmpRpcStubDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMacCloudBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func capturedOmpPrompt(at capture: URL) throws -> String {
        let lines = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let data = Data(line.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if object["type"] as? String == "prompt", let message = object["message"] as? String {
                return message
            }
        }
        throw CloudGateTestError.missingOmpPrompt
    }
}

private enum CloudGateTestError: Error {
    case missingOmpPrompt
}

private func ompRpcStubURL() -> URL {
    testProductsDirectory().appendingPathComponent("OmpRpcStub")
}

private func testProductsDirectory() -> URL {
    Bundle(for: OmpRpcStubTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
}

/// Only exists to give `Bundle(for:)` a class in this test target.
private final class OmpRpcStubTestBundleAnchor {}
