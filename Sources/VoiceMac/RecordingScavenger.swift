import Foundation

/// The single source of truth for the capture temp directory: WAV minting and the app
/// layer's launch-time stale-audio sweep both name it here, so the two cannot diverge.
///
/// That coupling is the whole point. Minting into one path while sweeping another would
/// leak recordings silently, and nothing would fail loudly enough to notice.
public enum CaptureTemporaryFile {
    /// `<temp>/voiceour`. Public because ``RecordingScavenger/sweep(directory:olderThan:now:)``
    /// is driven from the app layer, which must sweep exactly the directory recorders mint into.
    public static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voiceour", isDirectory: true)

    /// Creates the directory if needed and returns a fresh, unused WAV URL inside it.
    ///
    /// Throwing here is the recorder's cheapest failure: it happens before anything is
    /// written, so there is no capture file for startup failure to have to remove.
    static func makeWAVURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    }
}

public enum RecordingScavenger {
    /// Deletes stale capture files left by crashes/sleep. Every regular file in the app's temp
    /// directory is a candidate, deliberately — the directory is ours, and a filter by
    /// extension would strand the next artefact we add.
    /// Safe for live recordings: only files older than maxAge are removed.
    public static func sweep(
        directory: URL,
        olderThan maxAge: TimeInterval = 3600,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: []
            )
        else {
            return
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        for file in files {
            guard
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                values.isRegularFile == true,
                let modificationDate = values.contentModificationDate,
                modificationDate < cutoff
            else {
                continue
            }

            try? fileManager.removeItem(at: file)
        }
    }
}
