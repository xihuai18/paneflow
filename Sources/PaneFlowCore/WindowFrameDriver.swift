import Foundation
import CoreGraphics

/// Separate AX axes so the transport can be tested without any personal windows.
public enum WindowFrameDriver {
    private enum Axis {
        case position(CGPoint)
        case size(CGSize)

        func matches(_ frame: CGRect) -> Bool {
            switch self {
            case .position(let point):
                return abs(frame.minX - point.x) <= FrameSettler.tolerance && abs(frame.minY - point.y) <= FrameSettler.tolerance
            case .size(let size):
                return abs(frame.width - size.width) <= FrameSettler.tolerance && abs(frame.height - size.height) <= FrameSettler.tolerance
            }
        }
    }

    public static func adjust(to requested: CGRect, read: () -> CGRect?,
                              setPosition: @escaping (CGPoint) -> FrameWriteStatus, setSize: (CGSize) -> FrameWriteStatus,
                              now: () -> TimeInterval, wait: (TimeInterval) -> Void,
                              shouldStop: () -> Bool = { false }) -> FrameAdjustment {
        guard FrameSettler.matches(requested, requested) else {
            return .init(reachedTarget: false, actual: nil, writes: 0, unavailable: true, constrainedMinimum: nil)
        }
        let start = now()
        let initial = read()
        let deadline = start + 5.6
        var active: Axis?
        var phaseStarted = start
        var phaseWrites = 0
        var lastWrite = start
        var writes = 0
        var stableSince = start
        var matchingSince: TimeInterval?
        var previous: CGRect?
        var actual = initial
        var acceptedSize = false

        func send(_ axis: Axis) -> FrameWriteStatus {
            switch axis {
            case .position(let point): return setPosition(point)
            case .size(let size): return setSize(size)
            }
        }

        // Different AX attributes can each animate a whole frame with stale values for the
        // other axis. Merely reversing the setter order is insufficient: finish one first.
        for _ in 0..<160 {
            let timestamp = now()
            if timestamp >= deadline || shouldStop() { break }
            actual = read()
            guard let current = actual, FrameSettler.matches(current, current) else {
                wait(0.04)
                continue
            }
            if previous.map({ FrameSettler.matches($0, current) }) != true { stableSince = timestamp }
            previous = current
            if FrameSettler.matches(current, requested) {
                if let matchingSince, timestamp - matchingSince >= 0.16 {
                    return .init(reachedTarget: true, actual: current, writes: writes, unavailable: false, constrainedMinimum: nil)
                }
                if matchingSince == nil { matchingSince = timestamp }
                wait(0.04)
                continue
            }
            matchingSince = nil

            if let axis = active {
                if axis.matches(current), timestamp - stableSince >= 0.08 {
                    active = nil
                    phaseWrites = 0
                } else {
                    if timestamp - phaseStarted >= 2.8 { break }
                    // Do not restart an animation that is making progress. One lost reply can
                    // be retried, but no more than once after a full motionless response interval.
                    if phaseWrites < 2, timestamp - lastWrite >= 1.2, timestamp - stableSince >= 1.2 {
                        let outcome = send(axis)
                        writes += 1; phaseWrites += 1; lastWrite = now()
                        if case .size = axis { acceptedSize = acceptedSize || outcome == .accepted }
                        if outcome == .unavailable {
                            return .init(reachedTarget: false, actual: current, writes: writes, unavailable: true, constrainedMinimum: nil)
                        }
                    }
                    wait(min(0.04, max(0, deadline - now())))
                    continue
                }
            }

            let positionMatches = Axis.position(requested.origin).matches(current)
            let sizeMatches = FrameSettler.matchesSize(current, requested)
            let axis: Axis
            // Shrink first only when movement towards the right/bottom would clip the OLD
            // larger window. For growth, move away from the edge before requesting the size.
            let needsRoom = (requested.minX > current.minX + 2 && current.width > requested.width + 2) ||
                (requested.minY > current.minY + 2 && current.height > requested.height + 2)
            if !positionMatches && needsRoom {
                axis = .size(CGSize(width: min(current.width, requested.width), height: min(current.height, requested.height)))
            } else if !positionMatches {
                axis = .position(requested.origin)
            } else if !sizeMatches {
                axis = .size(requested.size)
            } else { continue }
            active = axis
            phaseStarted = timestamp
            phaseWrites = 1
            let outcome = send(axis)
            writes += 1
            lastWrite = now()
            stableSince = lastWrite
            if case .size = axis { acceptedSize = acceptedSize || outcome == .accepted }
            if outcome == .unavailable {
                return .init(reachedTarget: false, actual: current, writes: writes, unavailable: true, constrainedMinimum: nil)
            }
            wait(min(0.04, max(0, deadline - now())))
        }

        actual = read()
        var minimum: CGSize?
        if !shouldStop(), acceptedSize, let initial, let actual, now() - stableSince >= 0.2,
           previous.map({ FrameSettler.matches($0, actual) }) == true {
            let width = actual.width > requested.width + 2 && abs(actual.width - initial.width) > 2 ? actual.width : 0
            let height = actual.height > requested.height + 2 && abs(actual.height - initial.height) > 2 ? actual.height : 0
            if width > 0 || height > 0 { minimum = CGSize(width: width, height: height) }
        }
        return .init(reachedTarget: false, actual: actual, writes: writes, unavailable: false, constrainedMinimum: minimum)
    }
}
