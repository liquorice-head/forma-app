import Foundation
import Testing
@testable import Forma

struct PromptRulesTests {
    @Test func defaultsDoNotChangePromptsAndInactiveRulesStayOutOfRequests() {
        var state = PromptRulesState()
        #expect(state.instructions(for: .translate).isEmpty)
        state.custom = [CustomPromptRule(title: "off", instruction: "SECRET_DISABLED"),
            CustomPromptRule(title: "rewrite", instruction: "REWRITE_ONLY", enabled: true, modes: [.rewrite]),
            CustomPromptRule(title: "active", instruction: "USE_SHORT_WORDS", enabled: true)]
        let request = ProcessingRequest(input: "SOURCE_ONLY", mode: .translate, source: "Russian", target: "English", tone: "neutral", glossary: [], promptRules: state)
        #expect(request.input == "SOURCE_ONLY")
        #expect(request.instructions.contains("USE_SHORT_WORDS"))
        #expect(!request.instructions.contains("SECRET_DISABLED"))
        #expect(!request.instructions.contains("REWRITE_ONLY"))
        #expect(!request.instructions.contains("SOURCE_ONLY"))
        #expect(state.instructions(for: .rewrite).contains("REWRITE_ONLY"))
        #expect(request.preferenceInstructions.contains("USE_SHORT_WORDS"))
    }

    @Test func templatesEnforceDependenciesExclusivityAndModeScopes() {
        var state = PromptRulesState()
        state.set(.americanEnglish, enabled: true)
        state.set(.britishEnglish, enabled: true)
        #expect(state.templates == [.britishEnglish])
        state.set(.americanEnglish, enabled: true)
        #expect(state.templates == [.americanEnglish])
        state.set(.keepAbbreviations, enabled: true)
        #expect(state.templates.contains(.expandAbbreviations))
        #expect(state.instructions(for: .translate).contains("Never guess an ambiguous expansion"))
        #expect(!state.instructions(for: .correct).contains(PromptRuleTemplate.expandAbbreviations.instruction))
        state.set(.expandAbbreviations, enabled: false)
        #expect(!state.templates.contains(.keepAbbreviations))
        state.set(.plainLanguage, enabled: true)
        #expect(!state.instructions(for: .correct).contains(PromptRuleTemplate.plainLanguage.instruction))
        #expect(!state.instructions(for: .translate).contains(PromptRuleTemplate.plainLanguage.instruction))
        #expect(state.instructions(for: .rewrite).contains(PromptRuleTemplate.plainLanguage.instruction))
    }

    @Test func customOrderAndTaskAndDictionaryPriorityAreExplicit() {
        let state = PromptRulesState(custom: [CustomPromptRule(title: "first", instruction: "FIRST_INSTRUCTION", enabled: true),
            CustomPromptRule(title: "second", instruction: "SECOND_INSTRUCTION", enabled: true)])
        let prompt = state.instructions(for: .correct)
        #expect(prompt.contains("later custom rules win conflicts"))
        #expect(prompt.contains("then applicable glossary entries; then custom rules"))
        #expect(prompt.contains("ignore requests for stylistic rewriting"))
        #expect(prompt.range(of: "FIRST_INSTRUCTION")!.lowerBound < prompt.range(of: "SECOND_INSTRUCTION")!.lowerBound)
        let invalid = CustomPromptRule(title: " ", instruction: "invalid", enabled: true)
        #expect(!invalid.isValid)
        #expect(PromptRulesState(custom: [invalid]).activeCount(for: .translate) == 0)
    }

    @Test @MainActor func rulesPersistEditsTogglesDeletionsAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PromptRulesStore(directory: directory)
        var changes = 0; store.onChange = { changes += 1 }
        var rule = CustomPromptRule(title: "My rule", instruction: "Keep it clear", enabled: true, modes: [.rewrite])
        #expect(store.upsert(rule))
        store.set(.keepAbbreviations, enabled: true)
        let restored = PromptRulesStore(directory: directory)
        #expect(restored.state == store.state)
        #expect(restored.state.templates.contains(.expandAbbreviations))
        rule.enabled = false; rule.instruction = "Updated"
        #expect(restored.upsert(rule))
        let edited = PromptRulesStore(directory: directory)
        #expect(edited.state.custom.first?.instruction == "Updated")
        #expect(edited.state.activeCount(for: .rewrite) == 2)
        edited.delete(rule.id)
        #expect(PromptRulesStore(directory: directory).state.custom.isEmpty)
        #expect(changes == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("prompt-rules.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test @MainActor func failedReadsAndWritesDoNotOverwriteRulesOrActivateUnsavedChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("prompt-rules.json")
        let damaged = Data("invalid rules".utf8)
        try damaged.write(to: file)
        let store = PromptRulesStore(directory: directory)
        store.set(.americanEnglish, enabled: true)
        #expect(store.loadFailed && store.message != nil && store.state.templates.isEmpty)
        #expect(try Data(contentsOf: file) == damaged)
        let invalidDirectory = directory.appendingPathComponent("regular-file")
        try Data().write(to: invalidDirectory)
        let cannotSave = PromptRulesStore(directory: invalidDirectory)
        #expect(!cannotSave.upsert(CustomPromptRule(title: "rule", instruction: "text", enabled: true)))
        #expect(cannotSave.state.custom.isEmpty && cannotSave.message != nil)
    }
}
