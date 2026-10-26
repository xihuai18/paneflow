import Foundation
import PaneFlowCore

@main enum CoreChecks {
    static func main() throws {
        var passed = 0
        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }; passed += 1
        }
        let bounds = CGRect(x: -1400, y: -700, width: 1200, height: 800)
        for preset in LayoutPreset.builtins {
            for scale in [1.0, 2.0] {
                let geometry = try LayoutGeometry.make(preset.root, in: bounds, gap: 8, scale: scale)
                check("pane count", geometry.panes.count == preset.root.panes.count)
                for pane in geometry.panes.values { check("within negative-origin display", bounds.contains(pane)) }
                let panes = Array(geometry.panes.values)
                for index in panes.indices { for other in panes.indices where other > index { check("no overlap", !panes[index].intersects(panes[other])) } }
                let roundtrip = try JSONDecoder().decode(LayoutPreset.self, from: JSONEncoder().encode(preset))
                check("layout roundtrip", roundtrip == preset)
            }
        }
        let centered = LayoutPreset.builtins.first { $0.id == "centered-two-thirds" }!
        try centered.validate()
        check("centered layout skips both empty sides", centered.windowPanes == ["center"] && centered.emptyPanes.count == 2)
        let centerGeometry = try LayoutGeometry.make(centered.root,in:bounds,gap:0,scale:2)
        let centerFrame = centerGeometry.panes["center"]!
        check("two vertical lines leave a centered two-thirds window", abs(centerFrame.midX-bounds.midX)<0.5 && abs(centerFrame.width-bounds.width*2/3)<0.5)
        check("blank areas do not create live divider handles", centerGeometry.links(assigned:Set(centered.windowPanes)).isEmpty)
        check("line snapping supports one percent", abs(LayoutPreset.snappedPercent(45.6)-46)<1e-8)
        let movedLine = centered.root.movingLine("left-line",toPercent:18)
        let movedGeometry = try LayoutGeometry.make(movedLine,in:CGRect(x:0,y:0,width:10000,height:10000),gap:0)
        check("moving one line keeps the other line fixed", movedGeometry.seams.first{$0.id == "left-line"}!.line.midX == 1800 && abs(movedGeometry.seams.first{$0.id == "right-line"}!.line.midX-8333)<1)
        let limitedLine = centered.root.movingLine("left-line",toPercent:99)
        let limitedGeometry = try LayoutGeometry.make(limitedLine,in:CGRect(x:0,y:0,width:10000,height:10000),gap:0)
        check("lines cannot cross their neighbors", limitedGeometry.panes["center"]!.width >= 100)
        let centeredCopy = try JSONDecoder().decode(LayoutPreset.self,from:JSONEncoder().encode(centered))
        check("blank areas survive serialization", centeredCopy == centered)
        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(LayoutPreset.builtins[0])) as! [String:Any]
        legacy["emptyPanes"] = nil
        let decodedLegacy = try JSONDecoder().decode(LayoutPreset.self,from:JSONSerialization.data(withJSONObject:legacy))
        check("old layouts default to no blank areas", decodedLegacy.emptyPanes.isEmpty)
        do { try LayoutPreset(name:"empty",root:.pane("a"),emptyPanes:["a"]).validate(); check("all-empty layouts are rejected",false) }
        catch { check("all-empty layouts are rejected",true) }
        do { try LayoutPreset(name:"missing",root:.pane("a"),emptyPanes:["missing"]).validate(); check("unknown blank IDs are rejected",false) }
        catch { check("unknown blank IDs are rejected",true) }
        let nested = LayoutNode.split(id: "outer", axis: .horizontal, ratio: 0.5,
                                      first: .split(id: "inner", axis: .horizontal, ratio: 0.9, first: .pane("a"), second: .pane("b")), second: .pane("c"))
        let minimums = ["a": CGSize(width:100,height:80), "b": CGSize(width:100,height:80), "c": CGSize(width:100,height:80)]
        let geometry = try LayoutGeometry.make(nested, in: CGRect(x:0,y:0,width:2000,height:500), gap:8)
        let outer = geometry.seams.first { $0.id == "outer" }!
        let ratio = try outer.ratio(at:200, gap:8, minimums:minimums)
        let resized = try LayoutGeometry.make(nested.replacingRatio("outer", with:ratio), in:CGRect(x:0,y:0,width:2000,height:500),gap:8,minimums:minimums)
        check("nested 90/10 minimum remains intact", resized.panes["b"]!.width >= 100)
        let merged = nested.mergingPane("b")
        check("merging a nested pane preserves its outer split", merged == .split(id:"outer",axis:.horizontal,ratio:0.5,first:.pane("a"),second:.pane("c")))
        check("merging an outer pane promotes its sibling subtree", nested.mergingPane("c").panes == ["a","b"])
        check("merging an unknown pane leaves the layout intact", nested.mergingPane("missing") == nested)
        check("merging the only pane is a no-op", LayoutNode.pane("a").mergingPane("a") == .pane("a"))
        let duplicate = LayoutNode.split(id:"same",axis:.horizontal,ratio:0.5,first:.pane("a"),second:.split(id:"same",axis:.vertical,ratio:0.5,first:.pane("b"),second:.pane("c")))
        do { try duplicate.validate(); check("reject duplicate separators", false) } catch { passed += 1 }
        let narrow = LayoutPreset.builtins[0].root.replacingRatio("main", with:1.0/30.0)
        let narrowGeometry = try LayoutGeometry.make(narrow,in:CGRect(x:0,y:0,width:6000,height:500),gap:0)
        check("ratio below 5 percent is supported", narrowGeometry.panes["a"]!.width == 200)
        let swap = SlotPlacement.placing("A",in:"b",assignments:["a":"A","b":"B"])
        check("swap preserves both identities", swap.assignments == ["a":"B","b":"A"] && swap.displaced == nil)
        let external = SlotPlacement.placing("C",in:"b",assignments:["a":"A","b":"B"])
        check("external placement reports displaced window", external.assignments == ["a":"A","b":"C"] && external.displaced == "B")
        let triple = try LayoutGeometry.make(LayoutPreset.builtins[3].root,in:bounds,gap:8,scale:2)
        let links = triple.links(assigned:["a","b","c"])
        check("left-one right-two has three actual neighbour links", links.count == 3)
        check("both right windows share the root vertical boundary", links.filter { $0.seam.id == "main" }.count == 2)
        check("right windows share one horizontal boundary", links.filter { $0.seam.id == "side" }.count == 1)
        check("each link probes inside its actual window pair", links.allSatisfy { triple.panes[$0.first]!.contains($0.firstProbe) && triple.panes[$0.second]!.contains($0.secondProbe) })
        check("link probes stay outside their own floating handle", links.allSatisfy { !$0.frame.contains($0.firstProbe) && !$0.frame.contains($0.secondProbe) })
        check("root handles avoid the T-junction gap", links.filter { $0.seam.id == "main" }.allSatisfy { abs($0.frame.midY - triple.seams[0].line.midY) > 30 })
        check("one assigned window has no linked handle", triple.links(assigned:["a"]).isEmpty)
        check("only the two right windows expose their own shared boundary", triple.links(assigned:["b","c"]).map(\.seam.id) == ["side"])
        let noGap = try LayoutGeometry.make(LayoutPreset.builtins[3].root,in:bounds,gap:0)
        check("zero-gap layout retains all three links", noGap.links(assigned:["a","b","c"]).count == 3)
        check("zero-gap link probes also clear the handle", noGap.links(assigned:["a","b","c"]).allSatisfy { !$0.frame.contains($0.firstProbe) && !$0.frame.contains($0.secondProbe) })
        let grid = LayoutNode.split(id:"grid",axis:.horizontal,ratio:0.5,
                                    first:.split(id:"left",axis:.vertical,ratio:0.5,first:.pane("a"),second:.pane("b")),
                                    second:.split(id:"right",axis:.vertical,ratio:0.5,first:.pane("c"),second:.pane("d")))
        let gridGeometry = try LayoutGeometry.make(grid,in:bounds,gap:8)
        check("four-pane grid only links directly adjacent pairs", gridGeometry.links(assigned:["a","b","c","d"]).count == 4)
        let tall = CGRect(x:100,y:100,width:500,height:700)
        let upper = CGRect(x:610,y:100,width:400,height:340), lower = CGRect(x:610,y:448,width:400,height:352)
        let tallSnap = Magnet.snap(tall.offsetBy(dx:4,dy:0),to:[("upper",upper),("lower",lower)],gap:8)
        check("tall window snaps against a two-window column", tallSnap.x != nil && tallSnap.frame.maxX == 602 && tallSnap.frame.height == 700)
        let upperSnap = Magnet.snap(upper.offsetBy(dx:3,dy:0),to:[("tall",tall)],gap:8)
        check("short window snaps against a tall neighbour", upperSnap.x != nil && upperSnap.frame.minX == 608 && upperSnap.frame.height == 340)
        let target = CGRect(x:500,y:100,width:300,height:300)
        let initial = CGRect(x:180,y:100,width:300,height:300)
        let snap = Magnet.snap(initial,to:[("B",target)],gap:8)
        check("magnet acquires", snap.frame.maxX == 492 && snap.x != nil)
        let held = Magnet.snap(initial.offsetBy(dx:-10,dy:0),to:[("B",target)],gap:8,previous:snap)
        check("magnet release hysteresis", held.x != nil)
        let released = Magnet.snap(initial.offsetBy(dx:-40,dy:0),to:[("B",target)],gap:8,previous:held)
        check("magnet releases from original pointer displacement", released.x == nil)
        let removed = Magnet.snap(initial,to:[],gap:8,previous:snap)
        check("removed target unlocks", removed.x == nil && removed.y == nil)
        var preview = FramePreview()
        let before = CGRect(x:0,y:0,width:600,height:400), desired = CGRect(x:100,y:0,width:400,height:400)
        check("preview shrinks before moving right", preview.next(actual:before,target:desired,now:0) == .size(desired.size))
        check("preview waits for delayed size", preview.next(actual:before,target:desired,now:0.2) == nil)
        let sized = CGRect(origin:before.origin,size:desired.size)
        _ = preview.next(actual:sized,target:desired,now:0.3)
        check("preview separates axes after stable response", preview.next(actual:sized,target:desired,now:0.4) == .position(desired.origin))
        var responsive = FramePreview(settleInterval: 0)
        check("responsive preview writes first axis", responsive.next(actual:before,target:desired,now:0) == .size(desired.size))
        check("responsive preview still waits for acknowledgement", responsive.next(actual:before,target:desired,now:0.01) == nil)
        let latest = CGRect(x:120,y:0,width:380,height:400)
        check("responsive preview follows newest size after acknowledgement", responsive.next(actual:sized,target:latest,now:0.02) == .size(latest.size))
        check("responsive preview moves without stability delay", responsive.next(actual:CGRect(origin:before.origin,size:latest.size),target:latest,now:0.02) == .position(latest.origin))
        check("responsive preview settles at latest target", responsive.next(actual:latest,target:latest,now:0.03) == nil)
        var clock = 0.0, frame = before, queued: [(Double,CGRect)] = []
        let handshake = WindowFrameDriver.adjust(to:desired,read:{ for item in queued.filter({$0.0<=clock}) { frame=item.1 }; queued.removeAll{$0.0<=clock}; return frame },
            setPosition:{ point in queued.append((clock+0.18,CGRect(origin:point,size:frame.size))); return .retryable },
            setSize:{ size in queued.append((clock+0.18,CGRect(origin:frame.origin,size:size))); return .accepted },
            now:{clock},wait:{clock += $0})
        check("asynchronous axes and lost reply settle", handshake.reachedTarget && FrameSettler.matches(frame,desired))
        var cancelClock = 0.0
        let cancelled = WindowFrameDriver.adjust(to:desired,read:{before},setPosition:{_ in .accepted},setSize:{_ in .accepted},now:{cancelClock},wait:{cancelClock += $0},shouldStop:{cancelClock>=0.2})
        check("cancelled driver stops", !cancelled.reachedTarget && cancelClock<0.3)
        let flipped = DisplayGeometry.flip(bounds,primaryHeight:900)
        check("display transform roundtrip", DisplayGeometry.flip(flipped,primaryHeight:900) == bounds)
        let multi = LayoutPreset(id:"multi",name:"双屏",root:.pane("unused"),screens:[
            .init(id:"screen-a",name:"显示器 A",root:LayoutPreset.builtins[0].root),
            .init(id:"screen-b",name:"显示器 B",root:centered.root,emptyPanes:centered.emptyPanes)
        ])
        try multi.validate()
        check("multi-screen capacity skips each screen's blank regions",multi.windowCount == 3)
        check("screen selection excludes every other display",multi.onScreen("screen-c") == nil)
        check("screen resolution retains independent partition geometry",multi.onScreen("screen-b")?.root == centered.root && multi.onScreen("screen-b")?.emptyPanes == centered.emptyPanes)
        let decodedMulti = try JSONDecoder().decode(LayoutPreset.self,from:JSONEncoder().encode(multi))
        check("screen layouts survive serialization",decodedMulti == multi)
        var duplicateScreen = multi; duplicateScreen.screens.append(multi.screens[0])
        var rejectedScreen = false
        do { try duplicateScreen.validate() } catch { rejectedScreen = true }
        check("duplicated display assignments are rejected",rejectedScreen)
        print("PASS: \(passed) core checks")
    }
}
