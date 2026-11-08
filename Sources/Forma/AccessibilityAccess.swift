import AppKit
import ApplicationServices
import Observation

@MainActor @Observable final class AccessibilityAccess {
    private(set) var granted: Bool
    private(set) var waiting = false
    private(set) var requested = false
    private(set) var requiresRestart = false
    private(set) var repairRequired: Bool
    private(set) var settingsUnavailable = false
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    private let check: () -> Bool
    private let prompt: () -> Void
    private let openSettings: () -> Bool
    @ObservationIgnored private var watcher: Task<Void, Never>?
    private var awaitingSettingsReturn = false
    private var restartPromptPending = false

    init(restarted: Bool = false, check: @escaping () -> Bool = { AXIsProcessTrusted() },
         prompt: @escaping () -> Void = {
             _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
         },
         openSettings: @escaping () -> Bool = {
             NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
         }) {
        self.check = check; self.prompt = prompt; self.openSettings = openSettings
        let trusted = check()
        granted = trusted
        repairRequired = restarted && !trusted
    }

    func refresh() {
        let trusted = check()
        if trusted {
            waiting = false
            watcher?.cancel(); watcher = nil
        }
        guard granted != trusted else { return }
        if trusted {
            requiresRestart = true
            repairRequired = false
            restartPromptPending = true
        } else {
            requiresRestart = false
            restartPromptPending = false
        }
        granted = trusted
        onChange?(trusted)
    }

    func request(pollInterval: Duration = .seconds(1)) {
        refresh()
        guard !granted else { return }
        requested = true
        awaitingSettingsReturn = true
        prompt()
        settingsUnavailable = !openSettings()
        waiting = true
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollInterval) } catch { return }
                guard let self else { return }
                self.refresh()
                if self.granted { return }
            }
        }
    }

    func returnedFromSettings() {
        let shouldOfferRestart = awaitingSettingsReturn
        awaitingSettingsReturn = false
        refresh()
        // Some macOS versions do not reflect a changed grant in the current process.
        // Offer a restart without claiming that permission has actually been granted.
        if shouldOfferRestart && !granted {
            requiresRestart = true
            restartPromptPending = true
        }
    }

    func consumeRestartPrompt() -> Bool {
        guard restartPromptPending else { return false }
        restartPromptPending = false
        return true
    }

    deinit { watcher?.cancel() }
}
