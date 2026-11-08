import SwiftUI

struct AccessibilitySetupView: View {
    @Bindable var access: AccessibilityAccess
    let shortcut: String
    var relaunching = false
    var relaunchError: String?
    let relaunch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "hand.point.up.left.and.text")
                .font(.system(size: 30)).foregroundStyle(.tint)
            Text(tr(access.repairRequired ? "Обновите разрешение Accessibility" : access.requiresRestart ? "Перезапустите Forma" : "Быстрый перевод в любом приложении"))
                .font(.title2.weight(.semibold))
            Text(tr("Разрешите Forma доступ к Accessibility, чтобы вызывать перевод сочетанием клавиш, читать выделенный текст и заменять его результатом."))
                .fixedSize(horizontal: false, vertical: true)
            Label(shortcut, systemImage: "keyboard")
                .font(.system(.body, design: .monospaced))
            Text(tr("В настройках macOS включите Forma в разделе «Конфиденциальность и безопасность → Универсальный доступ»."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if access.repairRequired {
                Text(tr("После перезапуска macOS по-прежнему не подтверждает доступ этой копии Forma. Если переключатель уже включён, удалите старую запись Forma кнопкой «−», затем добавьте текущую копию кнопкой «+» и включите её."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(tr("Показать Forma в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }.buttonStyle(.link)
            }
            if access.granted {
                Label(tr("Доступ разрешён. Сохраните текст и перезапустите Forma."), systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else if access.waiting {
                Text(tr("После включения доступа сохраните текст и перезапустите Forma, чтобы применить разрешение."))
                    .font(.callout).foregroundStyle(.secondary)
                Text(tr("Если Forma нет в списке, нажмите «+» и выберите приложение."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(tr("Показать Forma в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }.buttonStyle(.link)
            }
            if access.waiting && !access.granted {
                Button(tr("Открыть системные настройки")) { access.request() }.buttonStyle(.link)
            }
            if access.settingsUnavailable {
                Text(tr("Откройте настройки macOS вручную: Конфиденциальность и безопасность → Универсальный доступ."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let relaunchError { Text(tr(relaunchError)).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button(tr("Позже")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(relaunching)
                Spacer()
                if access.waiting || access.granted || access.requiresRestart {
                    Button(tr("Сохранить и перезапустить"), action: relaunch)
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(relaunching)
                } else {
                    Button(tr("Открыть системные настройки")) { access.request() }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28).frame(width: 460)
    }
}
