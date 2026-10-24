import AppKit
import PaneFlowCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class HandleMaterial: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class SeamView: NSView {
    var axis: SplitAxis = .horizontal { didSet { updateAppearance() } }
    var begin: ((CGPoint) -> Void)?
    var change: ((CGPoint) -> Void)?
    var finish: ((CGPoint) -> Void)?
    private let material = HandleMaterial()
    private let grip = NSBox()
    private var pointerArea: NSTrackingArea?
    private var hovered = false
    private var dragging = false
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 5; material.layer?.masksToBounds = true
        material.setAccessibilityElement(false)
        grip.boxType = .custom; grip.borderWidth = 0; grip.cornerRadius = 1; grip.titlePosition = .noTitle
        grip.setAccessibilityElement(false)
        material.addSubview(grip); addSubview(material)
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateAppearance() {
        let vertical = axis == .horizontal
        let length: CGFloat = hovered || dragging ? 42 : 34
        let size = NSSize(width:vertical ? 10 : length,height:vertical ? length : 10)
        material.frame = NSRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height)
        material.alphaValue = hovered || dragging ? 1 : 0.85
        grip.frame = NSRect(x:size.width/2-(vertical ? 1 : 9),y:size.height/2-(vertical ? 9 : 1),width:vertical ? 2 : 18,height:vertical ? 18 : 2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            material.layer?.borderWidth = 0.5
            material.layer?.borderColor = (dragging ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            grip.fillColor = dragging ? .controlAccentColor : .secondaryLabelColor
        }
        toolTip = vertical ? "左右拖动，同时调整左右窗口宽度" : "上下拖动，同时调整上下窗口高度"
    }
    override func layout() { super.layout(); updateAppearance() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); pointerArea = area
        if let window { hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream,from:nil)) }
        updateAppearance()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateAppearance() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with event: NSEvent) { dragging = true; updateAppearance(); begin?(CGEvent(source:nil)?.location ?? .zero) }
    override func mouseDragged(with event: NSEvent) { change?(CGEvent(source: nil)?.location ?? .zero) }
    override func mouseUp(with event: NSEvent) { dragging = false; updateAppearance(); finish?(CGEvent(source:nil)?.location ?? .zero) }
}
final class ZoneView: NSView {
    var regions: [CGRect] = []
    var selected: CGRect?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for region in regions {
            let path = NSBezierPath(roundedRect: region.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
            NSColor.controlAccentColor.withAlphaComponent(region == selected ? 0.24 : 0.08).setFill(); path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke(); path.lineWidth = region == selected ? 3 : 1; path.stroke()
        }
    }
}

@MainActor final class OverlayCoordinator {
    private struct HandleID: Hashable {
        var group: String
        var seam: String
        var first: String
        var second: String
        init(_ group: WindowGroup, _ link: LayoutLink) {
            self.group = group.id; seam = link.seam.id; first = link.first; second = link.second
        }
    }
    private struct HandlePlacement {
        var group: WindowGroup
        var link: LayoutLink
    }
    private var handles: [HandleID:PassivePanel] = [:]
    private var preview: NSPanel?
    private var updateEpoch = 0
    private var updateTask: Task<Void,Never>?
    private var refreshPending = false
    private weak var model: AppModel?
    var beginResize: ((WindowGroup, LayoutSeam, CGPoint) -> Void)?
    var resize: ((CGPoint) -> Void)?
    var finishResize: ((CGPoint) -> Void)?
    var interacting = false {
        didSet { if interacting && !oldValue { updateEpoch += 1 } }
    }
    init(model: AppModel) { self.model = model }
    func requestUpdate(invalidate: Bool = false) {
        if invalidate { updateEpoch += 1 }
        guard updateTask == nil else { refreshPending = refreshPending || invalidate; return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshPending = false
                await update()
            } while refreshPending
            updateTask = nil
        }
    }
    func hideHandles() { handles.values.forEach { $0.orderOut(nil) }; handles = [:] }
    private func position(_ panel: NSPanel, at rect: CGRect) {
        let frame = DisplayGeometry.flip(rect, primaryHeight:Double(NSScreen.screens.first?.frame.height ?? 0))
        if panel.frame != frame { panel.setFrame(frame,display:true) }
    }
    private func apply(_ desired: [HandleID:HandlePlacement]) {
        for id in Array(handles.keys) where desired[id] == nil { handles.removeValue(forKey:id)?.orderOut(nil) }
        for (id,placement) in desired {
            let group = placement.group, link = placement.link, seam = link.seam
            let panel: PassivePanel
            let view: SeamView
            if let existing = handles[id], let content = existing.contentView as? SeamView {
                panel = existing; view = content
            } else {
                panel = PassivePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
                view = SeamView(frame:NSRect(origin:.zero,size:link.frame.size))
                panel.contentView = view; handles[id] = panel
            }
            if view.axis != seam.axis { view.axis = seam.axis }
            view.setAccessibilityElement(true); view.setAccessibilityLabel(seam.axis == .horizontal ? "左右联动分隔条" : "上下联动分隔条")
            view.setAccessibilityHelp("拖动分隔条，同时调整边界两侧的窗口。")
            view.begin = { [weak self] point in self?.beginResize?(group,seam,point) }
            view.change = { [weak self] point in self?.resize?(point) }
            view.finish = { [weak self] point in self?.finishResize?(point) }
            position(panel,at:link.frame)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
    func previewResize(_ group: WindowGroup, minimums: [String:CGSize]) {
        guard let geometry = try? group.geometry(minimums:minimums) else { return }
        interacting = true
        for link in geometry.links(assigned:Set(group.members.keys)) {
            if let panel = handles[HandleID(group,link)] { position(panel,at:link.frame) }
        }
    }
    private func status(_ title: String, _ hint: String) {
        guard let model else { return }
        if model.linkStatus != title { model.linkStatus = title }
        if model.linkHint != hint { model.linkHint = hint }
        if model.visibleLinkCount != handles.count { model.visibleLinkCount = handles.count }
    }
    func update() async {
        guard !interacting else { return }
        updateEpoch += 1; let epoch = updateEpoch
        let ownHandleIDs = Set(handles.values.map(\.windowNumber))
        let visible = WindowAccess.visibleWindows().filter { !ownHandleIDs.contains($0.id) }
        guard let model else { hideHandles(); return }
        guard model.trusted else { hideHandles(); status("辅助功能未允许","开启辅助功能后，即可排列并联动窗口。"); return }
        guard !model.paused else { hideHandles(); status("窗口管理已暂停","从菜单栏选择“继续窗口管理”。"); return }
        guard model.preferences.linkedEnabled else { hideHandles(); status("联动缩放已关闭","开启“同一布局内联动缩放”以显示分隔条。"); return }
        guard !model.busy else { hideHandles(); status("正在调整窗口","窗口就位后会显示分隔条。"); return }
        let groups = model.groups.filter { $0.members.count >= 2 }
        guard !groups.isEmpty else { hideHandles(); status("尚未建立联动布局","在布局面板勾选多个窗口，点击“排列并联动”。保存布局形状后还需排列窗口。"); return }
        let count = Set(groups.flatMap { $0.windows.map(\.id) }).count
        let summary = "已关联 \(count) 个窗口（\(groups.count) 组）"
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var desired: [HandleID:HandlePlacement] = [:]
        var active = false, alignedGroup = false, planned = 0
        for group in groups where group.windows.contains(where: { $0.app.pid == front }) {
            active = true
            guard let geometry = try? group.geometry() else { continue }
            let aligned = group.members.allSatisfy { slot, member in
                guard let expected = geometry.panes[slot] else { return false }
                return visible.contains { $0.pid == member.app.pid && $0.layer == 0 && FrameSettler.matches($0.frame, expected) }
            }
            guard aligned else { continue }
            alignedGroup = true
            let links = geometry.links(assigned:Set(group.members.keys)); planned += links.count
            let exposed = await model.access.exposedLinks(links,panes:geometry.panes,members:group.members,surfaces:visible)
            guard epoch == updateEpoch, !interacting else { return }
            guard !model.busy, !model.paused, model.trusted, model.preferences.linkedEnabled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { hideHandles(); return }
            for (index,link) in links.enumerated() where exposed.contains(index) {
                desired[HandleID(group,link)] = .init(group:group,link:link)
            }
        }
        apply(desired)
        if !handles.isEmpty { status("已显示 \(handles.count) 个分隔条","左右拖动竖向分隔条，或上下拖动横向分隔条。") }
        else if !active { status(summary,"点一下组内窗口，联动分隔条会显示在窗口之间。") }
        else if !alignedGroup { status(summary,"有组员已移动或暂时不可见。恢复原布局，或重新排列组内窗口。") }
        else if planned == 0 { status(summary,"相邻分区各放入一个窗口后，会显示联动分隔条。") }
        else { status(summary,"共享边界被其他窗口遮挡。将组内窗口切到前台。") }
    }
    func showZones(_ geometry: LayoutGeometry, bounds: CGRect, selected: String?) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        if preview == nil {
            let panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.level = .floating; panel.ignoresMouseEvents = true
            preview = panel
        }
        let view: ZoneView
        if let existing = preview?.contentView as? ZoneView { view = existing }
        else {
            view = ZoneView(frame: NSRect(origin: .zero, size: bounds.size))
            preview?.contentView = view
        }
        let regions = geometry.panes.sorted { $0.key < $1.key }.map { $0.value.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        let selection = selected.flatMap { geometry.panes[$0]?.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        if view.regions != regions || view.selected != selection {
            view.regions = regions; view.selected = selection; view.needsDisplay = true
        }
        let frame = DisplayGeometry.flip(bounds, primaryHeight: primary)
        if preview?.frame != frame { preview?.setFrame(frame, display: true) }
        if preview?.isVisible != true { preview?.orderFrontRegardless() }
    }
    func hidePreview() { preview?.orderOut(nil) }
    func stop() {
        updateEpoch += 1
        refreshPending = false
        hideHandles(); hidePreview()
        if model?.visibleLinkCount != 0 { model?.visibleLinkCount = 0 }
    }
}
