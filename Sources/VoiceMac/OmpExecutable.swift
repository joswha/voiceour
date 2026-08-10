import Foundation

public enum OmpExecutable {
    public static func resolve(explicitPath: String?) -> (url: URL, prefix: [String]) {
        let fileManager = FileManager.default
        if let explicitPath, fileManager.isExecutableFile(atPath: explicitPath) {
            return (URL(fileURLWithPath: explicitPath), [])
        }

        let candidates = [
            "~/.bun/bin/omp",
            "/opt/homebrew/bin/omp",
            "/usr/local/bin/omp",
        ]

        for candidate in candidates {
            let path = (candidate as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: path) {
                return (URL(fileURLWithPath: path), [])
            }
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), ["omp"])
    }
}
