import AppKit
import SwiftUI
import PaneFlowCore

final class PalettePanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor final class PanelCoordinator {
    let model: AppModel
    private var palette: PalettePanel?
    private var preferences: NSWindow?
    private var editor: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var paletteObservers: [NSObjectProtocol] = []
    private var menuTracking = 0
    private var menuEndedAt: TimeInterval = 0
    private var dismissAfterMenu = false
    private var openRequest = 0
    var onDismiss: (() -> Void)?
    init(model: AppModel) { self.model = model }
    func contains(_ point: CGPoint) -> Bool {
        guard let palette, palette.isVisible else { return false }
        return DisplayGeometry.flip(palette.frame, primaryHeight: Double(NSScreen.screens.first?.frame.height ?? 0)).contains(point)
    }
    func openFocused() {
        guard !model.busy, !model.paused else { return }
        openRequest += 1; let request = openRequest
        Task {
            let focused = await model.focusedWindow()
            guard request == openRequest else { return }
            guard let window = focused else { model.notice = "请先选中一个可调整的普通窗口，再打开布局面板。"; showPreferences(); return }
            show(window, anchor: nil)
        }
    }
    func toggleFocused() {
        if palette?.isVisible == true { dismissPalette() } else { openFocused() }
    }
    func dismissPalette(_ panel: PalettePanel? = nil) {
        if let panel, palette !== panel { return }
        openRequest += 1
        guard let current = palette else { return }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        paletteObservers.forEach { NotificationCenter.default.removeObserver($0) }; paletteObservers = []
        menuTracking = 0; menuEndedAt = 0; dismissAfterMenu = false
        let wasVisible = current.isVisible
        current.orderOut(nil)
        if wasVisible { onDismiss?() }
    }
    private func requestDismiss() {
        if menuTracking > 0 { dismissAfterMenu = true } else { dismissPalette() }
    }
    private func monitor(_ panel: PalettePanel) {
        let center = NotificationCenter.default
        paletteObservers.append(center.addObserver(forName:NSMenu.didBeginTrackingNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking += 1 }
        })
        paletteObservers.append(center.addObserver(forName:NSMenu.didEndTrackingNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuEndedAt = ProcessInfo.processInfo.systemUptime
                self.menuTracking = max(0,self.menuTracking-1)
                if self.menuTracking == 0, self.dismissAfterMenu { self.dismissPalette() }
            }
        })
        paletteObservers.append(center.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestDismiss() }
        })
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown,.rightMouseDown,.otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching:clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestDismiss() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:clicks.union(.keyDown)) { [weak self, weak panel] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let panel, panel.isVisible, self.menuTracking == 0 else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
                        // A native menu can return its already-consumed cancel event to the panel.
                        guard event.timestamp > self.menuEndedAt else { return true }
                        self.dismissPalette(panel); return true
                    }
                } else if event.window !== panel { self.dismissPalette(panel) }
                return false
            }
            return handled ? nil : event
        }
    }
    func show(_ target: LiveWindow, anchor: CGRect?) {
        guard !model.busy, !model.paused else { return }
        dismissPalette()
        let screen = model.desktop(for: target.frame) ?? Desktop.all.first
        guard let screen else { return }
        let panel = PalettePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isMovable = true; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        let dismiss = { [weak self, weak panel] in if let panel { self?.dismissPalette(panel) } }
        panel.dismiss = { [weak self, weak panel] in
            guard let self, let panel, self.menuTracking == 0 else { return }
            if let event = NSApp.currentEvent, event.type == .keyDown, event.timestamp <= self.menuEndedAt { return }
            self.dismissPalette(panel)
        }
        let view = PaletteView(model: model, target: target, close: dismiss, edit: { [weak self] in self?.showEditor() })
        let available = screen.visible.insetBy(dx: 8, dy: 8)
        // Keyboard invocation anchors to the target titlebar; hover uses the real green button.
        let attachment = anchor ?? CGRect(x:target.frame.minX+40,y:target.frame.minY+8,width:14,height:14)
        let height = min(CGFloat(540), available.height)
        let below = available.maxY - attachment.maxY
        let above = attachment.minY - available.minY
        let pointsUp = below >= height || below >= above
        let initial = CGRect(x:attachment.midX-44,
                             y:pointsUp ? attachment.maxY+3 : attachment.minY-height-3,
                             width:min(CGFloat(380),available.width),height:height)
        let frame = DisplayGeometry.clampPanel(initial, to: available)
        let host = NSHostingView(rootView:view)
        panel.contentView = PaletteChrome(content:host,pointsUp:pointsUp,pointerX:attachment.midX-frame.minX)
        panel.setFrame(DisplayGeometry.flip(frame, primaryHeight: Double(NSScreen.screens.first?.frame.height ?? 0)), display: true)
        palette = panel; monitor(panel)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                panel.animator().alphaValue = 1
            }
        }
        Task { await model.refresh(focused: target) }
    }
    func showPreferences() {
        dismissPalette()
        if let preferences {
            if preferences.isMiniaturized { preferences.deminiaturize(nil) }
            preferences.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "窗合 PaneFlow"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView(model: model, edit: { [weak self] in self?.showEditor() }))
        window.center(); window.makeKeyAndOrderFront(nil); preferences = window; NSApp.activate(ignoringOtherApps: true)
    }
    func showEditor() {
        dismissPalette()
        var draft = model.layout; draft.id = UUID().uuidString; draft.name = "我的布局"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "自定义布局"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LayoutEditorView(model: model, draft: draft, close: { [weak window] in window?.close() }))
        window.center(); window.makeKeyAndOrderFront(nil); editor = window; NSApp.activate(ignoringOtherApps: true)
    }
}
