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
    public func splittingPane(_ pane: String, axis: SplitAxis, ratio: Double = 0.5) -> LayoutNode {
        switch self {
        case .pane(let id):
            return id == pane ? .split(id: UUID().uuidString, axis: axis, ratio: ratio, first: .pane(id), second: .pane(UUID().uuidString)) : self
        case let .split(id, direction, value, first, second):
            return .split(id: id, axis: direction, ratio: value, first: first.splittingPane(pane, axis: axis, ratio: ratio), second: second.splittingPane(pane, axis: axis, ratio: ratio))
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

public struct LayoutPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var root: LayoutNode
    public init(id: String = UUID().uuidString, name: String, root: LayoutNode) { self.id = id; self.name = name; self.root = root }
    public static let builtins: [LayoutPreset] = [
        .init(id: "halves", name: "左右均分", root: .split(id: "main", axis: .horizontal, ratio: 0.5, first: .pane("a"), second: .pane("b"))),
        .init(id: "stack", name: "上下分屏", root: .split(id: "main", axis: .vertical, ratio: 0.5, first: .pane("a"), second: .pane("b"))),
        .init(id: "wide", name: "左宽右窄", root: .split(id: "main", axis: .horizontal, ratio: 0.6, first: .pane("a"), second: .pane("b"))),
        .init(id: "triple", name: "一大两小", root: .split(id: "main", axis: .horizontal, ratio: 0.6, first: .pane("a"), second: .split(id: "side", axis: .vertical, ratio: 0.5, first: .pane("b"), second: .pane("c"))))
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

public enum DisplayGeometry {
    public static func flip(_ frame: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
    public static func clampPanel(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        return CGRect(x: max(visible.minX, min(frame.minX, visible.maxX - width)), y: max(visible.minY, min(frame.minY, visible.maxY - height)), width: width, height: height)
    }
}
