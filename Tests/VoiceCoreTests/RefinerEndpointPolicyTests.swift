import Foundation
import Testing

@testable import VoiceCore

@Suite("RefinerEndpointPolicy")
struct RefinerEndpointPolicyTests {
    @Test func allowsRemoteHTTPS() throws {
        let url = try #require(URL(string: "https://api.example.com/v1"))
        #expect(RefinerEndpointPolicy.allowsCredential(url))
    }

    @Test func allowsLoopbackHTTP() throws {
        for value in [
            "http://localhost:11434/v1",
            "http://127.0.0.1:1234/v1",
            "http://[::1]:1234/v1",
        ] {
            let url = try #require(URL(string: value))
            #expect(RefinerEndpointPolicy.allowsCredential(url), "Expected loopback URL to be eligible: \(value)")
        }
    }

    @Test func rejectsRemoteHTTP() throws {
        let url = try #require(URL(string: "http://evil.example/v1"))
        #expect(!RefinerEndpointPolicy.allowsCredential(url))
    }

    @Test func rejectsFileURL() {
        #expect(!RefinerEndpointPolicy.allowsCredential(URL(fileURLWithPath: "/tmp/refiner")))
    }

    @Test func rejectsEmbeddedCredentials() throws {
        let url = try #require(URL(string: "https://user:password@api.example.com/v1"))
        #expect(!RefinerEndpointPolicy.allowsCredential(url))
    }

    @Test func schemeComparisonIsCaseInsensitive() throws {
        let url = try #require(URL(string: "HTTPS://api.example.com/v1"))
        #expect(RefinerEndpointPolicy.allowsCredential(url))
    }
}
