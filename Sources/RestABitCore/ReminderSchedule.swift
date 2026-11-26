import Foundation

public enum Reminder: String, CaseIterable, Codable, Hashable {
    case look, water, stand, blink

    public var defaultMinutes: Int {
        switch self {
        case .look: 20
        case .water: 40
        case .stand: 60
        case .blink: 10
        }
    }

    public var presentationSeconds: Double {
        switch self {
        case .look: 20
        case .water: 12
        case .stand: 45
        case .blink: 3.4
        }
    }

    public var usesEdgeEntrance: Bool { self == .look || self == .stand }

    static let priority: [Reminder] = [.stand, .look, .water, .blink]
}

public struct ReminderRule: Codable, Equatable {
    public var enabled: Bool
    public var minutes: Int

    public init(enabled: Bool = true, minutes: Int) {
        self.enabled = enabled
        self.minutes = minutes
    }

    var seconds: TimeInterval { Double(max(1, min(minutes, 240))) * 60 }
}

public struct ReminderBatch: Equatable {
    public let main: Reminder
    public let included: [Reminder]

    public init(main: Reminder, included: [Reminder]? = nil) {
        self.main = main
        self.included = included ?? [main]
    }
}

public struct ReminderSchedule {
    private static let breakMergeWindow: TimeInterval = 30
    private static let blinkBreakWindow: TimeInterval = 120
    private static let waterConflictWindow: TimeInterval = 30
    private static let waterGapAfterHeadsUp: TimeInterval = 40
    private static let waterGapAfterRest: TimeInterval = 25
    public static let idlePauseAfter: TimeInterval = 120
    private static let idleResetAfter: TimeInterval = 600
    public private(set) var rules: [Reminder: ReminderRule]
    public private(set) var pausedUntil: TimeInterval?
    private var elapsed: [Reminder: TimeInterval] = [:]
    private var snoozedUntil: [Reminder: TimeInterval] = [:]
    private var previousTick: TimeInterval?
    private var previouslyCounting = false
    private var eligibleAfter: TimeInterval = 0
    private var waterDeferredUntil: TimeInterval = 0
    private var excluded = false

    public init(rules: [Reminder: ReminderRule] = [:]) {
        self.rules = Dictionary(uniqueKeysWithValues: Reminder.allCases.map {
            ($0, rules[$0] ?? ReminderRule(minutes: $0.defaultMinutes))
        })
    }

    public mutating func update(_ rule: ReminderRule, for reminder: Reminder) {
        if rules[reminder] != rule {
            rules[reminder] = rule
            finish(ReminderBatch(main: reminder))
        }
    }

    public mutating func advance(to now: TimeInterval, idle: TimeInterval, excluded: Bool, resting: Bool) {
        let interval = previousTick.map { max(0, now - $0) } ?? 0
        previousTick = now
        if self.excluded && !excluded { eligibleAfter = now + 30 }
        self.excluded = excluded
        if let end = pausedUntil, now >= end {
            pausedUntil = nil
            previouslyCounting = false
        }
        if idle >= Self.idlePauseAfter {
            if idle >= Self.idleResetAfter {
                elapsed.removeAll()
                snoozedUntil.removeAll()
                waterDeferredUntil = 0
            }
            previouslyCounting = false
            return
        }
        let counting = !excluded && pausedUntil == nil && !resting
        if counting && previouslyCounting {
            for reminder in Reminder.allCases where rules[reminder]?.enabled == true {
                elapsed[reminder, default: 0] += interval
            }
        }
        previouslyCounting = counting
    }

    public mutating func setPause(until: TimeInterval?) {
        pausedUntil = until
        previouslyCounting = false
    }

    public mutating func reset() {
        elapsed.removeAll()
        snoozedUntil.removeAll()
        previousTick = nil
        previouslyCounting = false
        eligibleAfter = 0
        waterDeferredUntil = 0
    }

    public mutating func finish(_ batch: ReminderBatch) {
        for reminder in batch.included {
            elapsed[reminder] = 0
            snoozedUntil[reminder] = nil
            if reminder == .water { waterDeferredUntil = 0 }
        }
    }

    public mutating func snooze(_ batch: ReminderBatch, now: TimeInterval) {
        for reminder in batch.included {
            snoozedUntil[reminder] = now + 300
        }
    }

    public func timeLeft(for reminder: Reminder, now: TimeInterval) -> TimeInterval? {
        guard let rule = rules[reminder], rule.enabled else { return nil }
        if let end = snoozedUntil[reminder] { return max(0, end - now) }
        return max(0, rule.seconds - elapsed[reminder, default: 0])
    }

    public func nextScreenBreak(now: TimeInterval) -> (Reminder, TimeInterval)? {
        [.stand, .look].compactMap { reminder in
            readyTime(for: reminder, now: now).map { (reminder, $0) }
        }.min { $0.1 < $1.1 }
    }

    public func next(now: TimeInterval) -> (Reminder, TimeInterval)? {
        Reminder.priority.compactMap { reminder in
            readyTime(for: reminder, now: now).map { (reminder, $0) }
        }.min { $0.1 < $1.1 }
    }

    public mutating func notePresentation(_ reminder: Reminder, now: TimeInterval) {
        if reminder.usesEdgeEntrance {
            deferNearbyWater(now: now, gap: Self.waterGapAfterHeadsUp)
        }
        let blinkWindow = reminder.usesEdgeEntrance ? Self.blinkBreakWindow : Self.waterConflictWindow
        if reminder != .blink, let blink = timeLeft(for: .blink, now: now), blink <= blinkWindow {
            finish(ReminderBatch(main: .blink))
        }
    }

    public mutating func noteRestEnded(now: TimeInterval) {
        deferNearbyWater(now: now, gap: Self.waterGapAfterRest)
    }

    private mutating func deferNearbyWater(now: TimeInterval, gap: TimeInterval) {
        guard let water = timeLeft(for: .water, now: now), water <= Self.waterConflictWindow else { return }
        waterDeferredUntil = max(waterDeferredUntil, now + gap)
    }

    private func readyTime(for reminder: Reminder, now: TimeInterval) -> TimeInterval? {
        guard let time = timeLeft(for: reminder, now: now) else { return nil }
        switch reminder {
        case .stand:
            return time
        case .look:
            if let stand = timeLeft(for: .stand, now: now), stand <= time + Self.breakMergeWindow {
                return nil
            }
            return time
        case .water:
            // Once a due drink has waited for one break, only another actually due break can outrank it.
            if waterDeferredUntil > 0 { return max(time, waterDeferredUntil - now) }
            if let edge = nextScreenBreak(now: now)?.1, edge <= time + Self.waterConflictWindow {
                return nil
            }
            return time
        case .blink:
            if let edge = nextScreenBreak(now: now)?.1, edge <= time + Self.blinkBreakWindow { return nil }
            if let water = readyTime(for: .water, now: now), water <= time + Self.waterConflictWindow { return nil }
            return time
        }
    }

    public func due(now: TimeInterval) -> ReminderBatch? {
        guard pausedUntil == nil, !excluded, now >= eligibleAfter, previouslyCounting,
              let (main, time) = next(now: now), time == 0 else { return nil }
        if main == .stand, let look = timeLeft(for: .look, now: now),
           look <= (snoozedUntil[.look] == nil ? Self.breakMergeWindow : 0) {
            return ReminderBatch(main: .stand, included: [.stand, .look])
        }
        return ReminderBatch(main: main)
    }
}
