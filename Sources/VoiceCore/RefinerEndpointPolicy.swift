import Foundation

public enum RefinerEndpointPolicy: Sendable {
    /// Whether an API key may be attached to a request to this URL.
    /// `https` is always eligible. Plain `http` is eligible only for a loopback
    /// authority, because a local model server (Ollama, LM Studio) is a
    /// first-class custom endpoint and has no TLS to offer.
    public static func allowsCredential(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let scheme = url.scheme else { return false }
        if scheme.caseInsensitiveCompare("https") == .orderedSame { return true }
        guard scheme.caseInsensitiveCompare("http") == .orderedSame, let host = url.host else { return false }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
            || host == "::1"
            || host == "[::1]"
            || isIPv4Loopback(host)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        var octetIndex = 0
        var octetValue = 0
        var digitCount = 0

        for byte in host.utf8 {
            if byte >= 48, byte <= 57 {
                guard digitCount < 3 else { return false }
                octetValue = octetValue * 10 + Int(byte - 48)
                guard octetValue <= 255 else { return false }
                digitCount += 1
            } else if byte == 46 {
                guard digitCount > 0, octetIndex < 3 else { return false }
                if octetIndex == 0, octetValue != 127 { return false }
                octetIndex += 1
                octetValue = 0
                digitCount = 0
            } else {
                return false
            }
        }

        return octetIndex == 3 && digitCount > 0
    }
}
