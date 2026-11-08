import AppKit

enum ReplacementOutcome: Equatable {
    case confirmed
    case sent
}

/// Keep the safety checks shared by AX replacement and keyboard-only editors.
@MainActor struct SelectionReplacement {
    var activate: () async throws -> Bool
    var isSourceActive: () -> Bool
    var selection: () -> String?
    var setSelection: (String) -> Bool
    var copySelection: () async throws -> String?
    var paste: (String) async throws -> ReplacementOutcome

    func replace(_ original: String, with replacement: String) async throws -> ReplacementOutcome {
        guard try await activate(), isSourceActive() else { throw Self.selectionChanged() }
        try Task.checkCancellation()
        let selected = selection()
        // Some editors expose an empty AX selection even while native Copy works.
        if let selected, !selected.isEmpty, selected != original { throw Self.selectionChanged() }
        if selected == original {
            if replacement == original { return .confirmed }
            if setSelection(replacement) { return .confirmed }
        }
        // A clipboard capture must also be replaceable when AXSelectedText is unavailable.
        // Require a fresh native Copy; the old clipboard is not evidence of a current selection.
        guard try await copySelection() == original, isSourceActive() else { throw Self.selectionChanged() }
        try Task.checkCancellation()
        if let selected = selection(), !selected.isEmpty, selected != original { throw Self.selectionChanged() }
        if replacement == original { return .confirmed }
        return try await paste(replacement)
    }

    static func selectionChanged() -> AppFailure {
        AppFailure(message: "Выделение в исходном приложении изменилось или недоступно. Скопируйте результат.")
    }
}

/// Restore all clipboard formats only while the transaction still owns its contents.
@MainActor final class ReplacementClipboard {
    private let pasteboard: NSPasteboard
    private let originalItems: [[(NSPasteboard.PasteboardType, Data)]]
    private var ownedChangeCount: Int?

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        originalItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func readSelection(isSourceActive: () -> Bool, sendCopy: () -> Void = { SourceKeyboard.send(key: 8) }) async throws -> String? {
        guard isSourceActive() else { return nil }
        let baseline = pasteboard.changeCount
        sendCopy()
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(50))
            guard isSourceActive() else { return nil }
            if pasteboard.changeCount != baseline {
                ownedChangeCount = pasteboard.changeCount
                return pasteboard.string(forType: .string)
            }
        }
        return nil
    }

    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownedChangeCount = pasteboard.changeCount
    }

    func restore() {
        guard let ownedChangeCount, pasteboard.changeCount == ownedChangeCount else { return }
        let items = originalItems.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
        self.ownedChangeCount = nil
    }
}

enum SourceKeyboard {
    static func send(key: CGKeyCode) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: 0x464F524D41)
            event?.post(tap: .cghidEventTap)
        }
    }
}
