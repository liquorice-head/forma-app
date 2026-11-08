import AppKit
import Observation
import SwiftUI
import Translation
import CryptoKit

struct TextSelection: Identifiable {
    let id = UUID()
    let text: String
    let range: NSRange
    var anchor: CGRect = .zero
}

struct PreferenceChange {
    let before: MemoryEntry?
    let after: MemoryEntry
    func undo(in entries: [MemoryEntry]) -> [MemoryEntry] {
        guard let current = entries.first(where: { $0.id == after.id }),
              current.source == after.source, current.preferred == after.preferred,
              current.languages == after.languages, current.context == after.context else { return entries }
        var result = entries.filter { $0.id != after.id }
        if let before { result.insert(before, at: 0) }
        return result
    }
}

@MainActor @Observable final class PrototypeModel {
    static let sample = "Привет, Анна! Давай созвонимся на следующей неделе и обсудим запуск. Я собрал обратную связь от команды — думаю, мы можем сделать процесс немного проще."
    let account = ChatGPTAccount()
    let updates = AppUpdater()
    let loginItems = LoginItemSettings()
    let store = LibraryStore()
    let promptRules = PromptRulesStore()
    var quickCapture: QuickCaptureController?
    var mode: WritingMode = .translate
    var tone = "Нейтральный"
    var sourceLanguage = "Автоопределение"
    var targetLanguage = UserDefaults.standard.string(forKey: "targetLanguage") ?? "English" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage") }
    }
    private var lastTranslationPair: TranslationLanguagePair? {
        didSet {
            if let pair = lastTranslationPair {
                UserDefaults.standard.set(["source": pair.source, "target": pair.target], forKey: "translation.lastPair")
            }
        }
    }
    var input = "" { didSet { if oldValue != input { cancelProcessing(); output = ""; capture = nil; resultEngine = nil; notice = nil; processingMetrics = nil } } }
    var output = ""
    var selection: TextSelection?
    var memory: [MemoryEntry] = [] { didSet { store.updateMemory(memory); if oldValue != memory { textService.clearCache() } } }
    var history: [HistoryEntry] = [] { didSet { store.updateHistory(history) } }
    var notice: String?
    var pinned = UserDefaults.standard.object(forKey: "popup.pinned") as? Bool ?? true { didSet { UserDefaults.standard.set(pinned, forKey: "popup.pinned") } }
    var automaticallyRun = UserDefaults.standard.object(forKey: "popup.autoRun") as? Bool ?? true { didSet { UserDefaults.standard.set(automaticallyRun, forKey: "popup.autoRun") } }
    var showMenuBarIcon = UserDefaults.standard.object(forKey: "menuBar.visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "menuBar.visible") }
    }
    var shortcut = UserDefaults.standard.string(forKey: "shortcut.label") ?? "⌘C  ⌘C" { didSet { UserDefaults.standard.set(shortcut, forKey: "shortcut.label") } }
    var shortcutKeyCode: UInt16? = (UserDefaults.standard.object(forKey: "shortcut.keyCode") as? Int).flatMap { UInt16(exactly: $0) } { didSet { UserDefaults.standard.set(shortcutKeyCode.map { Int($0) }, forKey: "shortcut.keyCode") } }
    var shortcutModifiers: UInt = UInt(UserDefaults.standard.integer(forKey: "shortcut.modifiers")) { didSet { UserDefaults.standard.set(Int(shortcutModifiers), forKey: "shortcut.modifiers") } }
    var recordingShortcut = false
    var engine = TextEngine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .chatGPT { didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine"); cancelProcessing(); output = ""; resultEngine = nil; notice = nil } }
    var allowOfflineFallback = UserDefaults.standard.object(forKey: "offlineFallback") as? Bool ?? true { didSet { UserDefaults.standard.set(allowOfflineFallback, forKey: "offlineFallback") } }
    private let modelCatalog = ModelCatalog()
    var modelChoices: [ModelChoice] { modelCatalog.choices }
    var selectedModel = UserDefaults.standard.string(forKey: "model") ?? "" { didSet { UserDefaults.standard.set(selectedModel, forKey: "model") } }
    var reasoningSetting = ReasoningEffort(rawValue: UserDefaults.standard.string(forKey: "reasoning.effort") ?? "") ?? .fast {
        didSet { UserDefaults.standard.set(reasoningSetting.rawValue, forKey: "reasoning.effort"); if oldValue != reasoningSetting { cancelProcessing() } }
    }
    var cacheResults = UserDefaults.standard.object(forKey: "processing.cache") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cacheResults, forKey: "processing.cache"); textService.clearCache() }
    }
    var showProcessingTimes = UserDefaults.standard.bool(forKey: "processing.showTimes") {
        didSet { UserDefaults.standard.set(showProcessingTimes, forKey: "processing.showTimes") }
    }
    var processingMetrics: ProcessingMetrics?
    var currentModel: ModelChoice? { modelChoices.first { $0.id == selectedModel } }
    var reasoningChoices: [ReasoningEffort] { currentModel?.reasoningChoices ?? [.modelDefault] }
    var effectiveReasoningSetting: ReasoningEffort {
        reasoningChoices.contains(reasoningSetting) ? reasoningSetting : (reasoningChoices.contains(.fast) ? .fast : .modelDefault)
    }
    var isProcessing = false
    var isReplacing = false
    var resultEngine: TextEngine?
    var alternatives: [WordAlternative] = []
    var alternativesLoading = false
    var alternativesMessage: String?
    var lastOutput: String?
    private var preferenceChange: PreferenceChange?
    var showSettings = false
    var choosingLanguage = false
    var openSettings: (() -> Void)?
    var showAccessibilitySetup = false
    var relaunching = false
    var relaunchError: String?
    private(set) var didRelaunchForAccessibility = false
    private var offeredAccessibilityRepair = false
    var showPrototypeInfo = false
    var screen: String? = "editor"
    var capture: CapturedText?
    var appleConfiguration: TranslationSession.Configuration?
    var appleContext = false
    private var appleRequest: AppleTranslationRequest?
    private var lastAppleConfiguration: TranslationSession.Configuration?
    private var appleSession: TranslationSession?
    private var operationID = UUID()
    private var processingTask: Task<Void, Never>?
    private let automaticProcessing = DebouncedAction()
    private var needsAutomaticTarget = false
    private var alternativesTask: Task<Void, Never>?
    @ObservationIgnored private lazy var textService = OpenAITextService(account: account)
    let tones = ["Нейтральный", "Дружеский", "Деловой", "Формальный"]

    init() {
        promptRules.onChange = { [weak self] in self?.cancelProcessing(); self?.textService.clearCache() }
        store.attach(rules: promptRules)
        memory = store.snapshot.memory.filter { !$0.deleted }.sorted { $0.modifiedAt > $1.modifiedAt }
        history = store.snapshot.history
        if let saved = UserDefaults.standard.dictionary(forKey: "translation.lastPair"),
           let source = saved["source"] as? String, let target = saved["target"] as? String {
            lastTranslationPair = TranslationLanguagePair(source: source, target: target)
        }
        if lastTranslationPair == nil {
            lastTranslationPair = history.sorted { $0.date > $1.date }.lazy.compactMap { entry in
                guard entry.mode == .translate, let source = entry.sourceLanguage, let target = entry.targetLanguage else { return nil as TranslationLanguagePair? }
                return TranslationLanguagePair(source: source, target: target)
            }.first
        }
        notice = store.message
        store.onMemoryUpdate = { [weak self] in self?.memory = $0 }
        store.onHistoryUpdate = { [weak self] in self?.history = $0 }
        do {
            if let draft = try RelaunchStore.take() {
                mode = draft.mode; tone = draft.tone
                sourceLanguage = draft.sourceLanguage; targetLanguage = draft.targetLanguage
                input = draft.input; output = draft.output; resultEngine = draft.resultEngine
                screen = draft.screen
                didRelaunchForAccessibility = draft.accessibilityRestart == true
            }
        } catch { notice = "Не удалось восстановить текст после перезапуска." }
        updates.onAccessRequired = { [weak self] in self?.showSettings = true }
        updates.beforeInstall = { [weak self] in
            guard let self else { return }
            guard !account.busy else { throw AppFailure(message: "Завершите вход перед обновлением.") }
            try RelaunchStore.save(RelaunchDraft(mode: mode, tone: tone, sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, input: input, output: isProcessing ? "" : output,
                resultEngine: isProcessing ? nil : resultEngine, screen: screen))
            cancelProcessing()
            showAccessibilitySetup = false; showSettings = false
            for window in NSApp.windows {
                if let sheet = window.attachedSheet {
                    sheet.preventsApplicationTerminationWhenModal = false
                    window.endSheet(sheet)
                }
            }
        }
    }
    func saveAndRelaunch() {
        guard !relaunching else { return }
        relaunchError = nil
        do {
            try RelaunchStore.save(RelaunchDraft(mode: mode, tone: tone, sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, input: input, output: isProcessing ? "" : output,
                resultEngine: isProcessing ? nil : resultEngine, screen: screen,
                accessibilityRestart: quickCapture?.accessibility.requested == true || quickCapture?.accessibility.requiresRestart == true))
        } catch {
            relaunchError = "Не удалось сохранить текст. Приложение не будет закрыто."
            return
        }
        cancelProcessing()
        relaunching = true
        // A modal settings/setup sheet otherwise vetoes NSApplication.terminate.
        showAccessibilitySetup = false
        showSettings = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                sheet.preventsApplicationTerminationWhenModal = false
                window.endSheet(sheet)
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, _ in
            Task { @MainActor in
                guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    RelaunchStore.discard()
                    self?.relaunching = false
                    self?.relaunchError = "Не удалось перезапустить Forma. Закройте и откройте приложение вручную."
                    self?.showAccessibilitySetup = true
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
    func offerAccessibilitySetupIfNeeded() {
        guard let access = quickCapture?.accessibility, !showSettings else { return }
        if access.repairRequired && !offeredAccessibilityRepair {
            offeredAccessibilityRepair = true
            showAccessibilitySetup = true
            return
        }
        guard !access.granted,
              !UserDefaults.standard.bool(forKey: "accessibility.setupPresented") else { return }
        UserDefaults.standard.set(true, forKey: "accessibility.setupPresented")
        showAccessibilitySetup = true
    }
    func offerAccessibilityRestartIfNeeded() {
        guard NSApp.isActive, let access = quickCapture?.accessibility, access.consumeRestartPrompt() else { return }
        let alert = NSAlert()
        alert.messageText = tr("Перезапустить Forma?")
        alert.informativeText = tr(access.granted
            ? "Доступ к Accessibility разрешён. Сохраните текст и перезапустите Forma, чтобы включить глобальный шорткат."
            : "Если вы включили Forma в настройках, сохраните текст и перезапустите приложение, чтобы применить разрешение. macOS пока не подтвердила доступ этой копии Forma.")
        alert.addButton(withTitle: tr("Сохранить и перезапустить"))
        alert.addButton(withTitle: tr("Позже"))
        if alert.runModal() == .alertFirstButtonReturn { saveAndRelaunch() }
    }
    var detectedLanguage: String? { sourceLanguage == "Автоопределение" ? LanguageCatalog.detect(input).map(LanguageCatalog.label) : sourceLanguage }
    var providerLabel: String {
        if isProcessing { return "Обработка…" }
        switch resultEngine ?? engine {
        case .chatGPT: return account.connected ? "ChatGPT · ваш тариф" : "Подключите ChatGPT в настройках"
        case .apple: return "Apple · на устройстве"
        }
    }
    private func request() -> ProcessingRequest {
        let source = detectedLanguage ?? "auto-detect"
        let pair = source + " → " + targetLanguage
        let glossary = mode == .translate ? Array(memory.filter { $0.languages == pair && input.localizedCaseInsensitiveContains($0.source) }.prefix(20)) : []
        return ProcessingRequest(input: input, mode: mode, source: source, target: targetLanguage, tone: tone, glossary: glossary, promptRules: promptRules.state)
    }
    func setMode(_ value: WritingMode, compact: Bool = false) {
        cancelProcessing(); mode = value
        if !input.isEmpty { process(compact: compact) }
    }
    func changeModel(_ value: String) {
        guard selectedModel != value else { return }
        cancelProcessing(); selectedModel = value; processingMetrics = nil
    }
    func cancelProcessing() {
        automaticProcessing.cancel()
        let wasProcessing = isProcessing
        operationID = UUID()
        processingTask?.cancel(); processingTask = nil
        appleSession?.cancel(); appleSession = nil
        appleRequest = nil; appleConfiguration = nil
        isProcessing = false
        if wasProcessing { output = ""; resultEngine = nil }
        selection = nil
        alternativesTask?.cancel()
        lastOutput = nil; preferenceChange = nil
    }
    func process(compact: Bool = false, automaticallyChooseTarget: Bool? = nil) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelProcessing()
        if automaticallyChooseTarget ?? needsAutomaticTarget { chooseTargetForIncomingText() }
        if mode == .translate { needsAutomaticTarget = false }
        let id = UUID(); operationID = id
        let input = request()
        let engine = engine
        let reasoning = reasoningSetting
        let useCache = cacheResults
        let started = ContinuousClock.now
        var firstText: TimeInterval?
        processingMetrics = nil
        output = ""; notice = nil; resultEngine = nil; isProcessing = true
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                if engine == .apple { try await beginApple(input, compact: compact, id: id, allowDownloads: true); return }
                let model = try await resolveModel()
                try Task.checkCancellation()
                let result = try await textService.process(input, model: model, reasoning: reasoning, useCache: useCache) { [weak self] text in
                    guard self?.operationID == id else { return }
                    if firstText == nil, !text.isEmpty { firstText = ProcessingMetrics.seconds(ContinuousClock.now - started) }
                    self?.output = text
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                processingMetrics = ProcessingMetrics(firstText: firstText, total: ProcessingMetrics.seconds(ContinuousClock.now - started),
                    cacheHit: result.cacheHit, reasoningTokens: result.reasoningTokens)
                complete(result.text, request: input, engine: .chatGPT, id: id)
            } catch is CancellationError { }
            catch let error as URLError where allowOfflineFallback && input.mode == .translate && input.tone == "Нейтральный" && [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(error.code) {
                do {
                    try Task.checkCancellation()
                    notice = "Нет сети. Используем перевод Apple на этом Mac."
                    try await beginApple(input, compact: compact, id: id, allowDownloads: false)
                } catch { fail(error, id: id) }
            } catch { fail(error, id: id) }
        }
    }
    private func resolveModel() async throws -> ModelChoice {
        if modelChoices.isEmpty { try await refreshModels() }
        guard let model = modelChoices.first(where: { $0.id == selectedModel }) ?? modelChoices.first else {
            throw AppFailure(message: "Для этого подключения не найдено доступных моделей.")
        }
        selectedModel = model.id
        return model
    }
    func refreshModels() async throws {
        try await modelCatalog.refresh { [textService] in try await textService.models() }
        if !modelChoices.contains(where: { $0.id == selectedModel }) { selectedModel = modelChoices.first?.id ?? "" }
    }
    func accountDidChange() {
        cancelProcessing(); textService.clearCache(); processingMetrics = nil
        modelCatalog.activate(scope: account.inferenceScope)
        if !modelChoices.isEmpty, !modelChoices.contains(where: { $0.id == selectedModel }) { selectedModel = modelChoices.first?.id ?? "" }
        if account.connected {
            let scope = account.inferenceScope
            Task {
                guard account.inferenceScope == scope else { return }
                do { try await refreshModels() }
                catch is CancellationError { }
                catch { if account.inferenceScope == scope { account.message = error.localizedDescription } }
            }
        }
    }
    private func beginApple(_ input: ProcessingRequest, compact: Bool, id: UUID, allowDownloads: Bool) async throws {
        guard input.mode == .translate, input.tone == "Нейтральный" else {
            throw AppFailure(message: "Перевод Apple работает в режиме перевода с нейтральным тоном. Для коррекции и переписывания выберите ChatGPT.")
        }
        guard input.source != "auto-detect" else { throw AppFailure(message: "Не удалось определить язык. Выберите исходный язык в редакторе.") }
        let source = Locale.Language(identifier: LanguageCatalog.code(input.source))
        let target = Locale.Language(identifier: LanguageCatalog.code(input.target))
        if source.languageCode == target.languageCode { complete(input.input, request: input, engine: .apple, id: id); return }
        let status = try await AsyncDeadline.value(after: .seconds(15)) { await LanguageAvailability().status(from: source, to: target) }
        try Task.checkCancellation()
        guard operationID == id else { return }
        switch status {
        case .installed:
            let session = TranslationSession(installedSource: source, target: target)
            appleSession = session
            let result = try await AsyncDeadline.value(after: .seconds(60), cancel: { session.cancel() }) { try await session.translate(input.input) }
            try Task.checkCancellation()
            complete(result.targetText, request: input, engine: .apple, id: id)
        case .supported:
            guard allowDownloads else { throw AppFailure(message: "Языки для офлайн-перевода ещё не скачаны. Подключитесь к сети и выберите перевод Apple один раз.") }
            appleRequest = AppleTranslationRequest(input: input.input, source: source, target: target, context: compact, operationID: id)
            appleContext = compact
            var configuration = lastAppleConfiguration ?? .init(source: source, target: target)
            if configuration.source != source || configuration.target != target { configuration = .init(source: source, target: target) }
            configuration.invalidate()
            lastAppleConfiguration = configuration
            appleConfiguration = configuration
        case .unsupported:
            throw AppFailure(message: "Apple не поддерживает эту пару языков. Выберите ChatGPT или другую пару.")
        @unknown default: throw AppFailure(message: "Системный перевод Apple сейчас недоступен.")
        }
    }
    func performAppleTranslation(using session: TranslationSession) async {
        guard let pending = appleRequest, pending.operationID == operationID else { return }
        let original = request()
        appleSession = session
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            let result = try await AsyncDeadline.value(after: .seconds(60), cancel: { session.cancel() }) { try await session.translate(pending.input) }
            try Task.checkCancellation()
            complete(result.targetText, request: original, engine: .apple, id: pending.operationID)
        } catch { fail(error, id: pending.operationID) }
    }
    private func complete(_ text: String, request: ProcessingRequest, engine: TextEngine, id: UUID) {
        guard operationID == id else { return }
        output = text; resultEngine = engine; isProcessing = false
        if engine == .apple && request.promptRules.activeCount(for: request.mode) > 0 {
            notice = "Apple Translation не применяет Custom Prompt Rules. Для правил выберите ChatGPT."
        }
        appleRequest = nil; appleSession = nil
        if request.mode == .translate, let pair = TranslationLanguagePair(source: request.source, target: request.target) {
            lastTranslationPair = pair
        }
        history.insert(HistoryEntry(mode: request.mode, source: request.input, result: text,
            sourceLanguage: request.source, targetLanguage: request.target, engine: engine.rawValue), at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
    }
    private func fail(_ error: Error, id: UUID) {
        guard operationID == id else { return }
        output = ""; isProcessing = false
        appleRequest = nil; appleSession = nil
        if !(error is CancellationError) { notice = error.localizedDescription }
    }
    func editInput(_ text: String, change: InputChange = .typing) {
        guard text != input else { return }
        let delay = InputChange.automaticDelay(from: input, to: text, change: change)
        input = text
        needsAutomaticTarget = true
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if delay == .zero { process() }
        else { automaticProcessing.schedule(after: delay) { [weak self] in self?.process() } }
    }
    func receiveCapture(_ captured: CapturedText) {
        cancelProcessing()
        sourceLanguage = "Автоопределение"
        input = captured.text
        output = ""
        capture = captured
        notice = nil
        needsAutomaticTarget = true
        chooseTargetForIncomingText()
        if mode == .translate { needsAutomaticTarget = false }
    }
    private func chooseTargetForIncomingText() {
        guard mode == .translate else { return }
        targetLanguage = TranslationLanguagePair.suggestedTarget(source: detectedLanguage,
            currentTarget: targetLanguage, previous: lastTranslationPair)
    }
    func loadExample() { editInput(Self.sample, change: .paste) }
    func loadAlternatives(for selected: TextSelection) {
        alternativesTask?.cancel(); alternatives = []; alternativesMessage = nil
        guard resultEngine == .chatGPT, !isProcessing else {
            alternativesMessage = "Контекстные альтернативы доступны для результатов ChatGPT."; return
        }
        let original = output
        let input = request()
        alternativesLoading = true
        alternativesTask = Task { [weak self] in
            guard let self else { return }
            defer { if selection?.id == selected.id { alternativesLoading = false } }
            do {
                let model = try await resolveModel()
                try Task.checkCancellation()
                let variants = try await textService.alternatives(for: selected, input: input, output: original, model: model, reasoning: effectiveReasoningSetting)
                try Task.checkCancellation()
                guard selection?.id == selected.id, output == original else { return }
                alternatives = variants
                if variants.isEmpty { alternativesMessage = "Для этого фрагмента не найдено подходящих вариантов." }
            } catch is CancellationError { }
            catch { if selection?.id == selected.id { alternativesMessage = error.localizedDescription } }
        }
    }
    func cancelAlternatives() { alternativesTask?.cancel(); alternativesLoading = false }
    func replaceSelection(with variant: WordAlternative) {
        guard selection != nil, !isProcessing else { return }
        lastOutput = output; preferenceChange = nil
        output = variant.updatedText
        if mode == .translate, let phrase = variant.sourcePhrase, !phrase.isEmpty, input.contains(phrase) {
            let pair = (detectedLanguage ?? sourceLanguage) + " → " + targetLanguage
            let previous = memory.first { $0.source == phrase && $0.languages == pair }
            var entry = MemoryEntry(source: phrase, preferred: variant.replacement, languages: pair, context: String(input.prefix(300)))
            if let previous { entry.id = previous.id }
            preferenceChange = PreferenceChange(before: previous, after: entry)
            memory.removeAll { $0.source == phrase && $0.languages == pair }
            memory.insert(entry, at: 0)
            notice = "Предпочтение сохранено в словарь."
        } else { notice = "Замена применена." }
        selection = nil
    }
    func undoReplacement() {
        if let lastOutput { output = lastOutput }
        if let preferenceChange { memory = preferenceChange.undo(in: memory) }
        lastOutput = nil; preferenceChange = nil; notice = nil
    }
    func deleteMemory(_ id: UUID) { memory.removeAll { $0.id == id } }
    func copyResult() {
        guard !output.isEmpty, !isProcessing else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
        notice = "Скопировано."
    }
    func replaceCapturedText() async -> Bool {
        guard !isProcessing, !isReplacing, !output.isEmpty else { return false }
        isReplacing = true
        defer { isReplacing = false }
        do {
            guard let capture else { throw AppFailure(message: "Сначала вызовите поп-ап для выделенного текста в другом приложении.") }
            let outcome = try await capture.replace(with: output)
            // A new capture may arrive while native Paste is being confirmed.
            if self.capture?.id == capture.id {
                self.capture = nil
                notice = outcome == .confirmed ? "Текст заменён." : "Результат отправлен в исходное приложение. Если текст не изменился, вставьте его вручную."
                return true
            }
        } catch { notice = error.localizedDescription }
        return false
    }
    func swapLanguages() {
        guard mode == .translate, !output.isEmpty, !isProcessing else { return }
        let previous = detectedLanguage ?? "Русский"
        let translated = output
        cancelProcessing(); sourceLanguage = targetLanguage; targetLanguage = previous
        input = translated; output = ""
        process()
    }
}
