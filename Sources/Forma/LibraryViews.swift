import SwiftUI

struct MemoryView: View {
    @Bindable var model: PrototypeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Ваши предпочтения в словах")).font(.largeTitle.weight(.semibold))
            Text(tr("Личные исправления будут синхронизироваться через ваш iCloud."))
                .foregroundStyle(.secondary)
            if model.memory.isEmpty {
                ContentUnavailableView {
                    Label(tr("Пока ничего не сохранено"), systemImage: "text.book.closed")
                } description: {
                    Text(tr("Выберите альтернативу в переводе — предпочтение появится здесь."))
                }
            } else {
                List {
                    ForEach(model.memory) { entry in
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 14) {
                                    Text(entry.source).fontWeight(.medium)
                                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                    Text(entry.preferred).fontWeight(.medium)
                                }
                                Text(entry.languages).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.deleteMemory(entry.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help(tr("Удалить правило"))
                        }.padding(.vertical, 12)
                    }
                }.listStyle(.inset).padding(.horizontal, -10).padding(.top, 20)
            }
            Spacer(minLength: 0)
            Label(tr(model.store.cloudEnabled ? "Словарь синхронизируется через iCloud" : "Словарь сохранён на этом Mac"), systemImage: model.store.cloudEnabled ? "icloud" : "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HistoryView: View {
    @Bindable var model: PrototypeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Недавние тексты")).font(.largeTitle.weight(.semibold))
                Spacer()
                Button(tr("Очистить историю")) { model.history.removeAll() }
                    .disabled(model.history.isEmpty)
            }
            Text(tr(model.store.cloudEnabled ? "Последние 500 результатов синхронизируются через iCloud" : "Последние 500 результатов сохранены на этом Mac")).foregroundStyle(.secondary)
            if model.history.isEmpty {
                ContentUnavailableView(tr("История пуста"), systemImage: "clock", description: Text(tr("Обработанные примеры появятся здесь.")))
            } else {
                List(model.history) { entry in
                    Button {
                        model.cancelProcessing()
                        model.mode = entry.mode
                        model.sourceLanguage = entry.sourceLanguage ?? "Автоопределение"
                        model.targetLanguage = entry.targetLanguage ?? "English"
                        model.input = entry.source
                        model.output = entry.result
                        model.resultEngine = entry.engine.flatMap(TextEngine.init(rawValue:))
                        model.notice = nil
                        model.screen = "editor"
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(tr(entry.mode.rawValue), systemImage: entry.mode.symbol).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.date, style: .time).font(.caption).foregroundStyle(.tertiary)
                            }
                            Text(entry.source).lineLimit(2).foregroundStyle(.primary)
                            Text(entry.result).lineLimit(2).foregroundStyle(.secondary)
                        }.padding(.vertical, 14).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tr("Открыть в редакторе"))
                }.listStyle(.inset).padding(.horizontal, -10).padding(.top, 20)
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsView: View {
    @Bindable var model: PrototypeModel
    @Bindable var strings = UIStrings.shared
    @State private var recording = false
    @State private var recorder: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(tr("Настройки")).font(.title2.weight(.semibold))
                Spacer()
                Button(tr("Готово")) { model.showSettings = false }.keyboardShortcut(.defaultAction)
            }
            Form {
                UpdateSettingsView(updater: model.updates)
                Section(tr("Общие")) {
                    Toggle(tr("Показывать иконку в строке меню"), isOn: $model.showMenuBarIcon)
                    Toggle(tr("Запускать при входе в систему"), isOn: Binding(
                        get: { model.loginItems.enabled },
                        set: { enabled in Task { await model.loginItems.setEnabled(enabled) } }))
                        .disabled(model.loginItems.busy)
                    Text(tr("При входе Forma запускается в фоне, без главного окна. Глобальный шорткат работает и при скрытой иконке."))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.loginItems.status == .requiresApproval {
                        Text(tr("Автозапуск выключен в macOS. Разрешите его в разделе «Основные → Объекты входа и расширения»."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(tr("Открыть системные настройки")) { model.loginItems.openSystemSettings() }
                        Button(tr("Отменить регистрацию автозапуска")) { Task { await model.loginItems.setEnabled(false) } }
                            .disabled(model.loginItems.busy)
                    }
                    if model.loginItems.status == .notFound {
                        Text(tr("Для автозапуска установите Forma в папку «Программы» и откройте приложение оттуда."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.loginItems.message {
                        Text(tr(message)).font(.caption).foregroundStyle(.secondary)
                    }
                    Picker(tr("Язык интерфейса"), selection: $strings.language) {
                        Text(tr("Как в системе")).tag(UIStrings.systemLanguage)
                        Text("Русский").tag("Русский")
                        Text("English").tag("English")
                    }
                }
                Section(tr("Обработка текста")) {
                    Picker(tr("Сервис"), selection: Binding(get: { model.engine }, set: { model.engine = $0; if $0 == .apple { model.tone = "Нейтральный" } })) {
                        ForEach(TextEngine.allCases, id: \.self) { Text(tr($0.rawValue)).tag($0) }
                    }
                    Toggle(tr("Перевод Apple при отсутствии сети"), isOn: $model.allowOfflineFallback)
                    Text(tr("Офлайн работают скачанные языки. Apple переводит с нейтральным тоном; коррекция и переписывание используют ChatGPT."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.modelChoices.isEmpty {
                        Picker(tr("Модель ChatGPT"), selection: Binding(get: { model.selectedModel }, set: { model.changeModel($0) })) {
                            ForEach(model.modelChoices) { Text($0.name).tag($0.id) }
                        }
                        Picker(tr("Обдумывание"), selection: Binding(get: { model.effectiveReasoningSetting }, set: { model.reasoningSetting = $0 })) {
                            ForEach(model.reasoningChoices) { Text(tr($0.title)).tag($0) }
                        }
                        .disabled(model.reasoningChoices.count == 1 || model.engine != .chatGPT)
                        Text(tr(model.reasoningChoices.count == 1
                            ? "Для этой модели доступно обдумывание по умолчанию."
                            : "«Быстро» выбирает минимальное доступное обдумывание. Для сложных текстов можно повысить уровень."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(tr("Запоминать повторные результаты"), isOn: $model.cacheResults)
                    Text(tr("Точные повторы показываются сразу. Кэш хранится в памяти до закрытия приложения; изменения словаря и правил очищают его."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(tr("Показывать время обработки"), isOn: $model.showProcessingTimes)
                }
                Section(tr("Поведение поп-апа")) {
                    Toggle(tr("Оставлять поверх окон"), isOn: $model.pinned)
                    Text(tr(model.pinned ? "Закрывать только крестиком или Escape" : "Скрывать при клике снаружи"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(tr("Запускать сразу после вызова"), isOn: $model.automaticallyRun)
                    LabeledContent(tr("Сочетание клавиш")) {
                        HStack {
                            Text(model.shortcut).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            Button(tr(recording ? "Запишите сочетание" : "Изменить…")) { startRecording() }
                        }
                    }
                    if recording {
                        Text(tr("Нажмите сочетание с ⌘, ⌥ или ⌃. Escape — отмена.")).font(.caption).foregroundStyle(.tint)
                    }
                    Button(tr("По умолчанию")) { stopRecording(); model.shortcutKeyCode = nil; model.shortcutModifiers = 0; model.shortcut = "⌘C  ⌘C" }.font(.caption)
                    if model.quickCapture?.ready == true {
                        Label(tr("Быстрый вызов включён"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if model.quickCapture?.accessibility.requiresRestart == true {
                        Label(tr("Перезапустите Forma, чтобы применить разрешение"), systemImage: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    } else {
                        Button(tr("Разрешить быстрый вызов и замену текста")) { model.quickCapture?.requestPermission() }
                        Text(tr("Разрешите Универсальный доступ для Forma в настройках macOS."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.quickCapture?.accessibility.requested == true || model.quickCapture?.accessibility.requiresRestart == true {
                        Button(tr("Сохранить и перезапустить")) { model.saveAndRelaunch() }.disabled(model.relaunching)
                        if let error = model.relaunchError { Text(tr(error)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section(tr("Синхронизация")) {
                    Toggle(tr("Синхронизировать через iCloud"), isOn: Binding(get: { model.store.cloudEnabled }, set: { model.store.enableCloud($0) }))
                        .disabled(!model.store.cloudConfigured)
                    Text(tr(model.store.cloudConfigured ? "Словарь, последние 500 результатов и Custom Prompt Rules сохраняются в вашей личной базе iCloud. Локальная копия доступна без интернета." : "В этой сборке iCloud ещё не настроен."))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.store.cloudEnabled {
                        Button(tr("Синхронизировать сейчас")) { model.store.scheduleSync(after: .zero) }
                            .disabled(model.store.syncing)
                    }
                    if model.store.syncing { ProgressView().controlSize(.small) }
                    if let message = model.store.message { Text(tr(message)).font(.caption).foregroundStyle(.secondary) }
                }
                Section(tr("Аккаунт")) {
                    if !model.account.profiles.isEmpty {
                        Picker(tr("Подключение"), selection: Binding(get: { model.account.selectedID ?? "" }, set: { model.account.selectedID = $0; model.accountDidChange() })) {
                            ForEach(model.account.profiles) { Text($0.email + " · " + String($0.clientID.suffix(6))).tag($0.clientID) }
                        }
                    }
                    if model.account.busy {
                        ProgressView().controlSize(.small)
                        Button(tr("Отменить")) { model.account.cancelSignIn() }
                    } else {
                        if model.account.connected {
                            Label(tr("ChatGPT подключён"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(tr("Используется ваш тариф ChatGPT.")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button(tr("Продолжить с ChatGPT")) { Task { await model.account.signIn(); model.accountDidChange() } }
                        }
                        if !model.account.profiles.isEmpty {
                            Button(tr("Добавить аккаунт")) { Task { await model.account.signIn(addAccount: true); model.accountDidChange() } }
                        }
                        if model.account.connected {
                            Button(tr("Выйти")) { model.cancelProcessing(); Task { await model.account.signOut(); model.accountDidChange() } }
                        }
                    }
                    if let message = model.account.message { Text(tr(message)).font(.caption).foregroundStyle(.secondary) }
                    Link(tr("Управлять использованием тарифа"), destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    Text(tr("Запросы ChatGPT используют ваш тариф. Перевод Apple выполняется на устройстве."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
        .padding(24).frame(width: 520, height: 670)
        .onAppear { model.loginItems.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.loginItems.refresh()
        }
        .onDisappear { stopRecording() }
        .alert(tr("Используется ваш тариф ChatGPT."), isPresented: Binding(get: { model.account.showPlanNotice }, set: { model.account.showPlanNotice = $0 })) {
            Button(tr("Готово")) { model.account.confirmPlanNotice() }
        } message: {
            Text(tr("Запросы ChatGPT используют ваш тариф. Перевод Apple выполняется на устройстве."))
        }
    }

    private func startRecording() {
        stopRecording()
        recording = true
        model.recordingShortcut = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
            model.shortcut = (flags.contains(.control) ? "⌃" : "")
                + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "")
                + (flags.contains(.command) ? "⌘" : "") + key.uppercased()
            model.shortcutKeyCode = event.keyCode
            model.shortcutModifiers = flags.intersection([.command, .option, .control, .shift]).rawValue
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = false
        model.recordingShortcut = false
    }
}
