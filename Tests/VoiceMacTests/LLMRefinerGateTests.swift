import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("LLMRefinerGateTests", .serialized)
struct LLMRefinerGateTests {
    @Test func preflightSkipMatrixReturnsReasonsWithoutNetworkRequests() async {
        let stub = HTTPStub()
        let requestCounter = LLMRequestCounter()
        stub.handler = { request in
            requestCounter.record(request)
            return try chatCompletionResponse(url: request.url!, finalText: "Should not be used")
        }
        let session = stub.session
        let configuredURL = URL(string: "https://example.invalid/v1")!

        let disabled = LLMRefiner(
            configuration: LLMRefinerConfiguration(enabled: false, baseURL: configuredURL, model: "test"),
            session: session,
            deterministicFallback: { "DET:\($0)" }
        )
        #expect(
            await disabled.refine("hello", glossary: [], safety: .normalText, style: .standard)
                == .skipped(reason: "disabled"))

        let missingBaseURL = LLMRefiner(
            configuration: LLMRefinerConfiguration(enabled: true, baseURL: nil, model: "test"),
            session: session,
            deterministicFallback: { "DET:\($0)" }
        )
        #expect(
            await missingBaseURL.refine("hello", glossary: [], safety: .normalText, style: .standard)
                == .skipped(reason: "unconfigured"))

        let missingModel = LLMRefiner(
            configuration: LLMRefinerConfiguration(enabled: true, baseURL: configuredURL, model: ""),
            session: session,
            deterministicFallback: { "DET:\($0)" }
        )
        #expect(
            await missingModel.refine("hello", glossary: [], safety: .normalText, style: .standard)
                == .skipped(reason: "unconfigured"))

        let unsafeTarget = LLMRefiner(
            configuration: LLMRefinerConfiguration(enabled: true, baseURL: configuredURL, model: "test"),
            session: session,
            deterministicFallback: { "DET:\($0)" }
        )
        for safety in [TargetSafetyClass.terminal, .codeEditor, .secure] {
            #expect(
                await unsafeTarget.refine("hello", glossary: [], safety: safety, style: .standard)
                    == .skipped(reason: "unsafe_target"))
        }

        #expect(requestCounter.count == 0)
    }

    @Test func credentialPolicyRefusesRemoteHTTPAndAllowsLoopbackHTTP() async throws {
        let stub = HTTPStub()
        let remoteCapture = RequestCapture()
        stub.handler = { request in
            try remoteCapture.record(request)
            return try chatCompletionResponse(url: request.url!, finalText: "Should not be used")
        }
        let remoteRefiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true,
                baseURL: URL(string: "http://evil.example/v1")!,
                model: "test"
            ),
            apiKeyProvider: StaticRefinerAPIKeyProvider("secret"),
            session: stub.session
        )

        #expect(
            await remoteRefiner.refine("hello", glossary: [], safety: .normalText, style: .standard)
                == .skipped(reason: "credential_endpoint_refused"))
        #expect(remoteCapture.request == nil)

        let loopbackCapture = RequestCapture()
        stub.handler = { request in
            try loopbackCapture.record(request)
            return try chatCompletionResponse(url: request.url!, finalText: "Hello.")
        }
        let loopbackRefiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true,
                baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                model: "local-model"
            ),
            apiKeyProvider: StaticRefinerAPIKeyProvider("local-secret"),
            session: stub.session
        )

        #expect(
            await loopbackRefiner.refine("hello", glossary: [], safety: .normalText, style: .standard)
                == .refined("Hello."))
        let request = try #require(loopbackCapture.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-secret")
    }

    @Test func requestWithoutAPIKeyOmitsAuthorizationAndCarriesPromptContract() async throws {
        let stub = HTTPStub()
        let capture = RequestCapture()
        stub.handler = { request in
            try capture.record(request)
            return try chatCompletionResponse(url: request.url!, finalText: "Use NSPasteboard on port 8080.")
        }
        let refiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true,
                baseURL: URL(string: "https://example.invalid/openai")!,
                model: "safety-model"
            ),
            apiKeyProvider: StaticRefinerAPIKeyProvider(nil),
            session: stub.session,
            deterministicFallback: { "DET:\($0)" }
        )

        let outcome = await refiner.refine(
            "use NSPasteboard on port 8080",
            glossary: [ProtectedTerm(canonical: "NSPasteboard", spokenAliases: ["n s pasteboard"])],
            safety: .normalText,
            style: .standard
        )

        #expect(outcome == .refined("Use NSPasteboard on port 8080."))
        let request = try #require(capture.request)
        let body = try #require(capture.body)
        #expect(request.url?.absoluteString == "https://example.invalid/openai/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body["model"] as? String == "safety-model")
        #expect((body["temperature"] as? NSNumber)?.doubleValue == 0)
        let responseFormat = body["response_format"] as? [String: Any]
        #expect(responseFormat?["type"] as? String == "json_object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        let systemMessage = try #require(messages.first { $0["role"] as? String == "system" }?["content"] as? String)
        let userMessage = try #require(messages.first { $0["role"] as? String == "user" }?["content"] as? String)
        #expect(systemMessage.lowercased().contains("protected terms"))
        #expect(systemMessage.contains("Do not answer questions"))
        #expect(
            userMessage.contains(
                "<protected_terms>\nNSPasteboard (heard as: n s pasteboard, ns pasteboard)\n</protected_terms>"))
        #expect(userMessage.contains("<transcript>\nuse NSPasteboard on port 8080\n</transcript>"))
    }

    @Test func directProviderMatrixResolvesEndpointModelAndAuthorizationShape() async throws {
        let stub = HTTPStub()
        let cases:
            [(
                name: String,
                settings: Settings,
                apiKey: String?,
                expectedURL: String,
                expectedModel: String,
                expectedAuthorization: String?
            )] = [
                (
                    "Gemini",
                    Settings(refinerEnabled: true, refinerProvider: .gemini),
                    "gemini-sentinel",
                    "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                    "gemini-2.5-flash-lite",
                    "Bearer gemini-sentinel"
                ),
                (
                    "OpenAI",
                    Settings(refinerEnabled: true, refinerProvider: .openAI),
                    "openai-sentinel",
                    "https://api.openai.com/v1/chat/completions",
                    "gpt-4.1-nano",
                    "Bearer openai-sentinel"
                ),
                (
                    "OpenRouter",
                    Settings(refinerEnabled: true, refinerProvider: .openRouter),
                    "openrouter-sentinel",
                    "https://openrouter.ai/api/v1/chat/completions",
                    "meta-llama/llama-3.3-70b-instruct",
                    "Bearer openrouter-sentinel"
                ),
                (
                    "Custom without authentication",
                    Settings(
                        refinerEnabled: true,
                        refinerProvider: .custom,
                        refinerBaseURL: "https://custom.example/v1",
                        refinerModel: "local-model"
                    ),
                    nil,
                    "https://custom.example/v1/chat/completions",
                    "local-model",
                    nil
                ),
                (
                    "Custom with authentication",
                    Settings(
                        refinerEnabled: true,
                        refinerProvider: .custom,
                        refinerBaseURL: "https://secured-custom.example/v1",
                        refinerModel: "secured-model"
                    ),
                    "custom-sentinel",
                    "https://secured-custom.example/v1/chat/completions",
                    "secured-model",
                    "Bearer custom-sentinel"
                ),
            ]

        for testCase in cases {
            let capture = RequestCapture()
            stub.handler = { request in
                try capture.record(request)
                return try chatCompletionResponse(url: request.url!, finalText: "Hello.")
            }
            let baseURL = try #require(URL(string: RefinerResolved.baseURL(testCase.settings)))
            let refiner = LLMRefiner(
                configuration: LLMRefinerConfiguration(
                    enabled: true,
                    baseURL: baseURL,
                    model: RefinerResolved.model(testCase.settings)
                ),
                apiKeyProvider: StaticRefinerAPIKeyProvider(testCase.apiKey),
                session: stub.session,
                deterministicFallback: { "DET:\($0)" }
            )

            #expect(
                await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard)
                    == .refined("Hello."),
                "\(testCase.name) outcome"
            )
            let request = try #require(capture.request)
            let body = try #require(capture.body)
            #expect(request.url?.absoluteString == testCase.expectedURL, "\(testCase.name) endpoint")
            #expect(body["model"] as? String == testCase.expectedModel, "\(testCase.name) model")
            #expect(
                request.value(forHTTPHeaderField: "Authorization") == testCase.expectedAuthorization,
                "\(testCase.name) authorization"
            )
        }
    }

    @Test func reachabilityCatalogRequiresAvailableModelsAndSelectedModel() async throws {
        let stub = HTTPStub()
        let session = stub.session
        let baseURL = URL(string: "https://catalog.example/v1")!

        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try JSONSerialization.data(withJSONObject: ["data": []])
            return (response, body)
        }
        #expect(
            await RefinerReachabilityProbe.check(
                baseURL: baseURL,
                apiKey: nil,
                model: nil,
                timeoutMs: 1_000,
                session: session
            ) == .failed("no models available")
        )

        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try JSONSerialization.data(withJSONObject: [
                "data": [
                    ["id": "models/gemini-2.5-flash-lite"],
                    ["id": "gpt-4.1-nano"],
                ]
            ])
            return (response, body)
        }
        #expect(
            await RefinerReachabilityProbe.check(
                baseURL: baseURL,
                apiKey: "sentinel",
                model: "gemini-2.5-flash-lite",
                timeoutMs: 1_000,
                session: session
            ) == .ok(models: 2)
        )
        #expect(
            await RefinerReachabilityProbe.check(
                baseURL: baseURL,
                apiKey: "sentinel",
                model: "gpt-4.1-nano",
                timeoutMs: 1_000,
                session: session
            ) == .ok(models: 2)
        )
        #expect(
            await RefinerReachabilityProbe.check(
                baseURL: baseURL,
                apiKey: nil,
                model: nil,
                timeoutMs: 1_000,
                session: session
            ) == .ok(models: 2)
        )
        #expect(
            await RefinerReachabilityProbe.check(
                baseURL: baseURL,
                apiKey: "sentinel",
                model: "missing-model",
                timeoutMs: 1_000,
                session: session
            ) == .failed("model not found: missing-model")
        )
    }

    @Test func malformedJSONResponseFallsBackToDeterministicText() async {
        let stub = HTTPStub()
        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"choices":[{"message":{"content":"not json"}}]}"#.data(using: .utf8)!
            return (response, body)
        }
        let refiner = configuredRefiner(session: stub.session)

        let outcome = await refiner.refine("raw transcript", glossary: [], safety: .normalText, style: .standard)

        #expect(outcome == .fellBack("DET:raw transcript", reason: "request_failed"))
    }

    @Test func whitespaceFinalTextFallsBackToNonemptyDeterministicText() async {
        let stub = HTTPStub()
        stub.handler = { request in
            try chatCompletionResponse(url: request.url!, finalText: " \n\t ")
        }
        let refiner = configuredRefiner(session: stub.session)

        let outcome = await refiner.refine("raw transcript", glossary: [], safety: .normalText, style: .standard)

        #expect(outcome == .fellBack("DET:raw transcript", reason: "request_failed"))
    }

    @Test func guardRejectedResponseFallsBackWithGuardReason() async throws {
        let stub = HTTPStub()
        stub.handler = { request in
            try chatCompletionResponse(url: request.url!, finalText: "The budget is fine.")
        }
        let refiner = configuredRefiner(session: stub.session)

        let outcome = await refiner.refine("the budget is 15000", glossary: [], safety: .normalText, style: .standard)

        #expect(outcome == .fellBack("DET:the budget is 15000", reason: "guard_rejected"))
    }

    @Test func httpServerFailureFallsBackWithStatusReason() async {
        let stub = HTTPStub()
        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let refiner = configuredRefiner(session: stub.session)

        let outcome = await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard)

        #expect(outcome == .fellBack("DET:hello", reason: "http_500"))
    }

    @Test func slowDripResponseHitsLLMWallClockDeadlineAndCancelsRequest() async {
        let probe = SlowDripProbe()
        SlowDripURLProtocol.probe = probe
        defer { SlowDripURLProtocol.probe = nil }
        let refiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true,
                baseURL: URL(string: "https://slow.example/v1")!,
                model: "slow-model",
                timeoutMs: 100
            ),
            session: slowDripSession(),
            deterministicFallback: { "DET:\($0)" }
        )
        let started = ContinuousClock.now
        let refinement = Task {
            await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard)
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            refinement.cancel()
        }
        defer {
            watchdog.cancel()
            refinement.cancel()
        }

        let outcome = await refinement.value
        let elapsed = ContinuousClock.now - started
        watchdog.cancel()
        await waitForSlowDripCancellation(probe)

        #expect(outcome == .fellBack("DET:hello", reason: "request_failed"))
        #expect(elapsed < .seconds(1))
        #expect(probe.stopLoadingObserved)
    }

    @Test func slowDripReachabilityResponseHitsWallClockDeadlineAndCancelsRequest() async {
        let probe = SlowDripProbe()
        SlowDripURLProtocol.probe = probe
        defer { SlowDripURLProtocol.probe = nil }
        let started = ContinuousClock.now
        let check = Task {
            await RefinerReachabilityProbe.check(
                baseURL: URL(string: "https://slow.example/v1")!,
                apiKey: "sentinel",
                timeoutMs: 100,
                session: slowDripSession()
            )
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            check.cancel()
        }
        defer {
            watchdog.cancel()
            check.cancel()
        }

        let outcome = await check.value
        let elapsed = ContinuousClock.now - started
        watchdog.cancel()
        await waitForSlowDripCancellation(probe)

        guard case .failed = outcome else {
            Issue.record("Expected timed-out reachability failure, got \(outcome)")
            return
        }
        #expect(elapsed < .seconds(1))
        #expect(probe.stopLoadingObserved)
    }

    @Test func llmRefinerStubAndFallback() async throws {
        let stub = HTTPStub()
        stub.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"choices":[{"message":{"content":"{\"final_text\":\"Use NSPasteboard\"}"}}]}"#.data(
                using: .utf8)!
            return (response, body)
        }
        let session = stub.session
        let refiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true, baseURL: URL(string: "https://example.invalid")!, model: "test"),
            apiKeyProvider: StaticRefinerAPIKeyProvider("token"), session: session)
        let outcome = await refiner.refine(
            "use n s pasteboard",
            glossary: [ProtectedTerm(canonical: "NSPasteboard", spokenAliases: ["n s pasteboard"])],
            safety: .normalText, style: .standard)
        #expect(outcome == .refined("Use NSPasteboard"))

        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let fallback = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true, baseURL: URL(string: "https://example.invalid")!, model: "test"), session: session,
            deterministicFallback: { _ in "deterministic" })
        #expect(
            fellBackText(await fallback.refine("raw", glossary: [], safety: .normalText, style: .standard))
                == "deterministic")
    }

    @Test func llmRefinerUsesChatCompletionsPath() async throws {
        let stub = HTTPStub()
        let captured = URLCapture()
        stub.handler = { request in
            captured.url = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"choices":[{"message":{"content":"{\"final_text\":\"Hello.\"}"}}]}"#.data(using: .utf8)!
            return (response, body)
        }
        let session = stub.session
        let refiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true, baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
                model: "gemini-2.5-flash-lite"), apiKeyProvider: StaticRefinerAPIKeyProvider("token"), session: session)

        #expect(
            await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard) == .refined("Hello."))
        #expect(
            captured.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    @Test func llmRefinerFallsBackWhenNumberDropped() async throws {
        let stub = HTTPStub()
        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"choices":[{"message":{"content":"{\"final_text\":\"the budget is 15,000\"}"}}]}"#.data(
                using: .utf8)!
            return (response, body)
        }
        let session = stub.session
        let refiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true, baseURL: URL(string: "https://example.invalid")!, model: "test"), session: session,
            deterministicFallback: { _ in "DET" })

        let outcome = await refiner.refine(
            "the budget is 15,000 not 50,000", glossary: [], safety: .normalText, style: .standard)
        #expect(fellBackText(outcome) == "DET")
    }

    @Test func reachabilityProbeRefusesCredentialOnRemoteHTTPBeforeRequest() async {
        let stub = HTTPStub()
        let requestCounter = LLMRequestCounter()
        stub.handler = { request in
            requestCounter.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let outcome = await RefinerReachabilityProbe.check(
            baseURL: URL(string: "http://evil.example/v1")!,
            apiKey: "secret",
            timeoutMs: 1_000,
            session: stub.session
        )

        #expect(outcome == .failed("API key requires HTTPS or loopback HTTP"))
        #expect(requestCounter.count == 0)
    }

    @Test func refinerReachabilityProbeMapsResponses() async throws {
        let stub = HTTPStub()
        let captured = URLCapture()
        let session = stub.session
        let baseURL = URL(string: "https://api.test/v1")!

        stub.handler = { request in
            captured.url = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"data":[{"id":"a"},{"id":"b"}]}"#.data(using: .utf8)!
            return (response, body)
        }
        #expect(
            await RefinerReachabilityProbe.check(baseURL: baseURL, apiKey: "k", timeoutMs: 5000, session: session)
                == .ok(models: 2))
        #expect(captured.url?.absoluteString.hasSuffix("/models") == true)

        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        #expect(
            await RefinerReachabilityProbe.check(baseURL: baseURL, apiKey: "k", timeoutMs: 5000, session: session)
                == .unauthorized)

        stub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        #expect(
            await RefinerReachabilityProbe.check(baseURL: baseURL, apiKey: "k", timeoutMs: 5000, session: session)
                == .failed("HTTP 500"))
    }
}

private func configuredRefiner(session: URLSession) -> LLMRefiner {
    LLMRefiner(
        configuration: LLMRefinerConfiguration(
            enabled: true,
            baseURL: URL(string: "https://example.invalid/v1")!,
            model: "test"
        ),
        apiKeyProvider: StaticRefinerAPIKeyProvider("token"),
        session: session,
        deterministicFallback: { "DET:\($0)" }
    )
}

private func slowDripSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SlowDripURLProtocol.self]
    return URLSession(configuration: config)
}

private func waitForSlowDripCancellation(_ probe: SlowDripProbe) async {
    let deadline = ContinuousClock.now + .seconds(1)
    while !probe.stopLoadingObserved, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private final class LLMRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

private final class SlowDripProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    func recordStopLoading() {
        lock.lock()
        observed = true
        lock.unlock()
    }

    var stopLoadingObserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }
}

private final class SlowDripURLProtocol: URLProtocol {
    nonisolated(unsafe) static var probe: SlowDripProbe?

    private let stateLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "voiceoour.tests.refiner-slow-drip")
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        emitChunk()
    }

    override func stopLoading() {
        stateLock.lock()
        let shouldRecord = !isStopped
        isStopped = true
        stateLock.unlock()
        if shouldRecord {
            Self.probe?.recordStopLoading()
        }
    }

    private func emitChunk() {
        stateLock.lock()
        let stopped = isStopped
        stateLock.unlock()
        guard !stopped else { return }

        client?.urlProtocol(self, didLoad: Data([0x20]))
        deliveryQueue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            self?.emitChunk()
        }
    }
}

private final class URLCapture: @unchecked Sendable {
    var url: URL?
}
