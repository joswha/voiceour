import AppKit
import Foundation
import VoiceCore

public struct OmpOnboardingSession: Equatable, Sendable {
    public let subscription: OmpSubscription
    public let directoryURL: URL
    public let scriptURL: URL
    public let resultURL: URL
    public let executableURL: URL
    public let argumentPrefix: [String]
    public let profileDirectory: URL?

    public init(
        subscription: OmpSubscription,
        directoryURL: URL,
        scriptURL: URL,
        resultURL: URL,
        executableURL: URL,
        argumentPrefix: [String],
        profileDirectory: URL?
    ) {
        self.subscription = subscription
        self.directoryURL = directoryURL
        self.scriptURL = scriptURL
        self.resultURL = resultURL
        self.executableURL = executableURL
        self.argumentPrefix = argumentPrefix
        self.profileDirectory = profileDirectory
    }
}

public enum OmpOnboardingOutcome: Equatable, Sendable {
    case signedIn(models: [OmpAvailableModel], catalogWarning: String?)
    case cancelled
    case failed(String)
}

public enum OmpOnboardingError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case unsupportedProvider(String)
    case cannotPrepare(String)
    case cannotOpenTerminal

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Oh My Pi is unavailable. Install or update `omp`, then try again. \(detail)"
        case .unsupportedProvider(let provider):
            "This `omp` version does not offer the \(provider) sign-in. Update Oh My Pi or choose Other."
        case .cannotPrepare(let detail):
            "Could not prepare the Oh My Pi sign-in. \(detail)"
        case .cannotOpenTerminal:
            "Could not open the temporary Oh My Pi sign-in in Terminal."
        }
    }
}

/// Creates a one-shot `.command` file and lets Terminal host OMP's own
/// interactive login. Voiceour never parses prompts and never reads OMP's
/// credential database; arbitrary provider-specific browser, device-code, and
/// paste-code flows therefore remain owned by OMP.
public enum OmpOnboarding {
    public typealias ScriptOpener = @Sendable (URL) async -> Bool
    private struct SessionFiles {
        let directoryURL: URL
        let scriptURL: URL
        let resultURL: URL
    }

    private static func sessionFiles(in root: URL) -> SessionFiles {
        let directoryURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SessionFiles(
            directoryURL: directoryURL,
            scriptURL: directoryURL.appendingPathComponent("Sign in to Oh My Pi.command"),
            resultURL: directoryURL.appendingPathComponent("result")
        )
    }

    private static func prepare(_ files: SessionFiles, under root: URL, using fileManager: FileManager) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.createDirectory(at: files.directoryURL, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directoryURL.path)
    }

    private static func beginError(from error: Error) -> OmpOnboardingError {
        if let error = error as? OmpOnboardingError { return error }
        if let error = error as? OmpProcessError { return .unavailable(error.shortMessage) }
        return .cannotPrepare(error.localizedDescription)
    }

    public static func begin(
        subscription: OmpSubscription,
        executableURL: URL,
        argumentPrefix: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileDirectory: URL? = OmpRpcProfile.defaultDirectory(),
        sessionRoot: URL = URL.voiceourSupportDirectory
            .appendingPathComponent("omp-onboarding", isDirectory: true),
        openScript: @escaping ScriptOpener = { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    ) async throws -> OmpOnboardingSession {
        let fileManager = FileManager.default
        let files = sessionFiles(in: sessionRoot)

        do {
            try prepare(files, under: sessionRoot, using: fileManager)
            let providers = try await authProviders(
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                environment: environment,
                currentDirectoryURL: files.directoryURL
            )
            if let providerID = subscription.providerID,
                !providers.contains(where: { $0.id == providerID })
            {
                throw OmpOnboardingError.unsupportedProvider(subscription.displayName)
            }

            let contents = scriptContents(
                subscription: subscription,
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                environment: environment,
                files: files
            )
            try contents.write(to: files.scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.scriptURL.path)
            guard await openScript(files.scriptURL) else {
                throw OmpOnboardingError.cannotOpenTerminal
            }
            return OmpOnboardingSession(
                subscription: subscription,
                directoryURL: files.directoryURL,
                scriptURL: files.scriptURL,
                resultURL: files.resultURL,
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                profileDirectory: profileDirectory
            )
        } catch is CancellationError {
            try? fileManager.removeItem(at: files.directoryURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: files.directoryURL)
            throw beginError(from: error)
        }
    }

    public static func finish(
        _ session: OmpOnboardingSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        modelTimeoutMs: Int = 15_000,
        pollNanoseconds: UInt64 = 200_000_000
    ) async -> OmpOnboardingOutcome {
        defer { try? FileManager.default.removeItem(at: session.directoryURL) }
        do {
            let status = try await waitForExitStatus(
                at: session.resultURL,
                pollNanoseconds: pollNanoseconds
            )
            if status == 130 {
                return .cancelled
            }
            guard status == 0 else {
                return .failed(
                    "Oh My Pi sign-in exited with status \(status). See the Terminal window for details."
                )
            }

            do {
                let models = try await OmpModelCatalog.load(
                    executableURL: session.executableURL,
                    argumentPrefix: session.argumentPrefix,
                    providerID: session.subscription.providerID,
                    timeoutMs: modelTimeoutMs,
                    environment: environment,
                    profileDirectory: session.profileDirectory
                )
                return .signedIn(models: models, catalogWarning: nil)
            } catch {
                let warning =
                    "Sign-in completed, but Voiceour could not load "
                    + "OMP's model catalog: \(shortMessage(for: error))."
                return .signedIn(models: [], catalogWarning: warning)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed("Could not read the Oh My Pi sign-in result: \(error.localizedDescription)")
        }
    }

    private struct AuthProvider: Decodable {
        let id: String
    }

    private static func authProviders(
        executableURL: URL,
        argumentPrefix: [String],
        environment: [String: String],
        currentDirectoryURL: URL
    ) async throws -> [AuthProvider] {
        let stdout = try await OmpProcess.run(
            executableURL: executableURL,
            arguments: argumentPrefix + ["auth-broker", "list", "--json"],
            timeoutMs: 8_000,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL
        )
        guard let providers = try? JSONDecoder().decode([AuthProvider].self, from: Data(stdout.utf8)),
            !providers.isEmpty
        else {
            throw OmpOnboardingError.unavailable("The provider catalog was empty or invalid.")
        }
        return providers
    }

    private static func waitForExitStatus(
        at resultURL: URL,
        pollNanoseconds: UInt64
    ) async throws -> Int32 {
        while true {
            try Task.checkCancellation()
            if let raw = try? String(contentsOf: resultURL, encoding: .utf8) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let status = Int32(trimmed) else {
                    throw OmpOnboardingError.cannotPrepare("The Terminal result was invalid.")
                }
                return status
            }
            try await Task.sleep(nanoseconds: max(pollNanoseconds, 1_000_000))
        }
    }

    private static func scriptContents(
        subscription: OmpSubscription,
        executableURL: URL,
        argumentPrefix: [String],
        environment: [String: String],
        files: SessionFiles
    ) -> String {
        let childEnvironment = OmpEnvironment.augmented(
            environment,
            workingDirectory: files.directoryURL
        )
        let assignments =
            childEnvironment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var command = ["/usr/bin/env", "-i"]
        command.append(contentsOf: assignments)
        command.append(executableURL.path)
        command.append(contentsOf: argumentPrefix)
        command.append(contentsOf: ["auth-broker", "login"])
        if let providerID = subscription.providerID {
            command.append(providerID)
        }
        let invocation = command.map(shellQuote).joined(separator: " ")
        let connecting =
            subscription == .other
            ? "Choose any provider supported by your installed OMP."
            : "Connecting your \(subscription.displayName) subscription."

        return """
            #!/bin/sh
            umask 077
            cd \(shellQuote(files.directoryURL.path)) || exit 70
            printf '\\033]0;Voiceour · Oh My Pi sign-in\\007'
            printf '\\nVoiceour · Oh My Pi sign-in\\n%s\\n\\n' \(shellQuote(connecting))
            \(invocation)
            status=$?
            result_path=\(shellQuote(files.resultURL.path))
            tmp_path="${result_path}.tmp"
            printf '%s\\n' "$status" > "$tmp_path"
            /bin/mv -f "$tmp_path" "$result_path"
            /bin/rm -f -- "$0"
            printf '\\n'
            if [ "$status" -eq 0 ]; then
                printf 'Sign-in complete. Return to Voiceour; this window can be closed.\\n'
            else
                printf 'Sign-in did not complete (status %s). Review the message above, '
                printf 'then return to Voiceour.\\n' "$status"
            fi
            exit "$status"
            """ + "\n"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func shortMessage(for error: Error) -> String {
        switch error {
        case let error as OmpProcessError:
            error.shortMessage
        case let error as OmpRpcError:
            error.shortMessage
        case let error as OmpModelCatalogError:
            error.shortMessage
        default:
            error.localizedDescription
        }
    }
}
