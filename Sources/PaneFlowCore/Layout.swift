import Foundation
import CoreGraphics

public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }

public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case pane(String)
    case split(id: String, axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    public var panes: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second): return first.panes + second.panes
        }
    }
    public var splitIDs: [String] {
        switch self {
        case .pane: return []
        case let .split(id, _, _, first, second): return [id] + first.splitIDs + second.splitIDs
        }
    }
    public func replacingRatio(_ id: String, with value: Double) -> LayoutNode {
        switch self {
        case .pane: return self
        case let .split(key, axis, ratio, first, second):
            return .split(id: key, axis: axis, ratio: key == id ? value : ratio,
                          first: first.replacingRatio(id, with: value), second: second.replacingRatio(id, with: value))
        }
    }
    public func movingLine(_ id: String, toPercent percent: Double) -> LayoutNode {
        guard percent.isFinite,
              let geometry = try? LayoutGeometry.make(self,in:CGRect(x:0,y:0,width:10000,height:10000),gap:0),
              let target = geometry.seams.first(where:{$0.id == id}) else { return self }
        let horizontal = target.axis == .horizontal
        func coordinate(_ seam: LayoutSeam) -> Double { seam.axis == .horizontal ? seam.line.midX : seam.line.midY }
        let firstIDs = Set(target.first.splitIDs), secondIDs = Set(target.second.splitIDs)
        let before = geometry.seams.filter { $0.axis == target.axis && firstIDs.contains($0.id) }.map(coordinate).max()
        let after = geometry.seams.filter { $0.axis == target.axis && secondIDs.contains($0.id) }.map(coordinate).min()
        let lower = (before ?? (horizontal ? target.bounds.minX : target.bounds.minY))+100
        let upper = (after ?? (horizontal ? target.bounds.maxX : target.bounds.maxY))-100
        guard lower <= upper else { return self }
        var positions = Dictionary(uniqueKeysWithValues:geometry.seams.map { ($0.id,coordinate($0)) })
        positions[id] = min(upper,max(lower,percent*100))
        func rebuild(_ node: LayoutNode, in area: CGRect) -> LayoutNode {
            guard case let .split(key,axis,_,first,second) = node, let value = positions[key] else { return node }
            let start = axis == .horizontal ? area.minX : area.minY
            let length = axis == .horizontal ? area.width : area.height
            let ratio = (value-start)/length
            guard ratio > 0, ratio < 1 else { return node }
            let a: CGRect, b: CGRect
            if axis == .horizontal {
                a = CGRect(x:area.minX,y:area.minY,width:value-area.minX,height:area.height)
                b = CGRect(x:value,y:area.minY,width:area.maxX-value,height:area.height)
            } else {
                a = CGRect(x:area.minX,y:area.minY,width:area.width,height:value-area.minY)
                b = CGRect(x:area.minX,y:value,width:area.width,height:area.maxY-value)
            }
            return .split(id:key,axis:axis,ratio:ratio,first:rebuild(first,in:a),second:rebuild(second,in:b))
        }
        return rebuild(self,in:CGRect(x:0,y:0,width:10000,height:10000))
    }
    public func splittingPane(_ pane: String, axis: SplitAxis, ratio: Double = 0.5) -> LayoutNode {
        switch self {
        case .pane(let id):
            return id == pane ? .split(id: UUID().uuidString, axis: axis, ratio: ratio, first: .pane(id), second: .pane(UUID().uuidString)) : self
        case let .split(id, direction, value, first, second):
            return .split(id: id, axis: direction, ratio: value, first: first.splittingPane(pane, axis: axis, ratio: ratio), second: second.splittingPane(pane, axis: axis, ratio: ratio))
        }
    }
    public func mergingPane(_ pane: String) -> LayoutNode {
        switch self {
        case .pane: return self
        case let .split(id, axis, ratio, first, second):
            if case .pane(let id) = first, id == pane { return second }
            if case .pane(let id) = second, id == pane { return first }
            return .split(id:id,axis:axis,ratio:ratio,first:first.mergingPane(pane),second:second.mergingPane(pane))
        }
    }
    public func validate(depth: Int = 0) throws {
        guard depth <= 8, panes.count <= 16, Set(panes).count == panes.count, Set(splitIDs).count == splitIDs.count,
              panes.allSatisfy({ !$0.isEmpty && $0.count < 128 }) else { throw LayoutError.invalid }
        switch self {
        case .pane: break
        case let .split(id, _, ratio, first, second):
            guard !id.isEmpty, ratio.isFinite, ratio > 0, ratio < 1 else { throw LayoutError.invalid }
            try first.validate(depth: depth + 1); try second.validate(depth: depth + 1)
        }
    }
    public func minimumSize(_ sizes: [String: CGSize], gap: Double, scale: Double = 1) -> CGSize {
        switch self {
        case .pane(let id): return sizes[id] ?? .zero
        case let .split(_, axis, ratio, first, second):
            let a = first.minimumSize(sizes, gap: gap, scale: scale), b = second.minimumSize(sizes, gap: gap, scale: scale)
            let rounding = 0.5 / scale
            return axis == .horizontal ? CGSize(width: gap + max((a.width + rounding) / ratio, (b.width + rounding) / (1 - ratio)), height: max(a.height, b.height))
                : CGSize(width: max(a.width, b.width), height: gap + max((a.height + rounding) / ratio, (b.height + rounding) / (1 - ratio)))
        }
    }
}

public struct ScreenLayout: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var root: LayoutNode
    public var emptyPanes: Set<String>
    public var windowPanes: [String] { root.panes.filter { !emptyPanes.contains($0) } }
    public init(id: String, name: String, root: LayoutNode, emptyPanes: Set<String> = []) {
        self.id = id; self.name = name; self.root = root; self.emptyPanes = emptyPanes
    }
    public func validate() throws {
        try root.validate()
        guard !id.isEmpty, id.count < 128, !name.isEmpty, name.count <= 80,
              emptyPanes.isSubset(of:Set(root.panes)), !windowPanes.isEmpty else { throw LayoutError.invalid }
    }
}

public struct LayoutPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var root: LayoutNode
    public var emptyPanes: Set<String>
    public var screens: [ScreenLayout]
    public var capturedSpacing: Bool
    public var windowPanes: [String] { root.panes.filter { !emptyPanes.contains($0) } }
    public var windowCount: Int { screens.isEmpty ? windowPanes.count : screens.reduce(0) { $0 + $1.windowPanes.count } }
    public init(id: String = UUID().uuidString, name: String, root: LayoutNode, emptyPanes: Set<String> = [], screens: [ScreenLayout] = [], capturedSpacing: Bool = false) {
        self.id = id; self.name = name; self.root = root; self.emptyPanes = emptyPanes; self.screens = screens; self.capturedSpacing = capturedSpacing
    }
    public func onScreen(_ id: String) -> LayoutPreset? {
        guard !screens.isEmpty else { return self }
        guard let screen = screens.first(where:{$0.id == id}) else { return nil }
        return LayoutPreset(id:self.id,name:name,root:screen.root,emptyPanes:screen.emptyPanes,capturedSpacing:capturedSpacing)
    }
    private enum CodingKeys: String, CodingKey { case id, name, root, emptyPanes, screens, capturedSpacing }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decode(String.self,forKey:.id); name = try values.decode(String.self,forKey:.name)
        root = try values.decode(LayoutNode.self,forKey:.root)
        emptyPanes = try values.decodeIfPresent(Set<String>.self,forKey:.emptyPanes) ?? []
        screens = try values.decodeIfPresent([ScreenLayout].self,forKey:.screens) ?? []
        capturedSpacing = try values.decodeIfPresent(Bool.self,forKey:.capturedSpacing) ?? false
        try validate()
    }
    public func validate() throws {
        try root.validate()
        guard emptyPanes.isSubset(of:Set(root.panes)), !windowPanes.isEmpty else { throw LayoutError.invalid }
        guard Set(screens.map(\.id)).count == screens.count else { throw LayoutError.invalid }
        for screen in screens { try screen.validate() }
    }
    public static func snappedPercent(_ value: Double) -> Double { value.rounded() }
    public static func capturing(_ frames: [CGRect], in bounds: CGRect) throws -> LayoutPreset {
        guard !frames.isEmpty else { throw LayoutCaptureError.empty }
        guard frames.count <= 16, bounds.width > 0, bounds.height > 0 else { throw LayoutCaptureError.complex }
        let tolerance: CGFloat = 2
        let clipped = try frames.map { frame -> CGRect in
            let value = frame.intersection(bounds)
            guard !value.isNull, value.width > tolerance, value.height > tolerance,
                  abs(value.minX-frame.minX) <= tolerance, abs(value.minY-frame.minY) <= tolerance,
                  abs(value.maxX-frame.maxX) <= tolerance, abs(value.maxY-frame.maxY) <= tolerance else { throw LayoutCaptureError.outside }
            return value
        }
        for i in clipped.indices {
            for j in clipped.indices where j > i {
                let overlap = clipped[i].intersection(clipped[j])
                if overlap.width > tolerance && overlap.height > tolerance { throw LayoutCaptureError.overlap }
            }
        }
        var emptyPanes = Set<String>()
        func blank() -> LayoutNode { let id = UUID().uuidString; emptyPanes.insert(id); return .pane(id) }
        func build(_ windows: [CGRect], in area: CGRect, depth: Int) throws -> LayoutNode {
            guard depth <= 8 else { throw LayoutCaptureError.complex }
            if windows.isEmpty { return blank() }
            var cut: (SplitAxis,CGFloat)?
            if windows.count == 1, let rect = windows.first {
                if rect.minX-area.minX > tolerance { cut = (.horizontal,rect.minX) }
                else if area.maxX-rect.maxX > tolerance { cut = (.horizontal,rect.maxX) }
                else if rect.minY-area.minY > tolerance { cut = (.vertical,rect.minY) }
                else if area.maxY-rect.maxY > tolerance { cut = (.vertical,rect.maxY) }
                else { return .pane(UUID().uuidString) }
            } else {
                var best = Int.max
                for axis in [SplitAxis.horizontal,.vertical] {
                    let start = axis == .horizontal ? area.minX : area.minY
                    let end = axis == .horizontal ? area.maxX : area.maxY
                    let candidates = Set(windows.flatMap { axis == .horizontal ? [$0.minX,$0.maxX] : [$0.minY,$0.maxY] }).sorted()
                    for value in candidates where value-start > tolerance && end-value > tolerance {
                        let first = windows.filter { (axis == .horizontal ? $0.maxX : $0.maxY) <= value+tolerance }
                        let second = windows.filter { (axis == .horizontal ? $0.minX : $0.minY) >= value-tolerance }
                        let separatesEveryWindow = windows.allSatisfy { rect in
                            ((axis == .horizontal ? rect.maxX : rect.maxY) <= value+tolerance) != ((axis == .horizontal ? rect.minX : rect.minY) >= value-tolerance)
                        }
                        if !first.isEmpty, !second.isEmpty, separatesEveryWindow, abs(first.count-second.count) < best {
                            best = abs(first.count-second.count); cut = (axis,value)
                        }
                    }
                }
            }
            guard let (axis,value) = cut else { throw LayoutCaptureError.complex }
            let horizontal = axis == .horizontal
            let firstArea = horizontal ? CGRect(x:area.minX,y:area.minY,width:value-area.minX,height:area.height) : CGRect(x:area.minX,y:area.minY,width:area.width,height:value-area.minY)
            let secondArea = horizontal ? CGRect(x:value,y:area.minY,width:area.maxX-value,height:area.height) : CGRect(x:area.minX,y:value,width:area.width,height:area.maxY-value)
            let first = windows.filter { (horizontal ? $0.maxX : $0.maxY) <= value+tolerance }.map{$0.intersection(firstArea)}
            let second = windows.filter { (horizontal ? $0.minX : $0.minY) >= value-tolerance }.map{$0.intersection(secondArea)}
            let ratio = horizontal ? firstArea.width/area.width : firstArea.height/area.height
            return .split(id:UUID().uuidString,axis:axis,ratio:Double(ratio),first:try build(first,in:firstArea,depth:depth+1),second:try build(second,in:secondArea,depth:depth+1))
        }
        let root = try build(clipped,in:bounds,depth:0)
        let result = LayoutPreset(name:"读取的布局",root:root,emptyPanes:emptyPanes,capturedSpacing:true)
        do { try result.validate() } catch { throw LayoutCaptureError.complex }
        guard result.windowCount == frames.count else { throw LayoutCaptureError.complex }
        return result
    }
    public static let builtins: [LayoutPreset] = [
        .init(id: "halves", name: "左右均分", root: .split(id: "main", axis: .horizontal, ratio: 0.5, first: .pane("a"), second: .pane("b"))),
        .init(id: "stack", name: "上下分屏", root: .split(id: "main", axis: .vertical, ratio: 0.5, first: .pane("a"), second: .pane("b"))),
        .init(id: "wide", name: "左宽右窄", root: .split(id: "main", axis: .horizontal, ratio: 0.6, first: .pane("a"), second: .pane("b"))),
        .init(id: "triple", name: "一大两小", root: .split(id: "main", axis: .horizontal, ratio: 0.6, first: .pane("a"), second: .split(id: "side", axis: .vertical, ratio: 0.5, first: .pane("b"), second: .pane("c")))),
        .init(id:"centered-two-thirds",name:"2/3 居中",root:.split(id:"left-line",axis:.horizontal,ratio:1.0/6,first:.pane("left-space"),second:.split(id:"right-line",axis:.horizontal,ratio:0.8,first:.pane("center"),second:.pane("right-space"))),emptyPanes:["left-space","right-space"])
    ]
}

public struct LayoutSeam: Sendable {
    public var id: String
    public var axis: SplitAxis
    public var ratio: Double
    public var bounds: CGRect
    public var line: CGRect
    public var first: LayoutNode
    public var second: LayoutNode
    public func ratio(at coordinate: Double, gap: Double, minimums: [String: CGSize], scale: Double = 1) throws -> Double {
        let a = first.minimumSize(minimums, gap: gap, scale: scale), b = second.minimumSize(minimums, gap: gap, scale: scale)
        let available = (axis == .horizontal ? bounds.width : bounds.height) - gap
        let firstMin = axis == .horizontal ? a.width : a.height
        let secondMin = axis == .horizontal ? b.width : b.height
        let lower = max(1 / scale, firstMin + 0.5 / scale) / available
        let upper = 1 - max(1 / scale, secondMin + 0.5 / scale) / available
        guard available > 0, lower <= upper, coordinate.isFinite else { throw LayoutError.tooSmall }
        let origin = axis == .horizontal ? bounds.minX : bounds.minY
        return max(lower, min(upper, (coordinate - origin - gap / 2) / available))
    }
}

public struct LayoutGeometry: Sendable {
    public var panes: [String: CGRect] = [:]
    public var seams: [LayoutSeam] = []
    public static func make(_ root: LayoutNode, in bounds: CGRect, gap: Double, scale: Double = 1, minimums: [String: CGSize] = [:]) throws -> LayoutGeometry {
        try root.validate()
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height, gap, scale].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, gap >= 0, (1...4).contains(scale) else { throw LayoutError.invalid }
        var result = LayoutGeometry()
        func walk(_ node: LayoutNode, _ area: CGRect) throws {
            guard area.width >= 1, area.height >= 1 else { throw LayoutError.tooSmall }
            switch node {
            case .pane(let id): result.panes[id] = area
            case let .split(id, axis, ratio, first, second):
                let length = (axis == .horizontal ? area.width : area.height) - gap
                let size = (length * ratio * scale).rounded() / scale
                guard size > 0, length - size > 0 else { throw LayoutError.tooSmall }
                let a: CGRect, b: CGRect, seam: CGRect
                if axis == .horizontal {
                    a = CGRect(x: area.minX, y: area.minY, width: size, height: area.height)
                    b = CGRect(x: a.maxX + gap, y: area.minY, width: length - size, height: area.height)
                    seam = CGRect(x: a.maxX, y: area.minY, width: gap, height: area.height)
                } else {
                    a = CGRect(x: area.minX, y: area.minY, width: area.width, height: size)
                    b = CGRect(x: area.minX, y: a.maxY + gap, width: area.width, height: length - size)
                    seam = CGRect(x: area.minX, y: a.maxY, width: area.width, height: gap)
                }
                result.seams.append(.init(id: id, axis: axis, ratio: ratio, bounds: area, line: seam, first: first, second: second))
                try walk(first, a); try walk(second, b)
            }
        }
        try walk(root, bounds)
        for (id, minimum) in minimums {
            if let frame = result.panes[id], frame.width + 0.0001 < minimum.width || frame.height + 0.0001 < minimum.height { throw LayoutError.tooSmall }
        }
        return result
    }
}

public enum LayoutError: Error, LocalizedError {
    case invalid, tooSmall
    public var errorDescription: String? { self == .invalid ? "布局数据无效。请选择或重新保存布局。" : "空间不足，无法满足这些窗口的最小尺寸。" }
}

public enum LayoutCaptureError: Error, LocalizedError {
    case empty, outside, overlap, complex
    public var errorDescription: String? {
        switch self {
        case .empty: return "请先勾选要参与布局的窗口。"
        case .outside: return "有窗口跨越屏幕或超出可用区域，请移回屏幕内，或取消勾选。"
        case .overlap: return "勾选的窗口互相重叠，请取消其中一个，或先排好窗口后刷新。"
        case .complex: return "当前摆法无法完整转换为每屏最多 16 个横竖分区，请减少窗口或调整摆放。"
        }
    }
}

public enum DisplayGeometry {
    public static func fittedFrames(_ frames: [CGRect], in bounds: CGRect) -> [CGRect] {
        let source = frames.reduce(CGRect.null) { $0.union($1) }
        let available = bounds.insetBy(dx:8,dy:8)
        guard !frames.isEmpty, source.width > 0, source.height > 0, available.width > 0, available.height > 0 else { return [] }
        let scale = min(available.width/source.width,available.height/source.height)
        let origin = CGPoint(x:available.midX-source.width*scale/2,y:available.midY-source.height*scale/2)
        return frames.map { frame in
            CGRect(x:origin.x+(frame.minX-source.minX)*scale,y:origin.y+(frame.minY-source.minY)*scale,width:frame.width*scale,height:frame.height*scale)
        }
    }
    public static func flip(_ frame: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
    public static func clampPanel(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        return CGRect(x: max(visible.minX, min(frame.minX, visible.maxX - width)), y: max(visible.minY, min(frame.minY, visible.maxY - height)), width: width, height: height)
    }
}
