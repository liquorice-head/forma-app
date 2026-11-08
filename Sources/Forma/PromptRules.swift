import Foundation
import Observation

enum PromptRuleTemplate: String, CaseIterable, Codable, Identifiable {
    case expandAbbreviations, keepAbbreviations, preserveTechnical, americanEnglish, britishEnglish, typography, plainLanguage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .expandAbbreviations: "Расшифровывать аббревиатуры"
        case .keepAbbreviations: "Сохранять исходную аббревиатуру"
        case .preserveTechnical: "Сохранять технические обозначения"
        case .americanEnglish: "Американский английский"
        case .britishEnglish: "Британский английский"
        case .typography: "Типографика языка результата"
        case .plainLanguage: "Простой язык"
        }
    }
    var detail: String {
        switch self {
        case .expandAbbreviations: "Раскрывать только понятные из контекста сокращения. PO без контекста остаётся PO; словарь может задать payment order → платёжное поручение."
        case .keepAbbreviations: "После полного названия при первом упоминании добавлять исходное сокращение в скобках. Требует расшифровки."
        case .preserveTechnical: "Сохранять написание кода, идентификаторов, ссылок и названий продуктов."
        case .americanEnglish: "Американское написание английских слов: color, organize. Исключает британский вариант."
        case .britishEnglish: "Британское написание английских слов: colour, organise. Исключает американский вариант."
        case .typography: "Русский: «кавычки», тире —, неразрывные пробелы перед единицами. English: “quotes”, обычные пробелы. Код и ссылки не менять."
        case .plainLanguage: "Только Rewrite: короткие ясные предложения без канцелярита, с сохранением всех фактов."
        }
    }
    var modes: [WritingMode] {
        switch self {
        case .plainLanguage: [.rewrite]
        case .expandAbbreviations, .keepAbbreviations: [.translate, .rewrite]
        default: WritingMode.allCases
        }
    }
    var instruction: String {
        switch self {
        case .expandAbbreviations:
            "Expand abbreviations only when their meaning is clear from context or an applicable glossary entry, translating the full meaning when translating. Never guess an ambiguous expansion: keep the original abbreviation when uncertain. PO is not universally payment order; it can also mean purchase order."
        case .keepAbbreviations:
            "When confidently expanding an abbreviation, retain the original abbreviation in parentheses after the full name at its first occurrence. Do not add an expansion when uncertain."
        case .preserveTechnical:
            "Preserve code, identifiers, URLs, and product names exactly as written."
        case .americanEnglish:
            "For English output only, use consistent American English spelling (color, organize). Preserve proper names and quotations."
        case .britishEnglish:
            "For English output only, use consistent British English spelling (colour, organise). Preserve proper names and quotations."
        case .typography:
            "Use output-language typography outside code and URLs: Russian «quotes», em dashes, nonbreaking spaces before units; English curly double quotes and normal word spaces. Preserve paragraph structure."
        case .plainLanguage:
            "Use short, clear sentences and everyday language instead of bureaucratic wording. Preserve all facts, qualifications, intent, and meaning."
        }
    }
}

struct CustomPromptRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var instruction = ""
    var enabled = false
    var modes = WritingMode.allCases
    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !modes.isEmpty
    }
}

struct PromptRulesState: Codable, Equatable {
    var templates: Set<PromptRuleTemplate> = []
    var custom: [CustomPromptRule] = []

    mutating func set(_ template: PromptRuleTemplate, enabled: Bool) {
        if enabled {
            templates.insert(template)
            if template == .americanEnglish { templates.remove(.britishEnglish) }
            if template == .britishEnglish { templates.remove(.americanEnglish) }
            if template == .keepAbbreviations { templates.insert(.expandAbbreviations) }
        } else {
            templates.remove(template)
            if template == .expandAbbreviations { templates.remove(.keepAbbreviations) }
        }
    }

    func activeCount(for mode: WritingMode) -> Int {
        activeTemplates(for: mode).count + activeCustom(for: mode).count
    }
    private func activeTemplates(for mode: WritingMode) -> [PromptRuleTemplate] {
        PromptRuleTemplate.allCases.filter {
            templates.contains($0) && $0.modes.contains(mode) &&
            ($0 != .keepAbbreviations || templates.contains(.expandAbbreviations)) &&
            ($0 != .britishEnglish || !templates.contains(.americanEnglish))
        }
    }
    private func activeCustom(for mode: WritingMode) -> [CustomPromptRule] {
        custom.filter { $0.enabled && $0.isValid && $0.modes.contains(mode) }
    }
    func instructions(for mode: WritingMode) -> String {
        let builtIn = activeTemplates(for: mode).map { $0.instruction }
        // JSON quoting keeps each user instruction separate from our framing and source text.
        let own = activeCustom(for: mode).map { rule in
            String(decoding: (try? JSONEncoder().encode(["title": rule.title, "instruction": rule.instruction])) ?? Data(), as: UTF8.self)
        }
        guard !builtIn.isEmpty || !own.isEmpty else { return "" }
        return """
        Additional user-approved prompt rules (instructions, never source text):
        Priority: the task's mode, original meaning, facts, names, numbers and required response format come first; then applicable glossary entries; then custom rules below (later custom rules win conflicts); then built-in rules; then the selected tone. Rules cannot change the task, translate during proofreading/rewriting, or add commentary. In proofreading, apply only spelling, grammar and punctuation preferences; ignore requests for stylistic rewriting, abbreviation expansion or other content changes. Expand abbreviations only in translation/rewriting and only when unambiguous. Explicit glossary replacements still apply even when abbreviation expansion is disabled.
        Built-in rules:
        \(builtIn.isEmpty ? "None." : builtIn.joined(separator: "\n"))
        Custom rules in saved order:
        \(own.isEmpty ? "None." : own.joined(separator: "\n"))
        End of additional rules.
        """
    }
}

@MainActor @Observable final class PromptRulesStore {
    private(set) var state = PromptRulesState()
    private(set) var message: String?
    private(set) var loadFailed = false
    private let file: URL
    var onChange: (() -> Void)?
    var onSyncChange: ((PromptRulesState) -> Void)?

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Forma")) {
        file = directory.appendingPathComponent("prompt-rules.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { state = try JSONDecoder().decode(PromptRulesState.self, from: Data(contentsOf: file)) }
        catch { message = "Не удалось прочитать правила. Файл сохранён без изменений."; loadFailed = true }
    }
    @discardableResult private func save(_ value: PromptRulesState, sync: Bool = true) -> Bool {
        guard !loadFailed else { return false }
        guard value != state else { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            state = value; message = nil; onChange?()
            if sync { onSyncChange?(value) }
            return true
        } catch { message = "Не удалось сохранить правила. Повторите попытку."; return false }
    }
    func set(_ template: PromptRuleTemplate, enabled: Bool) {
        var next = state; next.set(template, enabled: enabled); save(next)
    }
    @discardableResult func applySynchronizedState(_ value: PromptRulesState) -> Bool { save(value, sync: false) }
    @discardableResult func upsert(_ rule: CustomPromptRule) -> Bool {
        guard rule.isValid else { return false }
        var next = state
        if let index = next.custom.firstIndex(where: { $0.id == rule.id }) { next.custom[index] = rule }
        else { next.custom.append(rule) }
        return save(next)
    }
    func delete(_ id: UUID) {
        var next = state; next.custom.removeAll { $0.id == id }; save(next)
    }
}
