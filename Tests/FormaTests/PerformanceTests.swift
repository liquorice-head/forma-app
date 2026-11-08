import AppKit
import Foundation
import Testing
@testable import Forma

@Suite(.serialized) @MainActor struct PerformanceTests {
    @Test func modelCapabilitiesControlReasoningAndUnknownModelsStayOnDefaults() throws {
        let data = Data(#"{"models":[{"slug":"future-model","display_name":"Future","visibility":"list","supported_reasoning_efforts":[{"effort":"high"},{"effort":"low"},{"effort":"made-up"}]},{"slug":"gpt-6-luna","visibility":"list","supported_reasoning_efforts":[]},{"slug":"gpt-6.1-sol","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}"#.utf8)
        let models = try ModelChoice.parseCatalog(data)
        #expect(models.count == 3 && models[0].name == "Future")
        #expect(models[0].supportedEfforts == [.low, .high])
        #expect(models[0].effort(for: .fast) == .low)
        #expect(models[0].effort(for: .none) == .low)
        #expect(models[1].reasoningChoices == [.modelDefault])
        #expect(models[1].effort(for: .fast) == nil)
        #expect(models[2].supportedEfforts.first == .low)
        #expect(!models[2].reasoningChoices.contains(.none))
        #expect(ModelChoice(id: "gpt-5-2025-08-07", name: "5").effort(for: .fast) == .minimal)
        #expect(ModelChoice(id: "gpt-5.5", name: "5.5").effort(for: .fast) == ReasoningEffort.none)
        for id in ["gpt-unknown", "gpt-6.1-sol-pro", "gpt-6-luna-future", "gpt-4.1"] {
            #expect(ModelChoice(id: id, name: id).effort(for: .fast) == nil)
        }
    }

    @Test func requestsKeepStreamingAndOnlySendAnExplicitSupportedEffort() throws {
        let low = try body(reasoning: .low)
        #expect((low["reasoning"] as? [String: String])?["effort"] == "low")
        #expect(low["store"] as? Bool == false && low["stream"] as? Bool == true)
        #expect(low["instructions"] as? String == "rules")
        #expect((low["input"] as? [[String: String]])?.first?["content"] == "Привет 🌍")
        #expect(try body(reasoning: nil)["reasoning"] == nil)
        #expect(try body(reasoning: .modelDefault)["reasoning"] == nil)
        #expect(try body(reasoning: .fast)["reasoning"] == nil)
        #expect((try body(reasoning: ReasoningEffort.none)["reasoning"] as? [String: String])?["effort"] == "none")
    }

    @Test func resultCacheSeparatesAccountsModelsReasoningAndEveryPromptChange() {
        var cache = ProcessingResultCache()
        let original = key()
        cache.insert("Hello", for: original)
        #expect(cache.value(for: original) == "Hello")
        for other in [key(account: "another"), key(model: "another"), key(reasoning: .medium),
                      key(instructions: "changed tone, language, mode, dictionary or rule"), key(input: "Привет!")] {
            #expect(cache.value(for: other) == nil)
        }
        cache.removeAll()
        #expect(cache.value(for: original) == nil)
    }

    @Test func cacheEvictsLeastRecentlyUsedAndRejectsOversizedOrEmptyResults() {
        var cache = ProcessingResultCache(capacity: 2, byteLimit: 100)
        let a = key(input: "a"), b = key(input: "b"), c = key(input: "c")
        cache.insert("A", for: a); cache.insert("B", for: b)
        #expect(cache.value(for: a) == "A")
        cache.insert("C", for: c)
        #expect(cache.value(for: b) == nil)
        #expect(cache.value(for: a) == "A" && cache.value(for: c) == "C")
        cache.insert(String(repeating: "🌍", count: 100), for: b)
        cache.insert(" \n", for: b)
        #expect(cache.value(for: b) == nil)
        var small = ProcessingResultCache(byteLimit: key(input: "a").byteCount + 1)
        small.insert("A", for: a); small.insert("B", for: b)
        #expect(small.value(for: a) == nil && small.value(for: b) == "B")
    }

    @Test func completedRequestsAreCachedButBypassAndInvalidationMakeNewRequests() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        StubInference.reply = .completed
        var scope: String? = "test-account"
        let service = OpenAITextService(session: session, scope: { scope }, bearerToken: { "test-token" })
        let model = ModelChoice(id: "gpt-6.1-sol", name: "Sol")
        var seen: [String] = []
        let first = try await service.process(input(), model: model, reasoning: .fast) { seen.append($0) }
        #expect(!first.cacheHit && first.text == "Hello 🌍" && first.reasoningTokens == 12)
        #expect(seen.last == "Hello 🌍")
        let cached = try await service.process(input(), model: model, reasoning: .low) { _ in }
        #expect(cached.cacheHit && StubInference.requests.count == 1)
        #expect(StubInference.requests.first?.reasoning == "low")
        _ = try await service.process(input(), model: model, reasoning: .low, useCache: false) { _ in }
        #expect(StubInference.requests.count == 2)
        service.clearCache()
        _ = try await service.process(input(), model: model, reasoning: .low) { _ in }
        #expect(StubInference.requests.count == 3)
        scope = "another-account"
        let another = try await service.process(input(), model: model, reasoning: .low) { _ in }
        #expect(!another.cacheHit && StubInference.requests.count == 4)
        scope = nil
        await #expect(throws: AppFailure.self) { _ = try await service.process(input(), model: model, reasoning: .low) { _ in } }
        #expect(StubInference.requests.count == 4)
    }

    @Test func partialAndFailedStreamsNeverPopulateCache() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let service = OpenAITextService(session: session, scope: { "test" }, bearerToken: { "test-token" })
        let model = ModelChoice(id: "gpt-6-luna", name: "Luna")
        for reply in [StubInference.Reply.interrupted, .failed] {
            StubInference.reply = reply
            await #expect(throws: AppFailure.self) { _ = try await service.process(input(), model: model, reasoning: .fast) { _ in } }
            StubInference.reply = .completed
            let success = try await service.process(input(), model: model, reasoning: .fast) { _ in }
            #expect(!success.cacheHit && success.text == "Hello 🌍")
            service.clearCache()
        }
        #expect(StubInference.requests.count == 4)
        #expect(StubInference.requests.allSatisfy { $0.reasoning == "none" })
    }

    @Test func cancellingOrClearingCacheWhileStreamingCannotInsertAnOldResult() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        StubInference.reply = .completed
        let service = OpenAITextService(session: session, scope: { "test" }, bearerToken: { "test-token" })
        let model = ModelChoice(id: "gpt-6.1-sol", name: "Sol")
        _ = try await service.process(input(), model: model, reasoning: .fast) { _ in service.clearCache() }
        let fresh = try await service.process(input(), model: model, reasoning: .fast) { _ in }
        #expect(!fresh.cacheHit && StubInference.requests.count == 2)
        service.clearCache()
        let task = Task {
            _ = try await service.process(input(), model: model, reasoning: .fast) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let afterCancellation = try await service.process(input(), model: model, reasoning: .fast) { _ in }
        #expect(!afterCancellation.cacheHit && StubInference.requests.count == 4)
    }

    @Test func firstDeltaIsImmediateAndTrailingDeltaDoesNotWaitForAnotherNetworkEvent() async throws {
        var seen: [String] = []
        let publisher = StreamingTextPublisher(interval: .milliseconds(40)) { seen.append($0) }
        publisher.send("A")
        #expect(seen == ["A"])
        publisher.send("AB"); publisher.send("ABC")
        #expect(seen == ["A"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen == ["A", "ABC"])
        publisher.send("ABCD"); publisher.finish("ABCDE")
        #expect(seen.last == "ABCDE")
        let count = seen.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(seen.count == count)
        publisher.finish("current")
        let beforeCancel = seen.count
        publisher.send("stale"); publisher.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(seen.count == beforeCancel)
    }

    @Test func streamingAppendPreservesUnicodeSelectionAndTextStyling() throws {
        let view = AlternativeTextView()
        view.updateText("Привет 🌍", fontSize: 19, lineSpacing: 8)
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.updateText("Привет 🌍\nЕщё e\u{301}", fontSize: 19, lineSpacing: 8)
        #expect(view.string == "Привет 🌍\nЕщё e\u{301}")
        #expect(view.selectedRange() == NSRange(location: 0, length: 6))
        let storage = try #require(view.textStorage)
        #expect((storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont)?.pointSize == 19)
        #expect((storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing == 8)
        view.updateText("Replacement", fontSize: 17, lineSpacing: 6)
        #expect(view.string == "Replacement")
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 17)
        view.updateText("é", fontSize: 17, lineSpacing: 6)
        view.updateText("e\u{301} suffix", fontSize: 17, lineSpacing: 6)
        #expect(Array(view.string.utf16) == Array("e\u{301} suffix".utf16))
    }

    @Test func typingAndDeletionDebounceButWholeTextAndExplicitPasteStartImmediately() {
        #expect(InputChange.automaticDelay(from: "Привет", to: "Привет!", change: .typing) == .milliseconds(500))
        #expect(InputChange.automaticDelay(from: "Привет!", to: "Привет", change: .typing) == .milliseconds(500))
        #expect(InputChange.automaticDelay(from: "Hello world", to: "Hello мир 🌍", change: .typing) == .zero)
        #expect(InputChange.automaticDelay(from: "", to: "A whole pasted text", change: .typing) == .zero)
        #expect(InputChange.automaticDelay(from: "", to: "a", change: .paste) == .zero)
        #expect(InputChange.automaticDelay(from: "e", to: "e\u{301}", change: .typing) == .milliseconds(500))
    }

    @Test func warmCatalogIsScopedExpiresAndPreservesChoicesWhenRefreshFails() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 100)
        let catalog = ModelCatalog(defaults: defaults, now: { now })
        let choices = [ModelChoice(id: "gpt-6-luna", name: "Luna")]
        catalog.activate(scope: "a")
        try await catalog.refresh { choices }
        let warm = ModelCatalog(defaults: defaults, now: { now })
        warm.activate(scope: "a")
        #expect(warm.choices == choices)
        await #expect(throws: URLError.self) { try await warm.refresh { throw URLError(.notConnectedToInternet) } }
        #expect(warm.choices == choices)
        warm.activate(scope: "b")
        #expect(warm.choices.isEmpty)
        now.addTimeInterval(86401)
        warm.activate(scope: "a")
        #expect(warm.choices.isEmpty)
    }

    @Test func concurrentCatalogLoadsAreSharedAndAccountChangesDiscardLateResponses() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = ModelCatalog(defaults: defaults)
        catalog.activate(scope: "a")
        var loads = 0
        var resume: CheckedContinuation<[ModelChoice], Never>?
        let first = Task {
            try await catalog.refresh {
                loads += 1
                return await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        var joined = false
        let second = Task { joined = true; try await catalog.refresh { loads += 1; return [] } }
        while !joined { await Task.yield() }
        resume?.resume(returning: [ModelChoice(id: "a-model", name: "A")])
        try await first.value; try await second.value
        #expect(loads == 1 && catalog.choices.first?.id == "a-model")

        resume = nil
        let late = Task {
            try await catalog.refresh { await withCheckedContinuation { resume = $0 } }
        }
        while resume == nil { await Task.yield() }
        catalog.activate(scope: "b")
        try await catalog.refresh { [ModelChoice(id: "b-model", name: "B")] }
        resume?.resume(returning: [ModelChoice(id: "old-a-model", name: "Old A")])
        await #expect(throws: CancellationError.self) { try await late.value }
        #expect(catalog.choices.first?.id == "b-model")
        let restored = ModelCatalog(defaults: defaults)
        restored.activate(scope: "b")
        #expect(restored.choices.first?.id == "b-model")
    }

    private func body(reasoning: ReasoningEffort?) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: OpenAITextService.body(model: "test", reasoning: reasoning, instructions: "rules", text: "Привет 🌍")) as? [String: Any])
    }
    private func key(account: String = "a", model: String = "m", reasoning: ReasoningEffort? = .low, instructions: String = "i", input: String = "Привет") -> ProcessingResultCache.Key {
        .init(account: account, model: model, reasoning: reasoning, instructions: instructions, input: input)
    }
    private func input() -> ProcessingRequest {
        ProcessingRequest(input: "Привет 🌍", mode: .translate, source: "Русский", target: "English", tone: "Нейтральный", glossary: [])
    }
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "FormaTests.Performance." + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }
    private func stubSession() -> URLSession {
        StubInference.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubInference.self]
        return URLSession(configuration: config)
    }
}

private final class StubInference: URLProtocol {
    enum Reply { case completed, interrupted, failed }
    struct Request { let reasoning: String? }
    static var reply: Reply = .completed
    static var requests: [Request] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096), collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Self.requests.append(Request(reasoning: (object?["reasoning"] as? [String: String])?["effort"]))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        var wire = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 🌍\"}\n\n"
        switch Self.reply {
        case .completed: wire += "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"output_tokens_details\":{\"reasoning_tokens\":12}}}}\n\n"
        case .failed: wire += "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n"
        case .interrupted: break
        }
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
