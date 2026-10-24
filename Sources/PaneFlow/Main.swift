import AppKit
import Carbon

final class GlobalShortcut {
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var trigger: (() -> Void)?
    func start() -> String? {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { owner.trigger?() }; return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return "全局快捷键无法启动，请使用菜单栏入口。" }
        let identifier = EventHotKeyID(signature: 0x50464C57, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &key)
        return result == noErr ? nil : "⌃⌥ Space 已被占用，请从菜单栏打开窗合，或调整其他软件的快捷键。"
    }
    deinit { if let key { UnregisterEventHotKey(key) }; if let handler { RemoveEventHandler(handler) } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model: AppModel
    let panels: PanelCoordinator
    let overlays: OverlayCoordinator
    let gestures: GestureController
    private let shortcut = GlobalShortcut()
    private var status: NSStatusItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    init(ephemeral: Bool) {
        let model = AppModel(ephemeral: ephemeral)
        self.model = model; panels = PanelCoordinator(model: model); overlays = OverlayCoordinator(model: model)
        gestures = GestureController(model: model, overlays: overlays)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Verification.previewLayouts {
            let menu = NSMenu(), item = NSMenuItem(), application = NSMenu()
            application.addItem(withTitle:"退出窗合",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = application; menu.addItem(item); NSApp.mainMenu = menu
            panels.showLayoutManager(); return
        }
        if Verification.requested {
            Task { await Verification.run(delegate: self) }; return
        }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = PaneFlowBrand.image(size:18,template:true)
        status.button?.toolTip = "窗合 PaneFlow"; self.status = status
        let menu = NSMenu(); menu.delegate = self
        for (title, selector, key) in [("打开布局面板", #selector(openPalette), ""), ("布局管理…", #selector(openEditor), ""),
                                       ("设置…", #selector(openSettings), ","), ("打开练习窗口", #selector(openPractice), ""),
                                       ("撤销窗口操作", #selector(undo), ""), ("暂停窗口管理", #selector(pause), "")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出窗合", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(quit)
        status.menu = menu
        let mainMenu = NSMenu(), applicationItem = NSMenuItem(), applicationMenu = NSMenu()
        let settingsMain = NSMenuItem(title:"设置…",action:#selector(openSettings),keyEquivalent:","); settingsMain.target = self
        applicationMenu.addItem(settingsMain); applicationMenu.addItem(.separator())
        let quitMain = NSMenuItem(title:"退出窗合",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        applicationMenu.addItem(quitMain); applicationItem.submenu = applicationMenu; mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title:"编辑")
        for (title, action, key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {
            editMenu.addItem(withTitle:title,action:action,keyEquivalent:key)
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        connectControllers()
        shortcut.trigger = { [weak self] in self?.panels.toggleFocused() }
        if let error = shortcut.start() { model.notice = error }
        gestures.start()
        Task { await model.refresh() }
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.overlays.requestUpdate() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.activeSpaceDidChangeNotification || NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        self.panels.dismissPalette()
                    }
                    self.overlays.requestUpdate(invalidate:true)
                    if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular {
                        self.model.lastExternalApp = .init(pid: app.processIdentifier, name: app.localizedName ?? "应用", bundleID: app.bundleIdentifier ?? "")
                    }
                }
            })
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier, front.activationPolicy == .regular {
            model.lastExternalApp = .init(pid:front.processIdentifier,name:front.localizedName ?? "应用",bundleID:front.bundleIdentifier ?? "")
        }
        panels.showPreferences()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !Verification.requested else { return false }
        panels.showPreferences()
        return false
    }
    func connectControllers() {
        model.onGroupsChanged = { [weak overlays] in overlays?.requestUpdate(invalidate:true) }
        model.onOpenPalette = { [weak panels] in panels?.openFocused() }
        gestures.openPalette = { [weak panels] window, anchor in panels?.show(window, anchor: anchor) }
        gestures.paletteContains = { [weak panels] point in panels?.contains(point) ?? false }
        panels.onDismiss = { [weak gestures] in gestures?.suppressCurrentHover() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard panels.hasUnsavedLayouts else { return .terminateNow }
        panels.confirmLayoutChanges { sender.reply(toApplicationShouldTerminate:$0) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { panels.dismissPalette(); gestures.stop(); model.access.shutdown(); overlays.stop(); timer?.invalidate(); observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first { $0.action == #selector(pause) }?.title = model.paused ? "继续窗口管理" : "暂停窗口管理"
        menu.items.first { $0.action == #selector(undo) }?.isEnabled = model.undoCount > 0 && !model.busy
    }
    @objc func openPalette() { panels.openFocused() }
    @objc func openEditor() { panels.showLayoutManager() }
    @objc func openSettings() { panels.showPreferences() }
    @objc func openPractice() { model.openPractice() }
    @objc func undo() { model.undo() }
    @objc func pause() { model.paused.toggle(); if model.paused { gestures.cancelInteraction(); overlays.stop() } else { Task { await model.refresh() } } }
}

@main enum PaneFlowMain {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of:"--export-icons") {
            guard CommandLine.arguments.indices.contains(index+1) else { fputs("Missing iconset output path\n",stderr); exit(2) }
            do { try PaneFlowBrand.exportIconset(to:URL(fileURLWithPath:CommandLine.arguments[index+1])); return }
            catch { fputs("Could not export app icon\n",stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(ephemeral: Verification.requested || Verification.previewLayouts)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
