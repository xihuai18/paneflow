import AppKit
import SwiftUI
import PaneFlowCore
import ColorSync

struct Preferences: Codable {
    var version = 4
    var activeLayout = "wide"
    var customLayouts: [LayoutPreset] = []
    var gap: Double = 0
    var margin: Double = 10
    var magnetEnabled = true
    var linkedEnabled = true
    var zonesEnabled = true
    var hoverEnabled = true
}
struct Desktop: Identifiable {
    var id: String
    var name: String
    var frame: CGRect
    var visible: CGRect
    var scale: Double
    @MainActor static var all: [Desktop] {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil,$0) as String } ?? "display-\(number)"
            return .init(id:id,name:screen.localizedName,frame:DisplayGeometry.flip(screen.frame,primaryHeight:primary),
                         visible:DisplayGeometry.flip(screen.visibleFrame,primaryHeight:primary),scale:screen.backingScaleFactor)
        }
    }
}
struct WindowGroup {
    var id = UUID().uuidString
    var preset: LayoutPreset
    var bounds: CGRect
    var screenID: String
    var scale: Double
    var gap: Double
    var members: [String: LiveWindow]
    var windows: [LiveWindow] { Array(members.values) }
    func geometry(minimums: [String: CGSize] = [:]) throws -> LayoutGeometry {
        try LayoutGeometry.make(preset.root, in: bounds, gap: gap, scale: scale, minimums: minimums)
    }
    func moves(minimums: [String: CGSize] = [:]) throws -> [WindowMove] {
        let geometry = try geometry(minimums: minimums)
        return preset.windowPanes.compactMap { slot in
            guard let window = members[slot], let frame = geometry.panes[slot] else { return nil }
            return .init(window: window, frame: frame)
        }
    }
}
struct UndoEntry { var frames: [WindowMove]; var groups: [WindowGroup] }

@MainActor final class AppModel: ObservableObject {
    @Published var preferences = Preferences() { didSet { if !storingPreferences { persist() } } }
    @Published var windows: [LiveWindow] = []
    @Published var selectedIDs = Set<String>()
    @Published var groups: [WindowGroup] = []
    static let initialNotice = "按住 ⌥ 悬停绿按钮，或按 ⌃⌥ Space 选择布局。"
    @Published var notice = AppModel.initialNotice
    @Published var busy = false
    @Published var paused = false
    @Published var trusted = WindowAccess.trusted
    @Published var undoCount = 0
    @Published var linkStatus = "尚未建立联动布局"
    @Published var linkHint = "在布局面板勾选多个窗口，点击“排列并联动”。"
    @Published var visibleLinkCount = 0
    let access = WindowAccess()
    var lastExternalApp: WindowApp?
    var minimums: [String: CGSize] = [:]
    var onGroupsChanged: (() -> Void)?
    var onOpenPalette: (() -> Void)?
    private var history: [UndoEntry] = []
    private var scanGeneration = 0
    private let storage: URL?
    private var canPersist = true
    private var storingPreferences = false
    var layouts: [LayoutPreset] { LayoutPreset.builtins + preferences.customLayouts }
    var layout: LayoutPreset { layouts.first { $0.id == preferences.activeLayout } ?? LayoutPreset.builtins[2] }

    init(ephemeral: Bool = false, storageURL: URL? = nil) {
        storage = ephemeral ? nil : storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("PaneFlow/preferences.json")
        guard let storage, FileManager.default.fileExists(atPath: storage.path) else { return }
        do {
            var value = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: storage))
            guard (1...4).contains(value.version), value.customLayouts.count <= 100,
                  value.gap.isFinite, (0...40).contains(value.gap), value.margin.isFinite, (0...80).contains(value.margin),
                  Set(value.customLayouts.map(\.id)).count == value.customLayouts.count else { throw LayoutError.invalid }
            for item in value.customLayouts { try item.validate(); guard !item.name.isEmpty, item.name.count <= 80 else { throw LayoutError.invalid } }
            if value.version < 4 {
                let backup = storage.appendingPathExtension("backup-before-window-capture-v4")
                if !FileManager.default.fileExists(atPath:backup.path) { try FileManager.default.copyItem(at:storage,to:backup) }
                value.version = 4
            }
            preferences = value
        } catch { canPersist = false; notice = "设置文件无法读取，已保留原文件。请在设置中备份并重置后保存。" }
    }
    private func writePreferences(_ value: Preferences) throws {
        guard canPersist else { throw NSError(domain:"PaneFlowSettings",code:1,userInfo:[NSLocalizedDescriptionKey:"原设置无法读取，请先在设置中备份并重置。"] ) }
        guard let storage else { return }
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: storage, options: .atomic)
    }
    private func persist() {
        do { try writePreferences(preferences) }
        catch { notice = "设置未能保存：\(error.localizedDescription)" }
    }
    private func storePreferences(_ value: Preferences) -> Bool {
        do {
            try writePreferences(value)
            storingPreferences = true; preferences = value; storingPreferences = false
            return true
        } catch { notice = "设置未能保存：\(error.localizedDescription)"; return false }
    }
    func backupAndResetSettings() {
        guard let storage else { return }
        do {
            if FileManager.default.fileExists(atPath: storage.path) {
                try FileManager.default.copyItem(at: storage, to: storage.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))"))
            }
            canPersist = true; preferences = Preferences(); notice = "已备份原设置，并恢复默认设置。"
        } catch { notice = "备份失败，原设置保持不变。" }
    }
    func refresh(focused: LiveWindow? = nil) async {
        trusted = WindowAccess.trusted
        scanGeneration += 1
        let generation = scanGeneration
        let result = await access.scan(WindowApp.running)
        guard generation == scanGeneration, !busy else { return }
        windows = result
        if let focused, !windows.contains(where: { $0.id == focused.id }) { windows.insert(focused, at: 0) }
        selectedIDs.formIntersection(Set(windows.map(\.id)))
        if selectedIDs.isEmpty, let focused { selectedIDs.insert(focused.id) }
        let live = Dictionary(windows.map { ($0.id,$0.frame) },uniquingKeysWith:{first,_ in first})
        for index in groups.indices {
            let geometry = try? groups[index].geometry()
            groups[index].members = groups[index].members.filter { slot,member in
                guard let actual=live[member.id],let expected=geometry?.panes[slot] else { return false }
                return FrameSettler.matches(actual,expected)
            }
        }
        groups.removeAll { $0.members.isEmpty }
        onGroupsChanged?()
    }
    func invalidateScan() { scanGeneration += 1 }
    func focusedWindow() async -> LiveWindow? {
        let front = NSWorkspace.shared.frontmostApplication
        let app: WindowApp?
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier, front.activationPolicy == .regular {
            app = .init(pid: front.processIdentifier, name: front.localizedName ?? "应用", bundleID: front.bundleIdentifier ?? "")
            lastExternalApp = app
        } else { app = lastExternalApp }
        guard let app else { return nil }
        return await access.focused(app)
    }
    func desktop(for frame: CGRect) -> Desktop? {
        Desktop.all.max { a, b in a.frame.intersection(frame).area < b.frame.intersection(frame).area }
    }
    func makeGroup(layout: LayoutPreset, desktop: Desktop) -> WindowGroup {
        let margin = layout.capturedSpacing ? 0 : preferences.margin
        return .init(preset: layout, bounds: desktop.visible.insetBy(dx:margin,dy:margin), screenID: desktop.id,
                     scale: desktop.scale, gap: layout.capturedSpacing ? 0 : preferences.gap, members: [:])
    }
    func layoutGroups(_ preset: LayoutPreset, on desktops: [Desktop], fallback: Desktop?, reusingExisting: Bool = false) throws -> [WindowGroup] {
        let targets: [Desktop]
        if preset.screens.isEmpty {
            guard let fallback else { throw LayoutError.invalid }
            targets = [fallback]
        } else {
            targets = try preset.screens.map { config in
                guard let screen = desktops.first(where:{$0.id == config.id}) else {
                    throw NSError(domain:"PaneFlowDisplay",code:1,userInfo:[NSLocalizedDescriptionKey:"“\(config.name)”未连接，请连接它或在布局管理中取消选择。"])
                }
                return screen
            }
        }
        return targets.compactMap { screen in
            guard let value = preset.onScreen(screen.id) else { return nil }
            let target = makeGroup(layout:value,desktop:screen)
            if reusingExisting, let group = groups.last(where:{$0.screenID == screen.id && $0.preset.id == value.id && $0.preset.root == value.root && $0.preset.emptyPanes == value.emptyPanes && $0.gap == target.gap && $0.bounds == target.bounds}) { return group }
            return target
        }
    }
    func destinations(for frame: CGRect) throws -> [WindowGroup] {
        try layoutGroups(layout,on:Desktop.all,fallback:desktop(for:frame),reusingExisting:true)
    }
    func dropDestination(at point: CGPoint) -> WindowGroup? {
        guard let screen = Desktop.all.first(where:{$0.frame.contains(point)}), let value = layout.onScreen(screen.id) else { return nil }
        let target = makeGroup(layout:value,desktop:screen)
        return groups.last(where:{$0.screenID == screen.id && $0.preset.id == value.id && $0.preset.root == value.root && $0.preset.emptyPanes == value.emptyPanes && $0.gap == target.gap && $0.bounds == target.bounds}) ?? target
    }
    func group(containing window: LiveWindow) -> WindowGroup? { groups.first { $0.windows.contains(where: { $0.id == window.id }) } }
    func leafMinimums(_ group: WindowGroup) -> [String: CGSize] {
        Dictionary(uniqueKeysWithValues: group.members.map { ($0.key, minimums[$0.value.id] ?? CGSize(width: 64, height: 64)) })
    }
    func without(_ ids: Set<String>, from source: [WindowGroup]) -> [WindowGroup] {
        source.compactMap { value in
            var copy = value; copy.members = copy.members.filter { !ids.contains($0.value.id) }
            return copy.members.isEmpty ? nil : copy
        }
    }
    var windowGroups: [WindowAppGroup] {
        var result: [WindowAppGroup] = []
        for window in windows {
            let id = window.app.bundleID.isEmpty ? "pid-\(window.app.pid)" : window.app.bundleID
            if let index = result.firstIndex(where:{$0.id == id}) { result[index].windows.append(window) }
            else { result.append(.init(id:id,app:window.app,windows:[window])) }
        }
        return result
    }
    var selectedWindows: [LiveWindow] { windowGroups.flatMap(\.windows).filter { selectedIDs.contains($0.id) } }
    func arrangeSelected(completion: ((Bool) -> Void)? = nil) {
        let selected = selectedWindows
        guard !selected.isEmpty, selected.count <= layout.windowCount, let first = selected.first else {
            notice = "请选择 1 到 \(layout.windowCount) 个窗口。"; completion?(false); return
        }
        do {
            var targets = try layoutGroups(layout,on:Desktop.all,fallback:desktop(for:first.frame))
            var index = 0
            for i in targets.indices {
                for slot in targets[i].preset.windowPanes where index < selected.count {
                    targets[i].members[slot] = selected[index]; index += 1
                }
            }
            targets = targets.filter { !$0.members.isEmpty }
            let next = without(Set(selected.map(\.id)), from:groups) + targets
            let moves = try targets.flatMap { try $0.moves() }
            let message = targets.count > 1 ? "已在 \(targets.count) 块显示器排列窗口，可一次撤销。" : (selected.count > 1 ? "已排列窗口，留白区域保持空置。相邻窗口可联动调整。" : "窗口已放入指定区域。")
            Task { let success = await commit(moves,groups:next,success:message); completion?(success) }
        } catch { notice = error.localizedDescription; completion?(false) }
    }
    @discardableResult func dropWindow(_ id: String, slot: String, screenID: String, fallback: CGRect, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !busy, !paused, trusted else { completion?(false); return false }
        guard let window = windows.first(where:{$0.id == id}) ?? groups.flatMap(\.windows).first(where:{$0.id == id}) else {
            notice = "窗口已关闭或不在列表中，请刷新后重试。"; completion?(false); return false
        }
        do {
            guard let destination = try destinations(for:fallback).first(where:{$0.screenID == screenID}), destination.preset.windowPanes.contains(slot) else {
                notice = "这个区域当前不可放置窗口。"; completion?(false); return false
            }
            guard destination.members[slot]?.id != id else { completion?(false); return false }
            place(window,slot:slot,in:destination,completion:completion); return true
        } catch { notice = error.localizedDescription; completion?(false); return false }
    }
    func place(_ window: LiveWindow, slot: String, in destination: WindowGroup, baseline: [WindowMove] = [], completion: ((Bool) -> Void)? = nil) {
        guard destination.preset.windowPanes.contains(slot) else { completion?(false); return }
        var target = destination
        let source = group(containing: window)
        let placement = SlotPlacement.placing(window.id, in: slot, assignments: target.members.mapValues(\.id))
        var lookup = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in groups + [destination] { for value in group.windows { lookup[value.id] = value } }
        lookup[window.id] = window
        target.members = placement.assignments.compactMapValues { lookup[$0] }
        var next = groups.filter { $0.id != target.id }
        var extra: [WindowMove] = []
        if let source, source.id != target.id, let sourceIndex = next.firstIndex(where: { $0.id == source.id }),
           let sourceSlot = source.members.first(where: { $0.value.id == window.id })?.key {
            next[sourceIndex].members.removeValue(forKey: sourceSlot)
            if let displaced = placement.displaced, let other = lookup[displaced] { next[sourceIndex].members[sourceSlot] = other }
            do { extra = try next[sourceIndex].moves() } catch { notice = error.localizedDescription; completion?(false); return }
        } else if let displaced = placement.displaced, let other = lookup[displaced] {
            extra = [.init(window: other, frame: window.frame)]
        }
        next = without([window.id], from: next)
        next.append(target)
        do {
            let moves = try target.moves() + extra
            Task { let success = await commit(moves, groups: next, baseline: baseline, success: placement.displaced == nil ? "窗口已放入分区。" : "窗口位置已交换。"); completion?(success) }
        } catch { notice = error.localizedDescription; completion?(false) }
    }
    func detach(_ window: LiveWindow) {
        guard !busy else { return }
        groups = without([window.id], from: groups); onGroupsChanged?()
    }
    @discardableResult func commit(_ moves: [WindowMove], groups next: [WindowGroup], baseline: [WindowMove]? = nil, success: String = "已完成。") async -> Bool {
        guard !busy, !paused else { return false }
        busy = true; scanGeneration += 1; onGroupsChanged?()
        let previousGroups = groups
        let report = await access.apply(moves, baseline: baseline ?? [])
        for (key, value) in report.minimums { minimums[key] = value }
        if report.succeeded {
            history.append(.init(frames: report.originals, groups: previousGroups))
            if history.count > 20 { history.removeFirst() }
            groups = next; notice = report.warning ?? success
            for index in windows.indices { if let frame = report.actual[windows[index].id] { windows[index].frame = frame } }
        } else {
            let failed = report.rollbackFailed
            groups = without(failed, from: previousGroups)
            notice = report.message + (report.warning.map { " " + $0 } ?? "")
            if !failed.isEmpty { notice += " 请手动确认这些窗口的位置。" }
        }
        undoCount = history.count; busy = false; onGroupsChanged?()
        return report.succeeded
    }
    func undo() {
        guard !busy, let entry = history.last else { return }
        Task {
            busy = true; scanGeneration += 1; onGroupsChanged?()
            let result = await access.apply(entry.frames)
            if result.succeeded {
                history.removeLast(); groups = entry.groups; notice = result.warning ?? "已撤销上一次窗口操作。"
                for index in windows.indices { if let frame = result.actual[windows[index].id] { windows[index].frame = frame } }
            }
            else { groups = without(result.rollbackFailed, from: groups); notice = result.message + (result.warning.map { " " + $0 } ?? "") }
            undoCount = history.count; busy = false; onGroupsChanged?()
        }
    }
    @discardableResult func saveLayout(_ value: LayoutPreset) -> Bool {
        do {
            var value = value
            value.name = value.name.trimmingCharacters(in:.whitespacesAndNewlines)
            try value.validate()
            guard !value.name.isEmpty, value.name.count <= 80,
                  !LayoutPreset.builtins.contains(where: { $0.id == value.id }) else { throw LayoutError.invalid }
            var next = preferences
            if let index = next.customLayouts.firstIndex(where: { $0.id == value.id }) { next.customLayouts[index] = value }
            else {
                guard next.customLayouts.count < 100 else { notice = "最多可保存 100 个自定义布局，请先删除不需要的布局。"; return false }
                next.customLayouts.append(value)
            }
            next.activeLayout = value.id
            guard storePreferences(next) else { return false }
            notice = "已保存“\(value.name)”。"; return true
        } catch { notice = error.localizedDescription; return false }
    }
    @discardableResult func deleteLayout(_ id: String) -> Bool {
        guard let index = preferences.customLayouts.firstIndex(where: { $0.id == id }) else { return false }
        var next = preferences
        let name = next.customLayouts.remove(at:index).name
        if next.activeLayout == id { next.activeLayout = next.customLayouts.first?.id ?? LayoutPreset.builtins[2].id }
        guard storePreferences(next) else { return false }
        notice = "已删除“\(name)”。现有窗口位置保持不变。"; return true
    }
    func openPractice() {
        guard let url = Bundle.main.url(forResource: "PaneFlow Practice", withExtension: "app") else { notice = "练习窗口未打包，请运行 scripts/build-app.sh。"; return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }
}
private extension CGRect { var area: Double { isNull ? 0 : width * height } }
