import AppKit
import ApplicationServices
import PaneFlowCore

struct WindowApp: Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String
    @MainActor static var running: [WindowApp] {
        NSWorkspace.shared.runningApplications.compactMap {
            guard $0.activationPolicy == .regular, !$0.isHidden, !$0.isTerminated,
                  $0.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return .init(pid: $0.processIdentifier, name: $0.localizedName ?? "应用", bundleID: $0.bundleIdentifier ?? "")
        }
    }
}
struct LiveWindow: Identifiable, @unchecked Sendable {
    var id: String
    var element: AXUIElement
    var app: WindowApp
    var title: String
    var frame: CGRect
    var label: String { app.name + (title.isEmpty ? "" : " · " + title) }
}
struct WindowMove: @unchecked Sendable { var window: LiveWindow; var frame: CGRect }
typealias WindowSurface = (id: Int, pid: pid_t, frame: CGRect, layer: Int)
struct AccessReport: @unchecked Sendable {
    var succeeded: Bool
    var message: String
    var originals: [WindowMove] = []
    var actual: [String: CGRect] = [:]
    var minimums: [String: CGSize] = [:]
    var rollbackFailed: Set<String> = []
    var warning: String?
}

final class WindowAccess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.paneflow.accessibility", qos: .userInitiated)
    private var known: [LiveWindow] = []
    private let lock = NSLock()
    private var pending: (epoch: Int, moves: [WindowMove])?
    private var draining = false
    private var previewEpoch = 0
    private var stages: [String: FramePreview] = [:]
    private var stagesEpoch = -1
    // Access only on queue. A drag owns this temporary scope until commit or cancellation.
    private var enhancedToRestore: [pid_t: AXUIElement] = [:]
    private var responsiveApps = Set<pid_t>()
    static var trusted: Bool { AXIsProcessTrusted() }

    @MainActor static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = value(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let result = CGRect(origin: point, size: dimensions)
        return FrameSettler.matches(result, result) ? result : nil
    }
    static func eligible(_ element: AXUIElement) -> Bool {
        var size: DarwinBoolean = false, position: DarwinBoolean = false
        guard value(element, kAXRoleAttribute) as? String == kAXWindowRole,
              value(element, kAXMinimizedAttribute) as? Bool != true,
              value(element, "AXFullScreen") as? Bool != true,
              value(element, kAXSubroleAttribute) as? String != kAXDialogSubrole,
              AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &size) == .success, size.boolValue,
              AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &position) == .success, position.boolValue else { return false }
        return true
    }
    private func identify(_ element: AXUIElement, app: WindowApp) -> LiveWindow? {
        guard Self.eligible(element), let frame = Self.frame(element) else { return nil }
        let old = known.first { $0.app.pid == app.pid && CFEqual($0.element, element) }
        let window = LiveWindow(id: old?.id ?? UUID().uuidString, element: element, app: app,
                                title: Self.value(element, kAXTitleAttribute) as? String ?? "", frame: frame)
        if let index = known.firstIndex(where: { $0.id == window.id }) { known[index] = window } else { known.append(window) }
        return window
    }
    static func visibleWindows() -> [WindowSurface] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap {
            guard ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = $0[kCGWindowNumber as String] as? Int,
                  let pid = $0[kCGWindowOwnerPID as String] as? Int32,
                  let raw = $0[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: raw) else { return nil }
            return (id, pid, frame, $0[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
    private static func dockSurfaces(in surfaces: [WindowSurface]) -> Set<Int> {
        let candidates = surfaces.filter { $0.layer == CGWindowLevelForKey(.dockWindow) && NSRunningApplication(processIdentifier:$0.pid)?.bundleIdentifier == "com.apple.dock" }
        guard !candidates.isEmpty else { return [] }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0,nil,&count) == .success else { return [] }
        var displays = [CGDirectDisplayID](repeating:0,count:Int(count))
        guard CGGetActiveDisplayList(count,&displays,&count) == .success else { return [] }
        return Set(candidates.filter { surface in displays.prefix(Int(count)).contains { FrameSettler.matches(CGDisplayBounds($0),surface.frame) } }.map(\.id))
    }
    private static func surfaceIndex(at point: CGPoint, in surfaces: [WindowSurface], dock: Set<Int>) -> Int? {
        guard let top = surfaces.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
        guard dock.contains(surfaces[top].id) else { return top }
        // Dock can publish a screen-sized surface. Confirm the actual hit at this point;
        // its bounding rectangle alone cannot distinguish a backdrop from system UI.
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system,0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit,&pid) == .success, pid != ProcessInfo.processInfo.processIdentifier,
              let window = value(hit,kAXRoleAttribute) as? String == kAXWindowRole ? hit : element(hit,kAXWindowAttribute),
              let frame = frame(window),
              let index = surfaces.firstIndex(where: { !dock.contains($0.id) && $0.frame.contains(point) }),
              surfaces[index].pid == pid, FrameSettler.matches(surfaces[index].frame,frame) else { return nil }
        return index
    }
    func exposedLinks(_ links: [LayoutLink], panes: [String:CGRect], members: [String:LiveWindow], surfaces: [WindowSurface]) async -> Set<Int> {
        await withCheckedContinuation { continuation in
            queue.async {
                let dock = Self.dockSurfaces(in:surfaces)
                func exposed(_ point: CGPoint, slot: String) -> Int? {
                    guard let member = members[slot], let expected = panes[slot],
                          let index = Self.surfaceIndex(at:point,in:surfaces,dock:dock) else { return nil }
                    let top = surfaces[index]
                    return top.layer == 0 && top.pid == member.app.pid && FrameSettler.matches(top.frame,expected) ? index : nil
                }
                var result = Set<Int>()
                for (index,link) in links.enumerated() {
                    guard let first = exposed(link.firstProbe,slot:link.first), let second = exposed(link.secondProbe,slot:link.second) else { continue }
                    let members = [surfaces[first].id,surfaces[second].id]
                    let covered = surfaces.prefix(max(first,second)).contains { !members.contains($0.id) && !dock.contains($0.id) && $0.frame.intersects(link.frame) }
                    if !covered { result.insert(index) }
                }
                continuation.resume(returning:result)
            }
        }
    }
    func scan(_ apps: [WindowApp]) async -> [LiveWindow] {
        await withCheckedContinuation { continuation in
            queue.async {
                guard Self.trusted else { continuation.resume(returning: []); return }
                let visible = Self.visibleWindows()
                var result: [LiveWindow] = []
                for app in apps.prefix(128) {
                    let application = AXUIElementCreateApplication(app.pid)
                    AXUIElementSetMessagingTimeout(application, 0.12)
                    for element in (Self.value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(128) {
                        AXUIElementSetMessagingTimeout(element, 0.12)
                        guard let frame = Self.frame(element), visible.contains(where: { $0.pid == app.pid && $0.layer == 0 && FrameSettler.matches($0.frame, frame) }),
                              let window = self.identify(element, app: app) else { continue }
                        result.append(window)
                    }
                }
                self.known = result
                continuation.resume(returning: result)
            }
        }
    }
    func focused(_ app: WindowApp) async -> LiveWindow? {
        await withCheckedContinuation { continuation in
            queue.async {
                let application = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(application, 0.12)
                guard Self.trusted, let element = Self.element(application, kAXFocusedWindowAttribute) else { continuation.resume(returning: nil); return }
                continuation.resume(returning: self.identify(element, app: app))
            }
        }
    }
    func hit(_ point: CGPoint, apps: [WindowApp], zoomOnly: Bool = false) async -> (LiveWindow, CGRect?)? {
        await withCheckedContinuation { continuation in
            queue.async {
                let surfaces = Self.visibleWindows()
                guard Self.trusted, let index = Self.surfaceIndex(at:point,in:surfaces,dock:Self.dockSurfaces(in:surfaces)),
                      surfaces[index].layer == 0, let app = apps.first(where: { $0.pid == surfaces[index].pid }) else { continuation.resume(returning: nil); return }
                let application = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(application, 0.1)
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success, let hit else { continuation.resume(returning: nil); return }
                let target = Self.value(hit, kAXRoleAttribute) as? String == kAXWindowRole ? hit : Self.element(hit, kAXWindowAttribute)
                guard let target, let window = self.identify(target, app: app) else { continuation.resume(returning: nil); return }
                let zoom = Self.element(target, kAXZoomButtonAttribute).flatMap { Self.frame($0) }
                if zoomOnly && zoom?.insetBy(dx: -2, dy: -2).contains(point) != true { continuation.resume(returning: nil); return }
                continuation.resume(returning: (window, zoom))
            }
        }
    }
    func read(_ windows: [LiveWindow]) async -> [String: CGRect] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Dictionary(uniqueKeysWithValues: windows.compactMap { window in Self.frame(window.element).map { (window.id, $0) } })) }
        }
    }
    private static func position(_ point: CGPoint, of window: LiveWindow) -> FrameWriteStatus {
        var value = point
        guard let object = AXValueCreate(.cgPoint, &value) else { return .unavailable }
        return outcome(AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, object))
    }
    private static func size(_ size: CGSize, of window: LiveWindow) -> FrameWriteStatus {
        var value = size
        guard let object = AXValueCreate(.cgSize, &value) else { return .unavailable }
        return outcome(AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, object))
    }
    private static func outcome(_ error: AXError) -> FrameWriteStatus {
        error == .success ? .accepted : error == .cannotComplete ? .retryable : .unavailable
    }
    @MainActor private static var maySuspendEnhancedUI: Bool {
        !NSWorkspace.shared.isVoiceOverEnabled && !NSWorkspace.shared.isSwitchControlEnabled
    }
    private func prepareAdjustment(_ windows: [LiveWindow], suspendEnhancedUI: Bool) -> [pid_t: AXUIElement] {
        var restore: [pid_t: AXUIElement] = [:]
        var seen = Set<pid_t>()
        for window in windows where seen.insert(window.app.pid).inserted {
            let app = AXUIElementCreateApplication(window.app.pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
            let original = Self.value(app, "AXEnhancedUserInterface") as? Bool
            // These verified applications can animate each AX write independently. Preserve their original mode.
            if original == true, suspendEnhancedUI, ["com.microsoft.edgemac", "app.paneflow.practice"].contains(window.app.bundleID) {
                restore[window.app.pid] = app
                _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
            // A setter can report an error even when the attribute changed; read it back.
            if original == false || Self.value(app, "AXEnhancedUserInterface") as? Bool == false {
                responsiveApps.insert(window.app.pid)
            }
        }
        return restore
    }
    private func restoreEnhancedUI(_ apps: [pid_t: AXUIElement]) -> [pid_t: AXUIElement] {
        var unresolved: [pid_t: AXUIElement] = [:]
        for (pid, app) in apps {
            var restored = false
            for _ in 0..<2 {
                _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                if Self.value(app, "AXEnhancedUserInterface") as? Bool == true { restored = true; break }
            }
            if !restored { unresolved[pid] = app }
        }
        return unresolved
    }
    @MainActor func beginInteractiveAdjustment(_ windows: [LiveWindow]) {
        let suspend = Self.maySuspendEnhancedUI
        queue.async {
            self.enhancedToRestore = self.restoreEnhancedUI(self.enhancedToRestore)
            self.responsiveApps = []
            self.enhancedToRestore.merge(self.prepareAdjustment(windows, suspendEnhancedUI: suspend)) { old, _ in old }
        }
    }
    func endInteractiveAdjustment(completion: (@Sendable (Bool) -> Void)? = nil) {
        queue.async {
            self.enhancedToRestore = self.restoreEnhancedUI(self.enhancedToRestore)
            self.responsiveApps = []
            completion?(self.enhancedToRestore.isEmpty)
        }
    }
    func shutdown() {
        cancelPreviews()
        queue.sync {
            self.enhancedToRestore = self.restoreEnhancedUI(self.enhancedToRestore)
            self.responsiveApps = []
        }
    }
    func preview(_ moves: [WindowMove]) {
        lock.lock(); pending = (previewEpoch, moves)
        if draining { lock.unlock(); return }
        draining = true; lock.unlock()
        queue.async {
            while true {
                self.lock.lock(); let next = self.pending; self.pending = nil
                if next == nil { self.draining = false }
                self.lock.unlock()
                guard let next else { break }
                if self.stagesEpoch != next.epoch { self.stages = [:]; self.stagesEpoch = next.epoch }
                for move in next.moves {
                    self.lock.lock(); let valid = self.previewEpoch == next.epoch; self.lock.unlock()
                    guard valid else { break }
                    guard Self.eligible(move.window.element) else { continue }
                    let responsive = self.responsiveApps.contains(move.window.app.pid)
                    var stage = self.stages[move.window.id] ?? FramePreview(settleInterval: responsive ? 0 : 0.08)
                    // Advance the second axis immediately only after the first write is acknowledged.
                    for _ in 0..<(responsive ? 2 : 1) {
                        guard let actual = Self.frame(move.window.element) else { break }
                        let command = stage.next(actual: actual, target: move.frame, now: ProcessInfo.processInfo.systemUptime)
                        self.lock.lock(); let stillValid = self.previewEpoch == next.epoch; self.lock.unlock()
                        guard stillValid, let command else { break }
                        switch command {
                        case .position(let point): _ = Self.position(point, of: move.window)
                        case .size(let size): _ = Self.size(size, of: move.window)
                        }
                    }
                    self.stages[move.window.id] = stage
                }
            }
        }
    }
    func cancelPreviews() { lock.lock(); pending = nil; previewEpoch += 1; lock.unlock() }
    func apply(_ moves: [WindowMove], baseline: [WindowMove] = []) async -> AccessReport {
        cancelPreviews()
        let suspend = await MainActor.run { Self.maySuspendEnhancedUI }
        return await withCheckedContinuation { continuation in
            queue.async {
                let previousResponsiveApps = self.responsiveApps
                let restore = self.prepareAdjustment(moves.map(\.window), suspendEnhancedUI: suspend)
                var report = self.perform(moves, baseline: baseline)
                let unresolved = self.restoreEnhancedUI(restore)
                self.enhancedToRestore.merge(unresolved) { old, _ in old }
                self.responsiveApps = previousResponsiveApps
                if !unresolved.isEmpty { report.warning = "应用的辅助功能模式尚未确认恢复；请退出并重新打开相关应用。" }
                continuation.resume(returning: report)
            }
        }
    }
    private func adjust(_ move: WindowMove, deadline: TimeInterval) -> FrameAdjustment {
        WindowFrameDriver.adjust(to: move.frame, read: { Self.frame(move.window.element) },
                                 setPosition: { Self.position($0, of: move.window) }, setSize: { Self.size($0, of: move.window) },
                                 now: { ProcessInfo.processInfo.systemUptime }, wait: { Thread.sleep(forTimeInterval: $0) },
                                 shouldStop: { ProcessInfo.processInfo.systemUptime >= deadline })
    }
    private func perform(_ moves: [WindowMove], baseline: [WindowMove]) -> AccessReport {
        guard Self.trusted else { return .init(succeeded: false, message: "请先在系统设置中允许“窗合”的辅助功能权限。", rollbackFailed:Set(baseline.map { $0.window.id })) }
        guard !moves.isEmpty, Set(moves.map { $0.window.id }).count == moves.count else { return preflightFailure("窗口选择无效，请刷新后重试。",baseline:baseline) }
        var originals: [WindowMove] = []
        for move in moves {
            guard Self.eligible(move.window.element), let frame = Self.frame(move.window.element), FrameSettler.matches(move.frame, move.frame) else { return preflightFailure("窗口已关闭或不能调整。",baseline:baseline) }
            originals.append(.init(window: move.window, frame: baseline.first(where: { $0.window.id == move.window.id })?.frame ?? frame))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + min(40, 8 + Double(moves.count) * 4)
        var actual: [String: CGRect] = [:], minimums: [String: CGSize] = [:]
        var failure: String?
        for move in moves {
            let result = adjust(move, deadline: deadline)
            if let frame = result.actual { actual[move.window.id] = frame }
            if let minimum = result.constrainedMinimum { minimums[move.window.id] = minimum }
            if !result.reachedTarget { failure = "\(move.window.app.name) 未能达到目标尺寸或位置。"; break }
        }
        if failure == nil {
            Thread.sleep(forTimeInterval: 0.12)
            for move in moves {
                guard let frame = Self.frame(move.window.element), FrameSettler.matches(frame, move.frame) else { failure = "应用在调整后又改变了窗口位置。"; break }
                actual[move.window.id] = frame
            }
        }
        if let failure {
            let failed = restore(originals)
            return .init(succeeded: false, message: failure + (failed.isEmpty ? " 已恢复之前的位置。" : " 部分窗口无法恢复，已解除相关联动。"), originals: originals, actual: actual, minimums: minimums, rollbackFailed: failed)
        }
        return .init(succeeded: true, message: "已调整 \(moves.count) 个窗口。", originals: originals, actual: actual)
    }
    private func restore(_ originals: [WindowMove]) -> Set<String> {
        var failed = Set<String>()
        for original in originals {
            guard Self.eligible(original.window.element), Self.frame(original.window.element) != nil else { failed.insert(original.window.id); continue }
            if !adjust(original, deadline: ProcessInfo.processInfo.systemUptime + 6).reachedTarget { failed.insert(original.window.id) }
        }
        for original in originals {
            if Self.frame(original.window.element).map({ FrameSettler.matches($0, original.frame) }) != true { failed.insert(original.window.id) }
        }
        return failed
    }
    private func preflightFailure(_ message:String, baseline:[WindowMove]) -> AccessReport {
        let failed = restore(baseline)
        return .init(succeeded:false,message:message + (baseline.isEmpty ? " 请刷新后重试。" : failed.isEmpty ? " 已恢复拖动前的位置。" : " 可恢复窗口已还原，失效窗口已解除关联。"),originals:baseline,rollbackFailed:failed)
    }
}
