import Foundation
import VoiceCore
import os

/// Labels one entry with TypeSafe's Jev sorting model.
///
/// This target is the one place outside the model download that may open a connection, so the
/// rest of the app stays provably offline. The model only answers multiple-choice questions about
/// the user's words; it never writes text, and nothing it returns is text the user will read as theirs.
/// Every failure returns nil: an unlabelled entry is still a complete entry.
///
/// Diagnostics, when needed:
///
///     log stream --predicate 'subsystem == "com.voiceour.app" AND category == "organizer"'
///
/// The log carries only HTTP statuses and failure kinds. The key, the entry text and the reply never reach it.
public final class TypeSafeOrganizer: EntryOrganizing {
    /// Fixed so that no setting, environment variable or argument can send the user's words anywhere else.
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// Waits before the first and second retry. Two retries ride out a brief outage without
    /// holding an entry's label hostage to a server that is down.
    static let retryDelays: [Duration] = [.milliseconds(500), .milliseconds(1500)]

    /// A server may ask for a longer pause, but a label is not worth more than this per wait.
    static let maximumRetryDelay: Duration = .seconds(5)

    private static let log = Logger(subsystem: "com.voiceour.app", category: "organizer")

    private let key: @Sendable () -> String?
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void

    /// - Parameters:
    ///   - key: Read on every call, so a key the user saves or removes takes effect on the next entry.
    ///   - session: The transport. Tests substitute one whose protocol classes never leave the process.
    ///   - now: The time stamped on a label, injected so tests see a fixed date.
    ///   - sleep: The pause between retries, injected so tests do not wait in real time.
    public init(
        key: @escaping @Sendable () -> String?,
        session: URLSession = TypeSafeOrganizer.makeSession(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.key = key
        self.session = session
        self.now = now
        self.sleep = sleep
    }

    /// A session that keeps nothing between requests: no cookies, no response cache and no stored
    /// credentials, so the only trace of a request is the one the server keeps. It fails at once
    /// when offline instead of queueing the user's words until a connection appears.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func label(text: String, topics: [MemoryTopic]) async -> EntryLabel? {
        guard let key = key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let body: Data
        do {
            body = try JudgmentRequest.organize(text: text, topics: topics).body()
        } catch {
            Self.log.error("organizer request could not be encoded")
            return nil
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Voiceour", forHTTPHeaderField: "User-Agent")

        var retries = 0
        while true {
            switch await send(request) {
            case .reply(let data):
                guard let reply = try? JudgmentReply(data: data) else {
                    Self.log.notice("organizer reply could not be decoded")
                    return nil
                }
                return reply.label(topics: topics, now: now())
            case .refused:
                return nil
            case .transient(let retryAfter):
                guard retries < Self.retryDelays.count, !Task.isCancelled else {
                    let attempts = retries + 1
                    Self.log.notice("organizer gave up after \(attempts, privacy: .public) attempts")
                    return nil
                }
                await sleep(min(retryAfter ?? Self.retryDelays[retries], Self.maximumRetryDelay))
                retries += 1
                if Task.isCancelled { return nil }
            }
        }
    }

    /// What one request came to, as far as the retry loop cares.
    private enum Attempt {
        case reply(Data)
        /// Worth another try; carries the server's `Retry-After` when it sent one.
        case transient(retryAfter: Duration?)
        /// Another try would get the same answer, or the caller no longer wants one.
        case refused
    }

    private static let redirectRefusal = RedirectRefusal()

    private func send(_ request: URLRequest) async -> Attempt {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: Self.redirectRefusal)
        } catch {
            if Self.isConnectionFailure(error) {
                Self.log.notice("organizer connection failed")
                return .transient(retryAfter: nil)
            }
            Self.log.notice("organizer request ended without a reply")
            return .refused
        }

        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            Self.log.error("organizer reply was not HTTP")
            return .refused
        }
        let status = http.statusCode
        switch status {
        case 200:
            return .reply(data)
        case 408, 429, 500...599:
            Self.log.notice("organizer reply status \(status, privacy: .public), retryable")
            return .transient(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            Self.log.notice("organizer reply status \(status, privacy: .public)")
            return .refused
        }
    }

    /// A connection that never formed or dropped mid-request. A timeout is not one of them: the
    /// server had ten seconds already, and waiting again would only delay the next entry.
    /// A cancellation is not one either: the caller has stopped listening.
    private static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Reads the delay-seconds form of `Retry-After`. The HTTP-date form is ignored: it would make
    /// the wait depend on the clocks of two machines agreeing.
    private static func retryAfter(_ value: String?) -> Duration? {
        guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return .seconds(seconds)
    }
}

/// Refuses every redirect, so a request reaches the fixed endpoint or no host at all. A followed
/// redirect would repeat the request, the user's words included, at whatever host the reply named;
/// refused, the redirect itself is the reply, and its status ends the request with no label.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
