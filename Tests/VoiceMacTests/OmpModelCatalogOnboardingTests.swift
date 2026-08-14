import Foundation
import Testing

@testable import VoiceMac

/// Covers OMP model discovery, provider status, and onboarding.
extension OmpSuites {
    @Suite("Model Catalog and Onboarding", .serialized)
    struct ModelCatalogOnboarding {
        @Test func ompModelsProbeRequiresExactSelectorAndUsesSanitizedEnvironment() async throws {
            let captureDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpProbe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: captureDirectory) }
            let capture = captureDirectory.appendingPathComponent("environment.txt")
            let fixture = try makeExecutableScript(
                """
                {
                  printf 'openai=<%s>\\n' "$OPENAI_API_KEY"
                  printf 'openai_set=<%s>\\n' "${OPENAI_API_KEY+x}"
                  printf 'gemini=<%s>\\n' "$GEMINI_API_KEY"
                  printf 'anthropic_base=<%s>\\n' "$ANTHROPIC_BASE_URL"
                  printf 'foundry=<%s>\\n' "$CLAUDE_CODE_USE_FOUNDRY"
                  printf 'broker=<%s>\\n' "$OMP_AUTH_BROKER_TOKEN"
                  printf 'home=<%s>\\n' "$HOME"
                  printf 'unrelated=<%s>\\n' "$UNRELATED_PARENT_VALUE"
                } > '\(capture.path)'
                printf '%s\\n' '{"models":[{"selector":"provider/selected"},{"selector":"provider/other"}]}'
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let environment = [
                "HOME": "/Users/tester",
                "PATH": "/usr/bin:/bin",
                "OPENAI_API_KEY": "openai-secret",
                "GEMINI_API_KEY": "gemini-secret",
                "OMP_AUTH_BROKER_TOKEN": "broker-secret",
                "ANTHROPIC_BASE_URL": "https://dotenv-router.invalid",
                "CLAUDE_CODE_USE_FOUNDRY": "true",
                "UNRELATED_PARENT_VALUE": "drop-me",
            ]

            let ready = await OmpModelsProbe.check(
                executableURL: fixture.url,
                argumentPrefix: [],
                model: "provider/selected",
                timeoutMs: 1_000,
                environment: environment,
                profileDirectory: nil
            )
            #expect(ready == .ok(models: 2))
            let capturedEnvironment = try String(contentsOf: capture, encoding: .utf8)
            // The catalog query is the one omp call that runs without the
            // credential tombstones, because omp advertises a provider whenever
            // its variable is set: shadowed, `omp models` lists ~50 providers the
            // refiner cannot reach, and `GITLAB_TOKEN=" "` makes it hang forever.
            // Dropping the names entirely keeps the leak closed either way — a
            // credential inherited from the launching shell still never reaches
            // the child.
            #expect(capturedEnvironment.contains("openai=<>"))
            #expect(capturedEnvironment.contains("openai_set=<>"))
            #expect(capturedEnvironment.contains("gemini=<>"))
            #expect(capturedEnvironment.contains("anthropic_base=<>"))
            #expect(capturedEnvironment.contains("foundry=<false>"))
            #expect(!capturedEnvironment.contains("openai-secret"))
            #expect(!capturedEnvironment.contains("gemini-secret"))
            #expect(!capturedEnvironment.contains("https://dotenv-router.invalid"))
            #expect(capturedEnvironment.contains("broker=<broker-secret>"))
            #expect(capturedEnvironment.contains("home=</Users/tester>"))
            #expect(capturedEnvironment.contains("unrelated=<>"))

            // The transcript-bearing path keeps them, which is what the
            // tombstones are for: omp's dotenv loader must not refill a
            // credential the user never paired with this app.
            let refinerEnvironment = OmpEnvironment.augmented(environment)
            #expect(refinerEnvironment["OPENAI_API_KEY"] == OmpEnvironment.dotenvTombstone)
            #expect(refinerEnvironment["GEMINI_API_KEY"] == OmpEnvironment.dotenvTombstone)
            #expect(refinerEnvironment["ANTHROPIC_BASE_URL"] == OmpEnvironment.dotenvTombstone)
            #expect(refinerEnvironment["OMP_AUTH_BROKER_TOKEN"] == "broker-secret")
            #expect(refinerEnvironment["UNRELATED_PARENT_VALUE"] == nil)

            let unavailable = await OmpModelsProbe.check(
                executableURL: fixture.url,
                argumentPrefix: [],
                model: "provider/missing",
                timeoutMs: 1_000,
                environment: environment,
                profileDirectory: nil
            )
            #expect(
                unavailable
                    == .failed(
                        "selected model unavailable: provider/missing (2 models)"
                    ))
        }

        @Test func ompOnboardingRunsIsolatedLoginAndLoadsModels() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpOnboarding-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let loginCapture = root.appendingPathComponent("login.txt")
            let modelsCapture = root.appendingPathComponent("models-provider.txt")
            let fixture = try makeExecutableScript(
                """
                if [ "$1" = "auth-broker" ] && [ "$2" = "list" ]; then
                  printf '%s\\n' '[{"id":"anthropic","name":"Anthropic (Claude Pro/Max)"}]'
                elif [ "$1" = "auth-broker" ] && [ "$2" = "login" ]; then
                  {
                    printf 'provider=<%s>\\n' "$3"
                    printf 'openai=<%s>\\n' "$OPENAI_API_KEY"
                  } > '\(loginCapture.path)'
                elif [ "$1" = "models" ]; then
                  printf '%s' "$2" > '\(modelsCapture.path)'
                  printf '%s\n' '{"models":[{"selector":"anthropic/claude-haiku-4-5","name":"Claude Haiku 4.5"}]}'
                else
                  exit 64
                fi
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let session = try await OmpOnboarding.begin(
                subscription: .claude,
                executableURL: fixture.url,
                argumentPrefix: [],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin",
                    "OPENAI_API_KEY": "must-not-reach-login",
                ],
                profileDirectory: nil,
                sessionRoot: root.appendingPathComponent("sessions", isDirectory: true),
                openScript: { scriptURL in
                    let process = Process()
                    process.executableURL = scriptURL
                    do {
                        try process.run()
                        return true
                    } catch {
                        return false
                    }
                }
            )
            let outcome = await OmpOnboarding.finish(
                session,
                environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                modelTimeoutMs: 1_000,
                pollNanoseconds: 1_000_000
            )

            let expectedModel = OmpAvailableModel(
                provider: "anthropic",
                selector: "anthropic/claude-haiku-4-5",
                name: "Claude Haiku 4.5"
            )
            #expect(outcome == .signedIn(models: [expectedModel], catalogWarning: nil))
            let login = try String(contentsOf: loginCapture, encoding: .utf8)
            #expect(login.contains("provider=<anthropic>"))
            #expect(login.contains("openai=< >"))
            #expect(!login.contains("must-not-reach-login"))
            #expect(!FileManager.default.fileExists(atPath: session.directoryURL.path))
            #expect(try String(contentsOf: modelsCapture, encoding: .utf8) == "anthropic")
        }

        @Test func ompProviderStatusProbeAggregatesRedactedInventoryWithoutSecrets() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpStatus-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let capture = root.appendingPathComponent("usage-environment.txt")
            let fixture = try makeExecutableScript(
                """
                if [ "$1" = "usage" ]; then
                  {
                    printf 'args=<%s>\n' "$*"
                    printf 'openai=<%s>\n' "$OPENAI_API_KEY"
                    printf 'unrelated=<%s>\n' "$UNRELATED_PARENT_VALUE"
                  } > '\(capture.path)'
                  printf '%s\n' '{"reports":[{"provider":"openai-codex"},{"provider":"openai-codex"},{"provider":"anthropic"}],"accountsWithoutUsage":[{"provider":"kimi-code"},{"provider":"cursor"}],"disabledCredentials":[{"provider":"google-gemini-cli"}]}'
                elif [ "$1" = "auth-broker" ] && [ "$2" = "list" ]; then
                  printf '%s\n' '[{"id":"openai-codex","name":"ChatGPT Plus/Pro (Codex Subscription)"},{"id":"anthropic","name":"Anthropic (Claude Pro/Max)"},{"id":"google-gemini-cli","name":"Google Cloud Code Assist (Gemini CLI)"},{"id":"kimi-code","name":"Kimi Code"},{"id":"cursor","name":"Cursor (Claude, GPT, etc.)"}]'
                else
                  exit 64
                fi
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let snapshot = try await OmpProviderStatusProbe.load(
                executableURL: fixture.url,
                argumentPrefix: [],
                timeoutMs: 1_000,
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin",
                    "OPENAI_API_KEY": "must-not-reach-status",
                    "UNRELATED_PARENT_VALUE": "drop-me",
                ],
                profileDirectory: nil
            )

            #expect(
                snapshot.connections == [
                    OmpProviderConnection(
                        providerID: "anthropic",
                        displayName: "Anthropic",
                        activeAccounts: 1,
                        reportingAccounts: 1,
                        disabledAccounts: 0
                    ),
                    OmpProviderConnection(
                        providerID: "openai-codex",
                        displayName: "ChatGPT Plus/Pro",
                        activeAccounts: 2,
                        reportingAccounts: 2,
                        disabledAccounts: 0
                    ),
                    OmpProviderConnection(
                        providerID: "cursor",
                        displayName: "Cursor",
                        activeAccounts: 1,
                        reportingAccounts: 0,
                        disabledAccounts: 0
                    ),
                    OmpProviderConnection(
                        providerID: "google-gemini-cli",
                        displayName: "Google Cloud Code Assist",
                        activeAccounts: 0,
                        reportingAccounts: 0,
                        disabledAccounts: 1
                    ),
                    OmpProviderConnection(
                        providerID: "kimi-code",
                        displayName: "Kimi Code",
                        activeAccounts: 1,
                        reportingAccounts: 0,
                        disabledAccounts: 0
                    ),
                ])
            let captured = try String(contentsOf: capture, encoding: .utf8)
            #expect(captured.contains("args=<usage --json --redact>"))
            #expect(captured.contains("openai=< >"))
            #expect(captured.contains("unrelated=<>"))
            #expect(!captured.contains("must-not-reach-status"))
            #expect(!captured.contains("drop-me"))
        }

        @Test func ompModelsProbeUsesRuntimeProfileAndUnionsGlobalDisabledProviders() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpProfileProbe-\(UUID().uuidString)", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            let agent =
                home
                .appendingPathComponent(".omp", isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
            let profile = root.appendingPathComponent("profile", isDirectory: true)
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try """
            disabledProviders:
              - anthropic
              - paths:
                  - \(root.path)
                providers:
                  - groq
              - path: /definitely/not/the/refiner/profile
                values:
                  - openai
            """.write(
                to: agent.appendingPathComponent("config.yml"),
                atomically: true,
                encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: root) }

            let cwdCapture = root.appendingPathComponent("cwd.txt")
            let fixture = try makeExecutableScript(
                """
                printf '%s' "$PWD" > '\(cwdCapture.path)'
                printf '%s\\n' '{"models":[{"selector":"openai/selected"}]}'
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let result = await OmpModelsProbe.check(
                executableURL: fixture.url,
                argumentPrefix: [],
                model: "openai/selected",
                timeoutMs: 1_000,
                environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
                profileDirectory: profile
            )
            #expect(result == .ok(models: 1))
            let capturedCWD = try String(contentsOf: cwdCapture, encoding: .utf8)
            #expect(
                URL(fileURLWithPath: capturedCWD).resolvingSymlinksInPath().path
                    == profile.resolvingSymlinksInPath().path
            )

            let settingsData = try Data(
                contentsOf:
                    profile
                    .appendingPathComponent(".omp", isDirectory: true)
                    .appendingPathComponent("settings.json"))
            let settings = try #require(
                JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
            )
            let disabled = try #require(settings["disabledProviders"] as? [String])
            #expect(disabled.contains("anthropic"))
            #expect(disabled.contains("cursor"))
            #expect(disabled.contains("groq"))
            #expect(!disabled.contains("openai"))
            #expect(disabled.contains("native"))
            #expect(disabled.contains("agents-md"))
        }

    }
}
