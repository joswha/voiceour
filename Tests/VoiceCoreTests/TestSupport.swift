import Foundation

/// Fixtures shared by more than one `VoiceCoreTests` file. Swift test targets
/// cannot import one another, so each target keeps its own support file;
/// single-consumer, behaviour-specific helpers stay private to their own file.

// MARK: Deterministic time

// Fixed, wall-time-independent fixtures. UTC has no DST, so subtracting a
// whole day always moves exactly one calendar day back — that determinism
// is the whole point of injecting the calendar.
let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
let day: TimeInterval = 86_400

// MARK: Transcript bodies

/// Builds a body with exactly `n` whitespace-separated words.
func text(_ n: Int) -> String {
    n <= 0 ? "" : (1...n).map { "w\($0)" }.joined(separator: " ")
}

func isClose(_ value: Double?, _ expected: Double, tol: Double = 1e-6) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < tol
}

// MARK: File fixtures

func temporaryCoreTestFile(named fileName: String) -> (directory: URL, url: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
    return (directory, directory.appendingPathComponent(fileName))
}

func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
