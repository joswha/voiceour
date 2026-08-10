import Darwin
import Foundation
import Testing

@testable import VoiceMac

/// Covers one-shot OMP process invocation and descendant termination.
extension OmpSuites {
    @Suite("Process Support", .serialized)
    struct ProcessSupport {
        @Test func ompModelsProbeTimeoutKillsTermIgnoringParentWithPipeHoldingChild() async throws {
            let fixture = try makeExecutableScript(
                """
                trap '' TERM
                /bin/sleep 30 &
                printf '%s\\n' "$$" > "$0.parent-pid"
                printf '%s\\n' "$!" > "$0.child-pid"
                wait
                """)
            defer {
                for file in [
                    fixture.url.appendingPathExtension("parent-pid"),
                    fixture.url.appendingPathExtension("child-pid"),
                ] {
                    for pid in processIDs(in: file) {
                        _ = kill(pid, SIGKILL)
                    }
                }
                try? FileManager.default.removeItem(at: fixture.directory)
            }

            let result = await OmpModelsProbe.check(
                executableURL: fixture.url,
                argumentPrefix: [],
                model: "provider/selected",
                timeoutMs: 500,
                environment: ["HOME": "/Users/tester", "PATH": "/usr/bin:/bin"],
                profileDirectory: nil
            )
            #expect(result == .failed("omp timed out"))
            let parentPID = try #require(
                await awaitProcessIDs(
                    in: fixture.url.appendingPathExtension("parent-pid")
                ).first)
            #expect(await waitForProcessExit(parentPID))
            let childPID = try #require(
                await awaitProcessIDs(
                    in: fixture.url.appendingPathExtension("child-pid")
                ).first)
            #expect(await waitForProcessExit(childPID))
        }

        @Test func ompModelsProbeDoesNotExposeRawStderr() async throws {
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' 'provider-secret-value' >&2
                exit 7
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let result = await OmpModelsProbe.check(
                executableURL: fixture.url,
                argumentPrefix: [],
                model: "provider/selected",
                timeoutMs: 1_000,
                environment: ["HOME": "/Users/tester", "PATH": "/usr/bin:/bin"],
                profileDirectory: nil
            )
            #expect(result == .failed("omp exited with status 7 (stderr: 22 bytes)"))
            if case .failed(let reason) = result {
                #expect(!reason.contains("provider-secret-value"))
            }
        }

        @Test func ompExecutableResolvePrefersExecutableExplicitPathAndIgnoresMissingPath() {
            let explicit = OmpExecutable.resolve(explicitPath: "/bin/echo")
            #expect(explicit.url.path == "/bin/echo")
            #expect(explicit.prefix.isEmpty)

            let missing = OmpExecutable.resolve(explicitPath: "/nonexistent/omp-xyz")
            #expect(missing.prefix.isEmpty || missing.prefix == ["omp"])
            if missing.prefix == ["omp"] {
                #expect(missing.url.path == "/usr/bin/env")
            }
        }

    }
}
