import Foundation
import Testing
@testable import Forma

@Suite(.serialized) @MainActor struct AlternativesTests {
    @Test func phraseReplacementUsesExactUTF16OccurrenceAndPreservesSurroundings() throws {
        let output = "🌍 We can help you today; we can help you tomorrow."
        let selected = "we can help you"
        let request = makeRequest(output: output, selected: selected)
        let variants = try request.decode(reply(["we are here to support you", "we can assist you"]))
        #expect(variants.map(\.updatedText) == [
            "🌍 We can help you today; we are here to support you tomorrow.",
            "🌍 We can help you today; we can assist you tomorrow."
        ])
        let padded = makeRequest(output: "Before  some words \nAfter", selected: " some words \n")
        #expect(try padded.decode(reply(["a whole new phrase"])).first?.updatedText == "Before  a whole new phrase \nAfter")
        let repeated = makeRequest(output: "🌍 help / help", selected: "help")
        #expect(try repeated.decode(reply(["assist"])).first?.updatedText == "🌍 assist / help")
    }

    @Test func deduplicatesAcrossResponsesAndKeepsUpToEightUsefulAlternatives() throws {
        let request = makeRequest()
        let first = try request.decode(reply(["help", " HELP ", "", " \n", "assist", "Assist", "support"]))
        #expect(first.map(\.replacement) == ["assist", "support"])
        let combined = try request.decode(reply(["support", "aid", "lend a hand", "offer help", "provide assistance",
                                                "give support", "be of service", "come to the rescue"]), addingTo: first)
        #expect(combined.count == 8)
        #expect(combined.prefix(2).map(\.replacement) == ["assist", "support"])
        #expect(Set(combined.map(\.id)).count == combined.count)
    }

    @Test func sourceAlignmentMustBeAnExactSubstringAndOnlyAppliesToTranslation() throws {
        let json = #"{"alternatives":[{"replacement":"assist","sourcePhrase":"помочь"},{"replacement":"support","sourcePhrase":"invented"},{"replacement":"aid","sourcePhrase":" "},{"replacement":"lend a hand"}]}"#
        #expect(try makeRequest().decode(json).map(\.sourcePhrase) == ["помочь", nil, nil, nil])
        #expect(try makeRequest(mode: .rewrite).decode(json).allSatisfy { $0.sourcePhrase == nil })
        #expect(try makeRequest(mode: .correct).decode(json).allSatisfy { $0.sourcePhrase == nil })
    }

    @Test func staleAndInvalidSelectionsNeverReplaceAnotherSpan() throws {
        for range in [NSRange(location: 100, length: 4), NSRange(location: NSNotFound, length: 4),
                      NSRange(location: 0, length: 0), NSRange(location: 0, length: 1), NSRange(location: 2, length: 4)] {
            let request = AlternativesRequest(selected: TextSelection(text: "help", range: range), input: input(), output: "🌍 help")
            #expect(!request.isValid)
            #expect(try request.decode(reply(["assist"])).isEmpty)
        }
    }

    @Test func sparseResponsesTriggerOneTopUpWithExistingChoicesExcluded() async throws {
        let session = session(replies: [.text(reply(["help", "assist", "Assist"])), .text(reply(["assist", "support", "aid", "lend a hand"]))])
        defer { session.invalidateAndCancel() }
        let variants = try await load(using: session)
        #expect(variants.map(\.replacement) == ["assist", "support", "aid", "lend a hand"])
        #expect(AlternativesStub.requests.count == 2)
        let second = try #require(AlternativesStub.requests.last)
        let content = try #require((second["input"] as? [[String: String]])?.first?["content"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        #expect(payload["excludedReplacements"] as? [String] == ["assist"])
        #expect(payload["selected"] as? String == "help")
        #expect((second["reasoning"] as? [String: String])?["effort"] == "low")
    }

    @Test func enoughChoicesDoNotTriggerAnotherRequest() async throws {
        let session = session(replies: [.text(reply(["assist", "support", "aid", "lend a hand"]))])
        defer { session.invalidateAndCancel() }
        #expect(try await load(using: session).count == 4)
        #expect(AlternativesStub.requests.count == 1)
    }

    @Test func emptyResponsesStopAfterTwoAttempts() async throws {
        let session = session(replies: [.text(reply([])), .text(reply([]))])
        defer { session.invalidateAndCancel() }
        #expect(try await load(using: session).isEmpty)
        #expect(AlternativesStub.requests.count == 2)
    }

    @Test func failedOrMalformedTopUpKeepsFirstChoicesButInitialErrorsSurface() async throws {
        for failure in [AlternativesStub.Reply.failed, .text("invalid JSON")] {
            let session = session(replies: [.text(reply(["assist"])), failure])
            defer { session.invalidateAndCancel() }
            #expect(try await load(using: session).map(\.replacement) == ["assist"])
            #expect(AlternativesStub.requests.count == 2)
        }
        let session = session(replies: [.failed])
        defer { session.invalidateAndCancel() }
        await #expect(throws: AppFailure.self) { _ = try await load(using: session) }
        #expect(AlternativesStub.requests.count == 1)
    }

    private func input(mode: WritingMode = .translate) -> ProcessingRequest {
        ProcessingRequest(input: "Мы можем помочь.", mode: mode, source: "Russian", target: "English", tone: "neutral", glossary: [])
    }
    private func makeRequest(output: String = "We can help.", selected: String = "help", mode: WritingMode = .translate) -> AlternativesRequest {
        AlternativesRequest(selected: TextSelection(text: selected, range: (output as NSString).range(of: selected)), input: input(mode: mode), output: output)
    }
    private func reply(_ replacements: [String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["alternatives": replacements.map { ["replacement": $0] }]), as: UTF8.self)
    }
    private func session(replies: [AlternativesStub.Reply]) -> URLSession {
        AlternativesStub.replies = replies; AlternativesStub.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlternativesStub.self]
        return URLSession(configuration: configuration)
    }
    private func load(using session: URLSession) async throws -> [WordAlternative] {
        let request = makeRequest()
        let service = OpenAITextService(session: session, scope: { "test" }, bearerToken: { "test-token" })
        return try await service.alternatives(for: request.selected, input: request.input, output: request.output,
                                              model: ModelChoice(id: "gpt-6.1-sol", name: "Sol"), reasoning: .fast)
    }
}

private final class AlternativesStub: URLProtocol {
    enum Reply { case text(String), failed }
    static var replies: [Reply] = []
    static var requests: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        Self.requests.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        let reply = Self.replies.isEmpty ? .failed : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let events: [[String: Any]]
        switch reply {
        case .text(let text):
            events = [["type": "response.output_text.delta", "delta": text],
                      ["type": "response.completed", "response": ["status": "completed"]]]
        case .failed:
            events = [["type": "response.failed", "response": ["error": ["code": "rate_limit_exceeded"]]]]
        }
        for event in events {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            client?.urlProtocol(self, didLoad: Data("data: \(json)\n\n".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
