import Foundation
import CoreGraphics

/// One nonblocking axis at a time; mouse updates replace goals instead of queuing handshakes.
public struct FramePreview: Sendable {
    public enum Write: Equatable, Sendable { case position(CGPoint), size(CGSize) }
    private var active: Write?
    private var started: TimeInterval = 0
    private var matchedSince: TimeInterval?
    public private(set) var deferred = false
    private let settleInterval: TimeInterval
    public init(settleInterval: TimeInterval = 0.08) { self.settleInterval = max(0, settleInterval) }
    public mutating func next(actual: CGRect, target: CGRect, now: TimeInterval) -> Write? {
        guard !deferred, FrameSettler.matches(actual, actual), FrameSettler.matches(target, target) else { return nil }
        if let active {
            let matches: Bool
            switch active {
            case .position(let p): matches = abs(p.x-actual.minX)<1.5 && abs(p.y-actual.minY)<1.5
            case .size(let s): matches = abs(s.width-actual.width)<1.5 && abs(s.height-actual.height)<1.5
            }
            if matches {
                if settleInterval == 0 || matchedSince.map({ now-$0 >= settleInterval }) == true { self.active = nil; matchedSince = nil }
                else { if matchedSince == nil { matchedSince = now }; return nil }
            } else {
                matchedSince = nil
                if now-started >= 1.2 { deferred = true }
                return nil
            }
        }
        let positionMatches = abs(actual.minX-target.minX)<1.5 && abs(actual.minY-target.minY)<1.5
        let sizeMatches = FrameSettler.matchesSize(actual, target)
        guard !positionMatches || !sizeMatches else { return nil }
        let needsRoom = (target.minX>actual.minX+2 && target.width<actual.width-2) || (target.minY>actual.minY+2 && target.height<actual.height-2)
        let write: Write
        if !positionMatches && needsRoom { write = .size(.init(width:min(actual.width,target.width),height:min(actual.height,target.height))) }
        else if !positionMatches { write = .position(target.origin) }
        else { write = .size(target.size) }
        active = write; started = now; matchedSince = nil
        return write
    }
}
