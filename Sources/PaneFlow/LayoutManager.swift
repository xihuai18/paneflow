import AppKit
import SwiftUI
import PaneFlowCore

@MainActor final class LayoutManagerState: ObservableObject {
    let model: AppModel
    @Published var selectedID: String
    @Published var drafts: [String:LayoutPreset]
    @Published var order: [String]
    @Published var error: String?
    @Published var displays: [Desktop]
    @Published var screenID = ""
    private var screenDrafts: [String:[String:ScreenLayout]] = [:]
    init(model: AppModel, displays: [Desktop]? = nil) {
        self.model = model; selectedID = model.layout.id
        self.displays = displays ?? Desktop.all
        drafts = Dictionary(uniqueKeysWithValues:model.preferences.customLayouts.map { ($0.id,$0) })
        order = model.preferences.customLayouts.map(\.id)
    }
    var current: LayoutPreset { drafts[selectedID] ?? LayoutPreset.builtins.first { $0.id == selectedID } ?? LayoutPreset.builtins[2] }
    var isBuiltin: Bool { LayoutPreset.builtins.contains { $0.id == selectedID } }
    var customLayouts: [LayoutPreset] { order.compactMap { drafts[$0] } }
    var dirtyIDs: [String] { order.filter { id in drafts[id] != model.preferences.customLayouts.first { $0.id == id } } }
    var isDirty: Bool { dirtyIDs.contains(selectedID) }
    var hasSavedVersion: Bool { model.preferences.customLayouts.contains { $0.id == selectedID } }
    var editingScreenID: String { current.screens.first(where:{$0.id == screenID})?.id ?? current.screens.first?.id ?? "" }
    var partition: LayoutPreset { current.onScreen(editingScreenID) ?? current }
    func updatePartition(_ value: LayoutPreset) {
        guard !isBuiltin else { return }
        var next = current
        if let index = next.screens.firstIndex(where:{$0.id == editingScreenID}) {
            next.screens[index].root = value.root; next.screens[index].emptyPanes = value.emptyPanes
        } else { next.root = value.root; next.emptyPanes = value.emptyPanes }
        drafts[selectedID] = next
    }
    func setScreen(id: String, name: String, enabled: Bool) {
        guard !isBuiltin else { return }
        var next = current
        if enabled, !next.screens.contains(where:{$0.id == id}) {
            next.screens.append(screenDrafts[selectedID]?[id] ?? .init(id:id,name:name,root:next.root,emptyPanes:next.emptyPanes)); screenID = id
        } else if !enabled, let previous = next.screens.first(where:{$0.id == id}) {
            screenDrafts[selectedID,default:[:]][id] = previous
            next.screens.removeAll { $0.id == id }
            if next.screens.isEmpty { next.root = previous.root; next.emptyPanes = previous.emptyPanes }
        }
        drafts[selectedID] = next
    }
    func useCurrentScreen() {
        for screen in current.screens { screenDrafts[selectedID,default:[:]][screen.id] = screen }
        var next = current; next.root = partition.root; next.emptyPanes = partition.emptyPanes; next.screens = []
        drafts[selectedID] = next; screenID = ""
    }
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
        let draft = LayoutPreset(name:uniqueName(current.name+" 副本"),root:current.root,emptyPanes:current.emptyPanes,screens:current.screens)
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
        drafts[selectedID] = saved; screenDrafts[selectedID] = nil; error = nil
    }
    func discardAll() {
        screenDrafts = [:]
        drafts = Dictionary(uniqueKeysWithValues:model.preferences.customLayouts.map { ($0.id,$0) })
        order = model.preferences.customLayouts.map(\.id); selectedID = model.layout.id; error = nil
    }
    func removeCurrent() {
        guard !isBuiltin else { return }
        let id = selectedID
        if hasSavedVersion && !model.deleteLayout(id) { error = model.notice; return }
        drafts.removeValue(forKey:id); order.removeAll { $0 == id }
        screenDrafts[id] = nil
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
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification)) { _ in state.displays = Desktop.all }
    }
    private func row(_ layout: LayoutPreset) -> some View {
        HStack(spacing:10) {
            if layout.screens.isEmpty { LayoutThumbnail(root:layout.root,emptyPanes:layout.emptyPanes) }
            else { Image(systemName:"display.2").frame(width:38,height:27).foregroundStyle(.secondary) }
            VStack(alignment:.leading,spacing:3) {
                Text(layout.name).lineLimit(1)
                Text(layout.screens.isEmpty ? "\(layout.windowPanes.count) 个窗口区域" + (layout.emptyPanes.isEmpty ? "" : " · \(layout.emptyPanes.count) 处留白") : "\(layout.screens.count) 块显示器 · \(layout.windowCount) 个区域").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
            if state.dirtyIDs.contains(layout.id) { Image(systemName:"circle.fill").font(.system(size:6)).accessibilityLabel("未保存") }
        }.padding(.vertical,5)
    }
}

private struct MultiScreenLayoutCanvas: View {
    let screens: [ScreenLayout]
    let displays: [Desktop]
    let activeID: String
    let selected: String?
    let selectedLine: String
    let choose: (String,String) -> Void
    let moveLine: (String,String,Double) -> Void
    let selectLine: (String,String) -> Void
    let activate: (String) -> Void
    private var displayFrames: [CGRect] {
        let connected = screens.compactMap { screen in displays.first{$0.id == screen.id}?.frame }
        var right = connected.map(\.maxX).max() ?? 0
        return screens.map { screen in
            if let display = displays.first(where:{$0.id == screen.id}) { return display.frame }
            let frame = CGRect(x:right+80,y:0,width:1600,height:1000)
            right = frame.maxX; return frame
        }
    }
    var body: some View {
        GeometryReader { proxy in
            let frames = DisplayGeometry.fittedFrames(displayFrames,in:CGRect(origin:.zero,size:proxy.size))
            ZStack(alignment:.topLeading) {
                ForEach(Array(screens.enumerated()),id:\.element.id) { index,screen in
                    if frames.indices.contains(index) { screenView(screen,in:frames[index]) }
                }
            }
        }
    }
    private func screenView(_ screen: ScreenLayout, in frame: CGRect) -> some View {
        let active = activeID == screen.id
        let connected = displays.contains{$0.id == screen.id}
        return VStack(spacing:5) {
            Button { activate(screen.id) } label: {
                HStack(spacing:4) {
                    Image(systemName:"display").font(.system(size:10))
                    Text(screen.name).font(.system(size:11,weight:active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    if !connected { Text("未连接").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength:0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("编辑“\(screen.name)”的分区")
            LayoutCanvas(root:screen.root,emptyPanes:screen.emptyPanes,selected:active ? selected : nil,editing:true,selectedLine:active ? selectedLine : nil,
                         choose:{choose(screen.id,$0)},moveLine:{moveLine(screen.id,$0,$1)},selectLine:{selectLine(screen.id,$0)})
        }.padding(7)
            .frame(width:max(1,frame.width-10),height:max(1,frame.height-10))
            .background(Color(nsColor:.controlBackgroundColor).opacity(0.3),in:RoundedRectangle(cornerRadius:9))
            .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(active ? Color.accentColor : Color(nsColor:.separatorColor),lineWidth:active ? 1.5 : 1))
            .accessibilityElement(children:.contain).accessibilityLabel(screen.name)
            .position(x:frame.midX,y:frame.midY)
    }
}

private struct LayoutDetailsView: View {
    @ObservedObject var state: LayoutManagerState
    @State private var selected: String?
    @State private var seamID = ""
    @State private var selectedScreenID = ""
    private var draft: Binding<LayoutPreset> {
        Binding(get:{state.current},set:{ if !state.isBuiltin { state.drafts[state.selectedID] = $0 } })
    }
    private var partition: Binding<LayoutPreset> { Binding(get:{state.partition},set:state.updatePartition) }
    private var seams: [LayoutSeam] { (try? LayoutGeometry.make(state.partition.root,in:CGRect(x:0,y:0,width:10000,height:10000),gap:0).seams) ?? [] }
    private var selectedIsEmpty: Bool { selected.map { state.partition.emptyPanes.contains($0) } ?? false }
    private var position: Double {
        guard let seam = seams.first(where:{$0.id == seamID}) else { return 50 }
        return (seam.axis == .horizontal ? seam.line.midX : seam.line.midY)/100
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if state.isBuiltin { Text(state.current.name).font(.title3); Text("内置布局保持不变。复制一份即可自由编辑。").font(.callout).foregroundStyle(.secondary) }
            else {
                HStack {
                    TextField("布局名称",text:draft.name).textFieldStyle(.roundedBorder).accessibilityLabel("布局名称")
                    if state.isDirty { Text("未保存").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !state.isBuiltin { screenControls }
            layoutEditor.frame(minHeight:180,idealHeight:300,maxHeight:.infinity).layoutPriority(1)
            if !state.isBuiltin {
                HStack {
                    Button("加竖线") { split(.horizontal) }.disabled(state.partition.root.panes.count>=16)
                    Button("加横线") { split(.vertical) }.disabled(state.partition.root.panes.count>=16)
                    Button(selectedIsEmpty ? "取消留白" : "留白") {
                        guard let selected else { return }
                        if selectedIsEmpty { partition.wrappedValue.emptyPanes.remove(selected) }
                        else { partition.wrappedValue.emptyPanes.insert(selected) }
                    }.disabled(!selectedIsEmpty && state.partition.windowPanes.count <= 1)
                    Button("合并区域") {
                        guard let selected else { return }
                        var value = state.partition; value.root = value.root.mergingPane(selected)
                        value.emptyPanes.formIntersection(Set(value.root.panes)); partition.wrappedValue = value; resetSelection()
                    }.disabled(state.partition.root.panes.count<=1 || (!selectedIsEmpty && state.partition.windowPanes.count<=1)).help("选择要合并掉的区域，将空间交给相邻区域")
                }
                HStack {
                    if let seam = seams.first(where:{$0.id == seamID}) {
                        Text(seam.axis == .horizontal ? "竖线位置" : "横线位置")
                        TextField("百分比",value:Binding(get:{position},set:changePosition),format:.number.precision(.fractionLength(0...2))).frame(width:65).textFieldStyle(.roundedBorder)
                        Text("%")
                        Stepper("线的位置",onIncrement:{changePosition(position+1)},onDecrement:{changePosition(position-1)}).labelsHidden().help("每次调整 1%")
                    } else {
                        Text(state.current.screens.isEmpty ? "留白处不放窗口 · 拖线微调 1%" : "点击任意屏幕的区域编辑 · 拖线微调 1%").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(height:22,alignment:.leading)
            }
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
            .onChange(of:state.selectedID) { _,_ in state.screenID = ""; resetSelection() }
            .onChange(of:state.editingScreenID) { _,id in if selectedScreenID != id { resetSelection() } }
            .onChange(of:state.partition.root) { _,root in
                if selected.map({root.panes.contains($0)}) != true { selected = root.panes.first }
                if !seamID.isEmpty, !root.splitIDs.contains(seamID) { seamID = "" }
            }
    }
    @ViewBuilder private var layoutEditor: some View {
        if state.current.screens.isEmpty {
            LayoutCanvas(root:state.partition.root,emptyPanes:state.partition.emptyPanes,selected:selected,editing:true,selectedLine:seamID,choose:{selected=$0},moveLine:state.isBuiltin ? nil : { key,percent in
                partition.wrappedValue.root = state.partition.root.movingLine(key,toPercent:percent); seamID = key
            },selectLine:{seamID=$0}).aspectRatio(1.8,contentMode:.fit).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            MultiScreenLayoutCanvas(screens:state.current.screens,displays:state.displays,activeID:state.editingScreenID,selected:selected,selectedLine:seamID,
                choose:{screen,pane in activateScreen(screen); selected = pane; seamID = ""},
                moveLine:{screen,line,percent in activateScreen(screen); changePosition(line:line,percent:percent)},
                selectLine:{screen,line in activateScreen(screen); seamID = line},activate:activateScreen)
        }
    }
    private var screenControls: some View {
        HStack {
            Menu {
                Button("跟随当前窗口") { state.useCurrentScreen() }
                Divider()
                ForEach(state.displays) { display in
                    Toggle(display.name,isOn:Binding(get:{state.current.screens.contains{$0.id == display.id}},set:{state.setScreen(id:display.id,name:display.name,enabled:$0)}))
                }
                ForEach(state.current.screens.filter { screen in !state.displays.contains{$0.id == screen.id} }) { screen in
                    Toggle("\(screen.name)（未连接）",isOn:Binding(get:{true},set:{state.setScreen(id:screen.id,name:screen.name,enabled:$0)}))
                }
            } label: { Label(state.current.screens.isEmpty ? "显示器：当前屏幕" : "显示器：\(state.current.screens.count) 块",systemImage:"display.2") }
        }.controlSize(.small)
    }
    private func activateScreen(_ id: String) {
        guard state.editingScreenID != id else { return }
        state.screenID = id; resetSelection()
    }
    private func resetSelection() { selectedScreenID = state.editingScreenID; selected = state.partition.root.panes.first; seamID = "" }
    private func changePosition(line: String, percent: Double) {
        partition.wrappedValue.root = state.partition.root.movingLine(line,toPercent:percent); seamID = line
    }
    private func changePosition(_ percent: Double) {
        guard percent.isFinite else { return }
        partition.wrappedValue.root = state.partition.root.movingLine(seamID,toPercent:percent)
    }
    private func split(_ axis: SplitAxis) {
        guard let pane = selected ?? state.partition.root.panes.first else { return }
        let previous = Set(state.partition.root.splitIDs)
        let previousPanes = Set(state.partition.root.panes)
        var value = state.partition; value.root = value.root.splittingPane(pane,axis:axis)
        if value.emptyPanes.contains(pane) { value.emptyPanes.formUnion(Set(value.root.panes).subtracting(previousPanes)) }
        partition.wrappedValue = value
        seamID = state.partition.root.splitIDs.first { !previous.contains($0) } ?? ""
    }
}
