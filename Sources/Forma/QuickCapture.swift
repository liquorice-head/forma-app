import AppKit
import ApplicationServices
import Observation

struct DoubleCopyDetector {
    private var previous: TimeInterval?
    mutating func press(at timestamp: TimeInterval) -> Bool {
        if let previous, timestamp >= previous, timestamp - previous < 0.5 {
            self.previous = nil
            return true
        }
        previous = timestamp
        return false
    }
    mutating func reset() { previous = nil }
}

@MainActor struct CapturedText {
    let id = UUID()
    let text: String
    let app: NSRunningApplication

    func replace(with replacement: String) async throws -> ReplacementOutcome {
        guard AXIsProcessTrusted() else {
            throw AppFailure(message: "Разрешите Универсальный доступ для Forma в настройках macOS.")
        }
        guard !app.isTerminated else { throw SelectionReplacement.selectionChanged() }
        let clipboard = ReplacementClipboard()
        var keepResultOnClipboard = false
        // A nonactivating panel can retain keyboard focus even when the source app is frontmost.
        let panel = NSApp.keyWindow as? TranslationPanel
        let restorePanel = panel?.isVisible == true
        var completed = false
        defer {
            if !keepResultOnClipboard { clipboard.restore() }
            if restorePanel && !completed { panel?.makeKeyAndOrderFront(nil) }
        }
        let isSourceActive = { !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        // Web and Electron editors may rebuild their accessibility elements while Forma is open.
        var target: AXUIElement?
        let readSelection = {
            target = Self.focusedElement(in: app)
            return target.flatMap { Self.selection(of: $0) }
        }
        let operation = SelectionReplacement(
            activate: {
                panel?.orderOut(nil)
                guard app.activate(options: []) || isSourceActive() else { return false }
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(50))
                    if isSourceActive() { return true }
                }
                return false
            },
            isSourceActive: isSourceActive,
            selection: readSelection,
            setSelection: { replacement in
                guard let target else { return false }
                return AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success
            },
            copySelection: { try await clipboard.readSelection(isSourceActive: isSourceActive) },
            paste: { replacement in
                guard isSourceActive() else { throw SelectionReplacement.selectionChanged() }
                let canConfirm = readSelection() == text
                clipboard.write(replacement)
                SourceKeyboard.send(key: 9)
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(100))
                    guard isSourceActive() else { break }
                    // An unavailable AX attribute is not confirmation that Paste succeeded.
                    if canConfirm, let selected = readSelection(), selected != text {
                        return .confirmed
                    }
                }
                keepResultOnClipboard = true
                return .sent
            }
        )
        let outcome = try await operation.replace(text, with: replacement)
        completed = true
        return outcome
    }

    static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        var focused: CFTypeRef?
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }
    static func selection(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

@MainActor @Observable final class QuickCaptureController {
    let accessibility: AccessibilityAccess
    var permissionGranted: Bool { accessibility.granted }
    var ready: Bool { permissionGranted && !accessibility.requiresRestart && globalMonitor != nil }
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var detector = DoubleCopyDetector()
    private var copyStartCount = 0
    private var captureTask: Task<Void, Never>?
    private let model: PrototypeModel
    private let show: () -> Void
    init(model: PrototypeModel, show: @escaping () -> Void) {
        self.model = model; self.show = show
        accessibility = AccessibilityAccess(restarted: model.didRelaunchForAccessibility)
        accessibility.onChange = { [weak self] _ in
            self?.installEventMonitors()
            self?.model.offerAccessibilityRestartIfNeeded()
        }
    }

    func start() {
        accessibility.refresh()
        installEventMonitors()
    }
    func applicationDidBecomeActive() {
        accessibility.returnedFromSettings()
        start()
        model.offerAccessibilityRestartIfNeeded()
    }
    private func installEventMonitors() {
        stop()
        if permissionGranted && !accessibility.requiresRestart {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handle($0) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handle($0); return $0 }
    }
    func requestPermission() { accessibility.request() }
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        captureTask?.cancel()
        detector.reset()
    }
    private func handle(_ event: NSEvent) {
        guard !event.isARepeat, !model.recordingShortcut, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x464F524D41 else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let key = model.shortcutKeyCode {
            guard event.keyCode == key && flags.rawValue == model.shortcutModifiers else { return }
            capture(copied: false)
        } else if event.keyCode == 8 && flags == .command {
            if detector.press(at: event.timestamp) { capture(copied: true) }
            else { copyStartCount = NSPasteboard.general.changeCount }
        } else { detector.reset() }
    }
    private func capture(copied: Bool) {
        accessibility.refresh()
        guard ready else {
            if !model.showSettings { model.showAccessibilitySetup = true }
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let element = CapturedText.focusedElement(in: app)
        if let element, let text = CapturedText.selection(of: element), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliver(CapturedText(text: text, app: app)); return
        }
        if !copied {
            // Unsupported accessibility surfaces need an explicit native copy to obtain the selected text.
            copyStartCount = NSPasteboard.general.changeCount
            SourceKeyboard.send(key: 8)
        }
        let baseline = copyStartCount
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                if NSPasteboard.general.changeCount != baseline,
                   let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    self?.deliver(CapturedText(text: text, app: app)); return
                }
            }
            self?.model.notice = "Не удалось получить выделенный текст. Выделите текст и попробуйте ещё раз."
            self?.show()
        }
    }
    private func deliver(_ capture: CapturedText) {
        model.receiveCapture(capture)
        show()
    }
}
