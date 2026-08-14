#if UI_HARNESS

    import Foundation

    func repositoryRoot() -> URL? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

#endif
