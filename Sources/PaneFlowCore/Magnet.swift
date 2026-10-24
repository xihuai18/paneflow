import Foundation
import CoreGraphics

public struct MagnetAnchor: Sendable, Equatable {
    public var window: String
    public var position: Double
    public init(window: String, position: Double) { self.window = window; self.position = position }
}
public struct MagnetResult: Sendable {
    public var frame: CGRect
    public var x: MagnetAnchor?
    public var y: MagnetAnchor?
}
public enum Magnet {
    public static func snap(_ frame: CGRect, to windows: [(id: String, frame: CGRect)], gap: Double,
                            threshold: Double = 14, release: Double = 26, previous: MagnetResult? = nil) -> MagnetResult {
        guard frame.width > 0, frame.height > 0, [frame.minX, frame.minY, frame.width, frame.height, gap].allSatisfy(\.isFinite) else {
            return .init(frame: frame, x: nil, y: nil)
        }
        let frames = Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        func nearest(_ values: [MagnetAnchor], raw: Double, old: MagnetAnchor?) -> MagnetAnchor? {
            if let old, let current = values.first(where: { $0.window == old.window && abs($0.position - old.position) < 1 }),
               frames[old.window] != nil, abs(raw - current.position) <= release { return current }
            return values.filter { abs($0.position - raw) <= threshold }.min { abs($0.position - raw) < abs($1.position - raw) }
        }
        var xs: [MagnetAnchor] = [], ys: [MagnetAnchor] = []
        for (id, target) in windows where target.width > 0 && target.height > 0 {
            let overlapY = min(frame.maxY, target.maxY) - max(frame.minY, target.minY)
            let overlapX = min(frame.maxX, target.maxX) - max(frame.minX, target.minX)
            if overlapY > 20 {
                for value in [target.minX - gap - frame.width, target.maxX + gap, target.minX, target.maxX - frame.width] { xs.append(.init(window: id, position: value)) }
            }
            let besideX = overlapX > 20 || abs(frame.maxX + gap - target.minX) <= release || abs(target.maxX + gap - frame.minX) <= release
            if besideX {
                for value in [target.minY, target.maxY - frame.height] { ys.append(.init(window: id, position: value)) }
                if overlapX > 20 { ys += [.init(window: id, position: target.minY - gap - frame.height), .init(window: id, position: target.maxY + gap)] }
            }
        }
        let x = nearest(xs, raw: frame.minX, old: previous?.x), y = nearest(ys, raw: frame.minY, old: previous?.y)
        return .init(frame: CGRect(x: x?.position ?? frame.minX, y: y?.position ?? frame.minY, width: frame.width, height: frame.height), x: x, y: y)
    }
}

public struct SlotPlacement: Equatable, Sendable {
    public var assignments: [String: String]
    public var displaced: String?
    public init(assignments: [String: String], displaced: String?) { self.assignments = assignments; self.displaced = displaced }
    public static func placing(_ window: String, in slot: String, assignments: [String: String]) -> SlotPlacement {
        var result = assignments
        let oldSlot = result.first { $0.value == window }?.key
        let occupant = result[slot]
        if let oldSlot { result.removeValue(forKey: oldSlot) }
        result[slot] = window
        if let occupant, occupant != window, let oldSlot, oldSlot != slot { result[oldSlot] = occupant; return .init(assignments: result, displaced: nil) }
        return .init(assignments: result, displaced: occupant == window ? nil : occupant)
    }
}
