import Foundation

public enum RecordingScavenger {
    /// Deletes stale WAVs left by crashes/sleep. Safe for live recordings:
    /// only files older than maxAge are removed.
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
