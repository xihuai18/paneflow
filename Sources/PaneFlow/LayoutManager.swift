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
        let draft = LayoutPreset(name:uniqueName(current.name+" 副本"),root:current.root)
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
    var body: some View {
        Canvas { context, size in
            if let geometry = try? LayoutGeometry.make(root,in:CGRect(origin:.zero,size:size),gap:2,scale:2) {
                for rect in geometry.panes.values {
                    context.fill(Path(roundedRect:rect,cornerRadius:2),with:.color(.secondary.opacity(0.45)))
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
                    Button(action:state.duplicate) { Image(systemName:"doc.on.doc") }.help("复制选中布局").accessibilityLabel("复制布局")
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
            LayoutThumbnail(root:layout.root)
            VStack(alignment:.leading,spacing:3) {
                Text(layout.name).lineLimit(1)
                Text("\(layout.root.panes.count) 个区域").font(.caption).foregroundStyle(.secondary)
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
    private var seams: [LayoutSeam] { (try? LayoutGeometry.make(state.current.root,in:CGRect(x:0,y:0,width:500,height:260),gap:5).seams) ?? [] }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(state.isBuiltin ? "内置布局" : "编辑布局").font(.title2).fontWeight(.semibold)
                Spacer()
                if state.isDirty { Text("未保存").font(.caption).foregroundStyle(.secondary) }
            }
            if state.isBuiltin { Text(state.current.name).font(.title3); Text("内置布局保持不变。复制一份即可自由编辑。").font(.callout).foregroundStyle(.secondary) }
            else { TextField("布局名称",text:draft.name).textFieldStyle(.roundedBorder).accessibilityLabel("布局名称") }
            LayoutCanvas(root:state.current.root,selected:selected,editing:true,choose:{selected=$0},changeRatio:state.isBuiltin ? nil : { key,ratio in
                draft.wrappedValue.root = state.current.root.replacingRatio(key,with:ratio); seamID = key
            }).frame(height:240)
            if !state.isBuiltin {
                HStack {
                    Button("左右拆分") { split(.horizontal) }.disabled(state.current.root.panes.count>=16)
                    Button("上下拆分") { split(.vertical) }.disabled(state.current.root.panes.count>=16)
                    Button("合并区域") {
                        guard let selected else { return }
                        draft.wrappedValue.root = state.current.root.mergingPane(selected); resetSelection()
                    }.disabled(state.current.root.panes.count<=1).help("移除选中的分区，将空间合并到相邻分区")
                }
                if !seams.isEmpty {
                    HStack {
                        Picker("分隔线",selection:$seamID) {
                            ForEach(Array(seams.enumerated()),id:\.element.id) { index,seam in Text("\(index+1) · \(seam.axis == .horizontal ? "左右" : "上下")").tag(seam.id) }
                        }.frame(maxWidth:230)
                        Text("比例")
                        TextField("百分比",value:Binding(get:{(seams.first{$0.id==seamID}?.ratio ?? 0.5)*100},set:{value in
                            if value.isFinite { draft.wrappedValue.root = state.current.root.replacingRatio(seamID,with:max(0.001,min(0.999,value/100))) }
                        }),format:.number.precision(.fractionLength(0...1))).frame(width:65).textFieldStyle(.roundedBorder)
                        Text("%")
                    }
                }
                Text("选中区域后可拆分或合并，拖动分隔条可调整比例。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
            if let error = state.error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal:false,vertical:true) }
            else { Text("保存只更新布局配置。下次排列时生效，不会移动现有窗口。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            Divider()
            HStack {
                if state.isBuiltin {
                    Button("使用此布局") { state.model.preferences.activeLayout = state.selectedID }.disabled(state.model.preferences.activeLayout == state.selectedID)
                    Spacer(); Button("复制并编辑",action:state.duplicate).buttonStyle(.borderedProminent)
                } else {
                    Button("还原修改",action:state.revert).disabled(!state.isDirty || !state.hasSavedVersion)
                    Button("另存为新布局",action:state.duplicate)
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
                if !root.splitIDs.contains(seamID) { seamID = seams.first?.id ?? "" }
            }
    }
    private func resetSelection() { selected = state.current.root.panes.first; seamID = seams.first?.id ?? "" }
    private func split(_ axis: SplitAxis) {
        guard let pane = selected ?? state.current.root.panes.first else { return }
        let previous = Set(state.current.root.splitIDs)
        draft.wrappedValue.root = state.current.root.splittingPane(pane,axis:axis)
        seamID = state.current.root.splitIDs.first { !previous.contains($0) } ?? ""
    }
}
