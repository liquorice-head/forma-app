import AppKit
import SwiftUI

struct SelectableText: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat = 19
    var lineSpacing: CGFloat = 8
    var onSelection: (TextSelection) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = AlternativeTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = NSSize(width: 3, height: 10)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = .labelColor
        view.onSelection = onSelection
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AlternativeTextView else { return }
        view.onSelection = onSelection
        view.updateText(text, fontSize: fontSize, lineSpacing: lineSpacing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 350, height: proposal.height ?? 180)
    }
}

final class AlternativeTextView: NSTextView {
    var onSelection: ((TextSelection) -> Void)?
    private var appliedFontSize: CGFloat?
    private var appliedLineSpacing: CGFloat?

    func updateText(_ text: String, fontSize: CGFloat, lineSpacing: CGFloat) {
        let previous = string
        let styleChanged = appliedFontSize != fontSize || appliedLineSpacing != lineSpacing
        guard !previous.utf16.elementsEqual(text.utf16) || styleChanged else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
        ]
        if !styleChanged, text.utf16.starts(with: previous.utf16) {
            // Append only the newly streamed UTF-16 range, preserving the existing
            // text storage, selection and layout instead of restyling the full result.
            let suffix = (text as NSString).substring(from: (previous as NSString).length)
            textStorage?.append(NSAttributedString(string: suffix, attributes: attributes))
        } else {
            textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        appliedFontSize = fontSize; appliedLineSpacing = lineSpacing
    }

    override func mouseDown(with event: NSEvent) {
        // NSTextView tracks dragging through mouse-up inside mouseDown. Inspect the final selection afterwards.
        super.mouseDown(with: event)
        guard !string.isEmpty else { return }
        var range = selectedRange()
        if range.length == 0 {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            guard index < (string as NSString).length else { return }
            range = selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
        }
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        let phrase = (string as NSString).substring(with: range)
        guard phrase.rangeOfCharacter(from: .letters) != nil else { return }
        setSelectedRange(range)
        var anchor = CGRect.zero
        if let window, let scroll = enclosingScrollView {
            let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
            let local = scroll.convert(window.convertFromScreen(screenRect), from: nil)
            anchor = CGRect(x: local.minX, y: scroll.isFlipped ? local.minY : scroll.bounds.height - local.maxY,
                            width: local.width, height: local.height)
        }
        onSelection?(TextSelection(text: phrase, range: range, anchor: anchor))
    }
}
