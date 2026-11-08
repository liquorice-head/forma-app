import SwiftUI

struct PromptRulesView: View {
    @Bindable var model: PrototypeModel
    @State private var editing: CustomPromptRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Custom Prompt Rules").font(.largeTitle.weight(.semibold))
                Spacer()
                Button(tr("Создать правило"), systemImage: "plus") { editing = CustomPromptRule() }
                    .disabled(model.promptRules.loadFailed)
            }
            Text(tr("Правила работают в ChatGPT в редакторе и поп-апе. Apple Translation их не поддерживает, в том числе при офлайн-переключении."))
                .foregroundStyle(.secondary)
            Text(tr("Смысл и режим важнее правил. Затем: словарь → свои правила (нижние важнее) → шаблоны → тон. В коррекции — только ошибки и пунктуация."))
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.promptRules.message { Text(tr(message)).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("Готовые правила")).font(.title3.weight(.semibold))
                    ForEach(PromptRuleTemplate.allCases) { template in
                        templateRow(template)
                    }
                    Divider()
                    Text(tr("Свои правила")).font(.title3.weight(.semibold))
                    if model.promptRules.state.custom.isEmpty {
                        Text(tr("Создайте правило или свою версию готового шаблона.")).foregroundStyle(.secondary)
                    }
                    ForEach(model.promptRules.state.custom) { rule in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(isOn: Binding(get: {
                                model.promptRules.state.custom.first { $0.id == rule.id }?.enabled ?? false
                            }, set: { enabled in
                                var changed = rule; changed.enabled = enabled; model.promptRules.upsert(changed)
                            })) { Text(rule.title).fontWeight(.medium) }
                                .toggleStyle(.checkbox)
                            Spacer(minLength: 0)
                            Button { editing = rule } label: { Image(systemName: "pencil") }
                                .help(tr("Изменить правило"))
                            Button { model.promptRules.delete(rule.id) } label: { Image(systemName: "trash") }
                                .help(tr("Удалить инструкцию"))
                        }.buttonStyle(.borderless)
                        Text(rule.instruction).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        modeLabel(rule.modes)
                    }
                }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(model.promptRules.loadFailed)
            Text(tr(model.store.cloudEnabled ? "Правила синхронизируются через iCloud. Выполнение инструкций зависит от модели." : "Правила сохранены только на этом Mac. Выполнение инструкций зависит от модели."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .sheet(item: $editing) { rule in
            PromptRuleEditor(store: model.promptRules, rule: rule)
        }
    }

    private func templateRow(_ template: PromptRuleTemplate) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(tr(template.title), isOn: Binding(get: {
                model.promptRules.state.templates.contains(template)
            }, set: { model.promptRules.set(template, enabled: $0) }))
                .toggleStyle(.checkbox).fontWeight(.medium)
            Text(tr(template.detail)).font(.callout).foregroundStyle(.secondary)
            HStack {
                modeLabel(template.modes)
                Spacer()
                Button(tr("Создать свою версию")) {
                    editing = CustomPromptRule(title: tr(template.title), instruction: template.instruction, modes: template.modes)
                }.buttonStyle(.link)
            }
            DisclosureGroup(tr("Текст инструкции")) {
                Text(template.instruction).font(.callout).textSelection(.enabled).padding(.top, 4)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private func modeLabel(_ modes: [WritingMode]) -> some View {
        Text(modes.map { tr($0.rawValue) }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
    }
}

private struct PromptRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: PromptRulesStore
    @State var rule: CustomPromptRule
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Правило для ChatGPT")).font(.title2.weight(.semibold))
            TextField(tr("Название"), text: $rule.title)
            Text(tr("Инструкция")).font(.headline)
            TextEditor(text: $rule.instruction).font(.body)
                .frame(minHeight: 150).border(.quaternary)
                .accessibilityLabel(tr("Инструкция"))
            HStack {
                ForEach(WritingMode.allCases) { mode in
                    Toggle(tr(mode.rawValue), isOn: Binding(get: { rule.modes.contains(mode) }, set: { enabled in
                        rule.modes.removeAll { $0 == mode }
                        if enabled { rule.modes.append(mode) }
                    })).toggleStyle(.checkbox)
                }
            }
            Toggle(tr("Включено"), isOn: $rule.enabled).toggleStyle(.checkbox)
            if let message = store.message { Text(tr(message)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(tr("Отменить")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Сохранить")) { if store.upsert(rule) { dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(!rule.isValid || store.loadFailed)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 540)
    }
}
