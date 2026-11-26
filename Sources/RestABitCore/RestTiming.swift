import Foundation

public struct RestTiming {
    public let duration: TimeInterval
    public let endsAt: TimeInterval

    public init(startedAt: TimeInterval, duration: TimeInterval) {
        self.duration = duration
        endsAt = startedAt + duration
    }

    public func remaining(at now: TimeInterval) -> TimeInterval {
        min(duration, max(0, endsAt - now))
    }

    public func secondsRemaining(at now: TimeInterval) -> Int {
        Int(ceil(remaining(at: now)))
    }
}
