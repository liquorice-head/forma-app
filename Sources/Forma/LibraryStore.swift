import CloudKit
import Foundation
import Observation

@MainActor @Observable final class LibraryStore {
    struct Snapshot: Codable {
        var memory: [MemoryEntry] = []
        var history: [HistoryEntry] = []
        var cloudItems: [CloudSyncItem]? = nil
        var cloudAccount: String? = nil
    }
    private(set) var snapshot = Snapshot()
    var message: String?
    private(set) var syncing = false
    private(set) var cloudEnabled: Bool {
        didSet { defaults.set(cloudEnabled, forKey: "library.cloudAllDataEnabled.v1") }
    }
    var cloudConfigured: Bool { transport != nil }
    var onMemoryUpdate: (([MemoryEntry]) -> Void)?
    var onHistoryUpdate: (([HistoryEntry]) -> Void)?
    private let file: URL
    private let defaults: UserDefaults
    private let transport: (any CloudSyncTransport)?
    private let now: () -> Date
    private let automaticSync: Bool
    private weak var rulesStore: PromptRulesStore?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    private var generation = UUID()
    private var needsResync = false
    private var canSave = true
    @ObservationIgnored private var accountObserver: NSObjectProtocol?

    init(directory: URL? = nil, defaults: UserDefaults = .standard,
         transport: (any CloudSyncTransport)? = nil, automaticSync: Bool = true,
         now: @escaping () -> Date = Date.init) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Forma", isDirectory: true)
        file = directory.appendingPathComponent("library.json")
        self.defaults = defaults; self.now = now; self.automaticSync = automaticSync
        // Older dictionary-only consent must not silently upload history or rules.
        cloudEnabled = defaults.bool(forKey: "library.cloudAllDataEnabled.v1")
        if let transport { self.transport = transport }
        else if let id = Bundle.main.object(forInfoDictionaryKey: "FormaCloudContainerIdentifier") as? String,
                id.hasPrefix("iCloud."), !id.contains("$(") {
            self.transport = CloudKitTransport(containerIdentifier: id)
        } else { self.transport = nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: file.path) {
                snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            } else if let legacy = defaults.data(forKey: "prototype.memory") {
                snapshot.memory = try JSONDecoder().decode([MemoryEntry].self, from: legacy)
            }
            if snapshot.cloudItems == nil {
                var state = CloudSyncState()
                for entry in snapshot.memory {
                    let id = "memory." + entry.id.uuidString
                    if entry.deleted { state.delete(id, at: entry.modifiedAt) }
                    else { try state.set(entry, id: id, at: entry.modifiedAt) }
                }
                for entry in snapshot.history { try state.set(entry, id: "history." + entry.id.uuidString, at: entry.date) }
                snapshot.cloudItems = Array(state.items.values)
                persist()
            }
        } catch {
            canSave = false
            message = "Не удалось прочитать локальную историю. Исходный файл сохранён."
        }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountChanged() }
        }
    }
    deinit {
        scheduled?.cancel(); work?.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }
    private var state: CloudSyncState { CloudSyncState().merging(snapshot.cloudItems ?? []) }

    func attach(rules: PromptRulesStore) {
        rulesStore = rules
        guard !rules.loadFailed, canSave else { return }
        do {
            var next = state
            try next.captureRules(rules.state, at: next.items["settings.ruleOrder"] == nil ? .distantPast : now())
            snapshot.cloudItems = Array(next.items.values)
            persist()
            rules.onSyncChange = { [weak self] in self?.updateRules($0) }
        } catch { message = error.localizedDescription }
    }
    private func updateRules(_ rules: PromptRulesState) {
        guard canSave else { return }
        do {
            var next = state
            try next.captureRules(rules, at: now())
            snapshot.cloudItems = Array(next.items.values)
            persist(); scheduleSync()
        } catch { message = error.localizedDescription }
    }
    func updateMemory(_ active: [MemoryEntry]) {
        guard canSave else { return }
        var all = Dictionary(uniqueKeysWithValues: snapshot.memory.map { ($0.id, $0) })
        let activeIDs = Set(active.map(\.id))
        var next = state
        do {
            for var entry in active {
                if let previous = all[entry.id], !previous.deleted,
                   previous.source == entry.source, previous.preferred == entry.preferred,
                   previous.languages == entry.languages, previous.context == entry.context { continue }
                let key = "memory." + entry.id.uuidString
                entry.modifiedAt = max(now(), (next.items[key]?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
                entry.deleted = false
                all[entry.id] = entry
                try next.set(entry, id: key, at: entry.modifiedAt)
            }
            for (id, var entry) in all where !activeIDs.contains(id) && !entry.deleted {
                next.delete("memory." + id.uuidString, at: now())
                entry.deleted = true
                entry.modifiedAt = next.items["memory." + id.uuidString]!.modifiedAt
                all[id] = entry
            }
            guard next != state else { return }
            snapshot.memory = all.values.sorted { $0.id.uuidString < $1.id.uuidString }
            snapshot.cloudItems = Array(next.items.values)
            persist(); scheduleSync()
        } catch { message = error.localizedDescription }
    }
    func updateHistory(_ history: [HistoryEntry]) {
        guard canSave, history != snapshot.history else { return }
        do {
            var next = state
            let values = Array(history.prefix(500))
            let ids = Set(values.map { "history." + $0.id.uuidString })
            // Clearing also covers records outside the currently visible window.
            let previous = history.isEmpty ? next.items.keys.filter { $0.hasPrefix("history.") } : snapshot.history.map { "history." + $0.id.uuidString }
            for key in previous where !ids.contains(key) { next.delete(key, at: now()) }
            for entry in values { try next.set(entry, id: "history." + entry.id.uuidString, at: now()) }
            try next.trimHistory(at: now())
            snapshot.history = values
            snapshot.cloudItems = Array(next.items.values)
            persist(); scheduleSync()
        } catch { message = error.localizedDescription }
    }
    @discardableResult private func persist(_ value: Snapshot? = nil) -> Bool {
        guard canSave else { return false }
        do {
            try JSONEncoder().encode(value ?? snapshot).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { message = "Не удалось сохранить данные на этом Mac."; return false }
    }
    func enableCloud(_ enabled: Bool) {
        guard !enabled || cloudConfigured else { return }
        generation = UUID()
        scheduled?.cancel(); work?.cancel()
        cloudEnabled = enabled
        if enabled {
            snapshot.cloudAccount = nil
            defaults.removeObject(forKey: "library.cloudAccount")
            persist(); scheduleSync()
        }
    }
    func accountChanged() {
        generation = UUID()
        cloudEnabled = false
        scheduled?.cancel(); work?.cancel()
        message = CloudSyncFailure.changedAccount.localizedDescription
    }
    func scheduleSync(after delay: Duration = .seconds(1)) {
        guard automaticSync, cloudEnabled, cloudConfigured, canSave else { return }
        if syncing { needsResync = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, cloudEnabled, !Task.isCancelled else { return }
            scheduled = nil
            work = Task { [weak self] in await self?.synchronize() }
        }
    }
    func synchronize() async {
        guard cloudEnabled, canSave, let transport else { return }
        guard !syncing else { needsResync = true; return }
        guard rulesStore?.loadFailed != true else { message = CloudSyncFailure.localSave.localizedDescription; return }
        syncing = true
        let generation = generation
        var delay: Duration = .seconds(30)
        defer {
            syncing = false
            if cloudEnabled {
                let retry = needsResync; needsResync = false
                scheduleSync(after: retry ? .seconds(1) : delay)
            }
        }
        func checkScope() throws {
            try Task.checkCancellation()
            guard cloudEnabled, self.generation == generation else { throw CancellationError() }
        }
        do {
            let account = try await transport.accountIdentifier()
            try checkScope()
            if let previous = snapshot.cloudAccount ?? defaults.string(forKey: "library.cloudAccount"), previous != account {
                accountChanged(); throw CloudSyncFailure.changedAccount
            }
            let remote = try await transport.fetch()
            try checkScope()
            guard try await transport.accountIdentifier() == account else { accountChanged(); throw CloudSyncFailure.changedAccount }
            try checkScope()
            var merged = state.merging(remote)
            try merged.trimHistory(at: now())
            _ = try merged.values("memory", as: MemoryEntry.self)
            _ = try merged.values("history", as: HistoryEntry.self)
            if rulesStore != nil { _ = try merged.rules() }
            let remoteByID = CloudSyncState().merging(remote).items
            let changes = merged.items.values.filter { remoteByID[$0.id] != $0 }
            try checkScope()
            try await transport.save(Array(changes))
            try checkScope()
            guard try await transport.accountIdentifier() == account else { accountChanged(); throw CloudSyncFailure.changedAccount }
            try checkScope()
            let withNewEdits = merged.merging(Array(state.items.values))
            needsResync = needsResync || withNewEdits != merged
            merged = withNewEdits
            try merged.trimHistory(at: now())
            var candidate = snapshot
            let active = try merged.values("memory", as: MemoryEntry.self)
            var deleted = snapshot.memory.filter { merged.items["memory." + $0.id.uuidString]?.deleted == true }
            for index in deleted.indices {
                deleted[index].deleted = true
                deleted[index].modifiedAt = merged.items["memory." + deleted[index].id.uuidString]!.modifiedAt
            }
            candidate.memory = active + deleted
            candidate.history = try merged.values("history", as: HistoryEntry.self).sorted {
                $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
            }
            candidate.cloudItems = Array(merged.items.values)
            candidate.cloudAccount = account
            if let rulesStore, !rulesStore.applySynchronizedState(try merged.rules()) { throw CloudSyncFailure.localSave }
            guard persist(candidate) else { throw CloudSyncFailure.localSave }
            snapshot = candidate
            onMemoryUpdate?(active.sorted { $0.modifiedAt > $1.modifiedAt })
            onHistoryUpdate?(candidate.history)
            message = "Словарь, история и правила синхронизированы с iCloud."
        } catch is CancellationError { }
        catch {
            message = error.localizedDescription
            if let error = error as? CKError { delay = .seconds(max(10, error.retryAfterSeconds ?? 10)) }
            else { delay = .seconds(10) }
        }
    }
    nonisolated static func merge(local: [MemoryEntry], remote: [MemoryEntry]) -> [UUID: MemoryEntry] {
        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for entry in remote {
            if merged[entry.id] == nil || merged[entry.id]!.modifiedAt < entry.modifiedAt { merged[entry.id] = entry }
        }
        return merged
    }
}
