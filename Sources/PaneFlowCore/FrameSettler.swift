import Foundation
import CoreGraphics

public enum FrameWriteStatus: Equatable, Sendable {
    case accepted
    /// A timed-out AX reply does not prove that the receiving app ignored the request.
    case retryable
    case unavailable
}

public struct FrameAdjustment: Sendable {
    public let reachedTarget: Bool
    public let actual: CGRect?
    public let writes: Int
    public let unavailable: Bool
    /// Only dimensions that changed in response to a request and then stayed above it are measured lower bounds.
    public let constrainedMinimum: CGSize?
}

/// A bounded, independently testable handshake with asynchronously resizing applications.
/// The caller supplies a monotonic clock, off-main-thread wait, and its explicit live window.
public enum FrameSettler {
    public static let tolerance: Double = 2
    public static let timeout: TimeInterval = 2.8
    private static let responseGrace: TimeInterval = 1.2

    public static func matches(_ actual: CGRect, _ requested: CGRect) -> Bool {
        let a = [actual.origin.x, actual.origin.y, actual.size.width, actual.size.height]
        let b = [requested.origin.x, requested.origin.y, requested.size.width, requested.size.height]
        return (a + b).allSatisfy(\.isFinite) && actual.size.width > 0 && actual.size.height > 0 &&
            zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    public static func matchesSize(_ actual: CGRect, _ requested: CGRect) -> Bool {
        [actual.width, actual.height, requested.width, requested.height].allSatisfy(\.isFinite) &&
            actual.size.width > 0 && actual.size.height > 0 &&
            abs(actual.width - requested.width) <= tolerance && abs(actual.height - requested.height) <= tolerance
    }

    public static func adjust(to requested: CGRect, read: () -> CGRect?, write: () -> FrameWriteStatus,
                              repairPosition: (() -> FrameWriteStatus)? = nil,
                              now: () -> TimeInterval, wait: (TimeInterval) -> Void) -> FrameAdjustment {
        guard [requested.origin.x, requested.origin.y, requested.size.width, requested.size.height].allSatisfy(\.isFinite),
              requested.size.width > 0, requested.size.height > 0 else {
            return .init(reachedTarget: false, actual: nil, writes: 0, unavailable: true, constrainedMinimum: nil)
        }
        let start = now()
        let initial = read()
        let deadline = start + timeout
        var writes = 0
        var lastWrite = start - responseGrace
        var acceptedSizeRequest = false
        var positionRepairs = 0
        var lastPositionRepair = start - 0.16
        var actual: CGRect?
        var previous: CGRect?
        var stableSince = start
        var matchingSince: TimeInterval?
        // Iteration count also bounds a broken/injected non-advancing clock.
        for _ in 0..<90 {
            let timestamp = now()
            if timestamp >= deadline { break }
            actual = read()
            if let actual, matches(actual, requested) {
                if let matchingSince, timestamp - matchingSince >= 0.12 {
                    return .init(reachedTarget: true, actual: actual, writes: writes, unavailable: false, constrainedMinimum: nil)
                }
                if matchingSince == nil { matchingSince = timestamp }
            } else {
                matchingSince = nil
                if let actual, let previous, matches(actual, previous) { /* same observed frame */ }
                else { stableSince = timestamp }
                previous = actual
                // Both successful and lost replies may have queued real work. Re-sending
                // every 280ms restarts apps' resize debounce and can prevent completion.
                // Give each request a full response interval, with one bounded retry.
                if let actual, matchesSize(actual, requested), let repairPosition {
                    // Re-sending size to fix origin repeats the stale-frame bug. Correct only position.
                    if positionRepairs < 4 && timestamp - lastPositionRepair >= 0.16 {
                        let outcome = repairPosition()
                        positionRepairs += 1
                        lastPositionRepair = now()
                        if outcome == .unavailable {
                            return .init(reachedTarget: false, actual: actual, writes: writes, unavailable: true, constrainedMinimum: nil)
                        }
                    }
                } else if writes < 2 && timestamp - lastWrite >= responseGrace {
                    let outcome = write()
                    writes += 1
                    lastWrite = now()
                    if outcome == .unavailable {
                        return .init(reachedTarget: false, actual: actual, writes: writes, unavailable: true, constrainedMinimum: nil)
                    }
                    acceptedSizeRequest = acceptedSizeRequest || outcome == .accepted
                }
            }
            wait(min(0.04, max(0, deadline - now())))
        }
        actual = read()
        // A last read alone is not success: it has not demonstrated a stable position.
        var minimum: CGSize?
        if acceptedSizeRequest, let initial, let actual, let previous, matches(actual, previous),
           now() - stableSince >= 0.2, matchingSince == nil {
            // Seeing the old preset unchanged does NOT prove a minimum. It may just be
            // a busy app ignoring/delaying AX. Require a measured size response per axis.
            let width = actual.width > requested.width + tolerance && abs(actual.width - initial.width) > tolerance ? actual.width : 0
            let height = actual.height > requested.height + tolerance && abs(actual.height - initial.height) > tolerance ? actual.height : 0
            if width > 0 || height > 0 { minimum = CGSize(width: width, height: height) }
        }
        return .init(reachedTarget: false, actual: actual, writes: writes, unavailable: false, constrainedMinimum: minimum)
    }
}
