import SwiftUI
import Translation

struct EditorView: View {
    @Bindable var model: PrototypeModel
    var compact = false
    var replacementCompleted: (() -> Void)?

    private var actionTitle: String {
        switch model.mode {
        case .translate: tr("Перевести")
        case .correct: tr("Исправить")
        case .rewrite: tr("Переписать")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            content.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .clipped()
                .translationTask(model.appleContext == compact ? model.appleConfiguration : nil) { session in
                    await model.performAppleTranslation(using: session)
                }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if compact {
                resultPane
                    .layoutPriority(-1)
                    .clipped()
            } else {
                HStack(spacing: 0) {
                    sourcePane
                    Divider().padding(.vertical, 16)
                    resultPane
                }
            }
            if (model.resultEngine ?? model.engine) == .apple && model.promptRules.state.activeCount(for: model.mode) > 0 {
                Label(tr("Правила не применяются в Apple Translation"), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 4)
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(tr(notice)).font(.callout).textSelection(.enabled)
                        .lineLimit(compact ? 3 : nil).help(tr(notice))
                    Spacer(minLength: 4)
                    if model.lastOutput != nil {
                        Button(tr("Отменить")) { model.undoReplacement() }.buttonStyle(.plain).foregroundStyle(.tint)
                    }
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain).accessibilityLabel(tr("Закрыть"))
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, compact ? 20 : 28)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            }
            if model.showProcessingTimes, !model.isProcessing, let metrics = model.processingMetrics {
                HStack(spacing: 10) {
                    if metrics.cacheHit { Text(tr("Из кэша")) }
                    if let first = metrics.firstText { Text(tr("Первый текст") + ": " + seconds(first)) }
                    Text(tr("Готово") + ": " + seconds(metrics.total))
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, compact ? 16 : 24).padding(.vertical, 4)
            }
            bottomBar
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LanguagePicker(model: model, source: true, compact: compact)
                Spacer()
                if model.mode == .translate && !compact {
                    Button { model.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Поменять языки местами"))
                }
                Button {
                    model.editInput(NSPasteboard.general.string(forType: .string) ?? model.input, change: .paste)
                } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Вставить"))
                Button {
                    model.input = ""
                    model.output = ""
                    model.selection = nil
                    model.notice = nil
                } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help(tr("Очистить"))
            }
            TextEditor(text: Binding(get: { model.input }, set: { model.editInput($0) }))
                .font(.system(size: compact ? 16 : 19))
                .lineSpacing(compact ? 5 : 8)
                .scrollContentBackground(.hidden)
                .padding(.leading, -5)
                .accessibilityLabel(tr("Исходный текст"))
                .onChange(of: model.input) { _, _ in model.selection = nil }
                .frame(minHeight: compact ? 105 : 200, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if model.input.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tr("Введите или вставьте текст")).font(.system(size: 19)).foregroundStyle(.tertiary)
                            Button(tr("Пример")) { model.loadExample() }
                                .font(.callout).buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(.top, 1)
                    }
                }
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.vertical, compact ? 10 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.mode == .translate {
                    LanguagePicker(model: model, compact: compact)
                } else {
                    Text(tr("Результат")).font(.system(size: 15, weight: .semibold))
                }
                Spacer(minLength: 0)
                if model.mode != .correct {
                    Menu {
                        Picker(tr("Тон"), selection: Binding(get: { model.tone }, set: { model.tone = $0; model.process(compact: compact) })) {
                            ForEach(model.tones, id: \.self) { Text(tr($0)).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(tr(model.tone), systemImage: "slider.horizontal.3").font(.callout)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else if !compact {
                    Image(systemName: "checkmark.shield").foregroundStyle(.tertiary)
                        .help(tr("Без изменения тона"))
                }

            }
            SelectableText(text: model.output, fontSize: compact ? 17 : 19, lineSpacing: compact ? 6 : 8) { if !model.isProcessing { model.selection = $0 } }
                .accessibilityLabel(tr("Перевод текста"))
                .frame(minHeight: compact ? 0 : 200, maxHeight: .infinity)
                .popover(item: $model.selection, attachmentAnchor: .rect(.rect(model.selection?.anchor ?? .zero)), arrowEdge: .top) { selected in
                    AlternativesView(model: model, selected: selected)
                }
                .overlay(alignment: .topLeading) {
                    if compact && model.input.isEmpty {
                        Text(tr("Выделите текст и вызовите Forma сочетанием клавиш.")).font(.callout).foregroundStyle(.tertiary)
                            .padding(.top, 10).allowsHitTesting(false)
                    }
                }
        }
        .help(tr("Выберите слово или выделите фразу, чтобы посмотреть альтернативы."))
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.vertical, compact ? 10 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if !compact {
                Text("\(model.input.count)").monospacedDigit().font(.caption).foregroundStyle(.tertiary)
                    .help(tr(model.detectedLanguage ?? "Автоопределение"))
            }
            Button { model.openSettings?() } label: {
                let symbol = (model.resultEngine ?? model.engine) == .apple ? "desktopcomputer" : "sparkle"
                if compact {
                    Image(systemName: symbol)
                } else {
                    Label(tr(model.providerLabel), systemImage: symbol).lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.tertiary).buttonStyle(.plain)
            .accessibilityLabel(tr(model.providerLabel)).help(tr(model.providerLabel))
            Spacer(minLength: 0)
            if model.isProcessing {
                ProgressView().controlSize(.small)
                Button(tr("Отменить")) { model.cancelProcessing() }.buttonStyle(.glass).tint(.primary)
            } else if !compact {
                Button(actionTitle) { model.process(compact: compact) }
                    .buttonStyle(.glass).tint(.primary).disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(actionTitle)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Button { model.copyResult() } label: { Label(tr("Скопировать"), systemImage: "doc.on.doc") }
                .buttonStyle(.glass).tint(.primary).disabled(model.output.isEmpty || model.isProcessing)
            Button {
                Task {
                    if await model.replaceCapturedText() { replacementCompleted?() }
                }
            } label: { Label(tr("Заменить"), systemImage: "arrow.up.forward.app") }
                .buttonStyle(.glassProminent).disabled(model.output.isEmpty || model.isProcessing || model.isReplacing || model.capture == nil)
        }
        .controlSize(.regular)
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.top, 8).padding(.bottom, compact ? 12 : 16)
    }

    private func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " " + tr("с")
    }

}

struct WritingModePicker: View {
    @Bindable var model: PrototypeModel
    var compact = false

    var body: some View {
        Picker(tr("Режим"), selection: Binding(get: { model.mode }, set: { model.setMode($0, compact: compact) })) {
            ForEach(WritingMode.allCases) { mode in Text(tr(mode.rawValue)).tag(mode) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help(tr(model.mode.hint))
    }
}

struct AlternativesView: View {
    @Bindable var model: PrototypeModel
    let selected: TextSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Варианты замены")).font(.caption).foregroundStyle(.secondary)
            Text(selected.text).font(.title3.weight(.semibold)).lineLimit(3)
            if model.alternativesLoading { ProgressView().controlSize(.small) }
            if let message = model.alternativesMessage {
                Text(tr(message)).font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(model.alternatives) { variant in
                    Button { model.replaceSelection(with: variant) } label: {
                        HStack { Text(variant.replacement); Spacer(); Image(systemName: "arrow.turn.down.left").foregroundStyle(.tertiary) }
                            .padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            if !model.alternatives.isEmpty {
                Label(tr("Выбор сохранится в словаре, если найдено соответствие в оригинале."), systemImage: "bookmark")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 260)
        .task(id: selected.id) { model.loadAlternatives(for: selected) }
        .onDisappear { model.cancelAlternatives() }
    }
}
