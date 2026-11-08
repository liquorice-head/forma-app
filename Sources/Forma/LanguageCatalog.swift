import Foundation
import NaturalLanguage
import Translation

struct LanguageOption: Identifiable, Equatable {
    let code: String
    let value: String
    let russian: String
    let english: String
    let native: String
    var id: String { code }

    func name(englishInterface: Bool) -> String { englishInterface ? english : russian }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [russian, english, native, code, value].contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru"))
                .contains(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru")))
        }
    }
}

struct TranslationLanguagePair: Equatable {
    let source: String
    let target: String

    init?(source: String, target: String) {
        let sourceCode = LanguageCatalog.canonical(LanguageCatalog.code(source))
        let targetCode = LanguageCatalog.canonical(LanguageCatalog.code(target))
        guard sourceCode != targetCode,
              LanguageCatalog.all.contains(where: { LanguageCatalog.canonical($0.code) == sourceCode }),
              LanguageCatalog.all.contains(where: { LanguageCatalog.canonical($0.code) == targetCode }) else { return nil }
        self.source = LanguageCatalog.label(sourceCode)
        self.target = LanguageCatalog.label(targetCode)
    }

    static func sameLanguage(_ first: String, _ second: String) -> Bool {
        LanguageCatalog.canonical(LanguageCatalog.code(first)) == LanguageCatalog.canonical(LanguageCatalog.code(second))
    }

    static func suggestedTarget(source: String?, currentTarget: String, previous: Self?) -> String {
        guard let source, sameLanguage(source, currentTarget) else { return currentTarget }
        // Reverse the last successful pair. Before the first translation, use RU ↔ EN.
        let candidates = [previous?.source, previous?.target, "Русский", "English"].compactMap { $0 }
        return candidates.first { !sameLanguage($0, source) } ?? currentTarget
    }
}

enum LanguageCatalog {
    // Keep the original stored labels: history and dictionary entries use them as pair identifiers.
    static let common = ["Русский", "English", "Deutsch", "Français", "Español", "Italiano", "Português", "日本語", "한국어", "中文", "ქართული", "العربية"]
    static let codes = ["Русский": "ru", "English": "en", "Deutsch": "de", "Français": "fr", "Español": "es", "Italiano": "it", "Português": "pt", "日本語": "ja", "한국어": "ko", "中文": "zh-Hans", "ქართული": "ka", "العربية": "ar"]
    private static let ru = Locale(identifier: "ru")
    private static let en = Locale(identifier: "en")

    static func canonical(_ code: String) -> String { Locale.Language(identifier: code).minimalIdentifier }

    static func option(_ code: String) -> LanguageOption {
        let legacy = common.first { canonical(codes[$0]!) == canonical(code) }
        let identifier = legacy.flatMap { codes[$0] } ?? code
        return LanguageOption(code: identifier, value: legacy ?? identifier,
            russian: ru.localizedString(forIdentifier: identifier) ?? identifier,
            english: en.localizedString(forIdentifier: identifier) ?? identifier,
            native: Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier)
    }

    // ChatGPT publishes no exhaustive language capability list. Offer the system's
    // language catalog and explain in the picker that quality depends on the model.
    static let all: [LanguageOption] = {
        var seen = Set<String>()
        return (common.compactMap { codes[$0] } + ["zh-Hant"] + Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
            .map(option).filter { seen.insert(canonical($0.code)).inserted }
            .filter { $0.english != $0.code }
    }()

    static func code(_ label: String) -> String {
        codes[label] ?? all.first { $0.value == label || $0.english.caseInsensitiveCompare(label) == .orderedSame || $0.russian.caseInsensitiveCompare(label) == .orderedSame || $0.native.caseInsensitiveCompare(label) == .orderedSame }?.code ?? label
    }

    static func label(_ code: String) -> String { option(code).value }

    static func displayName(_ value: String, english: Bool) -> String {
        if value == "Автоопределение" { return english ? "Detect language" : value }
        return option(code(value)).name(englishInterface: english).localizedCapitalized
    }

    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    static func sorted(_ options: [LanguageOption], query: String, english: Bool) -> [LanguageOption] {
        options.filter { $0.matches(query) }.sorted {
            let first = common.firstIndex(of: $0.value) ?? common.count
            let second = common.firstIndex(of: $1.value) ?? common.count
            if first != second { return first < second }
            return $0.name(englishInterface: english).localizedStandardCompare($1.name(englishInterface: english)) == .orderedAscending
        }
    }

    @MainActor static func appleLanguages(otherLanguage: String?, selectingSource: Bool) async throws -> [LanguageOption] {
        try await AsyncDeadline.value(after: .seconds(10)) {
            let availability = LanguageAvailability()
            let languages = await availability.supportedLanguages
            let otherSupported = otherLanguage.map { other in
                languages.contains { canonical($0.minimalIdentifier) == canonical(code(other)) }
            } ?? false
            var options: [LanguageOption] = []
            for language in languages {
                try Task.checkCancellation()
                if let otherLanguage, otherSupported {
                    let other = Locale.Language(identifier: code(otherLanguage))
                    if canonical(language.minimalIdentifier) != canonical(other.minimalIdentifier) {
                        let status = await availability.status(from: selectingSource ? language : other,
                                                              to: selectingSource ? other : language)
                        if status == .unsupported { continue }
                    }
                }
                options.append(option(language.minimalIdentifier))
            }
            return options
        }
    }
}
