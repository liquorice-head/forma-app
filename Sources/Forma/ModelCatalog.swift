import Foundation
import Observation

enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case fast, modelDefault, none, minimal, low, medium, high, xhigh, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: "Быстро"
        case .modelDefault: "Как у модели"
        case .none: "Без обдумывания"
        case .minimal: "Минимальное"
        case .low: "Низкое"
        case .medium: "Среднее"
        case .high: "Высокое"
        case .xhigh: "Очень высокое"
        case .max: "Максимальное"
        }
    }
    static let explicitLevels: [Self] = [.none, .minimal, .low, .medium, .high, .xhigh, .max]
}

struct ModelChoice: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let supportedEfforts: [ReasoningEffort]

    init(id: String, name: String, supportedEfforts: [ReasoningEffort]? = nil) {
        self.id = id; self.name = name
        self.supportedEfforts = supportedEfforts ?? Self.documentedEfforts(for: id)
    }

    var reasoningChoices: [ReasoningEffort] {
        supportedEfforts.isEmpty ? [.modelDefault] : [.fast, .modelDefault] + supportedEfforts
    }

    func effort(for setting: ReasoningEffort) -> ReasoningEffort? {
        if setting == .modelDefault { return nil }
        if setting == .fast { return supportedEfforts.first }
        return supportedEfforts.contains(setting) ? setting : supportedEfforts.first
    }

    static func parseCatalog(_ data: Data) throws -> [Self] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let catalog = object?["models"] as? [[String: Any]] ?? []
        return catalog.compactMap { item in
            guard item["visibility"] as? String == "list", let slug = item["slug"] as? String else { return nil }
            // Prefer account-specific capability metadata when supplied. An explicit empty
            // list is authoritative; unknown levels must never become request parameters.
            let metadata = item["supported_reasoning_efforts"] ?? item["supported_reasoning_levels"]
            let levels = (metadata as? [Any])?.compactMap { value -> ReasoningEffort? in
                let raw = value as? String ?? (value as? [String: Any])?["effort"] as? String
                return raw.flatMap(ReasoningEffort.init(rawValue:))
            }
            let supported = metadata == nil ? nil : ReasoningEffort.explicitLevels.filter { levels?.contains($0) == true }
            return Self(id: slug, name: item["display_name"] as? String ?? slug, supportedEfforts: supported)
        }
    }

    private static func documentedEfforts(for id: String) -> [ReasoningEffort] {
        // Deliberately narrow fallback for catalogs containing only slug/display_name.
        // Match exact model IDs and dated snapshots, never arbitrary future variants.
        func matches(_ base: String) -> Bool {
            id == base || (id.hasPrefix(base + "-") && id.dropFirst(base.count + 1).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
        }
        if ["gpt-6-astra", "gpt-6.1-sol"].contains(where: matches) {
            return [.low, .medium, .high, .xhigh, .max]
        }
        if ["gpt-6-sol", "gpt-6-luna"].contains(where: matches) {
            return [.none, .low, .medium, .high, .xhigh, .max]
        }
        if ["gpt-5", "gpt-5-mini", "gpt-5-nano"].contains(where: matches) {
            return [.minimal, .low, .medium, .high]
        }
        if matches("gpt-5.1") { return [.none, .low, .medium, .high] }
        if ["gpt-5.4", "gpt-5.5"].contains(where: matches) { return [.none, .low, .medium, .high, .xhigh] }
        if matches("gpt-5.6-terra") { return [.none, .low, .medium, .high, .xhigh, .max] }
        return []
    }
}

/// A recent account-specific catalog removes discovery from the first translation's
/// critical path. Refreshes are shared, and a late response cannot cross accounts.
@MainActor @Observable final class ModelCatalog {
    private(set) var choices: [ModelChoice] = []
    private var scope: String?
    private var generation = UUID()
    private var loading: Task<[ModelChoice], Error>?
    private let defaults: UserDefaults
    private let now: () -> Date
    private struct Snapshot: Codable { let savedAt: Date; let choices: [ModelChoice] }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
    }

    func activate(scope: String?) {
        loading?.cancel(); loading = nil; generation = UUID()
        self.scope = scope; choices = []
        guard let scope, let data = defaults.data(forKey: "modelCatalog.v1." + scope),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
              (0..<86400).contains(now().timeIntervalSince(saved.savedAt)) else { return }
        choices = saved.choices
    }

    func refresh(load: @escaping @MainActor () async throws -> [ModelChoice]) async throws {
        guard let scope else { throw CancellationError() }
        let generation = generation
        let task: Task<[ModelChoice], Error>
        if let loading { task = loading }
        else {
            task = Task { try await load() }
            loading = task
        }
        defer { if self.generation == generation { loading = nil } }
        let fetched = try await task.value
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        choices = fetched
        if let data = try? JSONEncoder().encode(Snapshot(savedAt: now(), choices: fetched)) {
            defaults.set(data, forKey: "modelCatalog.v1." + scope)
        }
    }
}
