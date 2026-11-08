import Foundation
import Security
import Testing
@testable import Forma

struct CoreTests {
    @Test @MainActor func initialGrantIsReadyButAChangedGrantOffersOneRestart() {
        let alreadyTrusted = AccessibilityAccess(check: { true }, prompt: {}, openSettings: { true })
        #expect(alreadyTrusted.granted && !alreadyTrusted.requiresRestart)
        #expect(!alreadyTrusted.consumeRestartPrompt())
        var trusted = false
        let access = AccessibilityAccess(check: { trusted }, prompt: {}, openSettings: { true })
        trusted = true
        access.refresh()
        #expect(access.granted && access.requiresRestart)
        #expect(access.consumeRestartPrompt())
        access.returnedFromSettings()
        #expect(!access.consumeRestartPrompt())
    }

    @Test @MainActor func returnFromSettingsOffersRestartWithoutAssumingGrantAndFailedRestartExplainsRepair() {
        let access = AccessibilityAccess(check: { false }, prompt: {}, openSettings: { true })
        access.request()
        access.returnedFromSettings()
        #expect(!access.granted && access.requiresRestart)
        #expect(access.consumeRestartPrompt())
        access.returnedFromSettings()
        #expect(!access.consumeRestartPrompt())
        let afterRestart = AccessibilityAccess(restarted: true, check: { false }, prompt: {}, openSettings: { true })
        #expect(afterRestart.repairRequired && !afterRestart.requiresRestart)
        #expect(!afterRestart.consumeRestartPrompt())
        let success = AccessibilityAccess(restarted: true, check: { true }, prompt: {}, openSettings: { true })
        #expect(success.granted && !success.repairRequired && !success.requiresRestart)
    }
    @Test func relaunchDraftRestoresUnicodeAndCompletedResultOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = RelaunchDraft(mode: .rewrite, tone: "Деловой", sourceLanguage: "Русский", targetLanguage: "English",
            input: "Привет, мир 🌍\nВторая строка", output: "Здравствуйте, мир 🌍", resultEngine: .chatGPT, screen: "editor")
        try RelaunchStore.save(draft, directory: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("relaunch.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let savedDraft = try RelaunchStore.take(directory: directory)
        let restored = try #require(savedDraft)
        #expect(restored.input == draft.input && restored.output == draft.output)
        #expect(restored.mode == .rewrite && restored.tone == "Деловой" && restored.resultEngine == .chatGPT)
        #expect(try RelaunchStore.take(directory: directory) == nil)
    }

    @Test func expiredRelaunchDraftIsNotRestoredAndFailedSaveThrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = RelaunchDraft(mode: .translate, tone: "Нейтральный", sourceLanguage: "Русский", targetLanguage: "English",
            input: "old draft", output: "", resultEngine: nil, screen: "editor")
        draft.savedAt = Date(timeIntervalSince1970: 100)
        try RelaunchStore.save(draft, directory: directory)
        #expect(try RelaunchStore.take(directory: directory, now: Date(timeIntervalSince1970: 1000)) == nil)
        #expect(try RelaunchStore.take(directory: directory) == nil)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        #expect(throws: (any Error).self) { try RelaunchStore.save(draft, directory: blocker) }
    }

    @Test @MainActor func permissionGrantIsDetectedWhileSettingsIsOpenAndDoesNotPromptAgain() async throws {
        var trusted = false
        var prompts = 0
        var openedSettings = 0
        var changes: [Bool] = []
        let access = AccessibilityAccess(check: { trusted }, prompt: { prompts += 1 }, openSettings: { openedSettings += 1; return true })
        access.onChange = { changes.append($0) }
        #expect(!access.granted)
        access.request(pollInterval: .milliseconds(10))
        #expect(access.waiting)
        #expect(prompts == 1 && openedSettings == 1)
        trusted = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(access.granted && !access.waiting)
        #expect(access.requested) // Keep Save and Reopen available after the grant.
        #expect(changes == [true])
        access.request()
        #expect(prompts == 1 && openedSettings == 1)
        trusted = false
        access.refresh()
        #expect(!access.granted)
        #expect(changes == [true, false])
    }

    @Test @MainActor func settingsFailureProvidesManualRecoveryAndNeverAssumesPermission() {
        var trusted = false
        let access = AccessibilityAccess(check: { trusted }, prompt: {}, openSettings: { false })
        access.request()
        #expect(access.settingsUnavailable)
        #expect(!access.granted)
        trusted = true
        access.refresh()
        #expect(access.granted && !access.waiting)
    }

    @Test func networkEventBoundariesPreserveUnicodeAndCompletion() throws {
        // Foundation's AsyncBytes.lines drops the empty delimiters in this exact wire format.
        for newline in ["\n", "\r\n", "\r"] {
            let lines = ["\u{feff}: heartbeat", "", "event: response.output_text.delta",
                #"data: {"type":"response.output_text.delta","delta":"Привет 🌍"}"#, "",
                "event: response.completed", #"data: {"type":"response.completed","response":{"status":"completed"}}"#, "", ""]
            var events = ServerSentEvents()
            var stream = ResponseStream()
            var count = 0
            for byte in lines.joined(separator: newline).utf8 {
                if let event = try events.consume(byte) { try stream.consume(event); count += 1 }
            }
            #expect(count == 2)
            #expect(try stream.result() == "Привет 🌍")
        }
    }

    @Test func multilineEventsAndIncompleteFinalEventAreHandledSeparately() throws {
        var parser = ServerSentEvents()
        var events: [String] = []
        let wire = "id: 1\ndata: {\ndata: \"type\":\"response.created\"}\n\ndata: unfinished"
        for byte in wire.utf8 { if let event = try parser.consume(byte) { events.append(event) } }
        #expect(events == ["{\n\"type\":\"response.created\"}"])
        var stream = ResponseStream()
        #expect(throws: AppFailure.self) { try stream.consume("two JSON objects are not one event") }
    }

    @Test @MainActor func typingCoalescesAndManualActionCancelsPendingAutomaticAction() async throws {
        let debounce = DebouncedAction()
        var requests: [String] = []
        debounce.schedule(after: .milliseconds(80)) { requests.append("old draft") }
        try await Task.sleep(for: .milliseconds(20))
        debounce.schedule(after: .milliseconds(80)) { requests.append("latest draft") }
        #expect(requests.isEmpty)
        try await Task.sleep(for: .milliseconds(180))
        #expect(requests == ["latest draft"])
        debounce.schedule(after: .milliseconds(80)) { requests.append("duplicate automatic request") }
        debounce.cancel()
        requests.append("manual request")
        try await Task.sleep(for: .milliseconds(180))
        #expect(requests == ["latest draft", "manual request"])
    }

    @Test func keychainRoundTripUsesAnIsolatedDisposableRecord() throws {
        let service = "app.forma.test." + UUID().uuidString
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "connections"] as CFDictionary)
        }
        var profile = ChatGPTProfile(clientID: "test-client", subject: "test-subject", email: "test@example.invalid",
            accessToken: "non-credential-test-data", refreshToken: nil, idToken: nil, expiresAt: Date(), scopes: [])
        try CredentialStore.save([profile], service: service)
        #expect(try CredentialStore.load(service: service).first?.email == profile.email)
        profile.accessToken = "updated-test-data"
        try CredentialStore.save([profile], service: service)
        #expect(try CredentialStore.load(service: service).first?.accessToken == "updated-test-data")
    }
    @Test @MainActor func unresponsiveSystemOperationTimesOutAndRunsCancellation() async {
        var cancelled = false
        do {
            _ = try await AsyncDeadline.value(after: .milliseconds(20), cancel: { cancelled = true }) {
                try await Task.sleep(for: .seconds(30))
                return "late result"
            }
            Issue.record("An unresponsive operation must not complete successfully.")
        } catch { #expect(cancelled) }
    }
    @Test func doubleCopyRequiresTwoSeparatePressesAndResets() {
        var detector = DoubleCopyDetector()
        let first = [1.0, 1.3, 1.4].map { detector.press(at: $0) }
        #expect(first == [false, true, false])
        detector.reset()
        let second = [1.5, 2.5, 2.7].map { detector.press(at: $0) }
        #expect(second == [false, false, true])
    }

    @Test func interruptedAndFailedStreamsNeverBecomeSuccessfulTranslations() throws {
        var stream = ResponseStream()
        try stream.consume(#"{"type":"response.output_text.delta","delta":"Hello"}"#)
        #expect(throws: (any Error).self) { try stream.result() }
        #expect(throws: (any Error).self) { try stream.consume(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#) }
        #expect(throws: (any Error).self) { try stream.result() }
    }

    @Test func completedStreamPreservesUnicode() throws {
        var stream = ResponseStream()
        try stream.consume(#"{"type":"response.output_text.delta","delta":"Привет, "}"#)
        try stream.consume(#"{"type":"response.output_text.delta","delta":"мир 🌍"}"#)
        try stream.consume(#"{"type":"response.completed","response":{"status":"completed"}}"#)
        #expect(try stream.result() == "Привет, мир 🌍")
    }

    @Test func newerDeletionDoesNotResurrectFromAnOfflineDevice() {
        var old = MemoryEntry(source: "запуск", preferred: "launch", languages: "Русский → English")
        old.modifiedAt = Date(timeIntervalSince1970: 10)
        var deleted = old
        deleted.deleted = true
        deleted.modifiedAt = Date(timeIntervalSince1970: 20)
        #expect(LibraryStore.merge(local: [old], remote: [deleted])[old.id]?.deleted == true)
        #expect(LibraryStore.merge(local: [deleted], remote: [old])[old.id]?.deleted == true)
    }

    @Test func concurrentPreferencesForTheSamePhraseHaveTheSameIdentity() {
        let firstMac = MemoryEntry(source: "запуск", preferred: "launch", languages: "Русский → English")
        let secondMac = MemoryEntry(source: "запуск", preferred: "release", languages: "Русский → English")
        let anotherLanguage = MemoryEntry(source: "запуск", preferred: "lancement", languages: "Русский → Français")
        #expect(firstMac.id == secondMac.id)
        #expect(firstMac.id != anotherLanguage.id)
    }

    @Test func undoKeepsUnrelatedSyncedPreferencesAndLaterRemoteCorrections() {
        let original = MemoryEntry(source: "запуск", preferred: "launch", languages: "Русский → English")
        var chosen = original; chosen.preferred = "release"
        let synced = MemoryEntry(source: "отзыв", preferred: "feedback", languages: "Русский → English")
        let change = PreferenceChange(before: original, after: chosen)
        let undone = change.undo(in: [chosen, synced])
        #expect(undone.contains(synced))
        #expect(undone.first(where: { $0.id == original.id })?.preferred == "launch")
        var newerRemote = chosen; newerRemote.preferred = "rollout"
        #expect(change.undo(in: [newerRemote, synced]).contains(newerRemote))
    }

    @Test @MainActor func historySurvivesRelaunchAndDeletedPreferencesRemainTombstones() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let preference = MemoryEntry(source: "запуск", preferred: "launch", languages: "Русский → English")
        store.updateMemory([preference])
        store.updateHistory([HistoryEntry(mode: .translate, source: "Привет", result: "Hello")])
        store.updateMemory([])
        let restored = LibraryStore(directory: directory)
        #expect(restored.snapshot.history.first?.result == "Hello")
        #expect(restored.snapshot.memory.first?.id == preference.id)
        #expect(restored.snapshot.memory.first?.deleted == true)
    }

    @Test func validSignatureCannotBypassNonceAudienceOrExpiryChecks() throws {
        var keyError: Unmanaged<CFError>?
        let generated = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &keyError)
        let privateKey = try #require(generated, "\(String(describing: keyError?.takeRetainedValue()))")
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let publicData = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        var offset = 0
        func value(_ expected: UInt8) throws -> Data {
            #expect(publicData[offset] == expected); offset += 1
            var length = Int(publicData[offset]); offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F; length = 0
                for _ in 0..<count { length = length << 8 | Int(publicData[offset]); offset += 1 }
            }
            if expected == 0x30 { return Data() }
            let bytes = Data(publicData[offset..<(offset + length)]); offset += length
            return bytes
        }
        _ = try value(0x30)
        let modulus = try value(0x02)
        let exponent = try value(0x02)
        let jwkData = try JSONSerialization.data(withJSONObject: ["kty": "RSA", "kid": "test", "n": modulus.base64URL, "e": exponent.base64URL])
        let jwk = try JSONDecoder().decode(PublicJWK.self, from: jwkData)
        let header = Data(#"{"alg":"RS256","kid":"test"}"#.utf8).base64URL
        let payload = try JSONSerialization.data(withJSONObject: ["iss": "https://auth.openai.com", "aud": "test-client", "sub": "test-subject", "nonce": "test-nonce", "exp": 2000]).base64URL
        let signed = header + "." + payload
        let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil) as Data?)
        let token = signed + "." + signature.base64URL
        let now = Date(timeIntervalSince1970: 1000)
        #expect(try IdentityToken.verify(token, audience: "test-client", nonce: "test-nonce", keys: [jwk], now: now)["sub"] as? String == "test-subject")
        #expect(throws: (any Error).self) { try IdentityToken.verify(token, audience: "wrong-client", nonce: "test-nonce", keys: [jwk], now: now) }
        #expect(throws: (any Error).self) { try IdentityToken.verify(token, audience: "test-client", nonce: "wrong-nonce", keys: [jwk], now: now) }
        #expect(throws: (any Error).self) { try IdentityToken.verify(token, audience: "test-client", nonce: "test-nonce", keys: [jwk], now: Date(timeIntervalSince1970: 3000)) }
        let altered = header + "." + Data(#"{"sub":"attacker"}"#.utf8).base64URL + "." + signature.base64URL
        #expect(throws: (any Error).self) { try IdentityToken.verify(altered, audience: "test-client", nonce: "test-nonce", keys: [jwk], now: now) }
    }
}
