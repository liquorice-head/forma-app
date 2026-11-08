import SwiftUI

@main struct FormaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        @Bindable var model = delegate.model
        let _ = delegate.openMainWindow = { openWindow(id: "main") }
        Window("Forma", id: "main") {
            MainView(model: model, showPopup: delegate.showPopup)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    model.offerAccessibilitySetupIfNeeded()
                }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1000, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(tr("Проверить обновления…")) { model.updates.checkForUpdates() }
                    .disabled(model.updates.busy)
                Button(tr("Настройки")) { delegate.showSettings() }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button(tr("Открыть поп-ап"), action: delegate.showPopup).keyboardShortcut(" ", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra(isInserted: $model.showMenuBarIcon) {
            MenuBarActions(model: model, showPopup: delegate.showPopup)
        } label: {
            Image(nsImage: BrandIcon.templateImage)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PrototypeModel()
    var openMainWindow: (() -> Void)?
    private var popup: PopupController?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Follow interface appearance in the running Dock tile even when the
        // user keeps macOS's separate icon-style preference on Default.
        updateAppIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateAppIcon() }
        }
        // Services must also start when no SwiftUI window is created at login.
        model.openSettings = { [weak self] in self?.showSettings() }
        model.updates.onAccessRequired = { [weak self] in self?.showSettings() }
        model.quickCapture = QuickCaptureController(model: model, show: { [weak self] in self?.showPopup() })
        model.quickCapture?.start()
        model.store.scheduleSync()
        model.accountDidChange()
        model.updates.start()
        if !LaunchContext.isLoginItem(NSAppleEventManager.shared().currentAppleEvent) {
            showEditor()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        UIStrings.shared.refreshSystemLanguage()
        model.quickCapture?.applicationDidBecomeActive()
        model.loginItems.refresh()
        model.store.scheduleSync()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showEditor()
        return false
    }

    func showEditor() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        model.showSettings = true
        showEditor()
    }

    func showPopup() {
        UIStrings.shared.refreshSystemLanguage()
        if popup == nil { popup = PopupController(model: model) }
        popup?.show()
    }

    private func updateAppIcon() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = BrandIcon.appImage(dark: dark)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarActions: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: PrototypeModel
    let showPopup: () -> Void
    var body: some View {
        Button(tr("Редактор")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(tr("Быстрый перевод"), action: showPopup)
        Button(tr("Настройки")) { openWindow(id: "main"); model.showSettings = true; NSApp.activate(ignoringOtherApps: true) }
        Button(tr("Проверить обновления…")) { model.updates.checkForUpdates() }.disabled(model.updates.busy)
        Divider()
        Button(tr("Завершить Forma")) { NSApp.terminate(nil) }
    }
}

struct MainView: View {
    @Bindable var model: PrototypeModel
    let showPopup: () -> Void
    @AppStorage("sidebar.collapsed") private var sidebarCollapsed = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarCollapsed ? 64 : 210)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
            Divider()
            Group {
                switch model.screen {
                case "history": HistoryView(model: model)
                case "memory": MemoryView(model: model)
                case "rules": PromptRulesView(model: model)
                default: EditorView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .animation(.easeInOut(duration: 0.18), value: sidebarCollapsed)
        .navigationTitle(model.screen == "rules" ? "Custom Prompt Rules" : model.screen == "history" ? tr("История") : model.screen == "memory" ? tr("Словарь") : "Forma")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { sidebarCollapsed.toggle() } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(tr(sidebarCollapsed ? "Развернуть боковую панель" : "Свернуть до иконок"))
                .accessibilityLabel(tr(sidebarCollapsed ? "Развернуть боковую панель" : "Свернуть до иконок"))
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            if model.screen == "editor" {
                ToolbarItem(placement: .principal) {
                    WritingModePicker(model: model).frame(width: 310)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showAccessibilitySetup) {
            if let access = model.quickCapture?.accessibility {
                AccessibilitySetupView(access: access, shortcut: model.shortcut,
                    relaunching: model.relaunching, relaunchError: model.relaunchError,
                    relaunch: model.saveAndRelaunch)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            sidebarItem("Редактор", brand: true, selected: model.screen == "editor") { model.screen = "editor" }
            sidebarItem("История", symbol: "clock", selected: model.screen == "history") { model.screen = "history" }
            sidebarItem("Словарь", symbol: "text.book.closed", selected: model.screen == "memory") { model.screen = "memory" }
            sidebarItem("Custom Prompt Rules", symbol: "list.bullet.rectangle", selected: model.screen == "rules") { model.screen = "rules" }
            Spacer(minLength: 16)
            sidebarItem("Быстрый перевод", symbol: "macwindow.on.rectangle", action: showPopup)
                .help(tr("Быстрый перевод") + " · " + model.shortcut)
            if !sidebarCollapsed {
                Text(model.shortcut).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if model.quickCapture?.ready == false {
                sidebarItem("Включить быстрый вызов", symbol: "hand.raised") { model.showAccessibilitySetup = true }
            }
            Divider().padding(.vertical, 6)
            sidebarItem("Настройки", symbol: "gearshape") { model.showSettings = true }
            if !sidebarCollapsed {
                Label(tr(model.providerLabel), systemImage: "circle.fill")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, sidebarCollapsed ? 8 : 12).padding(.vertical, 12)
    }

    private func sidebarItem(_ title: String, symbol: String = "", brand: Bool = false,
                             selected: Bool = false, action: @escaping () -> Void) -> some View {
        FormaSidebarItem(title: title, symbol: symbol, brand: brand, collapsed: sidebarCollapsed,
                         selected: selected, action: action)
    }
}

private struct FormaSidebarItem: View {
    let title: String
    let symbol: String
    let brand: Bool
    let collapsed: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if brand {
                        Image(nsImage: BrandIcon.templateImage).resizable().scaledToFit()
                    } else {
                        Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    }
                }.frame(width: 20, height: 20)
                if !collapsed {
                    Text(tr(title)).font(.body).lineLimit(title == "Custom Prompt Rules" ? 2 : 1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, collapsed ? 0 : 12)
            .frame(maxWidth: .infinity).frame(height: 38)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tr(title)).accessibilityLabel(tr(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
