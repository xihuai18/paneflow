import AppKit
import PaneFlowCore

private struct MouseGesture {
    var window: LiveWindow
    var start: CGPoint
    var kind: String?
    var group: WindowGroup?
    var baseline: [WindowMove]
    var seam: LayoutSeam?
    var magnet: MagnetResult?
    var draft: WindowGroup?
    var lastFrame: CGRect
    var drop: (WindowGroup, String)?
    var obstacles: [LiveWindow] = []
}

@MainActor final class GestureController {
    let model: AppModel
    let overlays: OverlayCoordinator
    var openPalette: ((LiveWindow, CGRect?) -> Void)?
    var paletteContains: ((CGPoint) -> Bool)?
    private var monitor: Any?
    private var timer: Timer?
    private var generation = 0
    private var gesture: MouseGesture?
    private var down = false
    private var processing = false
    private var finishing = false
    private var latestPoint = CGPoint.zero
    private var latestFlags: NSEvent.ModifierFlags = []
    private var hoverPoint = CGPoint.zero
    private var hoverSince: TimeInterval = 0
    private var hoverOpened = false
    private var hoverBusy = false
    private var hoverGeneration = 0
    private var manual = false
    var hasActiveResize: Bool { manual && gesture != nil }

    init(model: AppModel, overlays: OverlayCoordinator) {
        self.model = model; self.overlays = overlays
        overlays.beginResize = { [weak self] group, seam, point in self?.beginManual(group, seam: seam, at: point) }
        overlays.resize = { [weak self] point in self?.latestPoint = point; self?.updateManual() }
        overlays.finishResize = { [weak self] point in
            guard let self else { return }
            self.latestPoint = point
            self.updateManual(); self.down = false; self.finish()
        }
    }
    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.event(event) }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; timer?.invalidate(); timer = nil; cancelInteraction(); overlays.stop() }
    func cancelInteraction() {
        if let current = gesture, current.kind != nil {
            model.groups = model.without(Set((current.group?.windows ?? [current.window]).map(\.id)), from:model.groups)
            model.onGroupsChanged?()
        }
        generation += 1; gesture = nil; down = false; manual = false
        overlays.interacting = false; model.access.cancelPreviews(); endAdjustment()
    }
    private func endAdjustment() {
        model.access.endInteractiveAdjustment { [weak model] restored in
            if !restored { Task { @MainActor in model?.notice = "Edge 的辅助功能模式尚未确认恢复；请退出并重新打开 Edge。" } }
        }
    }
    private func event(_ event: NSEvent) {
        guard !manual, !model.busy, !model.paused, model.trusted else { return }
        latestPoint = CGEvent(source: nil)?.location ?? latestPoint; latestFlags = event.modifierFlags
        if event.type == .leftMouseDown {
            guard !finishing else { return }
            model.invalidateScan()
            generation += 1; let token = generation; down = true; gesture = nil
            let point = latestPoint, apps = WindowApp.running
            Task {
                guard let (window, _) = await model.access.hit(point, apps: apps), generation == token, down else { return }
                let group = model.group(containing: window)
                let frames = await model.access.read(group?.windows ?? [window])
                guard generation == token, down else { return }
                let baseline = (group?.windows ?? [window]).compactMap { item in frames[item.id].map { WindowMove(window: item, frame: $0) } }
                gesture = .init(window: window, start: point, group: group, baseline: baseline, lastFrame: window.frame)
                let obstacles = await model.access.scan(apps)
                guard generation == token, var current = gesture else { return }
                current.obstacles = obstacles
                gesture = current
            }
        } else if event.type == .leftMouseUp { down = false; if !processing { process() } }
        else if event.type == .leftMouseDragged, !processing { process() }
    }
    private func tick() {
        let trusted = WindowAccess.trusted
        if model.trusted != trusted { model.trusted = trusted }
        if model.busy && finishing { return }
        if model.paused || model.busy || !model.trusted {
            if !finishing, gesture != nil || manual { cancelInteraction() }
            overlays.stop(); return
        }
        if manual { if down { updateManual() }; return }
        if gesture != nil, !processing {
            if !CGEventSource.buttonState(.hidSystemState, button: .left) { down = false }
            process()
        } else if !down && gesture == nil { hover() }
    }
    private func process() {
        guard let current = gesture, !processing else { return }
        processing = true
        let token = generation
        Task {
            let frames = await model.access.read([current.window])
            guard generation == token, var live = gesture else { processing = false; return }
            if let actual = frames[live.window.id] {
                let initial = live.window.frame
                if live.kind == nil {
                    let borderDistance = min(abs(live.start.x-initial.minX),abs(live.start.x-initial.maxX),abs(live.start.y-initial.minY),abs(live.start.y-initial.maxY))
                    if !FrameSettler.matchesSize(actual,initial), borderDistance <= 8 { live.kind = "resize" }
                    else if hypot(actual.minX - initial.minX, actual.minY - initial.minY) > 3 { live.kind = "move" }
                    if live.kind != nil { model.access.beginInteractiveAdjustment(live.group?.windows ?? [live.window]) }
                }
                // Position-only magnet writes must not undo native tiling or app-driven resizing.
                if live.kind == "move", !FrameSettler.matchesSize(actual,initial), !(latestFlags.contains(.option) && model.preferences.zonesEnabled) {
                    live.kind = "native-resize"; live.drop = nil; live.magnet = nil
                    model.access.cancelPreviews(); overlays.hidePreview()
                }
                live.lastFrame = actual
                if live.kind == "move" {
                    if latestFlags.contains(.option), model.preferences.zonesEnabled {
                        model.access.cancelPreviews()
                        if let desktop = Desktop.all.first(where: { $0.frame.contains(latestPoint) }) {
                            let target = model.groups.last(where: { $0.screenID == desktop.id && $0.preset.id == model.layout.id && $0.preset.root == model.layout.root }) ?? model.makeGroup(layout: model.layout, desktop: desktop)
                            if let geometry = try? target.geometry() {
                                let slot = geometry.panes.first(where: { $0.value.contains(latestPoint) })?.key
                                live.drop = slot.map { (target, $0) }; live.magnet = nil
                                overlays.showZones(geometry, bounds: target.bounds, selected: slot)
                            }
                        }
                    } else {
                        live.drop = nil; overlays.hidePreview()
                        if model.preferences.magnetEnabled && !latestFlags.contains(.control) {
                            let raw = initial.offsetBy(dx: latestPoint.x - live.start.x, dy: latestPoint.y - live.start.y)
                            let obstacles = live.obstacles.filter { $0.id != live.window.id }.map { (id: $0.id, frame: $0.frame) }
                            let result = Magnet.snap(raw, to: obstacles, gap: model.preferences.gap, previous: live.magnet)
                            live.magnet = result
                            if result.x != nil || result.y != nil { model.access.preview([.init(window: live.window, frame: result.frame)]) }
                            else { model.access.cancelPreviews() }
                        } else { live.magnet = nil; model.access.cancelPreviews() }
                    }
                } else if live.kind == "resize", model.preferences.linkedEnabled, let group = live.group {
                    if live.seam == nil { live.seam = findSeam(group, window: live.window, actual: actual) }
                    if let seam = live.seam, let draft = resized(group, seam: seam, from: live.start, to: latestPoint) { live.draft = draft }
                }
                gesture = live
            }
            processing = false
            if !down { finish() }
        }
    }
    private func findSeam(_ group: WindowGroup, window: LiveWindow, actual: CGRect) -> LayoutSeam? {
        guard let geometry = try? group.geometry(), let slot = group.members.first(where: { $0.value.id == window.id })?.key else { return nil }
        let before = window.frame
        let edges: [(SplitAxis, Double, Double)] = [(.horizontal, before.minX, actual.minX-before.minX), (.horizontal, before.maxX, actual.maxX-before.maxX),
                                                    (.vertical, before.minY, actual.minY-before.minY), (.vertical, before.maxY, actual.maxY-before.maxY)]
        for edge in edges.sorted(by: { abs($0.2) > abs($1.2) }) where abs(edge.2) > 2 {
            if let seam = geometry.seams.first(where: { $0.axis == edge.0 && ($0.first.panes + $0.second.panes).contains(slot) && abs(($0.axis == .horizontal ? $0.line.midX : $0.line.midY)-edge.1) <= group.gap/2+3 }) { return seam }
        }
        return nil
    }
    private func resized(_ group: WindowGroup, seam: LayoutSeam, from start: CGPoint, to point: CGPoint) -> WindowGroup? {
        do {
            let coordinate = (seam.axis == .horizontal ? seam.line.midX + point.x-start.x : seam.line.midY + point.y-start.y)
            let minimums = model.leafMinimums(group)
            let ratio = try seam.ratio(at: coordinate, gap: group.gap, minimums: minimums, scale: group.scale)
            var next = group; next.preset.root = group.preset.root.replacingRatio(seam.id, with: ratio)
            let moves = try next.moves(minimums: minimums)
            model.access.preview(moves)
            overlays.previewResize(next,minimums:minimums)
            return next
        } catch { model.notice = error.localizedDescription; return nil }
    }
    private func beginManual(_ group: WindowGroup, seam: LayoutSeam, at point: CGPoint) {
        guard !model.busy, !finishing, !model.paused else { return }
        model.invalidateScan()
        generation += 1; let token = generation
        manual = true; down = true; overlays.interacting = true
        latestPoint = point
        let start = latestPoint
        Task {
            let frames = await model.access.read(group.windows)
            guard token == generation, manual else { return }
            let baseline = group.windows.compactMap { item in frames[item.id].map { WindowMove(window: item, frame: $0) } }
            guard baseline.count == group.windows.count, let first = group.windows.first else { manual = false; down = false; overlays.interacting = false; overlays.requestUpdate(invalidate:true); return }
            model.access.beginInteractiveAdjustment(group.windows)
            gesture = .init(window: first, start: start, kind: "resize", group: group, baseline: baseline, seam: seam, lastFrame: first.frame)
            updateManual()
            if !down { finish() }
        }
    }
    private func updateManual() {
        guard manual, var value = gesture, let group = value.group, let seam = value.seam else { return }
        if let draft = resized(group, seam: seam, from: value.start, to: latestPoint) { value.draft = draft }; gesture = value
    }
    private func finish() {
        guard !finishing, !processing else { return }
        guard let current = gesture else { if manual { down = false }; return }
        finishing = true; generation += 1; gesture = nil; down = false; manual = false
        overlays.hidePreview(); model.access.cancelPreviews()
        Task {
            defer { endAdjustment(); finishing = false; overlays.interacting = false; overlays.requestUpdate(invalidate:true) }
            if let draft = current.draft {
                do {
                    let moves = try draft.moves(minimums: model.leafMinimums(draft))
                    let next = model.groups.map { $0.id == draft.id ? draft : $0 }
                    _ = await model.commit(moves, groups: next, baseline: current.baseline, success: "已调整共享边界，组内窗口保持联动。")
                } catch { model.notice = error.localizedDescription }
            } else if let (group, slot) = current.drop { model.place(current.window, slot: slot, in: group, baseline: current.baseline) }
            else if current.kind == "move" {
                let actual = await model.access.read([current.window])
                let target = current.magnet.flatMap { $0.x != nil || $0.y != nil ? $0.frame : nil } ?? actual[current.window.id] ?? current.lastFrame
                _ = await model.commit([.init(window: current.window, frame: target)], groups: model.without([current.window.id], from: model.groups),
                                       baseline: [.init(window: current.window, frame: current.window.frame)], success: current.magnet?.x != nil || current.magnet?.y != nil ? "窗口已吸附；按住 ⌃ 拖动可临时跳过。" : "窗口已移出原布局，关联已解除。")
            } else if current.kind == "resize" || current.kind == "native-resize" { model.detach(current.window); await model.refresh() }
        }
    }
    private func hover() {
        guard model.preferences.hoverEnabled, NSEvent.modifierFlags.contains(.option),
              let point = CGEvent(source: nil)?.location else { hoverOpened = false; hoverSince = 0; hoverGeneration += 1; return }
        guard !hoverBusy else { return }
        if hypot(point.x-hoverPoint.x, point.y-hoverPoint.y) > 3 { hoverPoint = point; hoverSince = ProcessInfo.processInfo.systemUptime; hoverOpened = false }
        guard !hoverOpened, ProcessInfo.processInfo.systemUptime-hoverSince > 0.45, paletteContains?(point) != true else { return }
        hoverBusy = true
        let generation = hoverGeneration
        Task {
            defer { hoverBusy = false }
            if let (window, anchor) = await model.access.hit(point, apps: WindowApp.running, zoomOnly: true),
               generation == hoverGeneration,
               !down, NSEvent.modifierFlags.contains(.option), let now = CGEvent(source: nil)?.location,
               hypot(now.x-point.x,now.y-point.y) <= 3 { hoverOpened = true; openPalette?(window, anchor) }
        }
    }
    func suppressCurrentHover() {
        hoverGeneration += 1
        hoverPoint = CGEvent(source:nil)?.location ?? hoverPoint
        hoverSince = ProcessInfo.processInfo.systemUptime; hoverOpened = true
    }
}
