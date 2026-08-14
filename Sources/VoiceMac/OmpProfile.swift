import Foundation
import VoiceCore

/// Hermetic project profile for the refiner's RPC child.
///
/// Project settings isolate refinement from interactive agent state while
/// retaining every model provider the user disabled globally.
public enum OmpRpcProfile {
    static let discoveryProviderIDs = [
        "native", "claude", "codex", "gemini",
        "github", "opencode", "cursor", "agents", "agents-md",
    ]

    public static func defaultDirectory() -> URL {
        URL.voiceourSupportDirectory.appendingPathComponent("omp-rpc", isDirectory: true)
    }

    static var settingsJSON: String {
        get throws {
            try renderedSettingsJSON(
                disabledProviders: discoveryProviderIDs
            )
        }
    }

    static func provision(
        at directory: URL,
        environment: [String: String] = [:]
    ) throws {
        let globallyDisabled = try globalDisabledProviders(
            environment: environment,
            currentDirectory: directory
        )
        var seen = Set(discoveryProviderIDs)
        let disabledProviders =
            discoveryProviderIDs
            + globallyDisabled
            .filter { seen.insert($0).inserted }
            .sorted()
        let payload = Data(
            try renderedSettingsJSON(
                disabledProviders: disabledProviders
            ).utf8)

        let configDirectory = directory.appendingPathComponent(".omp", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let settingsURL = configDirectory.appendingPathComponent("settings.json")
        if let existing = try? Data(contentsOf: settingsURL), existing == payload {
            return
        }
        try payload.write(to: settingsURL, options: [.atomic])
    }

    private static func renderedSettingsJSON(disabledProviders: [String]) throws -> String {
        let settings: [String: Any] = [
            "disabledProviders": disabledProviders,
            "marketplace": ["autoUpdate": "off"],
            "mcp": ["enableProjectConfig": false],
            "memories": ["enabled": false],
            "memory": ["backend": "off"],
            "providers": ["anthropic": ["serverSideFallback": false]],
            "retry": ["modelFallback": false],
            "tools": ["approvalMode": "always-ask", "xdev": false],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func globalDisabledProviders(
        environment: [String: String],
        currentDirectory: URL
    ) throws -> [String] {
        guard
            let home = environment["HOME"],
            !home.isEmpty,
            let agentDirectory = try globalAgentDirectory(environment: environment)
        else {
            return []
        }
        let fileManager = FileManager.default
        for name in ["config.yml", "config.yaml"] {
            let url = agentDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                let contents = try String(contentsOf: url, encoding: .utf8)
                return disabledProviders(
                    inYAML: contents,
                    currentDirectory: currentDirectory,
                    home: home
                )
            }
        }

        let legacyURL = agentDirectory.appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else { return [] }
        let data = try Data(contentsOf: legacyURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OmpRpcError.launchFailed("global settings JSON is not an object")
        }
        guard let rawProviders = object["disabledProviders"] else { return [] }
        guard let entries = rawProviders as? [Any] else {
            throw OmpRpcError.launchFailed("global disabledProviders is not an array")
        }
        return resolvedProviderEntries(
            entries,
            currentDirectory: currentDirectory,
            home: home
        )
    }

    private static func globalAgentDirectory(
        environment: [String: String]
    ) throws -> URL? {
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        let rawProfile =
            environment.keys.contains("OMP_PROFILE")
            ? environment["OMP_PROFILE"]
            : environment["PI_PROFILE"]
        let profile = rawProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeProfile = profile.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }

        if let activeProfile {
            guard
                activeProfile.range(
                    of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#,
                    options: .regularExpression
                ) != nil
            else {
                throw OmpRpcError.launchFailed("invalid OMP profile name")
            }
            let root = configRoot(home: home, environment: environment)
            return
                root
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(activeProfile, isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
        }

        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            guard override.hasPrefix("/") else {
                throw OmpRpcError.launchFailed("PI_CODING_AGENT_DIR must be absolute")
            }
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return configRoot(home: home, environment: environment)
            .appendingPathComponent("agent", isDirectory: true)
    }

    private static func configRoot(
        home: String,
        environment: [String: String]
    ) -> URL {
        let configured =
            environment["PI_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? ".omp"
        let relative = configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
            .standardizedFileURL
    }

    private static func disabledProviders(
        inYAML contents: String,
        currentDirectory: URL,
        home: String
    ) -> [String] {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard
            let declarationIndex = lines.firstIndex(where: {
                !$0.hasPrefix(" ") && !$0.hasPrefix("\t")
                    && $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasPrefix("disabledProviders:")
            })
        else {
            return []
        }

        let declaration = lines[declarationIndex]
        let suffix = String(declaration.dropFirst("disabledProviders:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty {
            guard suffix.first == "[", suffix.last == "]" else { return [] }
            return yamlValues(in: suffix).compactMap(validatedProviderID)
        }

        var providers: [String] = []
        var index = declarationIndex + 1
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            let indent = leadingWhitespaceCount(raw)
            if indent == 0 { break }
            guard trimmed.hasPrefix("-") else {
                index += 1
                continue
            }

            let item = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.contains(":") {
                if let provider = validatedProviderID(unquoted(item)) {
                    providers.append(provider)
                }
                index += 1
                continue
            }

            var objectLines = [item]
            index += 1
            while index < lines.count {
                let nestedRaw = lines[index]
                let nestedTrimmed = nestedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                if nestedTrimmed.isEmpty || nestedTrimmed.hasPrefix("#") {
                    index += 1
                    continue
                }
                if leadingWhitespaceCount(nestedRaw) <= indent { break }
                objectLines.append(nestedTrimmed)
                index += 1
            }
            providers.append(
                contentsOf: resolvedYAMLScopedEntry(
                    objectLines,
                    currentDirectory: currentDirectory,
                    home: home
                ))
        }
        return providers
    }

    private static func resolvedProviderEntries(
        _ entries: [Any],
        currentDirectory: URL,
        home: String
    ) -> [String] {
        var providers: [String] = []
        for entry in entries {
            if let value = entry as? String {
                if let provider = validatedProviderID(value) {
                    providers.append(provider)
                }
                continue
            }
            guard let object = entry as? [String: Any] else { continue }
            let paths = ["path", "paths", "pathPrefix", "pathPrefixes"]
                .flatMap { stringValues(object[$0]) }
            guard
                paths.contains(where: {
                    path($0, contains: currentDirectory, home: home)
                })
            else { continue }
            providers.append(
                contentsOf: ["providers", "values", "items"]
                    .flatMap { stringValues(object[$0]) }
                    .compactMap(validatedProviderID)
            )
        }
        return providers
    }

    private static func resolvedYAMLScopedEntry(
        _ lines: [String],
        currentDirectory: URL,
        home: String
    ) -> [String] {
        enum Section {
            case paths
            case providers
            case ignored
        }

        var section = Section.ignored
        var paths: [String] = []
        var providers: [String] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") {
                let value = unquoted(String(trimmed.dropFirst()))
                switch section {
                case .paths:
                    paths.append(value)
                case .providers:
                    providers.append(value)
                case .ignored:
                    break
                }
                continue
            }
            guard let separator = trimmed.firstIndex(of: ":") else {
                section = .ignored
                continue
            }
            let key = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ["path", "paths", "pathPrefix", "pathPrefixes"].contains(key) {
                section = .paths
                paths.append(contentsOf: yamlValues(in: suffix))
            } else if ["providers", "values", "items"].contains(key) {
                section = .providers
                providers.append(contentsOf: yamlValues(in: suffix))
            } else {
                section = .ignored
            }
        }

        guard
            paths.contains(where: {
                path($0, contains: currentDirectory, home: home)
            })
        else { return [] }
        return providers.compactMap(validatedProviderID)
    }

    private static func stringValues(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func yamlValues(in value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.first == "[", trimmed.last == "]" {
            return trimmed.dropFirst().dropLast().split(separator: ",")
                .map { unquoted(String($0)) }
        }
        return [unquoted(trimmed)]
    }

    private static func path(
        _ configuredPath: String,
        contains currentDirectory: URL,
        home: String
    ) -> Bool {
        let expanded: URL
        if configuredPath == "~" {
            expanded = URL(fileURLWithPath: home, isDirectory: true)
        } else if configuredPath.hasPrefix("~/") {
            expanded = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(configuredPath.dropFirst(2)), isDirectory: true)
        } else if configuredPath.hasPrefix("/") {
            expanded = URL(fileURLWithPath: configuredPath, isDirectory: true)
        } else {
            expanded = currentDirectory.appendingPathComponent(configuredPath, isDirectory: true)
        }
        let root = expanded.standardizedFileURL.path
        let current = currentDirectory.standardizedFileURL.path
        return current == root || current.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func leadingWhitespaceCount(_ value: String) -> Int {
        value.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func unquoted(_ value: String) -> String {
        let withoutComment =
            value.split(separator: "#", maxSplits: 1)
            .first.map(String.init) ?? value
        let trimmed = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.count >= 2,
            let first = trimmed.first,
            first == trimmed.last,
            first == "\"" || first == "'"
        else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func validatedProviderID(_ value: String) -> String? {
        guard
            !value.isEmpty,
            value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }
        return value
    }
}
public enum OmpModelsProbe {
    public static func check(
        executableURL: URL,
        argumentPrefix: [String],
        model: String,
        timeoutMs: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileDirectory: URL? = OmpRpcProfile.defaultDirectory()
    ) async -> RefinerReachability {
        do {
            let models = try await OmpModelCatalog.load(
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                providerID: model.split(separator: "/", maxSplits: 1).first.map(String.init),
                timeoutMs: timeoutMs,
                environment: environment,
                profileDirectory: profileDirectory
            )
            guard !models.isEmpty else {
                return .failed("no models — sign in from Voiceour or run: omp auth-broker login <provider>")
            }
            guard models.contains(where: { $0.selector == model }) else {
                return .failed("selected model unavailable: \(model) (\(models.count) models)")
            }
            return .ok(models: models.count)
        } catch let error as OmpProcessError {
            return .failed(error.shortMessage)
        } catch let error as OmpRpcError {
            return .failed(error.shortMessage)
        } catch let error as OmpModelCatalogError {
            return .failed(error.shortMessage)
        } catch {
            return .failed("invalid models JSON")
        }
    }
}
