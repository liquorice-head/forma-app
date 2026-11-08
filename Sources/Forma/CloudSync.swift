import Foundation

/// A deletion is a small permanent marker, so an offline Mac cannot restore
/// removed history or rules. No authentication data is part of this schema.
struct CloudSyncItem: Codable, Equatable, Identifiable {
    let id: String
    var modifiedAt: Date
    var deleted: Bool
    var payload: Data?

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func value<T: Decodable>(_ type: T.Type) throws -> T {
        guard !deleted, let payload else { throw CloudSyncFailure.invalidRecord }
        return try JSONDecoder().decode(type, from: payload)
    }

    func wins(over other: Self) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        if deleted != other.deleted { return deleted }
        return (other.payload ?? Data()).lexicographicallyPrecedes(payload ?? Data())
    }
}

enum CloudSyncFailure: LocalizedError {
    case invalidRecord, unavailableAccount, changedAccount, localSave, oversizedRecord
    var errorDescription: String? {
        switch self {
        case .invalidRecord: "Не удалось прочитать данные iCloud. Локальные данные сохранены."
        case .unavailableAccount: "Войдите в iCloud в настройках macOS, чтобы включить синхронизацию."
        case .changedAccount: "Аккаунт iCloud изменился. Проверьте аккаунт и включите синхронизацию повторно."
        case .localSave: "Не удалось сохранить данные синхронизации на этом Mac."
        case .oversizedRecord: "Запись слишком велика для iCloud. Она сохранена на этом Mac."
        }
    }
}

struct CloudSyncState: Codable, Equatable {
    var items: [String: CloudSyncItem] = [:]

    mutating func set<T: Encodable>(_ value: T, id: String, at date: Date) throws {
        let data = try CloudSyncItem.encodeJSON(value)
        if let old = items[id], !old.deleted, old.payload == data { return }
        items[id] = CloudSyncItem(id: id, modifiedAt: nextDate(id, date), deleted: false, payload: data)
    }

    mutating func delete(_ id: String, at date: Date) {
        guard items[id]?.deleted != true else { return }
        items[id] = CloudSyncItem(id: id, modifiedAt: nextDate(id, date), deleted: true, payload: nil)
    }

    private func nextDate(_ id: String, _ date: Date) -> Date {
        // A local edit causally follows the last known revision, even if the
        // clock moved backwards. Unknown concurrent revisions use LWW below.
        guard let old = items[id] else { return date }
        return max(date, old.modifiedAt.addingTimeInterval(0.001))
    }

    func merging(_ remote: [CloudSyncItem]) -> Self {
        var result = self
        for item in remote {
            if result.items[item.id].map({ item.wins(over: $0) }) ?? true { result.items[item.id] = item }
        }
        return result
    }

    func values<T: Decodable & Identifiable>(_ kind: String, as type: T.Type) throws -> [T] where T.ID == UUID {
        try items.values.filter { $0.id.hasPrefix(kind + ".") && !$0.deleted }
            .sorted { $0.id < $1.id }.map { item in
                let value = try item.value(type)
                guard item.id == kind + "." + value.id.uuidString else { throw CloudSyncFailure.invalidRecord }
                return value
            }
    }

    mutating func captureRules(_ state: PromptRulesState, at date: Date) throws {
        let current = Set(state.custom.map { "rule." + $0.id.uuidString })
        for key in Array(items.keys) where key.hasPrefix("rule.") && !current.contains(key) { delete(key, at: date) }
        for rule in state.custom { try set(rule, id: "rule." + rule.id.uuidString, at: date) }
        try set(state.custom.map(\.id), id: "settings.ruleOrder", at: date)
        for template in PromptRuleTemplate.allCases {
            try set(state.templates.contains(template), id: "template." + template.rawValue, at: date)
        }
    }

    func rules() throws -> PromptRulesState {
        let custom = try values("rule", as: CustomPromptRule.self)
        guard custom.allSatisfy(\.isValid), Set(custom.map(\.id)).count == custom.count else { throw CloudSyncFailure.invalidRecord }
        let byID = Dictionary(uniqueKeysWithValues: custom.map { ($0.id, $0) })
        let savedOrder: [UUID] = try items["settings.ruleOrder"].map { try $0.value([UUID].self) } ?? []
        var seen: Set<UUID> = []
        let ordered = (savedOrder + custom.map(\.id).sorted { $0.uuidString < $1.uuidString }).compactMap { id -> CustomPromptRule? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        var result = PromptRulesState(custom: ordered)
        for template in PromptRuleTemplate.allCases {
            if try items["template." + template.rawValue]?.value(Bool.self) == true { result.templates.insert(template) }
        }
        // Resolve exclusive/dependent templates consistently after a concurrent edit.
        if result.templates.contains(.americanEnglish) { result.templates.remove(.britishEnglish) }
        if !result.templates.contains(.expandAbbreviations) { result.templates.remove(.keepAbbreviations) }
        return result
    }

    mutating func trimHistory(at date: Date, limit: Int = 500) throws {
        let history = try values("history", as: HistoryEntry.self).sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
        for entry in history.dropFirst(limit) { delete("history." + entry.id.uuidString, at: date) }
    }
}

@MainActor protocol CloudSyncTransport: AnyObject {
    func accountIdentifier() async throws -> String
    func fetch() async throws -> [CloudSyncItem]
    func save(_ items: [CloudSyncItem]) async throws
}
