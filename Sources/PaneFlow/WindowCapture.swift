import AppKit
import SwiftUI
import PaneFlowCore

@MainActor final class WindowCaptureState: ObservableObject {
    let manager: LayoutManagerState
    @Published var windows: [LiveWindow]
    @Published var selected: Set<String> { didSet { error = nil } }
    @Published var loading = false
    @Published var committing = false
    @Published var error: String?
    private let fixtures: [LiveWindow]?
    init(manager: LayoutManagerState, fixtures: [LiveWindow]? = nil, selected: Set<String> = []) {
        self.manager = manager; self.fixtures = fixtures; windows = fixtures ?? []; self.selected = selected
    }
    var picked: [LiveWindow] { windows.filter { selected.contains($0.id) } }
    func display(for window: LiveWindow) -> Desktop? {
        manager.displays.max { a,b in
            let first = a.frame.intersection(window.frame), second = b.frame.intersection(window.frame)
            return (first.isNull ? 0 : first.width*first.height) < (second.isNull ? 0 : second.width*second.height)
        }
    }
    func refresh(apps: [WindowApp]? = nil) async {
        guard fixtures == nil else { return }
        loading = true; error = nil
        let values = await manager.model.access.scan(apps ?? WindowApp.running)
        windows = values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        selected.formIntersection(Set(windows.map(\.id)))
        if !WindowAccess.trusted { error = "需要先允许 PaneFlow 的辅助功能权限，再刷新窗口列表。" }
        loading = false
    }
    func confirm() async -> Bool {
        let chosen = picked
        guard !chosen.isEmpty else { error = LayoutCaptureError.empty.localizedDescription; return false }
        committing = true; error = nil
        defer { committing = false }
        let frames = await manager.model.access.read(chosen)
        guard frames.count == chosen.count else { error = "有窗口已关闭或无法读取，请刷新后重新选择。"; return false }
        let current = chosen.map { item -> LiveWindow in var value = item; value.frame = frames[item.id]!; return value }
        do { try manager.captureWindows(current); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

struct WindowCaptureView: View {
    @StateObject private var state: WindowCaptureState
    @Environment(\.dismiss) private var dismiss
    init(manager: LayoutManagerState, fixtures: [LiveWindow]? = nil, selected: Set<String> = []) {
        _state = StateObject(wrappedValue:WindowCaptureState(manager:manager,fixtures:fixtures,selected:selected))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("读取窗口排列").font(.title2).fontWeight(.semibold)
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await state.refresh() } }.disabled(state.loading || state.committing)
            }
            Text("勾选参与的窗口，读取当前位置、大小和间隙。真实窗口保持原位。").foregroundStyle(.secondary)
            HSplitView {
                windowList.frame(minWidth:280,idealWidth:340,maxWidth:380)
                VStack(alignment:.leading,spacing:10) {
                    Text("已选 \(state.selected.count) 个窗口").font(.headline)
                    CapturedWindowsPreview(displays:state.manager.displays,windows:state.picked)
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                    Text("勾选的窗口会在这里显示。重叠的窗口需要取消选择，或先排好后刷新。").font(.caption).foregroundStyle(.secondary)
                }.padding(.leading,16).frame(minWidth:380)
            }.disabled(state.committing)
            if let error = state.error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Text("生成后可继续编辑，保存后生效。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.committing)
                Button(state.committing ? "正在读取…" : "生成布局") {
                    Task { if await state.confirm() { dismiss() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(state.selected.isEmpty || state.loading || state.committing)
            }
        }.padding(24).frame(minWidth:900,idealWidth:1000,minHeight:560,idealHeight:640)
            .task { await state.refresh() }.interactiveDismissDisabled(state.committing)
    }
    private var windowList: some View {
        List {
            ForEach(state.manager.displays) { display in
                Section(display.name) {
                    ForEach(state.windows.filter { state.display(for:$0)?.id == display.id }) { window in row(window) }
                }
            }
            if state.windows.isEmpty && !state.loading { Text("没有找到当前桌面可读取的普通窗口。").foregroundStyle(.secondary) }
        }.listStyle(.inset).scrollContentBackground(.hidden)
    }
    private func row(_ window: LiveWindow) -> some View {
        Toggle(isOn:Binding(get:{state.selected.contains(window.id)},set:{ value in
            if value { state.selected.insert(window.id) } else { state.selected.remove(window.id) }
        })) {
            HStack(spacing:8) {
                if let icon = NSRunningApplication(processIdentifier:window.app.pid)?.icon { Image(nsImage:icon).resizable().frame(width:20,height:20) }
                VStack(alignment:.leading,spacing:2) {
                    Text(window.app.name).font(.callout).lineLimit(1)
                    Text(window.title.isEmpty ? "未命名窗口" : window.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text("\(Int(window.frame.width)) × \(Int(window.frame.height)) pt").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }.help(window.label)
        }.toggleStyle(.checkbox).padding(.vertical,3)
    }
}

private struct CapturedWindowsPreview: View {
    let displays: [Desktop]
    let windows: [LiveWindow]
    var body: some View {
        Canvas { context,size in
            let frames = DisplayGeometry.fittedFrames(displays.map(\.frame),in:CGRect(origin:.zero,size:size))
            for (index,display) in displays.enumerated() where frames.indices.contains(index) {
                let frame = frames[index].insetBy(dx:4,dy:4)
                let path = Path(roundedRect:frame,cornerRadius:7)
                context.fill(path,with:.color(Color(nsColor:.controlBackgroundColor)))
                context.stroke(path,with:.color(Color(nsColor:.separatorColor)),lineWidth:1)
                context.draw(Text(display.name).font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:frame.midX,y:frame.minY+12))
                let area = CGRect(x:frame.minX+5,y:frame.minY+25,width:max(1,frame.width-10),height:max(1,frame.height-30))
                for window in windows {
                    let clipped = window.frame.intersection(display.visible)
                    guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
                    let target = CGRect(x:area.minX+(clipped.minX-display.visible.minX)/display.visible.width*area.width,
                                        y:area.minY+(clipped.minY-display.visible.minY)/display.visible.height*area.height,
                                        width:clipped.width/display.visible.width*area.width,height:clipped.height/display.visible.height*area.height)
                    let outline = Path(roundedRect:target,cornerRadius:3)
                    context.fill(outline,with:.color(.accentColor.opacity(0.15)))
                    context.stroke(outline,with:.color(.accentColor),lineWidth:1)
                    if target.width > 45 && target.height > 20 {
                        var text = context; text.clip(to:outline)
                        text.draw(Text(window.app.name).font(.system(size:9)),at:CGPoint(x:target.midX,y:target.midY))
                    }
                }
            }
        }.accessibilityLabel("所选窗口在各显示器上的当前位置预览")
    }
}
