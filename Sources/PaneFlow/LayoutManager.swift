import AppKit
import SwiftUI
import PaneFlowCore

@MainActor final class LayoutManagerState: ObservableObject {
    let model: AppModel
    @Published var selectedID: String
    @Published var drafts: [String:LayoutPreset]
    @Published var order: [String]
    @Published var error: String?
    init(model: AppModel) {
        self.model = model; selectedID = model.layout.id
        drafts = Dictionary(uniqueKeysWithValues:model.preferences.customLayouts.map { ($0.id,$0) })
        order = model.preferences.customLayouts.map(\.id)
    }
    var current: LayoutPreset { drafts[selectedID] ?? LayoutPreset.builtins.first { $0.id == selectedID } ?? LayoutPreset.builtins[2] }
    var isBuiltin: Bool { LayoutPreset.builtins.contains { $0.id == selectedID } }
    var customLayouts: [LayoutPreset] { order.compactMap { drafts[$0] } }
    var dirtyIDs: [String] { order.filter { id in drafts[id] != model.preferences.customLayouts.first { $0.id == id } } }
    var isDirty: Bool { dirtyIDs.contains(selectedID) }
    var hasSavedVersion: Bool { model.preferences.customLayouts.contains { $0.id == selectedID } }
    private func uniqueName(_ base: String) -> String {
        let names = Set((LayoutPreset.builtins+customLayouts).map(\.name))
        if !names.contains(base) { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
    func create() {
        let draft = LayoutPreset(name:uniqueName("新布局"),root:.pane(UUID().uuidString))
        drafts[draft.id] = draft; order.append(draft.id); selectedID = draft.id; error = nil
    }
    func duplicate() {
        let draft = LayoutPreset(name:uniqueName(current.name+" 副本"),root:current.root,emptyPanes:current.emptyPanes)
        drafts[draft.id] = draft; order.append(draft.id); selectedID = draft.id; error = nil
    }
    @discardableResult func save(_ id: String? = nil) -> Bool {
        let id = id ?? selectedID
        guard let draft = drafts[id] else { return false }
        guard model.saveLayout(draft) else { error = model.notice; return false }
        drafts[id] = model.preferences.customLayouts.first { $0.id == id }
        error = nil; return true
    }
    func saveAll() -> Bool {
        for id in dirtyIDs { if !save(id) { return false } }
        return true
    }
    func revert() {
        guard let saved = model.preferences.customLayouts.first(where: { $0.id == selectedID }) else { return }
        drafts[selectedID] = saved; error = nil
    }
    func discardAll() {
        drafts = Dictionary(uniqueKeysWithValues:model.preferences.customLayouts.map { ($0.id,$0) })
        order = model.preferences.customLayouts.map(\.id); selectedID = model.layout.id; error = nil
    }
    func removeCurrent() {
        guard !isBuiltin else { return }
        let id = selectedID
        if hasSavedVersion && !model.deleteLayout(id) { error = model.notice; return }
        drafts.removeValue(forKey:id); order.removeAll { $0 == id }
        selectedID = order.first ?? model.layout.id; error = nil
    }
}

@MainActor final class LayoutManagerWindowController: NSObject, NSWindowDelegate {
    let state: LayoutManagerState
    let window: NSWindow
    init(model: AppModel) {
        state = LayoutManagerState(model:model)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:880,height:620),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = "布局管理 · PaneFlow"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width:780,height:600); window.delegate = self
        window.contentView = NSHostingView(rootView:LayoutManagerView(state:state))
        window.center()
    }
    func show() {
        if !window.isVisible && state.dirtyIDs.isEmpty { state.discardAll() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !state.dirtyIDs.isEmpty else { return true }
        confirmChanges { allowed in if allowed { sender.close() } }
        return false
    }
    func confirmChanges(_ completion: @escaping (Bool) -> Void) {
        guard !state.dirtyIDs.isEmpty else { completion(true); return }
        guard window.attachedSheet == nil else { completion(false); return }
        show()
        let alert = NSAlert()
        alert.messageText = "保存布局修改？"
        alert.informativeText = "还有 \(state.dirtyIDs.count) 个布局未保存。"
        alert.addButton(withTitle:"全部保存"); alert.addButton(withTitle:"继续编辑"); alert.addButton(withTitle:"放弃修改")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { completion(false); return }
            if response == .alertFirstButtonReturn { completion(self.state.saveAll()) }
            else if response == .alertThirdButtonReturn { self.state.discardAll(); completion(true) }
            else { completion(false) }
        }
    }

}

private struct LayoutThumbnail: View {
    let root: LayoutNode
    var emptyPanes = Set<String>()
    var body: some View {
        Canvas { context, size in
            if let geometry = try? LayoutGeometry.make(root,in:CGRect(origin:.zero,size:size),gap:2,scale:2) {
                for (id,rect) in geometry.panes {
                    context.fill(Path(roundedRect:rect,cornerRadius:2),with:.color(.secondary.opacity(emptyPanes.contains(id) ? 0.1 : 0.45)))
                }
            }
        }.frame(width:38,height:27).accessibilityHidden(true)
    }
}

struct LayoutManagerView: View {
    @ObservedObject var state: LayoutManagerState
    @State private var confirmDelete = false
    var body: some View {
        HSplitView {
            VStack(spacing:0) {
                List(selection:Binding<String?>(get:{state.selectedID},set:{ if let id = $0 { state.selectedID = id; state.error = nil } })) {
                    Section("内置布局") {
                        ForEach(LayoutPreset.builtins) { layout in row(layout).tag(layout.id) }
                    }
                    Section("我的布局") {
                        ForEach(state.customLayouts) { layout in row(layout).tag(layout.id) }
                        if state.customLayouts.isEmpty { Text("点击下方“新建”添加布局").font(.caption).foregroundStyle(.secondary) }
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Button(action:state.create) { Label("新建",systemImage:"plus") }.help("新建一个空白布局")
                    Button(action:state.duplicate) { Label("复制",systemImage:"doc.on.doc") }.help("复制选中布局").accessibilityLabel("复制布局")
                    Spacer()
                    Button(role:.destructive) { confirmDelete = true } label: { Image(systemName:"trash") }
                        .disabled(state.isBuiltin).help("删除选中布局").accessibilityLabel("删除布局")
                }.buttonStyle(.borderless).padding(12)
            }.frame(minWidth:195,idealWidth:220,maxWidth:270)
            LayoutDetailsView(state:state).frame(minWidth:540,maxWidth:.infinity,maxHeight:.infinity)
        }
        .alert("删除“\(state.current.name)”？",isPresented:$confirmDelete) {
            Button("删除布局",role:.destructive) { state.removeCurrent() }
            Button("取消",role:.cancel) {}
        } message: { Text("只删除这份布局配置，不会移动或关闭现有窗口。") }
    }
    private func row(_ layout: LayoutPreset) -> some View {
        HStack(spacing:10) {
            LayoutThumbnail(root:layout.root,emptyPanes:layout.emptyPanes)
            VStack(alignment:.leading,spacing:3) {
                Text(layout.name).lineLimit(1)
                Text("\(layout.windowPanes.count) 个窗口区域" + (layout.emptyPanes.isEmpty ? "" : " · \(layout.emptyPanes.count) 处留白")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
            if state.dirtyIDs.contains(layout.id) { Image(systemName:"circle.fill").font(.system(size:6)).accessibilityLabel("未保存") }
        }.padding(.vertical,5)
    }
}

private struct LayoutDetailsView: View {
    @ObservedObject var state: LayoutManagerState
    @State private var selected: String?
    @State private var seamID = ""
    private var draft: Binding<LayoutPreset> {
        Binding(get:{state.current},set:{ if !state.isBuiltin { state.drafts[state.selectedID] = $0 } })
    }
    private var seams: [LayoutSeam] { (try? LayoutGeometry.make(state.current.root,in:CGRect(x:0,y:0,width:10000,height:10000),gap:0).seams) ?? [] }
    private var selectedIsEmpty: Bool { selected.map { state.current.emptyPanes.contains($0) } ?? false }
    private var position: Double {
        guard let seam = seams.first(where:{$0.id == seamID}) else { return 50 }
        return (seam.axis == .horizontal ? seam.line.midX : seam.line.midY)/100
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            if state.isBuiltin { Text(state.current.name).font(.title3); Text("内置布局保持不变。复制一份即可自由编辑。").font(.callout).foregroundStyle(.secondary) }
            else {
                HStack {
                    TextField("布局名称",text:draft.name).textFieldStyle(.roundedBorder).accessibilityLabel("布局名称")
                    if state.isDirty { Text("未保存").font(.caption).foregroundStyle(.secondary) }
                }
            }
            LayoutCanvas(root:state.current.root,emptyPanes:state.current.emptyPanes,selected:selected,editing:true,selectedLine:seamID,choose:{selected=$0},moveLine:state.isBuiltin ? nil : { key,percent in
                draft.wrappedValue.root = state.current.root.movingLine(key,toPercent:percent); seamID = key
            },selectLine:{seamID=$0}).frame(height:260)
            if !state.isBuiltin {
                HStack {
                    Button("加竖线") { split(.horizontal) }.disabled(state.current.root.panes.count>=16)
                    Button("加横线") { split(.vertical) }.disabled(state.current.root.panes.count>=16)
                    Button(selectedIsEmpty ? "取消留白" : "留白") {
                        guard let selected else { return }
                        if selectedIsEmpty { draft.wrappedValue.emptyPanes.remove(selected) }
                        else { draft.wrappedValue.emptyPanes.insert(selected) }
                    }.disabled(!selectedIsEmpty && state.current.windowPanes.count <= 1)
                    Button("合并区域") {
                        guard let selected else { return }
                        var value = state.current; value.root = value.root.mergingPane(selected)
                        value.emptyPanes.formIntersection(Set(value.root.panes)); draft.wrappedValue = value; resetSelection()
                    }.disabled(state.current.root.panes.count<=1 || (!selectedIsEmpty && state.current.windowPanes.count<=1)).help("选择要合并掉的区域，将空间交给相邻区域")
                }
                if let seam = seams.first(where:{$0.id == seamID}) {
                    HStack {
                        Text(seam.axis == .horizontal ? "竖线位置" : "横线位置")
                        TextField("百分比",value:Binding(get:{position},set:changePosition),format:.number.precision(.fractionLength(0...2))).frame(width:65).textFieldStyle(.roundedBorder)
                        Text("%")
                        Stepper("线的位置",onIncrement:{changePosition(position+1)},onDecrement:{changePosition(position-1)}).labelsHidden().help("每次调整 1%")
                    }
                }
                Text("留白处不放窗口 · 拖线微调 1%").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
            if let error = state.error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal:false,vertical:true) }
            else { Text("保存后，下次排列窗口时生效。").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                if state.isBuiltin {
                    Button("使用此布局") { state.model.preferences.activeLayout = state.selectedID }.disabled(state.model.preferences.activeLayout == state.selectedID)
                    Spacer(); Button("复制并编辑",action:state.duplicate).buttonStyle(.borderedProminent)
                } else {
                    Button("还原修改",action:state.revert).disabled(!state.isDirty || !state.hasSavedVersion)
                    Spacer()
                    Button(state.hasSavedVersion ? "保存修改" : "保存布局") { state.save() }
                        .buttonStyle(.borderedProminent).keyboardShortcut("s",modifiers:.command).disabled(!state.isDirty)
                }
            }
        }.padding(24).background(Color(nsColor:.windowBackgroundColor))
            .onAppear(perform:resetSelection)
            .onChange(of:state.selectedID) { _,_ in resetSelection() }
            .onChange(of:state.current.root) { _,root in
                if selected.map({root.panes.contains($0)}) != true { selected = root.panes.first }
                if !seamID.isEmpty, !root.splitIDs.contains(seamID) { seamID = "" }
            }
    }
    private func resetSelection() { selected = state.current.root.panes.first; seamID = "" }
    private func changePosition(_ percent: Double) {
        guard percent.isFinite else { return }
        draft.wrappedValue.root = state.current.root.movingLine(seamID,toPercent:percent)
    }
    private func split(_ axis: SplitAxis) {
        guard let pane = selected ?? state.current.root.panes.first else { return }
        let previous = Set(state.current.root.splitIDs)
        let previousPanes = Set(state.current.root.panes)
        var value = state.current; value.root = value.root.splittingPane(pane,axis:axis)
        if value.emptyPanes.contains(pane) { value.emptyPanes.formUnion(Set(value.root.panes).subtracting(previousPanes)) }
        draft.wrappedValue = value
        seamID = state.current.root.splitIDs.first { !previous.contains($0) } ?? ""
    }
}
