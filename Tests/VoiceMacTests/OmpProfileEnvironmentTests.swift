import Foundation
import Testing

@testable import VoiceMac

/// Covers OMP profile provisioning, launch arguments, and environment sanitization.
extension OmpSuites {
    @Suite("Profile and Environment", .serialized)
    struct ProfileEnvironment {
        @Test func ompRpcProfileSerializesSupportedIsolationSettings() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpProfile-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            try OmpRpcProfile.provision(at: directory)
            let settingsURL =
                directory
                .appendingPathComponent(".omp", isDirectory: true)
                .appendingPathComponent("settings.json")
            let data = try Data(contentsOf: settingsURL)

            let settings = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let memory = try #require(settings["memory"] as? [String: Any])
            let memories = try #require(settings["memories"] as? [String: Any])
            let marketplace = try #require(settings["marketplace"] as? [String: Any])
            let mcp = try #require(settings["mcp"] as? [String: Any])
            let tools = try #require(settings["tools"] as? [String: Any])
            let retry = try #require(settings["retry"] as? [String: Any])
            let providers = try #require(settings["providers"] as? [String: Any])
            let anthropic = try #require(providers["anthropic"] as? [String: Any])
            #expect(memory["backend"] as? String == "off")
            #expect(memories["enabled"] as? Bool == false)
            #expect(marketplace["autoUpdate"] as? String == "off")
            #expect(mcp["enableProjectConfig"] as? Bool == false)
            #expect(tools["xdev"] as? Bool == false)
            #expect(tools["approvalMode"] as? String == "always-ask")
            #expect(retry["modelFallback"] as? Bool == false)
            #expect(anthropic["serverSideFallback"] as? Bool == false)
            #expect(
                settings["disabledProviders"] as? [String] == [
                    "native", "claude", "codex", "gemini",
                    "github", "opencode", "cursor", "agents", "agents-md",
                ])
        }

        @Test func ompRpcLaunchUsesNoToolsAndAlwaysAskApproval() {
            let configuration = OmpRpcRefinerConfiguration(
                enabled: true,
                executableURL: URL(fileURLWithPath: "/tmp/omp"),
                argumentPrefix: ["launcher-prefix"],
                model: "provider/selected"
            )
            let arguments = OmpRpcRefiner.arguments(for: configuration)

            #expect(arguments.first == "launcher-prefix")
            #expect(arguments.contains("--no-tools"))
            #expect(!arguments.contains("--tools"))
            #expect(
                arguments.enumerated().contains { index, argument in
                    argument == "--approval-mode"
                        && arguments.indices.contains(index + 1)
                        && arguments[index + 1] == "always-ask"
                })
        }

        @Test func ompEnvironmentStripsSecretsShadowsDotenvAndPreservesAuthRuntime() {
            let environment = OmpEnvironment.augmented([
                "HOME": "/Users/tester",
                "PATH": "/custom/bin:/usr/bin",
                "TMPDIR": "/private/tmp/",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "XDG_CONFIG_HOME": "/tmp/config",
                "HTTPS_PROXY": "http://proxy.invalid",
                "SSL_CERT_FILE": "/tmp/ca.pem",
                "NODE_EXTRA_CA_CERTS": "/tmp/injected-ca.pem",
                "BUN_INSTALL": "/custom/bun",
                "OMP_PROFILE": "work",
                "PI_CODING_AGENT_DIR": "/tmp/agent",
                "OMP_AUTH_BROKER_URL": "https://broker.invalid",
                "OMP_AUTH_BROKER_TOKEN": "broker-secret",
                "CLAUDE_CODE_USE_FOUNDRY": "true",
                "ANTHROPIC_BASE_URL": "https://dotenv-router.invalid",
                "ANTHROPIC_CUSTOM_HEADERS": "x-direct-secret: header-secret",
                "OPENAI_API_KEY": "openai-secret",
                "GEMINI_API_KEY": "gemini-secret",
                "OPENROUTER_API_KEY": "openrouter-secret",
                "UNRELATED_PARENT_VALUE": "drop-me",
            ])

            #expect(
                OmpEnvironment.shadowedCredentialNames.allSatisfy {
                    environment[$0] == OmpEnvironment.dotenvTombstone
                        && environment[$0]?.isEmpty == false
                })
            #expect(!environment.values.contains("openai-secret"))
            #expect(!environment.values.contains("gemini-secret"))
            #expect(!environment.values.contains("openrouter-secret"))
            #expect(!environment.values.contains("https://dotenv-router.invalid"))
            #expect(!environment.values.contains("x-direct-secret: header-secret"))
            #expect(environment["HOME"] == "/Users/tester")
            #expect(environment["TMPDIR"] == "/private/tmp/")
            #expect(environment["LANG"] == "en_US.UTF-8")
            #expect(environment["LC_ALL"] == "en_US.UTF-8")
            #expect(environment["XDG_CONFIG_HOME"] == "/tmp/config")
            #expect(environment["HTTPS_PROXY"] == "http://proxy.invalid")
            #expect(environment["SSL_CERT_FILE"] == "/tmp/ca.pem")
            #expect(environment["NODE_EXTRA_CA_CERTS"] == OmpEnvironment.dotenvTombstone)
            #expect(environment["BUN_INSTALL"] == "/custom/bun")
            #expect(environment["OMP_PROFILE"] == "work")
            #expect(environment["PI_CODING_AGENT_DIR"] == "/tmp/agent")
            #expect(environment["OMP_AUTH_BROKER_URL"] == "https://broker.invalid")
            #expect(environment["OMP_AUTH_BROKER_TOKEN"] == "broker-secret")
            #expect(environment["CLAUDE_CODE_USE_FOUNDRY"] == "false")
            #expect(environment["UNRELATED_PARENT_VALUE"] == nil)
        }

        @Test func ompEnvironmentTombstonesNamesFromEveryDotenvLayer() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpDotenv-\(UUID().uuidString)", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            let config = home.appendingPathComponent(".omp", isDirectory: true)
            let agent = config.appendingPathComponent("agent", isDirectory: true)
            let project = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try """
            export LITELLM_BASE_URL = "https://project-route.invalid"
            """.write(
                to: project.appendingPathComponent(".env"),
                atomically: true,
                encoding: .utf8
            )
            try """
            FUTURE_CUSTOM_HEADER='provider-secret'
            """.write(
                to: agent.appendingPathComponent(".env"),
                atomically: true,
                encoding: .utf8
            )
            try """
            OMP_FUTURE_ROUTE="https://config-route.invalid"
            """.write(
                to: config.appendingPathComponent(".env"),
                atomically: true,
                encoding: .utf8
            )
            try """
            CUSTOM_PROVIDER_PATH=`/tmp/provider-secret`
            OMP_AUTH_BROKER_TOKEN=dotenv-broker-secret
            BAD-NAME=ignored
            """.write(
                to: home.appendingPathComponent(".env"),
                atomically: true,
                encoding: .utf8
            )

            let environment = OmpEnvironment.augmented(
                [
                    "HOME": home.path,
                    "PATH": "/usr/bin:/bin",
                    "OMP_AUTH_BROKER_TOKEN": "parent-broker-secret",
                ],
                workingDirectory: project
            )
            for name in [
                "LITELLM_BASE_URL",
                "FUTURE_CUSTOM_HEADER",
                "OMP_FUTURE_ROUTE",
                "PI_FUTURE_ROUTE",
                "CUSTOM_PROVIDER_PATH",
            ] {
                #expect(environment[name] == OmpEnvironment.dotenvTombstone)
            }
            #expect(environment["OMP_AUTH_BROKER_TOKEN"] == "parent-broker-secret")
            #expect(environment["BAD-NAME"] == nil)
            #expect(!environment.values.contains("https://project-route.invalid"))
            #expect(!environment.values.contains("provider-secret"))
            #expect(!environment.values.contains("https://config-route.invalid"))
            #expect(!environment.values.contains("/tmp/provider-secret"))
            #expect(!environment.values.contains("dotenv-broker-secret"))
        }

        @Test func ompEnvironmentTombstoneBlocksDotenvRefillWhileEmptyDoesNot() {
            func loadingDotenv(
                _ dotenv: [String: String],
                into initial: [String: String]
            ) -> [String: String] {
                var environment = initial
                for (name, value) in dotenv
                where environment[name] == nil || environment[name] == "" {
                    environment[name] = value
                }
                return environment
            }

            let dotenv = [
                "OPENAI_API_KEY": "dotenv-secret",
                "ANTHROPIC_BASE_URL": "https://dotenv-router.invalid",
            ]
            let refillable = loadingDotenv(
                dotenv,
                into: ["OPENAI_API_KEY": ""]
            )
            #expect(refillable["OPENAI_API_KEY"] == "dotenv-secret")
            #expect(refillable["ANTHROPIC_BASE_URL"] == "https://dotenv-router.invalid")

            let protected = loadingDotenv(
                dotenv,
                into: OmpEnvironment.augmented([
                    "HOME": "/Users/tester",
                    "OPENAI_API_KEY": "parent-secret",
                    "ANTHROPIC_BASE_URL": "https://parent-router.invalid",
                ])
            )
            #expect(protected["OPENAI_API_KEY"] == OmpEnvironment.dotenvTombstone)
            #expect(protected["ANTHROPIC_BASE_URL"] == OmpEnvironment.dotenvTombstone)
            #expect(!protected.values.contains("parent-secret"))
            #expect(!protected.values.contains("dotenv-secret"))
            #expect(!protected.values.contains("https://parent-router.invalid"))
            #expect(!protected.values.contains("https://dotenv-router.invalid"))
        }
        @Test func ompEnvironmentAugmentsPathSoBunIsFound() {
            // A minimal Finder/launchd environment lacks ~/.bun/bin, so the omp launcher's
            // `exec bun` fails (exit 127). augmented() must guarantee bun is reachable.
            let minimal = ["HOME": "/Users/tester", "PATH": "/usr/bin:/bin"]
            let augmented = OmpEnvironment.augmented(minimal)
            let entries = (augmented["PATH"] ?? "").split(separator: ":").map(String.init)
            #expect(entries.first == "/Users/tester/.bun/bin")
            #expect(entries.contains("/usr/bin"))
            #expect(entries.contains("/bin"))
            #expect(entries.count == Set(entries).count)
            #expect(augmented["BUN_INSTALL"] == "/Users/tester/.bun")

            let customBun = OmpEnvironment.augmented(["HOME": "/Users/tester", "BUN_INSTALL": "/custom/bun"])
            #expect(customBun["BUN_INSTALL"] == "/custom/bun")
        }
    }
}
