import SwiftUI

struct LanguagePicker: View {
    @Bindable var model: PrototypeModel
    var source = false
    var compact = false
    @State private var presented = false

    private var value: String { source ? model.sourceLanguage : model.targetLanguage }
    private var english: Bool { UIStrings.shared.isEnglish }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Text(LanguageCatalog.displayName(value, english: english))
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr(source ? "Исходный язык" : "Язык перевода"))
        .accessibilityValue(LanguageCatalog.displayName(value, english: english))
        .help(LanguageCatalog.displayName(value, english: english))
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            LanguagePickerContents(selection: value, source: source, engine: model.engine,
                otherLanguage: source ? model.targetLanguage : model.detectedLanguage) { value in
                    if source { model.sourceLanguage = value }
                    else { model.targetLanguage = value }
                    presented = false
                    model.process(compact: compact, automaticallyChooseTarget: source)
                }
                .onAppear { model.choosingLanguage = true }
                .onDisappear { model.choosingLanguage = false }
        }
    }
}

private struct LanguagePickerContents: View {
    let selection: String
    let source: Bool
    let engine: TextEngine
    let otherLanguage: String?
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var options: [LanguageOption] = []
    @State private var loading = false
    @State private var error: String?
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    private var english: Bool { UIStrings.shared.isEnglish }
    private var filtered: [LanguageOption] { LanguageCatalog.sorted(options, query: query, english: english) }
    private var showAutomatic: Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return source && (query.isEmpty ||
            ["Автоопределение", "Detect language", "auto"].contains { $0.localizedCaseInsensitiveContains(query) })
    }
    private var values: [String] { (showAutomatic ? ["Автоопределение"] : []) + filtered.map(\.value) }

    var body: some View {
        VStack(spacing: 0) {
            TextField(tr("Поиск языков"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { chooseHighlighted() }
                .padding(12)
            Divider()
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 12) {
                    Text(tr(error)).font(.callout).foregroundStyle(.secondary)
                    Button(tr("Повторить")) { Task { await load() } }
                }.padding(16).frame(maxHeight: .infinity)
            } else if values.isEmpty {
                Text(tr(options.isEmpty ? "Apple не поддерживает эту пару языков. Выберите ChatGPT или другую пару." : "Языки не найдены"))
                    .foregroundStyle(.secondary).padding(16).frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if showAutomatic { row(value: "Автоопределение", title: tr("Автоопределение"), subtitle: nil) }
                            ForEach(filtered) { option in
                                row(value: option.value,
                                    title: option.name(englishInterface: english).localizedCapitalized,
                                    subtitle: english ? option.native : option.english)
                            }
                        }.padding(6)
                    }
                    .onAppear {
                        if let highlighted { proxy.scrollTo(highlighted) }
                    }
                    .onChange(of: highlighted) { _, value in
                        if let value { proxy.scrollTo(value) }
                    }
                }
            }
            Divider()
            Text(tr(engine == .apple ? "Языки, доступные в Apple Translation. Нескачанные языки потребуют загрузки." : "Качество ChatGPT зависит от языка и выбранной модели."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(width: 300, height: 390)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.return) { chooseHighlighted(); return .handled }
        .onChange(of: query) { _, _ in highlighted = values.first }
        .task(id: engine.rawValue + "|" + (otherLanguage ?? "")) {
            searchFocused = true
            await load()
        }
    }

    private func row(value: String, title: String, subtitle: String?) -> some View {
        Button { choose(value) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                    .opacity(LanguageCatalog.code(selection) == LanguageCatalog.code(value) ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    if let subtitle, subtitle.caseInsensitiveCompare(title) != .orderedSame {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted == value ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
        .id(value)
    }

    private func move(_ offset: Int) {
        guard !values.isEmpty else { return }
        let index = highlighted.flatMap { values.firstIndex(of: $0) } ?? (offset > 0 ? -1 : values.count)
        highlighted = values[min(max(index + offset, 0), values.count - 1)]
    }

    private func chooseHighlighted() {
        guard !loading, error == nil, let value = highlighted, values.contains(value) else { return }
        choose(value)
    }

    private func load() async {
        loading = true
        error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let loaded = engine == .apple
                ? try await LanguageCatalog.appleLanguages(otherLanguage: otherLanguage, selectingSource: source)
                : LanguageCatalog.all
            try Task.checkCancellation()
            options = loaded
            highlighted = values.contains(selection) ? selection : values.first
        } catch is CancellationError {
        } catch {
            self.error = "Не удалось получить языки Apple. Повторите попытку."
        }
    }
}
