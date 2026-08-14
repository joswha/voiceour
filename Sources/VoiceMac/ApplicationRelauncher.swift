import Foundation

/// Launches a fresh Voiceour process before the current process exits. The app
/// layer owns the cleanup ordering; this adapter owns only Process setup.
public protocol ApplicationRelaunching {
    func launch(arguments: [String], environment: [String: String]) throws
}

public struct ProcessApplicationRelauncher: ApplicationRelaunching {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func launch(arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        try process.run()
    }
}
