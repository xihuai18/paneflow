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
    var names: [String: String] = [:]
    var details: [String: String] = [:]
    var selected: String?
    var choose: (String) -> Void
    var changeRatio: ((String, Double) -> Void)? = nil
    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let geometry = try? LayoutGeometry.make(root, in: bounds, gap: 5, scale: 2)
            ZStack(alignment: .topLeading) {
                ForEach(Array(root.panes.enumerated()), id: \.element) { index, slot in
                    if let frame = geometry?.panes[slot] {
                        Button { choose(slot) } label: {
                            VStack(spacing: 5) {
                                Text(names[slot] ?? "区域 \(index + 1)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                                if let detail = details[slot], !detail.isEmpty {
                                    Text(detail).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }.frame(width: frame.width, height: frame.height)
                                .foregroundStyle(selected == slot ? Color.white : Color.primary)
                        }.buttonStyle(LayoutRegionStyle(selected:selected == slot)).position(x: frame.midX, y: frame.midY)
                            .help(details[slot] ?? "点击放入当前窗口；已有窗口时交换位置。")
                            .accessibilityLabel("\(names[slot] ?? "区域 \(index + 1)")，点击放置或选择")
                    }
                }
                if let changeRatio {
                    ForEach(geometry?.seams ?? [], id: \.id) { seam in
                        let vertical = seam.axis == .horizontal
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.65))
                            .frame(width: vertical ? 4 : 34, height: vertical ? 34 : 4)
                            .padding(vertical ? .horizontal : .vertical, 5)
                            .contentShape(Rectangle()).position(x: seam.line.midX, y: seam.line.midY)
                            .gesture(DragGesture(coordinateSpace: .named("layout-editor")).onChanged { value in
                                let coordinate = vertical ? value.location.x : value.location.y
                                if let ratio = try? seam.ratio(at: coordinate, gap: 5, minimums: [:], scale: 2) { changeRatio(seam.id, ratio) }
                            })
                    }
                }
            }.coordinateSpace(name: "layout-editor")
        }
    }
}

private struct LayoutRegionStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(selected ? Color.accentColor : (hovered || configuration.isPressed ? Color.accentColor.opacity(0.14) : Color(nsColor:.controlBackgroundColor).opacity(0.35)),in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(hovered || selected ? Color.accentColor : Color(nsColor:.separatorColor),lineWidth:1))
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
    var destination: WindowGroup? {
        guard let desktop = model.desktop(for: target.frame) else { return nil }
        return model.groups.last { $0.screenID == desktop.id && $0.preset.id == model.layout.id && $0.preset.root == model.layout.root }
            ?? model.makeGroup(layout: model.layout, desktop: desktop)
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
                        Button("自定义…", action: edit)
                    }.controlSize(.small)
                    Text("点击分区放置当前窗口，已有窗口时交换位置。")
                        .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    LayoutCanvas(root: model.layout.root, names: destination?.members.mapValues { $0.app.name } ?? [:], details:destination?.members.mapValues { $0.title } ?? [:]) { slot in
                        if let destination { model.place(target, slot: slot, in: destination) { success in if success { close() } } }
                    }.frame(height: 108).disabled(model.busy || !model.trusted)
                    Divider()
                    HStack {
                        Text("排列多个窗口").font(.system(size:12,weight:.semibold))
                        Spacer()
                        Text("\(model.selectedIDs.count)/\(model.layout.root.panes.count)").font(.caption).foregroundStyle(.secondary)
                        Button("刷新") { Task { await model.refresh(focused: target) } }.controlSize(.small)
                    }
                    Text("最多勾选 \(model.layout.root.panes.count) 个窗口，按列表顺序填入分区。")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                    List {
                        ForEach(model.windows) { window in
                            Toggle(isOn: Binding(get: { model.selectedIDs.contains(window.id) }, set: { enabled in
                                if enabled { model.selectedIDs.insert(window.id) } else { model.selectedIDs.remove(window.id) }
                            })) {
                                Text(window.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(window.label)
                            }.toggleStyle(.checkbox)
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
                        .buttonStyle(.borderedProminent).disabled(model.busy || !model.trusted || model.selectedIDs.isEmpty)
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
    }
}

struct LayoutEditorView: View {
    @ObservedObject var model: AppModel
    @State var draft: LayoutPreset
    @State private var selected: String?
    @State private var seamID = ""
    var close: () -> Void
    private var seams: [LayoutSeam] { (try? LayoutGeometry.make(draft.root, in: CGRect(x: 0, y: 0, width: 500, height: 260), gap: 5).seams) ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("布局名称", text: $draft.name).textFieldStyle(.roundedBorder)
            LayoutCanvas(root: draft.root, selected: selected, choose: { selected = $0 }, changeRatio: { key, ratio in
                draft.root = draft.root.replacingRatio(key, with: ratio); seamID = key
            }).frame(height: 250)
            HStack {
                Text("选中区域后拆分").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("左右拆分") { split(.horizontal) }.disabled(draft.root.panes.count >= 16)
                Button("上下拆分") { split(.vertical) }.disabled(draft.root.panes.count >= 16)
            }
            if !seams.isEmpty {
                HStack {
                    Picker("分隔线", selection: $seamID) {
                        ForEach(Array(seams.enumerated()), id: \.element.id) { index, seam in Text("\(index + 1) · \(seam.axis == .horizontal ? "左右" : "上下")").tag(seam.id) }
                    }.frame(maxWidth: 200)
                    Text("比例")
                    TextField("百分比", value: Binding(get: { (seams.first { $0.id == seamID }?.ratio ?? 0.5) * 100 }, set: { value in
                        if value.isFinite { draft.root = draft.root.replacingRatio(seamID, with: max(0.001, min(0.999, value / 100))) }
                    }), format: .number.precision(.fractionLength(0...1))).frame(width: 65).textFieldStyle(.roundedBorder)
                    Text("%")
                }
            }
            Text("拖动预览中的分隔条可调整比例。只保存布局形状，不保存窗口标题。").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack { Button("取消", action: close); Spacer(); Button("保存布局") { model.saveLayout(draft); close() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(22).frame(minWidth: 500, minHeight: 470).background(Color(nsColor:.windowBackgroundColor))
            .onAppear { selected = draft.root.panes.first; seamID = seams.first?.id ?? "" }
    }
    private func split(_ axis: SplitAxis) {
        guard let pane = selected ?? draft.root.panes.first, draft.root.panes.count < 16 else { return }
        draft.root = draft.root.splittingPane(pane, axis: axis)
        seamID = seams.last?.id ?? ""
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
                Button("自定义布局…", action: edit)
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
