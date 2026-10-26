import AppKit
import SwiftUI
import ApplicationServices
import PaneFlowCore

private struct HandlePreview: NSViewRepresentable {
    let axis: SplitAxis
    func makeNSView(context: Context) -> NSView {
        let view = SeamView(frame:.zero); view.axis = axis; return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor enum Verification {
    static var previewLayouts: Bool { CommandLine.arguments.contains("--preview-layouts") }
    static var requested: Bool { CommandLine.arguments.contains("--verify-interface") || CommandLine.arguments.contains("--verify-native") || CommandLine.arguments.contains("--verify-layouts") }
    static func run(delegate: AppDelegate) async {
        let native = CommandLine.arguments.contains("--verify-native")
        let layouts = CommandLine.arguments.contains("--verify-layouts")
        let flag = layouts ? "--verify-layouts" : native ? "--verify-native" : "--verify-interface"
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index+1) else { fputs("Missing verification output path\n",stderr); exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[index+1])
        var results: [[String: Any]] = []
        var exitCode: Int32 = 0
        var status = "passed"
        var detail = ""
        do {
            if layouts { try layoutChecks(directory:output.deletingLastPathComponent(),results:&results) }
            else if native {
                if !WindowAccess.trusted { status = "blocked"; exitCode = 77; detail = "PaneFlow needs Accessibility permission before external practice-window verification." }
                else { try await nativeChecks(delegate: delegate, results: &results) }
            } else { try await interfaceChecks(delegate: delegate, directory: output.deletingLastPathComponent(), results: &results) }
        } catch { status = "failed"; exitCode = 1; detail = error.localizedDescription }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["kind": layouts ? "layout-management" : native ? "native-practice" : "interface", "status":status, "detail":detail, "checks":results],options:[.prettyPrinted,.sortedKeys])
            try data.write(to: output,options:.atomic)
        } catch { fputs("Could not write verification report\n",stderr); exit(1) }
        delegate.model.access.shutdown()
        print("\(status): \(results.count) checks; \(output.path)")
        exit(exitCode)
    }
    private static func require(_ value: Bool, _ name: String, _ results: inout [[String:Any]], observed: [String:Any] = [:]) throws {
        var result: [String:Any] = ["name":name,"passed":value]
        if !observed.isEmpty { result["observed"] = observed }
        results.append(result); if !value { throw NSError(domain:"PaneFlowVerification",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
    }
    private static func layoutChecks(directory: URL, results: inout [[String:Any]]) throws {
        let fixture = directory.appendingPathComponent("layout-fixture-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        let path = fixture.appendingPathComponent("preferences.json")
        let model = AppModel(storageURL:path)
        let saved = LayoutPreset(id:"saved-layout",name:"阅读",root:LayoutPreset.builtins[3].root)
        try require(model.saveLayout(saved),"save initial custom layout",&results)
        let state = LayoutManagerState(model:model)
        try require(state.current == saved && !state.isDirty,"manager selects the saved current layout",&results)
        state.drafts[saved.id]?.name = "编辑与阅读"
        state.drafts[saved.id]?.root = saved.root.replacingRatio("main",with:0.45)
        state.selectedID = LayoutPreset.builtins[0].id
        try require(state.dirtyIDs == [saved.id],"switching selection preserves unsaved edits",&results)
        state.selectedID = saved.id
        try require(state.save() && model.preferences.customLayouts.count == 1 && model.layout.id == saved.id,
                    "saving edits retains identity without creating a duplicate",&results)
        try require(AppModel(storageURL:path).layout == state.current,"edited name and geometry survive disk reload",&results)
        let edited = state.current
        state.duplicate(); let copyID = state.selectedID
        try require(copyID != saved.id && state.current.root == edited.root && state.isDirty,"save-as creates a separate editable draft",&results)
        try require(state.save() && model.preferences.customLayouts.count == 2 && model.preferences.customLayouts.first{$0.id == saved.id} == edited,
                    "saving the copy leaves the original intact",&results)
        state.drafts[copyID]?.name = "未保存的修改"; state.revert()
        try require(!state.isDirty && state.current.name != "未保存的修改","revert restores the saved copy",&results)
        state.create(); let newID = state.selectedID
        state.drafts[newID]?.root = state.current.root.splittingPane(state.current.root.panes[0],axis:.horizontal)
        state.selectedID = saved.id; state.drafts[saved.id]?.name = "阅读工作台"
        try require(state.dirtyIDs.count == 2 && state.saveAll(),"save all commits independent drafts",&results)
        try require(AppModel(storageURL:path).preferences.customLayouts.count == 3,"all layouts survive disk reload",&results)
        state.selectedID = copyID; state.removeCurrent()
        try require(!model.preferences.customLayouts.contains{$0.id == copyID} && AppModel(storageURL:path).preferences.customLayouts.count == 2,
                    "delete removes only the selected layout from disk",&results)
        state.selectedID = newID; _ = state.save(); state.removeCurrent()
        try require(model.layouts.contains{$0.id == model.preferences.activeLayout},"deleting the active layout selects an existing fallback",&results)
        try require(!model.saveLayout(LayoutPreset.builtins[0]) && !model.deleteLayout(LayoutPreset.builtins[0].id),"built-in layouts cannot be overwritten or deleted",&results)
        let before = model.preferences.customLayouts
        var invalid = edited; invalid.name = "   "
        try require(!model.saveLayout(invalid) && model.preferences.customLayouts == before,"invalid edits leave saved layouts intact",&results)
        let capped = AppModel(ephemeral:true)
        capped.preferences.customLayouts = (0..<100).map { LayoutPreset(id:"fixture-\($0)",name:"布局 \($0)",root:.pane("a")) }
        var existing = capped.preferences.customLayouts[0]; existing.name = "修改现有布局"
        try require(capped.saveLayout(existing) && capped.preferences.customLayouts.count == 100,"the layout limit still permits editing existing layouts",&results)
        try require(!capped.saveLayout(LayoutPreset(name:"超出上限",root:.pane("a"))),"the layout limit only rejects additional layouts",&results)
        let blockedParent = fixture.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to:blockedParent)
        let blocked = AppModel(storageURL:blockedParent.appendingPathComponent("preferences.json"))
        let blockedState = LayoutManagerState(model:blocked); blockedState.create()
        try require(!blockedState.save() && blocked.preferences.customLayouts.isEmpty && blockedState.isDirty && blockedState.error != nil,
                    "write failure preserves the dirty draft and does not change saved state",&results)
        var blankLayout = LayoutPreset.builtins.first{$0.id == "centered-two-thirds"}!
        blankLayout.id = "blank-fixture"
        try require(model.saveLayout(blankLayout) && AppModel(storageURL:path).layout.emptyPanes == blankLayout.emptyPanes,"blank regions survive save and reload",&results)
        let blankState = LayoutManagerState(model:model); blankState.duplicate()
        try require(blankState.current.emptyPanes == blankLayout.emptyPanes,"copy preserves blank regions",&results)
        var versionTwo = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
        versionTwo["version"] = 2
        let versionTwoPath = fixture.appendingPathComponent("version-two.json")
        let versionTwoBytes = try JSONSerialization.data(withJSONObject:versionTwo)
        try versionTwoBytes.write(to:versionTwoPath)
        let versionTwoModel = AppModel(storageURL:versionTwoPath)
        try require(versionTwoModel.preferences.version == 3 && versionTwoModel.preferences.customLayouts == model.preferences.customLayouts,"version-two layouts retain geometry and blank regions after migration",&results)
        try require((try Data(contentsOf:versionTwoPath.appendingPathExtension("backup-before-multiscreen-v3"))) == versionTwoBytes,"version-two migration retains exact original bytes",&results)
        var oldSettings = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
        oldSettings["version"] = 1
        oldSettings["customLayouts"] = (oldSettings["customLayouts"] as! [[String:Any]]).map { item -> [String:Any] in var item = item; item["emptyPanes"] = nil; return item }
        let legacyPath = fixture.appendingPathComponent("legacy.json")
        let legacyBytes = try JSONSerialization.data(withJSONObject:oldSettings)
        try legacyBytes.write(to:legacyPath)
        let migrated = AppModel(storageURL:legacyPath)
        try require(migrated.preferences.version == 3 && migrated.preferences.customLayouts.allSatisfy{$0.emptyPanes.isEmpty && $0.screens.isEmpty},"old layouts retain all original window regions after migration",&results)
        try require((try Data(contentsOf:legacyPath.appendingPathExtension("backup-before-multiscreen-v3"))) == legacyBytes,"migration retains an exact backup of original settings",&results)
        let bytes = try Data(contentsOf:path)
        state.create(); state.discardAll()
        try require(state.dirtyIDs.isEmpty && (try Data(contentsOf:path)) == bytes,"discarding drafts does not modify saved settings",&results)
        let displays = [Desktop(id:"display-a",name:"显示器 A",frame:CGRect(x:-1600,y:0,width:1600,height:1000),visible:CGRect(x:-1600,y:30,width:1600,height:970),scale:1),
                        Desktop(id:"display-b",name:"显示器 B",frame:CGRect(x:0,y:-1200,width:900,height:1200),visible:CGRect(x:0,y:-1170,width:900,height:1170),scale:2)]
        let multiState = LayoutManagerState(model:model,displays:displays)
        multiState.setScreen(id:displays[0].id,name:displays[0].name,enabled:true)
        var first = multiState.partition; first.root = LayoutPreset.builtins[0].root; first.emptyPanes = []
        multiState.updatePartition(first)
        multiState.setScreen(id:displays[1].id,name:displays[1].name,enabled:true)
        var second = multiState.partition; second.root = LayoutPreset.builtins[1].root; second.emptyPanes = []
        multiState.updatePartition(second)
        try require(multiState.current.screens[0].root == first.root && multiState.current.screens[1].root == second.root,"editing one display preserves the other display",&results)
        multiState.setScreen(id:displays[0].id,name:displays[0].name,enabled:false)
        multiState.setScreen(id:displays[0].id,name:displays[0].name,enabled:true)
        try require(multiState.partition.root == first.root,"temporarily deselecting a display retains its draft",&results)
        try require(multiState.save() && AppModel(storageURL:path).layout.screens == multiState.current.screens,"selected displays and their layouts survive save and reload",&results)
        let resolved = try model.layoutGroups(model.layout,on:displays,fallback:displays[0])
        try require(resolved.count == 2 && resolved[0].screenID == displays[1].id && resolved[1].screenID == displays[0].id
                    && resolved[0].bounds == displays[1].visible.insetBy(dx:model.preferences.margin,dy:model.preferences.margin)
                    && resolved[0].scale == 2,"screen plan uses selected order, each usable frame and each pixel scale",&results)
        var missingRejected = false
        do { _ = try model.layoutGroups(model.layout,on:[displays[0]],fallback:displays[0]) } catch { missingRejected = true }
        try require(missingRejected,"missing selected displays fail before any windows move",&results)
        multiState.duplicate()
        try require(multiState.current.screens == model.layout.screens,"copy preserves the complete multi-display layout",&results)
        multiState.useCurrentScreen()
        try require(multiState.current.screens.isEmpty && multiState.current.root == first.root,"returning to current-screen mode keeps the edited partition",&results)
        multiState.setScreen(id:displays[0].id,name:displays[0].name,enabled:true)
        multiState.setScreen(id:displays[0].id,name:displays[0].name,enabled:false)
        try require(multiState.current.screens.isEmpty && multiState.current.root == first.root,"deselecting the last display preserves its edited current-screen layout",&results)
    }
    private static func blankPair() -> LayoutPreset {
        let pair = LayoutNode.split(id:"pair-divider",axis:.horizontal,ratio:0.5,first:.pane("a"),second:.pane("b"))
        let middle = LayoutNode.split(id:"top-line",axis:.vertical,ratio:0.1,first:.pane("top-space"),second:.split(id:"bottom-line",axis:.vertical,ratio:8.0/9,first:pair,second:.pane("bottom-space")))
        return LayoutPreset(id:"blank-pair-fixture",name:"双窗留白",root:.split(id:"left-line",axis:.horizontal,ratio:0.1,first:.pane("left-space"),second:.split(id:"right-line",axis:.horizontal,ratio:8.0/9,first:middle,second:.pane("right-space"))),emptyPanes:["left-space","right-space","top-space","bottom-space"])
    }
    private static func interfaceChecks(delegate: AppDelegate, directory: URL, results: inout [[String:Any]]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = delegate.model
        let app = WindowApp(pid:ProcessInfo.processInfo.processIdentifier,name:"Microsoft Edge",bundleID:"app.paneflow.interface")
        let samples = (1...3).map { index in LiveWindow(id:"interface-\(index)",element:AXUIElementCreateApplication(app.pid),app:app,title:"项目资料与工作窗口 \(index)",frame:CGRect(x:100,y:100,width:600,height:400)) }
        let sample = samples[0]
        model.preferences.activeLayout = LayoutPreset.builtins[3].id
        model.windows = samples; model.selectedIDs = Set(samples.map(\.id)); model.trusted = true
        if let desktop = Desktop.all.first {
            var group = model.makeGroup(layout:model.layout,desktop:desktop)
            for (slot,window) in zip(group.preset.root.panes,samples) { group.members[slot] = window }
            model.groups = [group]
        }
        for dark in [false,true] {
            model.linkStatus = "尚未建立联动布局"; model.linkHint = "在布局面板勾选多个窗口，点击“排列并联动”。"; model.visibleLinkCount = 0
            for width in [320.0,360.0] {
                let view = PaletteView(model:model,target:sample,close:{},edit:{})
                try await capture(view, size:NSSize(width:width,height:560), name:"palette-\(dark ? "dark" : "light")-\(Int(width))", dark:dark,directory:directory,results:&results)
            }
            for pointsUp in [true,false] {
                let host = NSHostingView(rootView:PaletteView(model:model,target:sample,close:{},edit:{}).environment(\.colorScheme,dark ? .dark : .light))
                let chrome = PaletteChrome(content:host,pointsUp:pointsUp,pointerX:44)
                try await captureNative(chrome,size:NSSize(width:380,height:540),name:"bubble-\(dark ? "dark" : "light")-\(pointsUp ? "above" : "below")",dark:dark,directory:directory,results:&results)
            }
            model.linkStatus = "已显示 3 个分隔条"; model.linkHint = "拖动竖向分隔条调整左右，横向分隔条调整上下。"; model.visibleLinkCount = 3
            try await capture(PreferencesView(model:model,edit:{}),size:NSSize(width:540,height:680),name:"settings-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            model.trusted = false
            model.linkStatus = "辅助功能未允许"; model.linkHint = "开启辅助功能后，即可排列并联动窗口。"; model.visibleLinkCount = 0
            try await capture(PreferencesView(model:model,edit:{}),size:NSSize(width:540,height:680),name:"settings-permission-off-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            try await capture(PaletteView(model:model,target:sample,close:{},edit:{}),size:NSSize(width:360,height:560),name:"palette-permission-off-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            model.trusted = true
            let manager = LayoutManagerState(model:model)
            try await capture(LayoutManagerView(state:manager),size:NSSize(width:880,height:620),name:"layouts-builtin-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            manager.duplicate()
            try await capture(LayoutManagerView(state:manager),size:NSSize(width:880,height:620),name:"layouts-custom-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            try await capture(LayoutManagerView(state:manager),size:NSSize(width:780,height:580),name:"layouts-compact-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            manager.selectedID = "centered-two-thirds"; manager.duplicate()
            try await capture(LayoutManagerView(state:manager),size:NSSize(width:880,height:620),name:"layouts-blank-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            let previewDisplays = [Desktop(id:"preview-a",name:"显示器 A",frame:CGRect(x:0,y:0,width:1600,height:1000),visible:CGRect(x:0,y:30,width:1600,height:970),scale:1),
                                   Desktop(id:"preview-b",name:"显示器 B",frame:CGRect(x:1600,y:0,width:900,height:1440),visible:CGRect(x:1600,y:30,width:900,height:1410),scale:2)]
            let multiManager = LayoutManagerState(model:model,displays:previewDisplays)
            multiManager.duplicate()
            for display in previewDisplays { multiManager.setScreen(id:display.id,name:display.name,enabled:true) }
            try await capture(LayoutManagerView(state:multiManager),size:NSSize(width:880,height:660),name:"layouts-multiscreen-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            if Desktop.all.count >= 2 {
                let configs = Desktop.all.prefix(2).enumerated().map { index,display in ScreenLayout(id:display.id,name:"显示器 \(index+1)",root:LayoutPreset.builtins[index].root) }
                let multiPreview = LayoutPreset(id:"multi-interface",name:"双屏工作",root:.pane("a"),screens:configs)
                if let index = model.preferences.customLayouts.firstIndex(where:{$0.id == multiPreview.id}) { model.preferences.customLayouts[index] = multiPreview }
                else { model.preferences.customLayouts.append(multiPreview) }
                model.preferences.activeLayout = multiPreview.id
                try await capture(PaletteView(model:model,target:sample,close:{},edit:{}),size:NSSize(width:380,height:540),name:"palette-multiscreen-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            }
            model.preferences.activeLayout = "centered-two-thirds"; model.selectedIDs = [sample.id]; model.linkStatus = "尚未建立联动布局"
            try await capture(PaletteView(model:model,target:sample,close:{},edit:{}),size:NSSize(width:380,height:540),name:"palette-blank-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
            model.preferences.activeLayout = LayoutPreset.builtins[3].id; model.selectedIDs = Set(samples.map(\.id))
            let handles = HStack(spacing:36) {
                HandlePreview(axis:.horizontal).frame(width:18,height:64)
                HandlePreview(axis:.vertical).frame(width:64,height:18)
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.windowBackgroundColor))
            try await capture(handles,size:NSSize(width:180,height:100),name:"handles-\(dark ? "dark" : "light")",dark:dark,directory:directory,results:&results)
        }
    }
    private static func capture<V:View>(_ view: V, size:NSSize, name:String, dark:Bool, directory:URL, results:inout [[String:Any]]) async throws {
        let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView:view.environment(\.colorScheme,dark ? .dark : .light).background(Color(nsColor:.windowBackgroundColor)))
        host.appearance = window.appearance; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for:.milliseconds(250))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw LayoutError.invalid }
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let png = bitmap.representation(using:.png,properties:[:]) else { throw LayoutError.invalid }
        try png.write(to:directory.appendingPathComponent(name+".png"))
        try require(bitmap.pixelsWide>0 && bitmap.pixelsHigh>0 && host.bounds.width>=size.width-1,"render \(name)",&results)
        window.close()
    }
    private static func captureNative(_ view:NSView, size:NSSize, name:String, dark:Bool, directory:URL, results:inout [[String:Any]]) async throws {
        let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        view.appearance = window.appearance; window.contentView = view
        window.center(); window.orderFrontRegardless()
        try await Task.sleep(for:.milliseconds(250))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw LayoutError.invalid }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let png = bitmap.representation(using:.png,properties:[:]) else { throw LayoutError.invalid }
        try png.write(to:directory.appendingPathComponent(name+".png"))
        try require(bitmap.pixelsWide>0 && bitmap.pixelsHigh>0 && view.bounds.width>=size.width-1,"render \(name)",&results)
        window.close()
    }
    private static func nativeChecks(delegate:AppDelegate, results:inout [[String:Any]]) async throws {
        let model = delegate.model
        delegate.connectControllers()
        defer { delegate.overlays.stop() }
        guard let url = Bundle.main.url(forResource:"PaneFlow Practice",withExtension:"app") else { throw NSError(domain:"PaneFlowVerification",code:2,userInfo:[NSLocalizedDescriptionKey:"Build the app bundle with its practice helper first."]) }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
        let helper: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at:url,configuration:configuration) { app,error in
                if let app { continuation.resume(returning:app) } else { continuation.resume(throwing:error ?? LayoutError.invalid) }
            }
        }
        let app = WindowApp(pid:helper.processIdentifier,name:"PaneFlow Practice",bundleID:"app.paneflow.practice")
        var windows: [LiveWindow] = []
        for _ in 0..<30 {
            windows = await model.access.scan([app]); if windows.count == 3 { break }
            try await Task.sleep(for:.milliseconds(150))
        }
        let originals = windows.map { WindowMove(window:$0,frame:$0.frame) }
        do {
            try require(windows.count==3,"three separate-process practice windows",&results)
            guard let initialDesktop = model.desktop(for:windows[0].frame) else { throw LayoutError.invalid }
            let desktop = Desktop.all.first(where:{$0.id != initialDesktop.id}) ?? initialDesktop
            let application = AXUIElementCreateApplication(app.pid)
            let exerciseEnhanced = !NSWorkspace.shared.isVoiceOverEnabled && !NSWorkspace.shared.isSwitchControlEnabled
            if exerciseEnhanced {
                _ = AXUIElementSetAttributeValue(application,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
                try require(WindowAccess.value(application,"AXEnhancedUserInterface") as? Bool == true,"practice enhanced accessibility is enabled before adjustment",&results)
            }
            model.windows = windows
            for margin in [10.0,0.0] {
              model.preferences.margin = margin
              for index in [0,1,3] {
                var group = model.makeGroup(layout:LayoutPreset.builtins[index],desktop:desktop)
                for (slot,window) in zip(group.preset.root.panes,windows) { group.members[slot] = window }
                let success = await model.commit(try group.moves(),groups:[group])
                try require(success,"apply \(group.preset.name) with margin \(Int(margin)) and actual AX readback",&results)
              }
            }
            if exerciseEnhanced {
                try require(WindowAccess.value(application,"AXEnhancedUserInterface") as? Bool == true,"arrangement restores practice enhanced accessibility",&results)
            }
            if Desktop.all.count >= 2 { try await multiScreenChecks(model:model,windows:windows,results:&results) }
            let fullLayoutFrames = await model.access.read(windows), fullDepth = model.undoCount
            model.preferences.activeLayout = "centered-two-thirds"; model.selectedIDs = [windows[0].id]
            model.arrangeSelected(); await Task.yield()
            for _ in 0..<200 { if !model.busy && model.undoCount>fullDepth { break }; try await Task.sleep(for:.milliseconds(100)) }
            guard let centerGroup = model.groups.first(where:{$0.preset.id == "centered-two-thirds"}) else { throw LayoutError.invalid }
            let centerFrame = await model.access.read([windows[0]])
            let target = try centerGroup.geometry().panes["center"]!
            try require(Set(centerGroup.members.keys) == ["center"] && centerFrame[windows[0].id].map{FrameSettler.matches($0,target)} == true && abs(target.midX-centerGroup.bounds.midX)<1 && abs(target.width-centerGroup.bounds.width*2/3)<1,
                        "automatic single-window arrangement skips both blank side regions",&results)
            var blankPlacement: Bool?
            model.place(windows[1],slot:"left-space",in:centerGroup) { blankPlacement = $0 }
            try require(blankPlacement == false,"direct placement into a blank region is rejected",&results)
            model.undo(); await Task.yield()
            for _ in 0..<200 { if !model.busy && model.undoCount == fullDepth { break }; try await Task.sleep(for:.milliseconds(100)) }
            let centerUndo = await model.access.read(windows)
            try require(windows.allSatisfy { w in fullLayoutFrames[w.id].flatMap { f in centerUndo[w.id].map{FrameSettler.matches($0,f)} } == true },"centered placement undo restores the full layout",&results)
            _ = model.saveLayout(blankPair()); model.selectedIDs = Set(windows.prefix(2).map(\.id))
            model.arrangeSelected(); await Task.yield()
            for _ in 0..<200 { if !model.busy && model.undoCount>fullDepth { break }; try await Task.sleep(for:.milliseconds(100)) }
            guard let pairGroup = model.groups.first(where:{$0.preset.id == "blank-pair-fixture"}),
                  let pairSeam = try pairGroup.geometry().seams.first(where:{$0.id == "pair-divider"}) else { throw LayoutError.invalid }
            try require(Set(pairGroup.members.keys) == ["a","b"],"two-window arrangement skips all surrounding blank regions",&results)
            helper.activate(options:.activateAllWindows)
            for _ in 0..<15 { if NSWorkspace.shared.frontmostApplication?.processIdentifier == helper.processIdentifier { break }; try await Task.sleep(for:.milliseconds(100)) }
            let pairResized = try await resizeThroughHandle(delegate,group:pairGroup,seam:pairSeam,to:pairSeam.bounds.minX+pairSeam.bounds.width*0.6,results:&results)
            let pairActual = await model.access.read(pairGroup.windows)
            try require(pairResized && pairGroup.windows.allSatisfy { w in pairActual[w.id].map { pairSeam.bounds.insetBy(dx:-2,dy:-2).contains($0) } == true },"linked resizing preserves surrounding blank space",&results)
            for _ in 0..<2 {
                let depth = model.undoCount; model.undo(); await Task.yield()
                for _ in 0..<200 { if !model.busy && model.undoCount<depth { break }; try await Task.sleep(for:.milliseconds(100)) }
            }
            model.preferences.activeLayout = LayoutPreset.builtins[3].id
            guard var group = model.groups.first, let seam = try group.geometry().seams.first else { throw LayoutError.invalid }
            helper.activate(options:.activateAllWindows)
            for _ in 0..<15 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == helper.processIdentifier { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            await delegate.overlays.update()
            try await Task.sleep(for:.milliseconds(150))
            let baselineFrames = await model.access.read(group.windows)
            let resized = try await resizeThroughHandle(delegate,group:group,seam:seam,to:seam.bounds.minX+seam.bounds.width*0.68,results:&results)
            try require(resized,"shared-boundary drag controller keeps group geometry",&results)
            guard let rootGroup = model.groups.first else { throw LayoutError.invalid }; group = rootGroup
            let rootAfter = await model.access.read(group.windows)
            guard let left = group.members["a"], let upper = group.members["b"], let lower = group.members["c"],
                  let leftBefore = baselineFrames[left.id], let leftAfter = rootAfter[left.id],
                  let upperAfter = rootAfter[upper.id], let lowerAfter = rootAfter[lower.id] else { throw LayoutError.invalid }
            try require(abs(leftAfter.height-leftBefore.height)<2 && abs(leftAfter.width-leftBefore.width)>10
                        && abs(upperAfter.minX-lowerAfter.minX)<2 && abs(upperAfter.width-lowerAfter.width)<2,
                        "root vertical boundary resizes the tall left and both right windows",&results)
            guard let child = try group.geometry().seams.first(where:{$0.id=="side"}) else { throw LayoutError.invalid }
            let childResized = try await resizeThroughHandle(delegate,group:group,seam:child,to:child.bounds.minY+child.bounds.height*0.63,results:&results)
            guard let childGroup = model.groups.first else { throw LayoutError.invalid }; group = childGroup
            let childAfter = await model.access.read(group.windows)
            try require(childResized && childAfter[left.id].map{FrameSettler.matches($0,leftAfter)} == true
                        && childAfter[upper.id].map{abs($0.height-upperAfter.height)>10} == true
                        && childAfter[lower.id].map{abs($0.minY-lowerAfter.minY)>10} == true,
                        "right horizontal boundary resizes both right windows and preserves the left frame",&results)
            if exerciseEnhanced {
                _ = await model.access.read(group.windows)
                try require(WindowAccess.value(application,"AXEnhancedUserInterface") as? Bool == true,"linked resizing restores practice enhanced accessibility",&results)
            }
            helper.activate(options:.activateAllWindows)
            for _ in 0..<15 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == helper.processIdentifier { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            for _ in 0..<20 {
                await delegate.overlays.update()
                if model.visibleLinkCount == 3 { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            try await Task.sleep(for:.milliseconds(150))
            let expectedLinks = try group.geometry().links(assigned:Set(group.members.keys))
            let visibleHandles = WindowAccess.visibleWindows().filter { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.layer == NSWindow.Level.floating.rawValue }
            func rectData(_ rect:CGRect) -> [String:Double] {
                ["x":Double(rect.minX),"y":Double(rect.minY),"width":Double(rect.width),"height":Double(rect.height)]
            }
            func hitData(_ point:CGPoint, pid:pid_t) -> [String:Any] {
                let root = pid == 0 ? AXUIElementCreateSystemWide() : AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root,0.1)
                var hit:AXUIElement?; var actual:pid_t = -1
                let result = AXUIElementCopyElementAtPosition(root,Float(point.x),Float(point.y),&hit)
                guard let hit else { return ["root":pid,"result":result.rawValue] }
                AXUIElementGetPid(hit,&actual)
                let role = WindowAccess.value(hit,kAXRoleAttribute) as? String ?? "none"
                let window = role == kAXWindowRole ? hit : WindowAccess.element(hit,kAXWindowAttribute)
                return ["root":pid,"result":result.rawValue,"pid":actual,"role":role,"frame":window.flatMap{WindowAccess.frame($0)}.map{rectData($0)} ?? [:]]
            }
            let observation: [String:Any] = [
                "status":model.linkStatus,"hint":model.linkHint,"handle_count":model.visibleLinkCount,
                "front_pid":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "helper_pid":helper.processIdentifier,
                "expected_handles":expectedLinks.map{rectData($0.frame)},
                "onscreen_handles":visibleHandles.map{rectData($0.frame)},
                "helper_surfaces":WindowAccess.visibleWindows().filter{$0.pid==helper.processIdentifier}.map{["frame":rectData($0.frame),"layer":$0.layer] as [String:Any]},
                "link_surfaces":expectedLinks.map { link -> [String:Any] in
                    let visible = WindowAccess.visibleWindows()
                    let first = visible.firstIndex { $0.frame.contains(link.firstProbe) }
                    let second = visible.firstIndex { $0.frame.contains(link.secondProbe) }
                    let indices = [first,second].compactMap{$0}
                    return ["probes":[["x":Double(link.firstProbe.x),"y":Double(link.firstProbe.y)],["x":Double(link.secondProbe.x),"y":Double(link.secondProbe.y)]],
                            "ax_hits":[hitData(link.firstProbe,pid:0),hitData(link.firstProbe,pid:helper.processIdentifier),hitData(link.secondProbe,pid:0)],
                            "ordered_surfaces":visible.filter{$0.frame.contains(link.firstProbe)}.map{["id":$0.id,"pid":$0.pid,"layer":$0.layer,"frame":rectData($0.frame)] as [String:Any]},
                            "top_surfaces":indices.map { index in ["id":visible[index].id,"pid":visible[index].pid,"layer":visible[index].layer,"frame":rectData(visible[index].frame)] as [String:Any] },
                            "front_intersections":visible.prefix((indices.max() ?? -1)+1).filter{$0.frame.intersects(link.frame)}.map { ["id":$0.id,"pid":$0.pid,"layer":$0.layer,"frame":rectData($0.frame)] as [String:Any] }]
                },
                "own_panels":NSApp.windows.map{["visible":$0.isVisible,"active_space":$0.isOnActiveSpace,"hides_on_deactivate":$0.hidesOnDeactivate,"level":$0.level.rawValue,"frame":rectData(DisplayGeometry.flip($0.frame,primaryHeight:Double(NSScreen.screens.first?.frame.height ?? 0)))] as [String:Any]}
            ]
            try require(model.visibleLinkCount==3 && expectedLinks.allSatisfy { link in visibleHandles.contains { FrameSettler.matches($0.frame,link.frame) } },
                        "left-one right-two presents three connection handles in WindowServer",&results,observed:observation)
            let titleHit = await model.access.hit(CGPoint(x:leftAfter.midX,y:leftAfter.minY+12),apps:[app])
            let zoom = WindowAccess.element(left.element,kAXZoomButtonAttribute).flatMap{WindowAccess.frame($0)}
            let zoomHit = if let zoom { await model.access.hit(CGPoint(x:zoom.midX,y:zoom.midY),apps:[app],zoomOnly:true) } else { nil as (LiveWindow,CGRect?)? }
            try require(titleHit?.0.id == left.id && zoomHit?.0.id == left.id,"titlebar and green-button hit tests reach the actual practice window",&results)
            var stable = true
            let stableIDs = Set(visibleHandles.map(\.id))
            for _ in 0..<3 {
                let refresh = Task { await delegate.overlays.update() }
                await Task.yield()
                stable = stable && stableIDs.allSatisfy { id in NSApp.windows.contains { $0.windowNumber == id && $0.isVisible } }
                await refresh.value
                try await Task.sleep(for:.milliseconds(150))
                let shown = WindowAccess.visibleWindows().filter{$0.pid == ProcessInfo.processInfo.processIdentifier && $0.layer == NSWindow.Level.floating.rawValue}
                stable = stable && model.visibleLinkCount == 3 && Set(shown.map(\.id)) == stableIDs
                    && expectedLinks.allSatisfy { link in shown.contains { FrameSettler.matches($0.frame,link.frame) } }
            }
            try require(stable,"visibility refreshes retain the same three visible divider panels",&results,
                        observed:["initial_ids":Array(stableIDs).sorted(),"front_pid":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,"helper_pid":helper.processIdentifier])
            guard let link = expectedLinks.first else { throw LayoutError.invalid }
            let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
            let blocker = PassivePanel(contentRect:DisplayGeometry.flip(link.frame.insetBy(dx:-12,dy:-12),primaryHeight:primaryHeight),
                                       styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            blocker.isReleasedWhenClosed = false; blocker.level = .floating; blocker.backgroundColor = .windowBackgroundColor
            blocker.orderFrontRegardless()
            try await Task.sleep(for:.milliseconds(150))
            await delegate.overlays.update()
            let occluded = model.visibleLinkCount
            let occludedFront = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            let narrow = CGRect(x:link.frame.midX-2,y:link.frame.midY-6,width:4,height:12)
            blocker.setFrame(DisplayGeometry.flip(narrow,primaryHeight:primaryHeight),display:true)
            try await Task.sleep(for:.milliseconds(150))
            await delegate.overlays.update()
            let narrowOccluded = model.visibleLinkCount
            let narrowFront = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            blocker.orderOut(nil)
            try await Task.sleep(for:.milliseconds(150))
            await delegate.overlays.update()
            try require(occluded<3 && model.visibleLinkCount==3,"connection handles respect an unrelated foreground panel",&results,
                        observed:["covered":occluded,"narrow_covered":narrowOccluded,"restored":model.visibleLinkCount,
                                  "helper_pid":helper.processIdentifier,"covered_front_pid":occludedFront,"narrow_front_pid":narrowFront,
                                  "restored_front_pid":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                                  "restored_status":model.linkStatus,"restored_hint":model.linkHint])
            try require(narrowOccluded<3,"a narrow panel in the central gap also hides its connection handle",&results)
            delegate.overlays.stop()
            let firstSlot = group.preset.root.panes[0], secondSlot = group.preset.root.panes[1]
            guard let first = group.members[firstSlot], let second = group.members[secondSlot] else { throw LayoutError.invalid }
            let beforeSwap = await model.access.read(group.windows)
            let undoDepth = model.undoCount
            let dragged = await model.access.apply([.init(window:first,frame:beforeSwap[first.id]!.offsetBy(dx:12,dy:8))])
            try require(dragged.succeeded,"stage source-window movement before swap",&results)
            model.place(first,slot:secondSlot,in:group,baseline:group.windows.compactMap{ item in beforeSwap[item.id].map { WindowMove(window:item,frame:$0) } })
            await Task.yield()
            for _ in 0..<200 { if !model.busy && model.undoCount>undoDepth { break }; try await Task.sleep(for:.milliseconds(100)) }
            try require(model.groups.first?.members[secondSlot]?.id==first.id && model.groups.first?.members[firstSlot]?.id==second.id,"swap commits both window identities",&results)
            model.undo(); await Task.yield()
            for _ in 0..<200 { if !model.busy && model.undoCount==undoDepth { break }; try await Task.sleep(for:.milliseconds(100)) }
            let afterUndo = await model.access.read(group.windows)
            try require(group.windows.allSatisfy { item in beforeSwap[item.id].flatMap { before in afterUndo[item.id].map{FrameSettler.matches($0,before)} }==true },"swap undo restores actual frames",&results)
            var sourceGroup = model.makeGroup(layout:LayoutPreset.builtins[1],desktop:desktop)
            var targetGroup = model.makeGroup(layout:LayoutPreset.builtins[0],desktop:desktop)
            let splitWidth = (sourceGroup.bounds.width-12)/2
            sourceGroup.bounds.size.width = splitWidth
            targetGroup.bounds.origin.x += splitWidth+12; targetGroup.bounds.size.width = splitWidth
            sourceGroup.members["a"] = windows[0]; targetGroup.members["a"] = windows[1]; targetGroup.members["b"] = windows[2]
            let crossReady = await model.commit(try sourceGroup.moves()+targetGroup.moves(),groups:[sourceGroup,targetGroup])
            try require(crossReady,"arrange two explicit groups for cross-group swap",&results)
            let crossBefore = await model.access.read(windows), crossDepth = model.undoCount
            let crossDragged = await model.access.apply([.init(window:windows[0],frame:crossBefore[windows[0].id]!.offsetBy(dx:8,dy:8))])
            try require(crossDragged.succeeded,"stage cross-group drag",&results)
            model.place(windows[0],slot:"a",in:targetGroup,baseline:[.init(window:windows[0],frame:crossBefore[windows[0].id]!)])
            await Task.yield()
            for _ in 0..<200 { if !model.busy && model.undoCount>crossDepth { break }; try await Task.sleep(for:.milliseconds(100)) }
            try require(model.groups.first(where:{$0.id==sourceGroup.id})?.members["a"]?.id==windows[1].id && model.groups.first(where:{$0.id==targetGroup.id})?.members["a"]?.id==windows[0].id,"cross-group swap updates both owners",&results)
            model.undo(); await Task.yield()
            for _ in 0..<200 { if !model.busy && model.undoCount==crossDepth { break }; try await Task.sleep(for:.milliseconds(100)) }
            let crossAfter = await model.access.read(windows)
            try require(windows.allSatisfy { item in crossBefore[item.id].flatMap { before in crossAfter[item.id].map { FrameSettler.matches($0,before) } }==true },"cross-group undo restores source and destination frames",&results)
            if let cancelGroup = model.groups.first(where: { $0.members.count >= 2 }),
               let cancelSeam = try cancelGroup.geometry().seams.first,
               let cancelLink = try cancelGroup.geometry().links(assigned:Set(cancelGroup.members.keys)).first {
                let start = CGPoint(x:cancelLink.frame.midX,y:cancelLink.frame.midY)
                delegate.overlays.beginResize?(cancelGroup,cancelSeam,start)
                for _ in 0..<50 {
                    if delegate.gestures.hasActiveResize { break }
                    try await Task.sleep(for:.milliseconds(20))
                }
                guard delegate.gestures.hasActiveResize else { throw LayoutError.invalid }
                delegate.overlays.resize?(CGPoint(x:start.x+30,y:start.y+30))
                _ = await model.access.read(cancelGroup.windows)
                delegate.pause()
                try require(model.paused && !delegate.gestures.hasActiveResize && cancelGroup.windows.allSatisfy { model.group(containing:$0) == nil },
                            "pause during preview cancels drag and removes stale group ownership",&results)
                delegate.pause()
            }
            let safe = await model.access.read(windows)
            let bad = [WindowMove(window:windows[0],frame:safe[windows[0].id]!.offsetBy(dx:10,dy:0)),WindowMove(window:windows[1],frame:CGRect(x:desktop.visible.minX+20,y:desktop.visible.minY+20,width:40,height:40))]
            let failure = await model.access.apply(bad)
            let restored = await model.access.read(windows)
            try require(!failure.succeeded && failure.rollbackFailed.isEmpty,"minimum-size refusal rolls back transaction",&results)
            try require(windows.allSatisfy { item in safe[item.id].flatMap { before in restored[item.id].map { FrameSettler.matches($0,before) } }==true },"failed transaction leaves all practice windows intact",&results)
            let dragBaseline = windows.compactMap { item in safe[item.id].map { WindowMove(window:item,frame:$0) } }
            let moved = await model.access.apply([.init(window:windows[0],frame:safe[windows[0].id]!.offsetBy(dx:12,dy:8))])
            try require(moved.succeeded,"stage a drag before member closes",&results)
            guard windows[1].app.pid == helper.processIdentifier,
                  let close = WindowAccess.element(windows[1].element,kAXCloseButtonAttribute),
                  AXUIElementPerformAction(close,kAXPressAction as CFString) == .success else { throw LayoutError.invalid }
            try await Task.sleep(for:.milliseconds(200))
            let preflight = await model.access.apply(dragBaseline,baseline:dragBaseline)
            let recovered = await model.access.read([windows[0]])
            try require(!preflight.succeeded && preflight.rollbackFailed.contains(windows[1].id),"closed group member is reported during preflight",&results)
            try require(recovered[windows[0].id].map { FrameSettler.matches($0,safe[windows[0].id]!) }==true,"preflight failure restores surviving drag baseline",&results)
        } catch {
            let remaining = await model.access.read(windows)
            _ = await model.access.apply(originals.filter { remaining[$0.window.id] != nil }); helper.terminate(); throw error
        }
        let remaining = await model.access.read(windows)
        let restored = await model.access.apply(originals.filter { remaining[$0.window.id] != nil })
        helper.terminate()
        try require(restored.succeeded,"restore original practice frames",&results)
    }
    private static func multiScreenChecks(model:AppModel, windows:[LiveWindow], results:inout [[String:Any]]) async throws {
        let displays = Desktop.all
        let selected = [displays[0],displays[displays.count-1]]
        let savedPreferences = model.preferences, savedSelection = model.selectedIDs
        defer { model.preferences = savedPreferences; model.selectedIDs = savedSelection }
        let before = await model.access.read(windows), previousGroups = model.groups, depth = model.undoCount
        let plan = LayoutPreset(id:"multi-native-fixture",name:"双屏练习",root:.pane("a"),screens:selected.map { ScreenLayout(id:$0.id,name:$0.name,root:.pane("a")) })
        guard model.saveLayout(plan) else { throw LayoutError.invalid }
        model.selectedIDs = Set(windows.prefix(2).map(\.id))
        let arranged: Bool = await withCheckedContinuation { continuation in model.arrangeSelected { continuation.resume(returning:$0) } }
        try require(arranged && model.undoCount == depth+1,"one transaction arranges selected windows across two actual displays",&results)
        let groups = model.groups.filter{$0.preset.id == plan.id}, actual = await model.access.read(windows)
        try require(groups.count == 2 && selected.enumerated().allSatisfy { index,display in
            groups.first{$0.screenID == display.id}.flatMap { group in actual[windows[index].id].map { FrameSettler.matches($0,group.bounds) } } == true
        },"each cross-screen window matches its own display's usable frame",&results)
        try require(actual[windows[2].id].flatMap { frame in before[windows[2].id].map{FrameSettler.matches(frame,$0)} } == true,"unselected practice window stays in place during cross-screen arrangement",&results)
        try require(selected.allSatisfy { model.dropDestination(at:CGPoint(x:$0.visible.midX,y:$0.visible.midY))?.screenID == $0.id },"Option-drop resolves each selected physical display",&results)
        if let excluded = displays.first(where:{display in !selected.contains{$0.id == display.id}}) {
            try require(model.dropDestination(at:CGPoint(x:excluded.visible.midX,y:excluded.visible.midY)) == nil,"unselected physical display cannot become an Option-drop target",&results)
        }
        guard let destination = groups.first(where:{$0.screenID == selected[1].id}) else { throw LayoutError.invalid }
        let swapped: Bool = await withCheckedContinuation { continuation in model.place(windows[0],slot:"a",in:destination) { continuation.resume(returning:$0) } }
        let swappedFrames = await model.access.read(windows)
        try require(swapped && swappedFrames[windows[0].id].flatMap { f in actual[windows[1].id].map{FrameSettler.matches(f,$0)} } == true
                    && swappedFrames[windows[1].id].flatMap { f in actual[windows[0].id].map{FrameSettler.matches(f,$0)} } == true,"cross-screen slot exchange moves both windows to the correct monitors",&results)
        model.undo(); await Task.yield()
        for _ in 0..<200 { if !model.busy && model.undoCount == depth+1 { break }; try await Task.sleep(for:.milliseconds(100)) }
        let swapUndo = await model.access.read(windows)
        try require(windows.prefix(2).allSatisfy { item in swapUndo[item.id].flatMap{f in actual[item.id].map{FrameSettler.matches(f,$0)}} == true },"cross-screen exchange undo restores both monitor positions",&results)
        model.undo(); await Task.yield()
        for _ in 0..<200 { if !model.busy && model.undoCount == depth { break }; try await Task.sleep(for:.milliseconds(100)) }
        let arrangementUndo = await model.access.read(windows)
        try require(model.undoCount == depth && Set(model.groups.map(\.id)) == Set(previousGroups.map(\.id))
                    && windows.allSatisfy { item in arrangementUndo[item.id].flatMap{f in before[item.id].map{FrameSettler.matches(f,$0)}} == true },"one undo restores the entire cross-screen arrangement and previous groups",&results)
    }
    private static func resizeThroughHandle(_ delegate:AppDelegate, group:WindowGroup, seam:LayoutSeam, to coordinate:Double, results:inout [[String:Any]]) async throws -> Bool {
        guard let link = try group.geometry().links(assigned:Set(group.members.keys)).first(where:{$0.seam.id==seam.id}),
              let begin = delegate.overlays.beginResize, let change = delegate.overlays.resize, let finish = delegate.overlays.finishResize else { throw LayoutError.invalid }
        let start = CGPoint(x:link.frame.midX,y:link.frame.midY)
        let end = seam.axis == .horizontal ? CGPoint(x:coordinate,y:start.y) : CGPoint(x:start.x,y:coordinate)
        let depth = delegate.model.undoCount
        let expectedLinks = try group.geometry().links(assigned:Set(group.members.keys))
        for _ in 0..<20 {
            await delegate.overlays.update()
            let published = WindowAccess.visibleWindows().filter { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.layer == NSWindow.Level.floating.rawValue }
            if delegate.model.visibleLinkCount == expectedLinks.count && published.count == expectedLinks.count { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let surfaces = WindowAccess.visibleWindows()
        try require(delegate.model.visibleLinkCount == expectedLinks.count && surfaces.filter { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.layer == NSWindow.Level.floating.rawValue }.count == expectedLinks.count,"\(seam.id) divider visibility before drag",&results,
                    observed:["count":delegate.model.visibleLinkCount,"expected":expectedLinks.count,
                              "front_pid":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                              "member_pid":group.windows.first?.app.pid ?? -1,
                              "status":delegate.model.linkStatus,"hint":delegate.model.linkHint,
                              "probe_surfaces":expectedLinks.map { link in
                                  [link.firstProbe,link.secondProbe].map { point in
                                      surfaces.filter { $0.frame.contains(point) }.map { surface in
                                          ["id":Double(surface.id),"pid":Double(surface.pid),"layer":Double(surface.layer),
                                           "x":surface.frame.minX,"y":surface.frame.minY,"w":surface.frame.width,"h":surface.frame.height]
                                      }
                                  }
                              }])
        let initialIDs = Set(WindowAccess.visibleWindows().filter { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.layer == NSWindow.Level.floating.rawValue }.map(\.id))
        begin(group,seam,start)
        for _ in 0..<50 {
            if delegate.gestures.hasActiveResize { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        guard delegate.gestures.hasActiveResize else { throw LayoutError.invalid }
        let previewStarted = ProcessInfo.processInfo.systemUptime
        change(end)
        var actual: [String:CGRect] = [:]
        var boundary: Double?
        for _ in 0..<50 {
            change(end)
            actual = await delegate.model.access.read(group.windows)
            if let a = group.members[link.first].flatMap({actual[$0.id]}), let b = group.members[link.second].flatMap({actual[$0.id]}) {
                boundary = seam.axis == .horizontal ? (a.maxX+b.minX)/2 : (a.maxY+b.minY)/2
                if let boundary, abs(boundary-coordinate)<2 { break }
            }
            try await Task.sleep(for:.milliseconds(17))
        }
        let previewElapsed = (ProcessInfo.processInfo.systemUptime-previewStarted)*1000
        try await Task.sleep(for:.milliseconds(50))
        let shown = WindowAccess.visibleWindows().filter { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.layer == NSWindow.Level.floating.rawValue }
        let links = try group.geometry().links(assigned:Set(group.members.keys))
        let centers = links.compactMap { link -> CGPoint? in
            guard let a = group.members[link.first].flatMap({actual[$0.id]}), let b = group.members[link.second].flatMap({actual[$0.id]}) else { return nil }
            if link.seam.axis == .horizontal { return CGPoint(x:(a.maxX+b.minX)/2,y:(max(a.minY,b.minY)+min(a.maxY,b.maxY))/2) }
            return CGPoint(x:(max(a.minX,b.minX)+min(a.maxX,b.maxX))/2,y:(a.maxY+b.minY)/2)
        }
        let tracked = initialIDs.count == links.count && Set(shown.map(\.id)) == initialIDs
            && centers.count == links.count && centers.allSatisfy { point in shown.contains { abs($0.frame.midX-point.x)<2 && abs($0.frame.midY-point.y)<2 } }
            && boundary.map { abs($0-coordinate)<2 } == true
        finish(end)
        await Task.yield()
        for _ in 0..<200 {
            if !delegate.model.busy && delegate.model.undoCount>depth { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        try require(tracked,"\(seam.id) resize preview moves the same divider panels with actual window boundaries",&results,
                    observed:["initial_ids":Array(initialIDs).sorted(),"preview_ids":shown.map(\.id).sorted(),
                              "requested_boundary":coordinate,"actual_boundary":boundary ?? -1,
                              "preview_elapsed_ms":previewElapsed,
                              "expected_centers":centers.map{["x":Double($0.x),"y":Double($0.y)]},
                              "shown_centers":shown.map{["x":Double($0.frame.midX),"y":Double($0.frame.midY)]}])
        return !delegate.model.busy && delegate.model.undoCount==depth+1
    }
}
