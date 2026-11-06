import Foundation
import os

/// Launch-time removal of model caches no build reads any more.
///
/// The NVIDIA Parakeet TDT recognizer's two conversions cached their weights and a derived
/// weight arena (about 2.5 GB for f16) in `parakeet-tdt-0.6b-v3-ggml` and
/// `parakeet-tdt-0.6b-v3-ggml-q8_0` under the app's cache root. Granite, the one recognizer,
/// caches beside them in its own directory, so they would otherwise stay on disk for good with
/// no surface able to clear them.
///
/// Only the app's own cache root is swept, by exact directory name. A caller-owned
/// `VOICEOUR_MODEL_CACHE` is never touched: what its caller keeps there stays theirs.
public enum RetiredModelCacheSweep {
    /// `~/Library/Caches/Voiceour`, the root every cache directory the sidecar owns lives under.
    public static let applicationCacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Voiceour", isDirectory: true)

    public static let retiredDirectoryNames = [
        "parakeet-tdt-0.6b-v3-ggml",
        "parakeet-tdt-0.6b-v3-ggml-q8_0",
    ]

    private static let log = Logger(subsystem: "com.voiceour.app", category: "model")

    /// Deletes every retired directory present under `cacheRoot`. Best-effort: a directory
    /// that cannot be removed is reported through `logFailure` and left for the next launch,
    /// never thrown, because nothing here may cost a launch. Nil `logFailure` logs to the app's
    /// `model` category.
    public static func sweep(
        cacheRoot: URL = applicationCacheRoot,
        logFailure: ((String) -> Void)? = nil
    ) {
        let logFailure = logFailure ?? { log.error("\($0, privacy: .public)") }
        let fileManager = FileManager.default
        for name in retiredDirectoryNames {
            let directory = cacheRoot.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                logFailure("could not remove retired model cache \(directory.path): \(error)")
            }
        }
    }
}
