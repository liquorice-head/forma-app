import SwiftUI

struct UpdateSettingsView: View {
    @Bindable var updater: AppUpdater
    @State private var token = ""

    var body: some View {
        Section(tr("Обновления")) {
            LabeledContent(tr("Версия"), value: updater.version)
            Toggle(tr("Проверять обновления автоматически"), isOn: $updater.automaticChecks)
            Toggle(tr("Загружать и устанавливать обновления автоматически"), isOn: $updater.automaticInstall)
            Toggle(tr("Получать тестовые версии"), isOn: $updater.includePrereleases)
            Button(tr("Проверить обновления…")) { updater.checkForUpdates() }.disabled(updater.busy)
            if updater.busy { ProgressView().controlSize(.small) }
            if updater.installationDeferred {
                Button(tr("Сохранить и установить")) { updater.retryInstallation() }
            }
            if let status = updater.status { Text(tr(status)).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup(tr("Доступ к закрытому репозиторию")) {
                Text(tr("Для закрытых релизов нужен GitHub-токен только с доступом Contents: Read к репозиторию Forma. Он хранится в Связке ключей на этом Mac. Для публичных релизов токен не нужен."))
                    .font(.caption).foregroundStyle(.secondary)
                SecureField(tr("GitHub-токен"), text: $token)
                HStack {
                    Button(tr("Сохранить доступ")) { updater.saveAccess(token); token = "" }.disabled(token.isEmpty)
                    if updater.hasToken { Button(tr("Удалить доступ")) { updater.saveAccess("") } }
                }
                Link(tr("Создать токен GitHub"), destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            }
        }
    }
}
