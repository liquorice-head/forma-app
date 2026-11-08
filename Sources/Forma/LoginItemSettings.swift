import AppKit
import Observation
import ServiceManagement

@MainActor @Observable final class LoginItemSettings {
    private(set) var status: SMAppService.Status
    private(set) var busy = false
    private(set) var message: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void

    var enabled: Bool { status == .enabled }

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { refresh(); busy = false }
        do {
            if enabled { try register() }
            else { try await unregister() }
        } catch {
            let current = readStatus()
            if enabled ? (current != .enabled && current != .requiresApproval) : (current != .notRegistered) {
                message = "Не удалось изменить автозапуск. Проверьте разрешение в системных настройках и повторите попытку."
            }
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LaunchContext {
    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
