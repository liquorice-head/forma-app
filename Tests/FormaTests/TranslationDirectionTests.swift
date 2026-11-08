import Testing
@testable import Forma

struct TranslationDirectionTests {
    @Test func incomingTextReversesTheLastPairInBothDirections() throws {
        let pair = try #require(TranslationLanguagePair(source: "Русский", target: "English"))
        let english = LanguageCatalog.detect("Good morning. Let us meet tomorrow and discuss the project.").map(LanguageCatalog.label)
        let russian = LanguageCatalog.detect("Доброе утро. Давайте встретимся завтра и обсудим наш проект.").map(LanguageCatalog.label)
        #expect(english == "English")
        #expect(russian == "Русский")
        #expect(TranslationLanguagePair.suggestedTarget(source: english, currentTarget: "English", previous: pair) == "Русский")
        let reversed = try #require(TranslationLanguagePair(source: "English", target: "Русский"))
        #expect(TranslationLanguagePair.suggestedTarget(source: russian, currentTarget: "Русский", previous: reversed) == "English")
    }

    @Test func rememberedPairIsUsedInsteadOfAHardcodedRussianEnglishPair() throws {
        let pair = try #require(TranslationLanguagePair(source: "Deutsch", target: "English"))
        #expect(TranslationLanguagePair.suggestedTarget(source: "English", currentTarget: "English", previous: pair) == "Deutsch")
        let reversed = try #require(TranslationLanguagePair(source: "English", target: "Deutsch"))
        #expect(TranslationLanguagePair.suggestedTarget(source: "Deutsch", currentTarget: "Deutsch", previous: reversed) == "English")
    }

    @Test func anAlreadyDifferentTargetAndUnknownInputAreKept() throws {
        let pair = try #require(TranslationLanguagePair(source: "Русский", target: "English"))
        #expect(TranslationLanguagePair.suggestedTarget(source: "English", currentTarget: "Français", previous: pair) == "Français")
        #expect(TranslationLanguagePair.suggestedTarget(source: "ქართული", currentTarget: "English", previous: pair) == "English")
        #expect(TranslationLanguagePair.suggestedTarget(source: nil, currentTarget: "English", previous: pair) == "English")
    }

    @Test func firstRunHasADifferentTargetInBothPrimaryLanguages() {
        #expect(TranslationLanguagePair.suggestedTarget(source: "English", currentTarget: "English", previous: nil) == "Русский")
        #expect(TranslationLanguagePair.suggestedTarget(source: "Русский", currentTarget: "Русский", previous: nil) == "English")
    }

    @Test func languageAliasesDoNotProduceASameLanguagePair() throws {
        #expect(TranslationLanguagePair(source: "en", target: "English") == nil)
        #expect(TranslationLanguagePair(source: "auto-detect", target: "English") == nil)
        #expect(TranslationLanguagePair(source: "", target: "English") == nil)
        let pair = try #require(TranslationLanguagePair(source: "Dutch", target: "English"))
        #expect(pair.source == "nl")
        #expect(TranslationLanguagePair.suggestedTarget(source: "en", currentTarget: "English", previous: pair) == "nl")
    }

    @Test func chineseScriptsRemainDistinctTranslationTargets() throws {
        let pair = try #require(TranslationLanguagePair(source: "zh-Hans", target: "zh-Hant"))
        #expect(TranslationLanguagePair.suggestedTarget(source: "zh-Hans", currentTarget: "zh-Hant", previous: pair) == "zh-Hant")
        #expect(TranslationLanguagePair.suggestedTarget(source: "zh-Hant", currentTarget: "zh-Hant", previous: pair) == "中文")
    }
}
