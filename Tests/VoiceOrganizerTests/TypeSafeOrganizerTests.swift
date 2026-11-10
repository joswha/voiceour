import Foundation
import Synchronization
import Testing
import VoiceCore
import VoiceOrganizer

// MARK: - Scripted transport

/// One scripted answer to one request.
enum ScriptedOrganizerReply: Sendable {
    case http(status: Int, headers: [String: String] = [:], body: Data = Data())
    case connectionLost
    case timedOut
    case redirect(to: URL)
}

/// A request as the transport saw it. The body is read here because `URLSession` hands a
/// protocol the body as a stream, not as `httpBody`.
struct SeenOrganizerRequest: Sendable {
    var request: URLRequest
    var body: Data
}

/// A `URLProtocol` that answers from a script, so no request in this suite leaves the process.
// `state` protects the shared script and the record of requests.
final class ScriptedOrganizerProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var script: [ScriptedOrganizerReply] = []
        var seen: [SeenOrganizerRequest] = []
    }
    private static let state = Mutex(State())

    static func install(_ script: [ScriptedOrganizerReply]) {
        state.withLock { $0 = State(script: script) }
    }

    static var seen: [SeenOrganizerRequest] {
        state.withLock { $0.seen }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let seen = SeenOrganizerRequest(request: request, body: Self.body(of: request))
        let step = Self.state.withLock { state -> ScriptedOrganizerReply? in
            state.seen.append(seen)
            return state.script.isEmpty ? nil : state.script.removeFirst()
        }

        switch step {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .connectionLost:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .timedOut:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // A refused redirect leaves this load to end with the redirect itself as its reply;
            // a followed one starts a second load, which the script's next step answers.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Records every pause the client asks for instead of taking it.
final class RecordedSleeps: Sendable {
    private let waits = Mutex<[Duration]>([])

    var recorded: [Duration] { waits.withLock { $0 } }

    func record(_ duration: Duration) {
        waits.withLock { $0.append(duration) }
    }
}

// MARK: - Suite

private let fakeKey = "test-key-123"
private let fixedNow = Date(timeIntervalSince1970: 1_794_300_000)
private let topics = [
    MemoryTopic(
        id: "voiceour",
        name: "Voiceour",
        summary: "Work on the dictation app.",
        createdAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
]
private let spokenText = "Ship the journal tab before Friday."

/// A well-formed reply that picks a kind and the suite's one topic.
private let validReply = Data(
    """
    {"model":"jev-1.14.0","answers":{"kind":{"type":"choice","choice":"decision","confidence":0.92},\
    "topic":{"type":"choice","choice":"voiceour","confidence":0.81},"keep":{"type":"score","score":2}}}
    """.utf8
)

@Suite("TypeSafeOrganizerTests", .serialized)
struct TypeSafeOrganizerTests {
    private func makeOrganizer(key: String?, sleeps: RecordedSleeps = RecordedSleeps()) -> TypeSafeOrganizer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedOrganizerProtocol.self]
        return TypeSafeOrganizer(
            key: { key },
            session: URLSession(configuration: configuration),
            now: { fixedNow },
            sleep: { sleeps.record($0) }
        )
    }

    @Test(arguments: [nil, "", "   \n"] as [String?])
    func aMissingOrBlankKeySendsNothing(key: String?) async {
        ScriptedOrganizerProtocol.install([.http(status: 200, body: validReply)])

        let label = await makeOrganizer(key: key).label(text: spokenText, topics: topics)

        #expect(label == nil)
        #expect(ScriptedOrganizerProtocol.seen.isEmpty)
    }

    @Test(arguments: ["", "  \n\t "])
    func blankTextSendsNothing(text: String) async {
        ScriptedOrganizerProtocol.install([.http(status: 200, body: validReply)])

        let label = await makeOrganizer(key: fakeKey).label(text: text, topics: topics)

        #expect(label == nil)
        #expect(ScriptedOrganizerProtocol.seen.isEmpty)
    }

    @Test func theRequestPostsTheOrganizeQuestionsToTheFixedEndpoint() async throws {
        ScriptedOrganizerProtocol.install([.http(status: 200, body: validReply)])

        _ = await makeOrganizer(key: fakeKey).label(text: spokenText, topics: topics)

        let seen = try #require(ScriptedOrganizerProtocol.seen.first)
        #expect(ScriptedOrganizerProtocol.seen.count == 1)
        #expect(seen.request.httpMethod == "POST")
        #expect(seen.request.url == URL(string: "https://api.typesafe.ai/v1/systemone"))
        #expect(seen.request.url == TypeSafeOrganizer.endpoint)
        #expect(seen.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")
        #expect(seen.request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(seen.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(seen.request.value(forHTTPHeaderField: "User-Agent") == "Voiceour")
        let expectedBody = try JudgmentRequest.organize(text: spokenText, topics: topics).body()
        #expect(seen.body == expectedBody)
    }

    @Test func a200ReplyBecomesTheLabelStampedWithTheInjectedTime() async throws {
        ScriptedOrganizerProtocol.install([.http(status: 200, body: validReply)])

        let returned = await makeOrganizer(key: fakeKey).label(text: spokenText, topics: topics)
        let label = try #require(returned)

        let expected = try JudgmentReply(data: validReply).label(topics: topics, now: fixedNow)
        #expect(label == expected)
        #expect(label.kind == .decision)
        #expect(label.topicID == "voiceour")
        #expect(label.model == "jev-1.14.0")
        #expect(label.labeledAt == fixedNow)
        #expect(!String(reflecting: label).contains(fakeKey))
    }

    @Test func a429ThenA200SucceedsAfterOneRetry() async throws {
        ScriptedOrganizerProtocol.install([
            .http(status: 429),
            .http(status: 200, body: validReply),
        ])
        let sleeps = RecordedSleeps()

        let label = await makeOrganizer(key: fakeKey, sleeps: sleeps).label(text: spokenText, topics: topics)

        let returned = try #require(label)
        #expect(returned.kind == .decision)
        #expect(!String(reflecting: returned).contains(fakeKey))
        #expect(ScriptedOrganizerProtocol.seen.count == 2)
        #expect(sleeps.recorded == [.milliseconds(500)])
    }

    @Test(arguments: [408, 429, 500, 503, 599])
    func everyRetryableStatusIsRetried(status: Int) async {
        ScriptedOrganizerProtocol.install([
            .http(status: status),
            .http(status: 200, body: validReply),
        ])

        let label = await makeOrganizer(key: fakeKey).label(text: spokenText, topics: topics)

        #expect(label != nil)
        #expect(ScriptedOrganizerProtocol.seen.count == 2)
    }

    @Test func threeServerErrorsGiveUpAfterExactlyThreeAttempts() async {
        // A fourth answer is queued so that a client which kept trying would succeed and fail the test.
        ScriptedOrganizerProtocol.install([
            .http(status: 500),
            .http(status: 500),
            .http(status: 500),
            .http(status: 200, body: validReply),
        ])
        let sleeps = RecordedSleeps()

        let label = await makeOrganizer(key: fakeKey, sleeps: sleeps).label(text: spokenText, topics: topics)

        #expect(label == nil)
        #expect(ScriptedOrganizerProtocol.seen.count == 3)
        #expect(sleeps.recorded == [.milliseconds(500), .milliseconds(1500)])
    }

    @Test(arguments: [400, 401, 403, 404, 422])
    func aRefusingStatusIsNotRetried(status: Int) async {
        ScriptedOrganizerProtocol.install([
            .http(status: status),
            .http(status: 200, body: validReply),
        ])
        let sleeps = RecordedSleeps()

        let label = await makeOrganizer(key: fakeKey, sleeps: sleeps).label(text: spokenText, topics: topics)

        #expect(label == nil)
        #expect(ScriptedOrganizerProtocol.seen.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    @Test func anUndecodable200BodyReturnsNil() async {
        ScriptedOrganizerProtocol.install([
            .http(status: 200, body: Data("<html>gateway</html>".utf8)),
            .http(status: 200, body: validReply),
        ])

        let label = await makeOrganizer(key: fakeKey).label(text: spokenText, topics: topics)

        #expect(label == nil)
        #expect(ScriptedOrganizerProtocol.seen.count == 1)
    }

    @Test(arguments: [("2", Duration.seconds(2)), ("60", Duration.seconds(5)), ("0", Duration.zero)])
    func retryAfterIsHonouredUpToFiveSeconds(header: String, expectedWait: Duration) async {
        ScriptedOrganizerProtocol.install([
            .http(status: 429, headers: ["Retry-After": header]),
            .http(status: 200, body: validReply),
        ])
        let sleeps = RecordedSleeps()

        let label = await makeOrganizer(key: fakeKey, sleeps: sleeps).label(text: spokenText, topics: topics)

        #expect(label != nil)
        #expect(sleeps.recorded == [expectedWait])
    }

    @Test func aDroppedConnectionIsRetried() async {
        ScriptedOrganizerProtocol.install([
            .connectionLost,
            .http(status: 200, body: validReply),
        ])
        let sleeps = RecordedSleeps()

        let label = await makeOrganizer(key: fakeKey, sleeps: sleeps).label(text: spokenText, topics: topics)

        #expect(label != nil)
        #expect(ScriptedOrganizerProtocol.seen.count == 2)
        #expect(sleeps.recorded == [.milliseconds(500)])
    }

    @Test func aTimeoutIsNotRetried() async {
        ScriptedOrganizerProtocol.install([
            .timedOut,
            .http(status: 200, body: validReply),
        ])
        let sleeps = RecordedSleeps()

        let label = await makeOrganizer(key: fakeKey, sleeps: sleeps).label(text: spokenText, topics: topics)

        #expect(label == nil)
        #expect(ScriptedOrganizerProtocol.seen.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    @Test func aRedirectIsRefusedSoNothingReachesASecondHost() async {
        // The second answer would turn a followed redirect into a label and fail the test.
        ScriptedOrganizerProtocol.install([
            .redirect(to: URL(string: "https://elsewhere.example/v1/systemone")!),
            .http(status: 200, body: validReply),
        ])
        let sleeps = RecordedSleeps()

        let label = await makeOrganizer(key: fakeKey, sleeps: sleeps).label(text: spokenText, topics: topics)

        #expect(label == nil)
        #expect(ScriptedOrganizerProtocol.seen.map(\.request.url) == [TypeSafeOrganizer.endpoint])
        #expect(sleeps.recorded.isEmpty)
    }
}
