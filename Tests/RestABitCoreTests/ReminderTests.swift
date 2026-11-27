import XCTest
import RestABitCore

final class ReminderTests: XCTestCase {
    func testCompletingEyeBreakDoesNotResetWaterOrStanding() throws {
        var schedule = ReminderSchedule(rules: [.blink: ReminderRule(enabled: false, minutes: 10)])
        advance(&schedule, 0)
        advance(&schedule, 1_200)
        let first = try XCTUnwrap(schedule.due(now: 1_200))
        XCTAssertEqual(first, ReminderBatch(main: .look))
        schedule.finish(first)
        advance(&schedule, 1_220, resting: true)
        advance(&schedule, 1_221)
        advance(&schedule, 2_421)
        let second = try XCTUnwrap(schedule.due(now: 2_421))
        XCTAssertEqual(second, ReminderBatch(main: .look))
        schedule.finish(second)
        XCTAssertEqual(schedule.timeLeft(for: .stand, now: 2_421), 1_200)
    }

    func testStandingAndEyeBreakMergeWithoutConsumingWater() throws {
        var schedule = ReminderSchedule(rules: [
            .look: ReminderRule(minutes: 1),
            .water: ReminderRule(minutes: 1),
            .stand: ReminderRule(minutes: 1)
        ])
        advance(&schedule, 0)
        advance(&schedule, 60)
        let batch = try XCTUnwrap(schedule.due(now: 60))
        XCTAssertEqual(batch, ReminderBatch(main: .stand, included: [.stand, .look]))
        schedule.notePresentation(batch.main, now: 60)
        schedule.finish(batch)
        XCTAssertEqual(schedule.timeLeft(for: .water, now: 60), 0)
        advance(&schedule, 99)
        XCTAssertNil(schedule.due(now: 99))
        advance(&schedule, 100)
        XCTAssertEqual(schedule.due(now: 100), ReminderBatch(main: .water))
    }

    func testHigherPriorityBreakDoesNotStartEarly() {
        var schedule = ReminderSchedule(rules: [.look: ReminderRule(minutes: 1), .stand: ReminderRule(minutes: 2)])
        advance(&schedule, 0)
        advance(&schedule, 60)
        XCTAssertEqual(schedule.due(now: 60), ReminderBatch(main: .look))
        advance(&schedule, 90)
        XCTAssertNil(schedule.due(now: 90))
        XCTAssertEqual(schedule.next(now: 90)?.0, .stand)
        advance(&schedule, 120)
        XCTAssertEqual(schedule.due(now: 120), ReminderBatch(main: .stand, included: [.stand, .look]))
    }

    func testOverdueWaterGetsItsOwnReminderAfterTheFullScreenRest() throws {
        var schedule = ReminderSchedule(rules: [.look: ReminderRule(minutes: 1), .water: ReminderRule(minutes: 1)])
        advance(&schedule, 0)
        advance(&schedule, 60)
        let batch = try XCTUnwrap(schedule.due(now: 60))
        XCTAssertEqual(batch, ReminderBatch(main: .look))
        schedule.notePresentation(batch.main, now: 60)
        advance(&schedule, 61, resting: true)
        advance(&schedule, 102, resting: true)
        schedule.finish(batch)
        schedule.noteRestEnded(now: 102)
        advance(&schedule, 103)
        advance(&schedule, 126)
        XCTAssertNil(schedule.due(now: 126))
        advance(&schedule, 127)
        XCTAssertEqual(schedule.due(now: 127), ReminderBatch(main: .water))
    }

    func testSnoozingKeepsFiveMinutesAndDoesNotJoinEarly() throws {
        var schedule = ReminderSchedule(rules: [
            .look: ReminderRule(minutes: 1),
            .water: ReminderRule(minutes: 4),
            .stand: ReminderRule(enabled: false, minutes: 60)
        ])
        advance(&schedule, 0)
        advance(&schedule, 60)
        schedule.snooze(try XCTUnwrap(schedule.due(now: 60)), now: 60)
        advance(&schedule, 70)
        XCTAssertNil(schedule.due(now: 70), "The old heads-up deadline does not make a break due")
        advance(&schedule, 240)
        XCTAssertEqual(schedule.due(now: 240), ReminderBatch(main: .water))
        schedule.finish(ReminderBatch(main: .water))
        advance(&schedule, 360)
        XCTAssertEqual(schedule.due(now: 360), ReminderBatch(main: .look))
    }

    func testExclusionFreezesCountersAndAddsGracePeriod() {
        var schedule = shortSchedule()
        advance(&schedule, 0)
        advance(&schedule, 59)
        advance(&schedule, 59, excluded: true)
        advance(&schedule, 180, excluded: true)
        advance(&schedule, 181)
        advance(&schedule, 182)
        XCTAssertNil(schedule.due(now: 182))
        XCTAssertNil(schedule.due(now: 210))
        XCTAssertEqual(schedule.due(now: 211), ReminderBatch(main: .look))
    }

    func testBriefIdlePreservesScreenBreakProgressAndDoesNotPresentWhileIdle() {
        var schedule = shortSchedule()
        advance(&schedule, 0)
        advance(&schedule, 59)
        advance(&schedule, 119, idle: 120)
        advance(&schedule, 299, idle: 300)
        XCTAssertEqual(schedule.nextScreenBreak(now: 299)?.1, 1)
        XCTAssertNil(schedule.due(now: 299))

        advance(&schedule, 300)
        XCTAssertNil(schedule.due(now: 300))
        advance(&schedule, 301)
        XCTAssertEqual(schedule.due(now: 301), ReminderBatch(main: .look))
    }

    func testLongIdleAndWakeClearOverdueReminders() {
        var schedule = shortSchedule()
        advance(&schedule, 0)
        advance(&schedule, 59)
        advance(&schedule, 600, idle: 600)
        advance(&schedule, 601)
        XCTAssertEqual(schedule.timeLeft(for: .look, now: 601), 60)
        advance(&schedule, 661)
        XCTAssertNotNil(schedule.due(now: 661))
        schedule.reset()
        advance(&schedule, 2_500)
        XCTAssertEqual(schedule.timeLeft(for: .look, now: 2_500), 60)
    }

    func testPauseDoesNotCountTimeUntilResumed() {
        var schedule = shortSchedule()
        advance(&schedule, 0)
        advance(&schedule, 50)
        schedule.setPause(until: 1_850)
        advance(&schedule, 1_849)
        XCTAssertNil(schedule.due(now: 1_849))
        advance(&schedule, 1_850)
        XCTAssertEqual(schedule.timeLeft(for: .look, now: 1_850), 10)
        advance(&schedule, 1_860)
        XCTAssertEqual(schedule.due(now: 1_860), ReminderBatch(main: .look))
    }

    func testBlinkIsEnabledAtTenMinutesForExistingPreferences() {
        var schedule = ReminderSchedule(rules: [.look: ReminderRule(minutes: 25)])
        XCTAssertEqual(schedule.rules[.blink], ReminderRule(minutes: 10))
        advance(&schedule, 0)
        advance(&schedule, 599)
        XCTAssertNil(schedule.due(now: 599))
        advance(&schedule, 600)
        XCTAssertEqual(schedule.due(now: 600), ReminderBatch(main: .blink))
        schedule.finish(ReminderBatch(main: .blink))
        XCTAssertEqual(schedule.timeLeft(for: .look, now: 600), 900)
    }

    func testBlinkWaitsForUpcomingEdgeReminderWithoutStartingItEarly() {
        var schedule = ReminderSchedule(rules: [
            .blink: ReminderRule(minutes: 1), .look: ReminderRule(minutes: 3)
        ])
        advance(&schedule, 0)
        advance(&schedule, 60)
        XCTAssertNil(schedule.due(now: 60))
        XCTAssertEqual(schedule.next(now: 60)?.0, .look)
        XCTAssertEqual(schedule.next(now: 60)?.1, 120)

        advance(&schedule, 180)
        XCTAssertEqual(schedule.due(now: 180), ReminderBatch(main: .look))
    }

    func testSimultaneousBlinkIsSkippedWhenStandingReminderAppears() throws {
        var schedule = ReminderSchedule(rules: [
            .blink: ReminderRule(minutes: 2), .stand: ReminderRule(minutes: 2)
        ])
        advance(&schedule, 0)
        advance(&schedule, 120)
        let batch = try XCTUnwrap(schedule.due(now: 120))
        XCTAssertEqual(batch, ReminderBatch(main: .stand))

        schedule.notePresentation(batch.main, now: 120)
        schedule.finish(batch)
        XCTAssertEqual(schedule.timeLeft(for: .blink, now: 120), 120)
        XCTAssertNil(schedule.due(now: 120))
    }

    func testEdgeReminderSkipsUpcomingBlinkInItsWindow() throws {
        var schedule = ReminderSchedule(rules: [
            .blink: ReminderRule(minutes: 3), .look: ReminderRule(minutes: 2)
        ])
        advance(&schedule, 0)
        advance(&schedule, 120)
        let batch = try XCTUnwrap(schedule.due(now: 120))
        XCTAssertEqual(batch, ReminderBatch(main: .look))
        XCTAssertEqual(schedule.timeLeft(for: .blink, now: 120), 60)

        schedule.notePresentation(batch.main, now: 120)
        XCTAssertEqual(schedule.timeLeft(for: .blink, now: 120), 180)
    }

    func testEdgeReminderKeepsBlinkOutsideItsWindow() {
        var schedule = ReminderSchedule(rules: [.look: ReminderRule(minutes: 2)])
        advance(&schedule, 0)
        advance(&schedule, 120)
        schedule.notePresentation(.look, now: 120)
        XCTAssertEqual(schedule.timeLeft(for: .blink, now: 120), 480)
    }

    func testWaterOutranksBlinkAndSkipsTheNearbyBlink() {
        var schedule = ReminderSchedule(rules: [
            .blink: ReminderRule(minutes: 1), .water: ReminderRule(minutes: 1)
        ])
        advance(&schedule, 0)
        advance(&schedule, 60)
        let batch = ReminderBatch(main: .water)
        XCTAssertEqual(schedule.due(now: 60), batch)
        schedule.notePresentation(.water, now: 60)
        schedule.finish(batch)
        XCTAssertEqual(schedule.timeLeft(for: .blink, now: 60), 60)
        XCTAssertNil(schedule.due(now: 60))
    }

    func testMenuBarProgressTracksOnlyTheNextScreenBreak() {
        var schedule = ReminderSchedule(rules: [.look: ReminderRule(minutes: 20)])
        advance(&schedule, 0)
        XCTAssertEqual(schedule.nextScreenBreakProgress(now: 0), 0)
        advance(&schedule, 600)
        XCTAssertEqual(schedule.next(now: 600)?.0, .blink)
        XCTAssertEqual(schedule.nextScreenBreakProgress(now: 600), 0.5)
        advance(&schedule, 1_200)
        XCTAssertEqual(schedule.nextScreenBreakProgress(now: 1_200), 1)
        schedule.finish(ReminderBatch(main: .look))
        XCTAssertEqual(schedule.nextScreenBreakProgress(now: 1_200), 0)
    }

    func testMenuBarProgressUsesTheFiveMinuteSnoozeDuration() {
        var schedule = shortSchedule()
        advance(&schedule, 0)
        advance(&schedule, 60)
        schedule.snooze(ReminderBatch(main: .look), now: 60)
        XCTAssertEqual(schedule.nextScreenBreakProgress(now: 60), 0)
        XCTAssertEqual(schedule.nextScreenBreakProgress(now: 210), 0.5)
        XCTAssertEqual(schedule.nextScreenBreakProgress(now: 360), 1)
        schedule.update(ReminderRule(enabled: false, minutes: 1), for: .look)
        XCTAssertNil(schedule.nextScreenBreakProgress(now: 360))
    }

    private func shortSchedule() -> ReminderSchedule {
        ReminderSchedule(rules: [
            .look: ReminderRule(minutes: 1),
            .water: ReminderRule(enabled: false, minutes: 40),
            .stand: ReminderRule(enabled: false, minutes: 60)
        ])
    }

    private func advance(_ schedule: inout ReminderSchedule, _ time: Double, idle: Double = 0,
                         excluded: Bool = false, resting: Bool = false) {
        schedule.advance(to: time, idle: idle, excluded: excluded, resting: resting)
    }
}
