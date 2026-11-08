import Foundation
import Testing
@testable import Forma

@MainActor struct LocalizationTests {
    @Test func firstLaunchUsesTheFirstSupportedSystemLanguageIncludingRegionalVariants() throws {
        try withDefaults { defaults in
            for (preferred, expected) in [
                (["fr-FR", "ru-RU", "en-US"], "Русский"),
                (["ka-GE", "en-GB", "ru-RU"], "English"),
                (["ru-Cyrl-RU", "en-US"], "Русский"),
                (["en-AU", "ru"], "English")
            ] {
                let strings = UIStrings(defaults: defaults, preferredLanguages: { preferred })
                #expect(strings.language == UIStrings.systemLanguage)
                #expect(strings.effectiveLanguage == expected)
            }
            #expect(defaults.string(forKey: "prototype.language") == nil)
        }
    }

    @Test func unsupportedOrMissingSystemLanguagesFallBackToEnglish() throws {
        try withDefaults { defaults in
            for preferred in [[], ["ka-GE", "fr-FR", "de-DE"]] {
                let strings = UIStrings(defaults: defaults, preferredLanguages: { preferred })
                #expect(strings.effectiveLanguage == "English")
            }
        }
    }

    @Test func existingManualChoicesSurviveRelaunchAndSystemChanges() throws {
        try withDefaults { defaults in
            for manual in ["Русский", "English"] {
                defaults.set(manual, forKey: "prototype.language")
                var preferred = ["en-US"]
                let strings = UIStrings(defaults: defaults, preferredLanguages: { preferred })
                preferred = ["ru-RU"]
                strings.refreshSystemLanguage()
                #expect(strings.language == manual)
                #expect(strings.effectiveLanguage == manual)
                #expect(defaults.string(forKey: "prototype.language") == manual)
            }
        }
    }

    @Test func switchingBackToSystemPersistsAndTracksChangesWithoutSavingAResolvedLanguage() throws {
        try withDefaults { defaults in
            defaults.set("Русский", forKey: "prototype.language")
            var preferred = ["en-GB"]
            let strings = UIStrings(defaults: defaults, preferredLanguages: { preferred })
            strings.language = UIStrings.systemLanguage
            #expect(strings.effectiveLanguage == "English")
            preferred = ["ru-RU"]
            strings.refreshSystemLanguage()
            #expect(strings.effectiveLanguage == "Русский")
            #expect(defaults.string(forKey: "prototype.language") == UIStrings.systemLanguage)
            let relaunched = UIStrings(defaults: defaults, preferredLanguages: { ["en-US"] })
            #expect(relaunched.language == UIStrings.systemLanguage)
            #expect(relaunched.effectiveLanguage == "English")
        }
    }

    @Test func resolvedLanguageControlsBothInterfaceStringsAndLanguageNames() throws {
        try withDefaults { defaults in
            let strings = UIStrings(defaults: defaults, preferredLanguages: { ["en-US"] })
            #expect(strings.translate("Как в системе") == "System default")
            #expect(strings.translate("Язык интерфейса") == "Interface language")
            #expect(LanguageCatalog.displayName("nl", english: strings.isEnglish) == "Dutch")
            strings.language = "Русский"
            #expect(strings.translate("Как в системе") == "Как в системе")
            #expect(LanguageCatalog.displayName("nl", english: strings.isEnglish) == "Нидерландский")
        }
    }

    @Test func invalidStoredChoiceUsesSystemPreferences() throws {
        try withDefaults { defaults in
            defaults.set("unsupported", forKey: "prototype.language")
            let strings = UIStrings(defaults: defaults, preferredLanguages: { ["ru-RU"] })
            #expect(strings.language == UIStrings.systemLanguage)
            #expect(strings.effectiveLanguage == "Русский")
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) throws {
        let name = "FormaTests.Localization." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}
