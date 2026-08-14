import Foundation

public struct OmpProviderConnection: Equatable, Sendable, Identifiable {
    public let providerID: String
    public let displayName: String
    public let activeAccounts: Int
    public let reportingAccounts: Int
    public let disabledAccounts: Int

    public var id: String { providerID }
    public var isConnected: Bool { activeAccounts > 0 }

    public init(
        providerID: String,
        displayName: String,
        activeAccounts: Int,
        reportingAccounts: Int,
        disabledAccounts: Int
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.activeAccounts = activeAccounts
        self.reportingAccounts = reportingAccounts
        self.disabledAccounts = disabledAccounts
    }
}

public struct OmpProviderStatusSnapshot: Equatable, Sendable {
    public let connections: [OmpProviderConnection]

    public init(connections: [OmpProviderConnection]) {
        self.connections = connections
    }
}

public enum OmpProviderStatusError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Could not read Oh My Pi account status. \(detail)"
        case .invalidJSON:
            "Could not read Oh My Pi account status because `omp usage` returned invalid JSON."
        }
    }
}

private struct OmpProviderReference: Decodable {
    let provider: String
}

private struct OmpUsageEnvelope: Decodable {
    let reports: [OmpProviderReference]
    let accountsWithoutUsage: [OmpProviderReference]
    let disabledCredentials: [OmpProviderReference]

    private enum CodingKeys: String, CodingKey {
        case reports
        case accountsWithoutUsage
        case disabledCredentials
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reports = try container.decodeIfPresent([OmpProviderReference].self, forKey: .reports) ?? []
        accountsWithoutUsage =
            try container.decodeIfPresent(
                [OmpProviderReference].self,
                forKey: .accountsWithoutUsage
            ) ?? []
        disabledCredentials =
            try container.decodeIfPresent(
                [OmpProviderReference].self,
                forKey: .disabledCredentials
            ) ?? []
    }
}

private struct OmpAuthProvider: Decodable {
    let id: String
    let name: String
}

private struct OmpProviderCounts {
    var reporting = 0
    var withoutUsage = 0
    var disabled = 0
}

/// Reads OMP's redacted public usage inventory. VoiceOour deliberately ignores
/// account identities and receives only provider ids plus aggregate counts; it
/// never opens OMP's credential database or handles access/refresh tokens.
public enum OmpProviderStatusProbe {
    public static func load(
        executableURL: URL,
        argumentPrefix: [String],
        timeoutMs: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileDirectory: URL? = OmpRpcProfile.defaultDirectory()
    ) async throws -> OmpProviderStatusSnapshot {
        do {
            if let profileDirectory {
                try provisionProfile(profileDirectory, environment: environment)
            }
            return try await fetchSnapshot(
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                timeoutMs: timeoutMs,
                environment: environment,
                profileDirectory: profileDirectory
            )
        } catch let error as OmpProviderStatusError {
            throw error
        } catch let error as OmpProcessError {
            throw OmpProviderStatusError.unavailable(error.shortMessage)
        } catch let error as OmpRpcError {
            throw OmpProviderStatusError.unavailable(error.shortMessage)
        } catch {
            throw OmpProviderStatusError.unavailable(error.localizedDescription)
        }
    }

    private static func provisionProfile(
        _ profileDirectory: URL,
        environment: [String: String]
    ) throws {
        try OmpRpcProfile.provision(
            at: profileDirectory,
            environment: OmpEnvironment.augmented(
                environment,
                workingDirectory: profileDirectory
            )
        )
    }

    private static func fetchSnapshot(
        executableURL: URL,
        argumentPrefix: [String],
        timeoutMs: Int,
        environment: [String: String],
        profileDirectory: URL?
    ) async throws -> OmpProviderStatusSnapshot {
        async let usageOutput = OmpProcess.run(
            executableURL: executableURL,
            arguments: argumentPrefix + ["usage", "--json", "--redact"],
            timeoutMs: timeoutMs,
            environment: environment,
            currentDirectoryURL: profileDirectory
        )
        async let providerOutput = try? OmpProcess.run(
            executableURL: executableURL,
            arguments: argumentPrefix + ["auth-broker", "list", "--json"],
            timeoutMs: min(timeoutMs, 8_000),
            environment: environment,
            currentDirectoryURL: profileDirectory
        )

        let usageJSON = try await usageOutput
        let catalogJSON = await providerOutput
        return try snapshot(usageJSON: usageJSON, catalogJSON: catalogJSON)
    }

    private static func snapshot(
        usageJSON: String,
        catalogJSON: String?
    ) throws -> OmpProviderStatusSnapshot {
        guard
            let envelope = try? JSONDecoder().decode(
                OmpUsageEnvelope.self,
                from: Data(usageJSON.utf8)
            )
        else {
            throw OmpProviderStatusError.invalidJSON
        }

        let catalog =
            catalogJSON.flatMap {
                try? JSONDecoder().decode([OmpAuthProvider].self, from: Data($0.utf8))
            } ?? []
        var providerNames: [String: String] = [:]
        for provider in catalog {
            providerNames[provider.id] = provider.name
        }

        let countsByProvider = aggregate(envelope)
        let connections = countsByProvider.map { providerID, counts in
            OmpProviderConnection(
                providerID: providerID,
                displayName: displayName(
                    providerID: providerID,
                    catalogName: providerNames[providerID]
                ),
                activeAccounts: counts.reporting + counts.withoutUsage,
                reportingAccounts: counts.reporting,
                disabledAccounts: counts.disabled
            )
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return OmpProviderStatusSnapshot(connections: connections)
    }

    private static func aggregate(_ envelope: OmpUsageEnvelope) -> [String: OmpProviderCounts] {
        var countsByProvider: [String: OmpProviderCounts] = [:]
        for report in envelope.reports {
            countsByProvider[report.provider, default: OmpProviderCounts()].reporting += 1
        }
        for account in envelope.accountsWithoutUsage {
            countsByProvider[account.provider, default: OmpProviderCounts()].withoutUsage += 1
        }
        for disabled in envelope.disabledCredentials {
            countsByProvider[disabled.provider, default: OmpProviderCounts()].disabled += 1
        }
        return countsByProvider
    }

    private static func displayName(providerID: String, catalogName: String?) -> String {
        if let catalogName {
            let concise = catalogName.split(separator: "(", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let concise, !concise.isEmpty { return concise }
        }
        return
            providerID
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { part in
                switch part.lowercased() {
                case "github": "GitHub"
                case "openai": "OpenAI"
                case "xai": "xAI"
                default: part.prefix(1).uppercased() + String(part.dropFirst())
                }
            }
            .joined(separator: " ")
    }
}
