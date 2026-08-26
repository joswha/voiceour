// Copies fixtures/media/console-sample into a support directory for
// `scripts/console_shot.sh`, rebasing every date so the capture looks like a
// Mac that has been dictating up to today.
//
// The fixture carries the harness's own pinned dates. Left alone they would
// slide out of the activity grid — the ledger prunes day buckets past 400 days —
// so a screenshot regenerated a year from now would show an empty grid and a
// zero streak. Rebasing keeps one committed fixture correct indefinitely: every
// day key, every app's `lastDay` and every transcript stamp moves by the same
// offset, so the streaks, the gaps and the ordering are exactly the fixture's.
//
// Usage: seed_console_data <fixture-dir> <destination-dir>
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: seed_console_data <fixture-dir> <destination-dir>\n".utf8))
    exit(64)
}
let fixtureDirectory = URL(fileURLWithPath: arguments.first!, isDirectory: true)
let destinationDirectory = URL(fileURLWithPath: arguments.last!, isDirectory: true)

let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}()

let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("seed_console_data: \(message)\n".utf8))
    exit(1)
}

func loadJSON(_ name: String) -> Any {
    let url = fixtureDirectory.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url) else { fail("cannot read \(url.path)") }
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
        fail("\(name) is not JSON")
    }
    return json
}

func writeJSON(_ value: Any, to name: String) {
    let url = destinationDirectory.appendingPathComponent(name)
    guard
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else {
        fail("cannot encode \(name)")
    }
    do {
        try data.write(to: url, options: [.atomic])
    } catch {
        fail("cannot write \(url.path): \(error)")
    }
}

guard var ledger = loadJSON("dictation-activity.json") as? [String: Any],
    var days = ledger["days"] as? [String: Any]
else {
    fail("dictation-activity.json has no day buckets")
}

// The offset that lands the fixture's newest day on today. Whole days only, so
// a rebased key is always the same wall-clock day it was relative to the rest.
let fixtureDays = days.keys.compactMap { dayFormatter.date(from: $0) }
guard let newestFixtureDay = fixtureDays.max() else { fail("no parseable day keys") }
let today = calendar.startOfDay(for: Date())
guard
    let offsetDays = calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: newestFixtureDay), to: today
    ).day
else {
    fail("cannot measure the rebase offset")
}

func rebase(_ key: String) -> String {
    guard let date = dayFormatter.date(from: key),
        let moved = calendar.date(byAdding: .day, value: offsetDays, to: date)
    else {
        fail("unparseable day key \(key)")
    }
    return dayFormatter.string(from: moved)
}

days = Dictionary(uniqueKeysWithValues: days.map { (rebase($0.key), $0.value) })
ledger["days"] = days

if let apps = ledger["apps"] as? [String: [String: Any]] {
    ledger["apps"] = apps.mapValues { app -> [String: Any] in
        guard let lastDay = app["lastDay"] as? String else { return app }
        var moved = app
        moved["lastDay"] = rebase(lastDay)
        return moved
    }
}

writeJSON(ledger, to: "dictation-activity.json")

// Transcripts move by the same offset, then land two hours ago rather than at
// midnight: History stamps the newest row, and a row dated later than now reads
// as a clock bug.
if var sessions = loadJSON("recent-sessions.json") as? [[String: Any]] {
    let stamps = sessions.compactMap { $0["createdAt"] as? Double }
    if let newestStamp = stamps.max() {
        let target = Date(timeIntervalSinceNow: -2 * 3600).timeIntervalSinceReferenceDate
        let shift = target - newestStamp
        sessions = sessions.map { session in
            guard let createdAt = session["createdAt"] as? Double else { return session }
            var moved = session
            moved["createdAt"] = createdAt + shift
            return moved
        }
    }
    writeJSON(sessions, to: "recent-sessions.json")
}

print("rebased \(days.count) days by \(offsetDays) days into \(destinationDirectory.path)")
