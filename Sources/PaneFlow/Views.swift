import SwiftUI
import PaneFlowCore

private final class WindowDragView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        toolTip = "拖动此处移动面板"
        setAccessibilityElement(true); setAccessibilityLabel("移动布局面板")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with:event) }
}
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView(frame:.zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PaneFlowLogo: View {
    var size: CGFloat = 36
    var appIcon = false
    var body: some View {
        Image(nsImage:PaneFlowBrand.image(size:256,template:!appIcon)).resizable().interpolation(.high)
            .foregroundStyle(.primary).frame(width:size,height:size).accessibilityHidden(true)
    }
}

struct PermissionStatus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            Label(model.trusted ? "辅助功能：已允许" : "辅助功能：未允许",
                  systemImage:model.trusted ? "checkmark.circle.fill" : "hand.raised.fill")
                .foregroundStyle(model.trusted ? Color.green : Color.orange)
            Spacer()
            Button(model.trusted ? "系统设置…" : "开启辅助功能") { WindowAccess.requestPermission() }
        }
    }
}

struct LayoutCanvas: View {
    var root: LayoutNode
    var emptyPanes = Set<String>()
    var names: [String: String] = [:]
    var details: [String: String] = [:]
    var selected: String?
    var editing = false
    var selectedLine: String?
    var choose: (String) -> Void
    var moveLine: ((String, Double) -> Void)? = nil
    var selectLine: ((String) -> Void)? = nil
    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let gap = editing ? 0.0 : 5.0
            let geometry = try? LayoutGeometry.make(root, in: bounds, gap: gap, scale: 2)
            ZStack(alignment: .topLeading) {
                ForEach(Array(root.panes.enumerated()), id: \.element) { index, slot in
                    if let frame = geometry?.panes[slot] {
                        pane(slot,index:index,frame:frame)
                    }
                }
                if let moveLine {
                    ForEach(geometry?.seams ?? [], id: \.id) { seam in
                        divider(seam,bounds:bounds,moveLine:moveLine)
                    }
                }
            }.coordinateSpace(name: "layout-editor")
        }
    }
    private func pane(_ slot: String, index: Int, frame: CGRect) -> some View {
        let empty = emptyPanes.contains(slot)
        let number = (root.panes.filter { !emptyPanes.contains($0) }.firstIndex(of:slot) ?? index)+1
        let label = empty ? "留白" : (names[slot] ?? "区域 \(number)")
        let action = editing ? "选择区域" : (empty ? "不放窗口" : "点击放置")
        let hint = editing ? "选择区域后添加横线、竖线或设为留白。" : (empty ? "留白区域不会放入窗口。" : (details[slot] ?? "点击放入当前窗口；已有窗口时交换位置。"))
        return Button { choose(slot) } label: {
            VStack(spacing:5) {
                Text(label).font(.system(size:11,weight:.medium)).lineLimit(1)
                if let detail = details[slot], !detail.isEmpty {
                    Text(detail).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }.frame(width:frame.width,height:frame.height).foregroundStyle(Color.primary)
        }.buttonStyle(LayoutRegionStyle(selected:selected == slot,empty:empty)).position(x:frame.midX,y:frame.midY)
            .disabled(empty && !editing).help(hint).accessibilityLabel("\(label)，\(action)")
    }
    private func divider(_ seam: LayoutSeam, bounds: CGRect, moveLine: @escaping (String,Double) -> Void) -> some View {
        let vertical = seam.axis == .horizontal
        return RoundedRectangle(cornerRadius:2).fill(selectedLine == seam.id ? Color.accentColor : Color.secondary.opacity(0.55))
            .frame(width:vertical ? 4 : 34,height:vertical ? 34 : 4)
            .padding(vertical ? .horizontal : .vertical,5)
            .contentShape(Rectangle()).position(x:seam.line.midX,y:seam.line.midY)
            .onHover { inside in (inside ? (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set() }
            .help("拖动分隔线，每次调整 1%；点击可输入位置。")
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("layout-editor")).onChanged { value in
                let coordinate = vertical ? value.location.x : value.location.y
                let extent = vertical ? bounds.width : bounds.height
                let percent = Double(coordinate/extent)*100
                moveLine(seam.id,LayoutPreset.snappedPercent(percent))
            })
            .onTapGesture { selectLine?(seam.id) }
            .accessibilityLabel(vertical ? "竖向分隔线" : "横向分隔线")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selectLine?(seam.id) }
    }
}

private struct LayoutRegionStyle: ButtonStyle {
    let selected: Bool
    var empty = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered || configuration.isPressed || selected ? Color.accentColor.opacity(0.12) : Color(nsColor:.controlBackgroundColor).opacity(empty ? 0.08 : 0.35),in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(hovered || selected ? Color.accentColor : Color(nsColor:.separatorColor),style:StrokeStyle(lineWidth:1,dash:empty ? [4,3] : [])))
            .contentShape(RoundedRectangle(cornerRadius:7))
            .animation(reduceMotion ? nil : .easeOut(duration:0.10),value:hovered)
            .onHover { hovered = $0 }
    }
}

struct PaletteView: View {
    @ObservedObject var model: AppModel
    let target: LiveWindow
    let close: () -> Void
    let edit: () -> Void
    private var destinationResult: Result<[WindowGroup],Error> { Result { try model.destinations(for:target.frame) } }
    private var destinationError: String? {
        if case .failure(let error) = destinationResult { return error.localizedDescription }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing:8) {
                    PaneFlowLogo(size:22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("窗合 PaneFlow").font(.system(size:13,weight:.semibold))
                        Text(target.label).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(target.label)
                    }
                    Spacer(minLength:0)
                }.padding(.horizontal,14).padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading).overlay(WindowDragArea())
                Button(action: close) { Image(systemName: "xmark").font(.system(size:10,weight:.semibold)) }.buttonStyle(.plain).accessibilityLabel("关闭面板")
                    .foregroundStyle(.secondary).help("关闭面板（Esc），窗口联动会保留。")
                    .frame(width:30,height:30).padding(.trailing,8)
            }
            Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if !model.trusted { PermissionStatus(model:model).font(.caption) }
                    HStack {
                        Picker("布局", selection: $model.preferences.activeLayout) {
                            ForEach(model.layouts) { Text($0.name).tag($0.id) }
                        }
                        Button("管理…", action: edit)
                    }.controlSize(.small)
                    Text("点击分区放置当前窗口，已有窗口时交换位置。")
                        .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    layoutPreviews.disabled(model.busy || !model.trusted)
                    Divider()
                    HStack {
                        Text("排列多个窗口").font(.system(size:12,weight:.semibold))
                        Spacer()
                        Text("\(model.selectedIDs.count)/\(model.layout.windowCount)").font(.caption).foregroundStyle(.secondary)
                        Button("刷新") { Task { await model.refresh(focused: target) } }.controlSize(.small)
                    }
                    Text(model.layout.screens.isEmpty ? "最多勾选 \(model.layout.windowCount) 个窗口，留白区域会自动跳过。" : "按显示器顺序填入区域，最多 \(model.layout.windowCount) 个窗口。")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                    List {
                        ForEach(model.windows) { window in
                            Toggle(isOn: Binding(get: { model.selectedIDs.contains(window.id) }, set: { enabled in
                                if enabled {
                                    if model.layout.windowCount == 1 { model.selectedIDs = [window.id] }
                                    else if model.selectedIDs.count < model.layout.windowCount { model.selectedIDs.insert(window.id) }
                                } else { model.selectedIDs.remove(window.id) }
                            })) {
                                Text(window.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(window.label)
                            }.toggleStyle(.checkbox)
                                .disabled(model.layout.windowCount > 1 && model.selectedIDs.count >= model.layout.windowCount && !model.selectedIDs.contains(window.id))
                        }
                        if model.windows.isEmpty { Text("没有找到可调整的窗口，请先打开一个普通窗口。").font(.caption).foregroundStyle(.secondary) }
                    }.listStyle(.inset).scrollContentBackground(.hidden).frame(minHeight:100,maxHeight:.infinity)
                }.padding(.horizontal,14).padding(.vertical,12)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(model.busy ? "正在调整…" : (model.selectedIDs.count > 1 ? "排列并联动" : "放置所选窗口")) {
                        model.arrangeSelected { success in if success { close() } }
                    }
                        .buttonStyle(.borderedProminent).disabled(model.busy || !model.trusted || model.selectedIDs.isEmpty || model.selectedIDs.count > model.layout.windowCount || destinationError != nil)
                        .help("按列表顺序排列所选窗口，成功后自动收起面板。")
                    Button("撤销", action: model.undo).disabled(model.busy || model.undoCount == 0)
                    Spacer()
                }
                Text("⌥ 拖动标题栏交换分区 · 拖动分隔条联动缩放")
                    .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Label(model.linkStatus,systemImage:"rectangle.split.2x1").font(.system(size:11)).help(model.linkHint)
                Text(model.notice).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(2)
                Text("完成后自动收起 · 点击外部或按 Esc 关闭")
                    .font(.system(size:10)).foregroundStyle(.tertiary)
            }.padding(.horizontal,14).padding(.vertical,12).controlSize(.small)
        }.frame(minWidth: 320, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            .disabled(model.paused)
            .onAppear(perform:limitSelection)
            .onChange(of:model.preferences.activeLayout) { _,_ in limitSelection() }
    }
    @ViewBuilder private var layoutPreviews: some View {
        if let error = destinationError {
            Text(error).font(.callout).foregroundStyle(.secondary).frame(height:108).fixedSize(horizontal:false,vertical:true)
        } else if let groups = try? destinationResult.get() {
            if model.layout.screens.isEmpty, let group = groups.first { preview(group).frame(height:108) }
            else {
                ScrollView(.horizontal) {
                    HStack(alignment:.top,spacing:12) {
                        ForEach(groups,id:\.screenID) { group in
                            VStack(spacing:5) {
                                Text(model.layout.screens.first{$0.id == group.screenID}?.name ?? "显示器").font(.caption).lineLimit(1)
                                preview(group).aspectRatio(group.bounds.width/group.bounds.height,contentMode:.fit).frame(height:86)
                            }.frame(width:groups.count == 1 ? 280 : 155)
                        }
                    }
                }.frame(height:112)
            }
        }
    }
    private func preview(_ group: WindowGroup) -> some View {
        LayoutCanvas(root:group.preset.root,emptyPanes:group.preset.emptyPanes,names:group.members.mapValues{$0.app.name},details:group.members.mapValues{$0.title}) { slot in
            model.place(target,slot:slot,in:group) { success in if success { close() } }
        }
    }
    private func limitSelection() {
        if model.selectedIDs.count > model.layout.windowCount { model.selectedIDs = [target.id] }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var edit: () -> Void
    var body: some View {
        Form {
            Section {
                HStack(spacing:14) {
                    PaneFlowLogo(size:52,appIcon:true)
                    VStack(alignment:.leading,spacing:3) {
                        Text("窗合").font(.system(size:22,weight:.semibold))
                        Text("PaneFlow").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical,4)
            }
            Section("辅助功能") {
                PermissionStatus(model:model)
                Text("允许后可移动和调整其他应用的窗口。").font(.caption).foregroundStyle(.secondary)
            }
            Section("联动状态") {
                Label(model.linkStatus,systemImage:model.visibleLinkCount > 0 ? "link.circle.fill" : "link")
                Text(model.linkHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Button("打开布局面板") { model.onOpenPalette?() }
            }
            Section("窗口行为") {
                Toggle("窗口之间磁吸", isOn: $model.preferences.magnetEnabled)
                Toggle("同一布局内联动缩放", isOn: $model.preferences.linkedEnabled).onChange(of: model.preferences.linkedEnabled) { _, _ in model.onGroupsChanged?() }
                Toggle("⌥ 拖动显示布局分区", isOn: $model.preferences.zonesEnabled)
                Toggle("⌥ 悬停绿按钮显示面板", isOn: $model.preferences.hoverEnabled)
            }
            Section("布局间距") {
                HStack { Text("窗口间距"); Slider(value: $model.preferences.gap, in: 0...40, step: 1); Text("\(Int(model.preferences.gap)) pt").monospacedDigit().frame(width: 48) }
                HStack { Text("屏幕留边"); Slider(value: $model.preferences.margin, in: 0...80, step: 1); Text("\(Int(model.preferences.margin)) pt").monospacedDigit().frame(width: 48) }
                Text("间距修改会用于下一次放置或排列。").font(.caption).foregroundStyle(.secondary)
                Button("布局管理…", action: edit)
            }
            Section("使用") {
                Text("⌃⌥ Space：打开或收起布局面板\n点击分区：放置当前窗口，占用时交换\n勾选多个窗口：排列后建立联动\n⌥ 拖动标题栏：放入高亮分区或交换窗口\n⌃ 拖动：临时跳过磁吸\n拖动窗口之间的分隔条：联动缩放\n点击外部或按 Esc：收起面板")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("打开练习窗口", action: model.openPractice)
                Button("备份并重置设置", action: model.backupAndResetSettings)
                Text(model.notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped).frame(minWidth: 500, minHeight: 480)
    }
}
