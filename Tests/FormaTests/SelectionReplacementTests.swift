import AppKit
import Testing
@testable import Forma

@MainActor private final class ReplacementEditor {
    var selected: String?
    var copied: String?
    var active = true
    var activated = false
    var writable = false
    var focusLostOnCopy = false
    var selectionAfterCopy: String?
    var copies = 0
    var writes: [String] = []
    var pastes: [String] = []

    var operation: SelectionReplacement {
        SelectionReplacement(
            activate: { self.activated = true; return self.active },
            isSourceActive: { self.active },
            selection: { self.activated ? self.selected : nil },
            setSelection: { text in
                guard self.writable else { return false }
                self.writes.append(text)
                return true
            },
            copySelection: {
                self.copies += 1
                if self.focusLostOnCopy { self.active = false }
                if let selected = self.selectionAfterCopy { self.selected = selected }
                return self.copied
            },
            paste: { self.pastes.append($0); return .sent }
        )
    }
}

struct SelectionReplacementTests {
    @Test @MainActor func clipboardOnlySelectionCanBeReplaced() async throws {
        for unavailable: String? in [nil, ""] {
            let editor = ReplacementEditor()
            editor.selected = unavailable
            editor.copied = "Привет 🌍\nВторая строка"
            let outcome = try await editor.operation.replace("Привет 🌍\nВторая строка", with: "Hello 🌍\nSecond line")
            #expect(outcome == .sent)
            #expect(editor.copies == 1)
            #expect(editor.pastes == ["Hello 🌍\nSecond line"])
        }
    }

    @Test @MainActor func accessibilityIsReadAfterReturningFocusAndUsesDirectReplacement() async throws {
        let editor = ReplacementEditor()
        editor.selected = "original"
        editor.writable = true
        let outcome = try await editor.operation.replace("original", with: "replacement")
        #expect(outcome == .confirmed)
        #expect(editor.writes == ["replacement"])
        #expect(editor.copies == 0 && editor.pastes.isEmpty)
    }

    @Test @MainActor func readOnlyAccessibilitySelectionUsesVerifiedNativePaste() async throws {
        let editor = ReplacementEditor()
        editor.selected = "original"
        editor.copied = "original"
        _ = try await editor.operation.replace("original", with: "replacement")
        #expect(editor.copies == 1)
        #expect(editor.pastes == ["replacement"])
    }

    @Test @MainActor func changedSelectionRejectsReplacement() async {
        let editor = ReplacementEditor()
        editor.selected = "different text"
        editor.copied = "original"
        editor.writable = true
        await #expect(throws: AppFailure.self) {
            try await editor.operation.replace("original", with: "replacement")
        }
        #expect(editor.writes.isEmpty && editor.pastes.isEmpty && editor.copies == 0)
    }

    @Test @MainActor func missingOrChangedNativeCopyNeverPastes() async {
        for copied: String? in [nil, "", "different text"] {
            let editor = ReplacementEditor()
            editor.copied = copied
            await #expect(throws: AppFailure.self) {
                try await editor.operation.replace("original", with: "replacement")
            }
            #expect(editor.pastes.isEmpty)
        }
    }

    @Test @MainActor func focusLossDuringVerificationNeverPastes() async {
        let editor = ReplacementEditor()
        editor.copied = "original"
        editor.focusLostOnCopy = true
        await #expect(throws: AppFailure.self) {
            try await editor.operation.replace("original", with: "replacement")
        }
        #expect(editor.pastes.isEmpty)
    }

    @Test @MainActor func failedActivationNeverCopiesOrWrites() async {
        let editor = ReplacementEditor()
        editor.active = false
        editor.selected = "original"
        editor.writable = true
        await #expect(throws: AppFailure.self) {
            try await editor.operation.replace("original", with: "replacement")
        }
        #expect(editor.copies == 0 && editor.writes.isEmpty && editor.pastes.isEmpty)
    }

    @Test @MainActor func selectionChangedDuringNativeCopyNeverPastes() async {
        let editor = ReplacementEditor()
        editor.copied = "original"
        editor.selectionAfterCopy = "changed while copying"
        await #expect(throws: AppFailure.self) {
            try await editor.operation.replace("original", with: "replacement")
        }
        #expect(editor.pastes.isEmpty)
    }

    @Test @MainActor func nativeCopyRequiresANewClipboardWrite() async throws {
        let board = NSPasteboard(name: .init("FormaTests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("old clipboard text", forType: .string)
        let transaction = ReplacementClipboard(board)
        let stale = try await transaction.readSelection(isSourceActive: { true }, sendCopy: {})
        #expect(stale == nil)
        let fresh = try await transaction.readSelection(isSourceActive: { true }, sendCopy: {
            board.clearContents()
            board.setString("new selection", forType: .string)
        })
        #expect(fresh == "new selection")
        transaction.restore()
        #expect(board.string(forType: .string) == "old clipboard text")
    }

    @Test @MainActor func clipboardTransactionRestoresAllFormatsAndPreservesLaterUserCopy() {
        let board = NSPasteboard(name: .init("FormaTests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let original = NSPasteboardItem()
        let customType = NSPasteboard.PasteboardType("app.forma.test-data")
        original.setString("original", forType: .string)
        original.setData(Data([0, 1, 255]), forType: customType)
        board.writeObjects([original])
        let transaction = ReplacementClipboard(board)
        transaction.write("replacement")
        transaction.restore()
        #expect(board.string(forType: .string) == "original")
        #expect(board.data(forType: customType) == Data([0, 1, 255]))
        let next = ReplacementClipboard(board)
        next.write("replacement")
        board.clearContents()
        board.setString("new user copy", forType: .string)
        next.restore()
        #expect(board.string(forType: .string) == "new user copy")
    }
}
