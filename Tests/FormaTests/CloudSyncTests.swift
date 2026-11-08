import CloudKit
import Foundation
import Testing
@testable import Forma

@MainActor private final class CloudServer {
    var accounts: [String: [String: CloudSyncItem]] = [:]
}

@MainActor private final class CloudClient: CloudSyncTransport {
    let server: CloudServer
    var account = "first-account"
    var saveError: Error?
    var fetchHook: (() -> Void)?
    var saveHook: (() -> Void)?
    var saves = 0
    init(_ server: CloudServer) { self.server = server }
    func accountIdentifier() async throws -> String { account }
    func fetch() async throws -> [CloudSyncItem] {
        let result = Array(server.accounts[account, default: [:]].values)
        fetchHook?(); fetchHook = nil
        await Task.yield()
        return result
    }
    func save(_ items: [CloudSyncItem]) async throws {
        if let saveError { throw saveError }
        saves += 1
        for item in items { server.accounts[account, default: [:]][item.id] = item }
        saveHook?(); saveHook = nil
        await Task.yield()
    }
}

@MainActor private final class SyncFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let suite = "Forma.CloudSyncTests." + UUID().uuidString
    let client: CloudClient
    let store: LibraryStore
    let rules: PromptRulesStore
    init(server: CloudServer) {
        defaults = UserDefaults(suiteName: suite)!
        client = CloudClient(server)
        store = LibraryStore(directory: directory, defaults: defaults, transport: client, automaticSync: false)
        rules = PromptRulesStore(directory: directory)
        store.attach(rules: rules)
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite @MainActor struct CloudSyncTests {
    @Test func twoDevicesMergeDictionaryHistoryAndRulesAndPropagateDeletions() async throws {
        let server = CloudServer()
        let first = SyncFixture(server: server), second = SyncFixture(server: server)
        defer { first.cleanup(); second.cleanup() }
        let preference = MemoryEntry(source: "пример", preferred: "example", languages: "Русский → English")
        let history = HistoryEntry(mode: .translate, source: "Пример", result: "Example")
        let rule = CustomPromptRule(title: "Plain", instruction: "Use plain language", enabled: true, modes: [.rewrite])
        first.store.updateMemory([preference]); first.store.updateHistory([history]); first.rules.upsert(rule)
        first.rules.set(.expandAbbreviations, enabled: true)
        first.rules.set(.keepAbbreviations, enabled: true)
        first.store.enableCloud(true); second.store.enableCloud(true)
        await first.store.synchronize(); await second.store.synchronize()
        #expect(second.store.snapshot.memory.contains { $0.id == preference.id && !$0.deleted })
        #expect(second.store.snapshot.history == [history])
        #expect(second.rules.state.custom == [rule])
        #expect(second.rules.state.templates == [.expandAbbreviations, .keepAbbreviations])
        second.store.updateMemory([]); second.store.updateHistory([]); second.rules.delete(rule.id)
        await second.store.synchronize(); await first.store.synchronize()
        #expect(first.store.snapshot.memory.allSatisfy { $0.deleted })
        #expect(first.store.snapshot.history.isEmpty)
        #expect(first.rules.state.custom.isEmpty)
        let stale = CloudSyncState().merging(first.store.snapshot.cloudItems ?? [])
        let deleted = try #require(stale.items["history." + history.id.uuidString])
        #expect(deleted.deleted && deleted.payload == nil)
    }

    @Test func offlineChangesAndRuleOrderSurviveRelaunchWithoutResurrectingHistory() async throws {
        let server = CloudServer()
        let first = SyncFixture(server: server), second = SyncFixture(server: server)
        defer { first.cleanup(); second.cleanup() }
        let history = HistoryEntry(mode: .rewrite, source: "old", result: "new")
        let r1 = CustomPromptRule(title: "One", instruction: "Rule one", enabled: true)
        let r2 = CustomPromptRule(title: "Two", instruction: "Rule two", enabled: false, modes: [.translate])
        first.store.updateHistory([history]); first.rules.upsert(r1); first.rules.upsert(r2)
        first.store.enableCloud(true); second.store.enableCloud(true)
        await first.store.synchronize(); await second.store.synchronize()
        first.store.enableCloud(false)
        first.store.updateHistory([])
        var state = first.rules.state; state.custom.reverse()
        #expect(first.rules.applySynchronizedState(state))
        // A normal local edit publishes the current saved order too.
        var edited = r2; edited.enabled = true; first.rules.upsert(edited)
        let restoredRules = PromptRulesStore(directory: first.directory)
        let restored = LibraryStore(directory: first.directory, defaults: first.defaults, transport: first.client, automaticSync: false)
        restored.attach(rules: restoredRules); restored.enableCloud(true)
        await restored.synchronize(); await second.store.synchronize()
        #expect(second.store.snapshot.history.isEmpty)
        #expect(second.rules.state.custom.map(\.id) == [r2.id, r1.id])
        #expect(second.rules.state.custom.first?.enabled == true)
    }

    @Test func localEditsDuringFetchAndUploadArePreserved() async {
        let fixture = SyncFixture(server: CloudServer())
        defer { fixture.cleanup() }
        fixture.store.enableCloud(true)
        let fetchedEdit = HistoryEntry(mode: .correct, source: "fetch", result: "fetch edit")
        let uploadedEdit = HistoryEntry(mode: .correct, source: "upload", result: "upload edit")
        fixture.client.fetchHook = { fixture.store.updateHistory([fetchedEdit]) }
        fixture.client.saveHook = { fixture.store.updateHistory([uploadedEdit, fetchedEdit]) }
        await fixture.store.synchronize()
        #expect(Set(fixture.store.snapshot.history.map(\.id)) == [fetchedEdit.id, uploadedEdit.id])
        await fixture.store.synchronize()
        let remote = CloudSyncState().merging(Array(fixture.client.server.accounts[fixture.client.account, default: [:]].values))
        #expect((try? remote.values("history", as: HistoryEntry.self).count) == 2)
    }

    @Test func conflictsAndQuotaErrorsAreVisibleAndRetryPreservesLocalData() async {
        let fixture = SyncFixture(server: CloudServer())
        defer { fixture.cleanup() }
        let entry = HistoryEntry(mode: .translate, source: "local", result: "kept")
        fixture.store.updateHistory([entry]); fixture.store.enableCloud(true)
        for code in [CKError.Code.serverRecordChanged, .quotaExceeded] {
            fixture.client.saveError = CKError(code)
            await fixture.store.synchronize()
            #expect(fixture.store.snapshot.history == [entry])
            #expect(fixture.store.message != "Словарь, история и правила синхронизированы с iCloud.")
        }
        fixture.client.saveError = nil
        await fixture.store.synchronize()
        #expect(fixture.store.message == "Словарь, история и правила синхронизированы с iCloud.")
    }

    @Test func changedAccountAndDisableDuringFetchNeverUploadToAnotherAccount() async {
        let fixture = SyncFixture(server: CloudServer())
        defer { fixture.cleanup() }
        fixture.store.enableCloud(true)
        await fixture.store.synchronize()
        let saves = fixture.client.saves
        fixture.client.account = "different-account"
        await fixture.store.synchronize()
        #expect(!fixture.store.cloudEnabled)
        #expect(fixture.client.saves == saves)
        #expect(fixture.client.server.accounts["different-account"] == nil)
        fixture.store.enableCloud(true)
        fixture.client.fetchHook = { fixture.store.enableCloud(false) }
        await fixture.store.synchronize()
        #expect(fixture.client.saves == saves)
    }

    @Test func oldConsentDoesNotEnableExpandedScopeAndCorruptFilesAreNotOverwritten() throws {
        let fixture = SyncFixture(server: CloudServer())
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: "library.cloudEnabled")
        let restored = LibraryStore(directory: fixture.directory, defaults: fixture.defaults, transport: fixture.client, automaticSync: false)
        #expect(!restored.cloudEnabled)
        let file = fixture.directory.appendingPathComponent("library.json")
        let corrupted = Data("not json".utf8)
        try corrupted.write(to: file)
        let broken = LibraryStore(directory: fixture.directory, defaults: fixture.defaults, transport: fixture.client, automaticSync: false)
        broken.updateHistory([HistoryEntry(mode: .translate, source: "x", result: "y")])
        #expect(try Data(contentsOf: file) == corrupted)
    }

    @Test func malformedRemoteIdentityCannotOverwriteLocalDataOrTriggerUpload() async throws {
        let server = CloudServer()
        let fixture = SyncFixture(server: server)
        defer { fixture.cleanup() }
        let local = HistoryEntry(mode: .translate, source: "local", result: "kept")
        fixture.store.updateHistory([local])
        var remote = CloudSyncState()
        try remote.set(local, id: "history." + UUID().uuidString, at: Date())
        server.accounts[fixture.client.account] = remote.items
        fixture.store.enableCloud(true)
        await fixture.store.synchronize()
        #expect(fixture.client.saves == 0)
        #expect(fixture.store.snapshot.history == [local])
        #expect(fixture.store.message == CloudSyncFailure.invalidRecord.localizedDescription)
    }

    @Test func equalTimestampConflictsConvergeAndLocalClockRollbackStillAllowsEditing() throws {
        var left = CloudSyncState(), right = CloudSyncState()
        let date = Date(timeIntervalSince1970: 50)
        try left.set("a", id: "test.record", at: date)
        try right.set("b", id: "test.record", at: date)
        #expect(left.merging(Array(right.items.values)) == right.merging(Array(left.items.values)))
        left.delete("test.record", at: date.addingTimeInterval(1))
        #expect(left.merging(Array(right.items.values)).items["test.record"]?.deleted == true)
        try left.set("new", id: "test.record", at: .distantPast)
        #expect(left.items["test.record"]?.deleted == false)
        #expect(left.items["test.record"]!.modifiedAt > date)
    }

    @Test func historyLimitCreatesTombstonesAndRuleProjectionResolvesTemplateDependencies() throws {
        var state = CloudSyncState()
        for index in 0..<503 {
            var entry = HistoryEntry(mode: .translate, source: "item", result: "result")
            entry.date = Date(timeIntervalSince1970: Double(index))
            try state.set(entry, id: "history." + entry.id.uuidString, at: entry.date)
        }
        try state.trimHistory(at: Date())
        #expect(try state.values("history", as: HistoryEntry.self).count == 500)
        #expect(state.items.values.filter(\.deleted).count == 3)
        try state.set(true, id: "template.americanEnglish", at: Date())
        try state.set(true, id: "template.britishEnglish", at: Date())
        try state.set(true, id: "template.keepAbbreviations", at: Date())
        #expect(try state.rules().templates == [.americanEnglish])
    }
}
