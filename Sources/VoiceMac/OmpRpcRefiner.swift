import Foundation
import VoiceCore

/// Configuration for the persistent `omp --mode rpc` refiner child process.
public struct OmpRpcRefinerConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var executableURL: URL
    public var argumentPrefix: [String]
    public var model: String
    public var timeoutMs: Int
    /// Working directory for the RPC child. When set, a hermetic `.omp/settings.json`
    /// is provisioned there so refiner sessions carry no memory, MCP tools, or
    /// marketplace traffic. `nil` inherits the parent working directory (tests).
    public var profileDirectory: URL?

    public init(
        enabled: Bool,
        executableURL: URL,
        argumentPrefix: [String] = [],
        model: String,
        timeoutMs: Int = 3000,
        profileDirectory: URL? = nil
    ) {
        self.enabled = enabled
        self.executableURL = executableURL
        self.argumentPrefix = argumentPrefix
        self.model = model
        self.timeoutMs = timeoutMs
        self.profileDirectory = profileDirectory
    }
}

enum OmpRpcError: Error, Equatable {
    case launchFailed(String)
    case notReady(String)
    case timeout
    case superseded
    case processExited(String)
    case protocolError(String)

    var shortMessage: String {
        switch self {
        case .launchFailed(let message):
            "launch failed: \(message.prefix(200))"
        case .notReady(let message):
            "omp not ready: \(message.prefix(200))"
        case .timeout:
            "omp timed out"
        case .superseded:
            "superseded"
        case .processExited(let message):
            "omp exited: \(message.prefix(200))"
        case .protocolError(let message):
            "omp protocol error: \(message.prefix(200))"
        }
    }
}

/// Refines transcripts through one persistent `omp --mode rpc` child process.
///
/// The previous implementation spawned the full omp CLI per dictation (~1s Bun/CLI
/// boot before any network work) and inherited the user's interactive session
/// context (MCP servers, memory, ~22k tokens of tool schemas). This client pays
/// startup once, keeps request context at a few hundred tokens, and resets the
/// conversation after every refine so utterances never contaminate each other.
public final class OmpRpcRefiner: TranscriptRefining, @unchecked Sendable {
    private let configuration: OmpRpcRefinerConfiguration
    private let deterministicFallback: ((String) -> String)?
    private let runtime: OmpRpcRuntime

    public init(
        configuration: OmpRpcRefinerConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        deterministicFallback: ((String) -> String)? = nil
    ) {
        self.configuration = configuration
        self.deterministicFallback = deterministicFallback
        self.runtime = OmpRpcRuntime(
            executableURL: configuration.executableURL,
            arguments: Self.arguments(for: configuration),
            environment: OmpEnvironment.augmented(
                environment,
                workingDirectory: configuration.profileDirectory
            ),
            profileDirectory: configuration.profileDirectory
        )
    }

    deinit {
        let runtime = runtime
        Task.detached { await runtime.shutdown() }
    }

    /// Spawns the RPC child ahead of the first dictation so its ~1s startup never
    /// lands on the hotkey-to-paste path. No-op when refinement cannot run.
    public func warmUp() async {
        guard configuration.enabled, !configuration.model.isEmpty else { return }
        try? await runtime.warmUp(timeoutMs: configuration.timeoutMs)
    }

    public func refine(_ raw: String, glossary: [ProtectedTerm], safety: TargetSafetyClass, style: RefinementStyle)
        async -> RefineOutcome
    {
        let fallback = RefinerPolicy.deterministicFallback(for: raw, using: deterministicFallback)
        if let reason = RefinerPolicy.preflightSkipReason(
            enabled: configuration.enabled,
            safety: safety,
            isConfigured: !configuration.model.isEmpty
        ) {
            return .skipped(reason: reason)
        }

        let cloudGlossary = RefinerPolicy.cloudEligible(glossary)
        let message = RefinerPolicy.ompUserMessage(raw: raw, glossary: cloudGlossary, style: style)
        do {
            let stdout = try await runtime.complete(
                message,
                timeoutMs: RefinerPolicy.effectiveTimeoutMs(
                    configuredMs: configuration.timeoutMs,
                    transcript: raw
                )
            )
            let candidate = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return .fellBack(fallback, reason: "empty_output") }
            return RefinerPolicy.guardedOutcome(
                original: raw, candidate: candidate, glossary: glossary, fallback: fallback)
        } catch let error as OmpRpcError {
            return .fellBack(fallback, reason: error.shortMessage)
        } catch is CancellationError {
            return .fellBack(fallback, reason: "cancelled")
        } catch {
            return .fellBack(fallback, reason: "spawn_error")
        }
    }

    static let systemPrompt = RefinerPolicy.systemPrompt(for: .plainText)

    static func arguments(for configuration: OmpRpcRefinerConfiguration) -> [String] {
        configuration.argumentPrefix + [
            "--mode", "rpc",
            "--no-session",
            "--no-tools",
            "--approval-mode", "always-ask",
            "--no-lsp",
            "--no-skills",
            "--no-rules",
            "--no-extensions",
            "--no-title",
            "--thinking", "off",
            "--model", configuration.model,
            "--system-prompt", systemPrompt,
        ]
    }
}
