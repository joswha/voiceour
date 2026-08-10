import Foundation
import VoiceCore

public enum RefinerReachabilityProbe {
    /// GET {baseURL}/models with optional Bearer key.
    public static func check(
        baseURL: URL,
        apiKey: String?,
        model: String? = nil,
        timeoutMs: Int,
        session: URLSession = .shared
    ) async -> RefinerReachability {
        if let apiKey, !apiKey.isEmpty, !RefinerEndpointPolicy.allowsCredential(baseURL) {
            return .failed("API key requires HTTPS or loopback HTTP")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let configuredRequest = request

        do {
            let (data, response) = try await withWallClockTimeout(
                timeoutNanoseconds: UInt64(max(timeoutMs, 1)) * 1_000_000,
                timeoutError: { URLError(.timedOut) },
                operation: {
                    try await session.data(for: configuredRequest)
                }
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("invalid response")
            }

            switch httpResponse.statusCode {
            case 200:
                let object = try JSONSerialization.jsonObject(with: data)
                guard let root = object as? [String: Any],
                    let entries = root["data"] as? [[String: Any]]
                else {
                    return .failed("invalid model catalog")
                }
                let modelIDs = entries.compactMap { entry -> String? in
                    guard let id = entry["id"] as? String else { return nil }
                    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                guard !modelIDs.isEmpty else {
                    return .failed("no models available")
                }
                if let model,
                    !modelIDs.contains(where: { Self.modelID($0, matches: model) })
                {
                    return .failed("model not found: \(model)")
                }
                return .ok(models: modelIDs.count)
            case 401, 403:
                return .unauthorized
            default:
                return .failed("HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .failed(Self.shortMessage(for: error))
        }
    }

    private static func shortMessage(for error: any Error) -> String {
        error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
    }

    private static func modelID(_ candidate: String, matches selected: String) -> Bool {
        candidate == selected
            || strippingGeminiPrefix(candidate) == strippingGeminiPrefix(selected)
    }

    private static func strippingGeminiPrefix(_ modelID: String) -> Substring {
        modelID.hasPrefix("models/") ? modelID.dropFirst("models/".count) : modelID[...]
    }
}
