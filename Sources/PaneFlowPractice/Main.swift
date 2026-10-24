import AppKit

final class PracticeDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        for index in 0..<3 {
            let window = NSWindow(contentRect: NSRect(x: 140 + index*100, y: 180 + index*60, width: 440, height: 300), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = ["窗合练习 · 阅读", "窗合练习 · 编辑", "窗合练习 · 备忘"][index]
            window.minSize = NSSize(width: CommandLine.arguments.contains("--constrained") && index == 1 ? 900 : 160, height: 140)
            window.isReleasedWhenClosed = false
            let text = NSTextField(wrappingLabelWithString: ["阅读窗口\n\n试着把它和编辑窗口上下排列，再拖动中间的灰色分隔条。", "编辑窗口\n\n拖动标题栏靠近其他窗口，体验磁吸。按住 ⌃ 可临时跳过。", "备忘窗口\n\n按住 ⌥ 拖动标题栏，预览布局分区，松手放入或交换。"][index])
            text.font = .systemFont(ofSize: 18); text.textColor = .labelColor
            text.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView(); content.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28), text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), text.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
            window.contentView = content; window.makeKeyAndOrderFront(nil); windows.append(window)
        }
        let main = NSMenu(); let app = NSMenuItem(); let menu = NSMenu()
        menu.addItem(withTitle: "退出练习窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); app.submenu = menu; main.addItem(app); NSApp.mainMenu = main
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main enum PracticeMain {
    @MainActor static func main() { let app = NSApplication.shared; let delegate = PracticeDelegate(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } }
}
