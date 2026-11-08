import AppKit
import SwiftUI

enum PopupLayout {
    static let titleBarHeight: CGFloat = 44

    // Control frames are measured by SwiftUI in the popup's top-left coordinates.
    static func canDrag(at point: NSPoint, size: NSSize, controls: [CGRect]) -> Bool {
        guard !controls.isEmpty else { return false }
        let point = CGPoint(x: point.x, y: size.height - point.y)
        let title = CGRect(x: 12, y: 6, width: max(0, size.width - 24), height: titleBarHeight - 6)
        return title.contains(point) && !controls.contains { $0.contains(point) }
    }
}

private struct PopupTitleControlsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private extension View {
    func popupTitleControl() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: PopupTitleControlsKey.self,
                    value: [geometry.frame(in: .named("popup"))])
            }
        }
    }
}

final class TranslationPanel: NSPanel {
    var titleBarControls: [CGRect] = []
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Only the free title area starts a drag; mode/pin/close clicks reach SwiftUI.
        if event.type == .leftMouseDown,
           PopupLayout.canDrag(at: event.locationInWindow, size: frame.size, controls: titleBarControls) {
            performDrag(with: event)
        } else {
            super.sendEvent(event)
        }
    }
}

@MainActor final class PopupController: NSObject, NSWindowDelegate {
    let model: PrototypeModel
    private var panel: TranslationPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(model: PrototypeModel) { self.model = model; super.init() }

    func show() {
        if panel == nil {
            let panel = TranslationPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                backing: .buffered, defer: false
            )
            panel.title = "Forma · \(tr("Быстрый перевод"))"
            panel.delegate = self
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovable = true
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.minSize = NSSize(width: 420, height: 320)
            let hosting = NSHostingView(rootView: PopupView(model: model,
                close: { [weak self] in self?.hide() },
                updateTitleBarControls: { [weak panel] in panel?.titleBarControls = $0 }))
            hosting.sizingOptions = []
            panel.contentView = hosting
            if !panel.setFrameUsingName("FormaQuickTranslation") { panel.center() }
            panel.setFrameAutosaveName("FormaQuickTranslation")
            self.panel = panel
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, !self.model.pinned, !self.model.choosingLanguage else { return }
                self.hide()
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let popup = self.panel, popup.isVisible else { return event }
                // Leave Escape to menus and alternative popovers while one is open.
                if event.type == .keyDown, event.keyCode == 53, event.window == popup,
                   self.model.selection == nil, !self.model.showSettings, !self.model.choosingLanguage {
                    self.hide()
                    return nil
                }
                if event.type != .keyDown, event.window != popup, !self.model.pinned,
                   self.model.selection == nil, !self.model.showSettings, !self.model.choosingLanguage {
                    self.hide()
                }
                return event
            }
        }
        panel?.makeKeyAndOrderFront(nil)
        if model.automaticallyRun && model.output.isEmpty && !model.isProcessing { model.process(compact: true) }
    }

    func hide() { panel?.orderOut(nil) }

    func windowDidMove(_ notification: Notification) {
        panel?.saveFrame(usingName: "FormaQuickTranslation")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel?.close()
        panel = nil
    }
}

struct PopupView: View {
    @Bindable var model: PrototypeModel
    let close: () -> Void
    let updateTitleBarControls: ([CGRect]) -> Void
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                titleBar.frame(height: PopupLayout.titleBarHeight)
                EditorView(model: model, compact: true, replacementCompleted: close)
                    .frame(width: geometry.size.width, height: max(0, geometry.size.height - PopupLayout.titleBarHeight), alignment: .top)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .coordinateSpace(name: "popup")
        .onPreferenceChange(PopupTitleControlsKey.self, perform: updateTitleBarControls)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: BrandIcon.templateImage).resizable().scaledToFit()
                .frame(width: 17, height: 17).foregroundStyle(.primary)
                .frame(width: 24, height: 28)
                .help(tr("Перетащите окно за заголовок"))
            WritingModePicker(model: model, compact: true)
                .controlSize(.small)
                .frame(maxWidth: 310)
                .popupTitleControl()
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Button { model.pinned.toggle() } label: {
                    Image(systemName: model.pinned ? "pin.fill" : "pin")
                        .frame(width: 16, height: 16)
                }.buttonStyle(.glass).tint(model.pinned ? .accentColor : .secondary)
                    .help(tr(model.pinned ? "Поверх окон — можно перетаскивать" : "Оставлять поверх окон"))
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.glass).tint(.primary).help(tr("Закрыть"))
            }
            .controlSize(.small)
            .fixedSize()
            .popupTitleControl()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
