import XCTest
@testable import RestABitCore

final class PelvicPracticeTests: XCTestCase {
    func testEachRoundIncludesFullReleaseAndFinishesAfterTheFifthRound() {
        XCTAssertEqual(PelvicPracticeTiming.cue(elapsed: 0).phase, .prepare)
        XCTAssertEqual(PelvicPracticeTiming.cue(elapsed: 0).secondsLeft, 3)
        for round in 1...5 {
            let start = 3 + Double(round - 1) * 9
            let squeeze = PelvicPracticeTiming.cue(elapsed: start)
            let release = PelvicPracticeTiming.cue(elapsed: start + 3)
            XCTAssertEqual(squeeze.phase, .squeeze)
            XCTAssertEqual(squeeze.secondsLeft, 3)
            XCTAssertEqual(squeeze.round, round)
            XCTAssertEqual(release.phase, .release)
            XCTAssertEqual(release.secondsLeft, 6)
            XCTAssertEqual(release.round, round)
        }
        XCTAssertEqual(PelvicPracticeTiming.cue(elapsed: 47.9).phase, .release)
        XCTAssertEqual(PelvicPracticeTiming.cue(elapsed: 48).phase, .finished)
        XCTAssertEqual(PelvicPracticeTiming.cue(elapsed: 100).progress, 1)
    }

    func testFoxTransitionsStayInsideEachPromptAndReturnToRest() {
        let frameCount = 25
        let keys = PelvicPracticeTiming.foxKeyframes(frameCount: frameCount)
        XCTAssertEqual(keys.first?.time, 0)
        XCTAssertEqual(keys.first?.frame, 0)
        XCTAssertTrue(zip(keys, keys.dropFirst()).allSatisfy { pair in pair.0.time < pair.1.time })

        for round in 1...PelvicPracticeTiming.rounds {
            let drawn = keys.dropFirst().filter { PelvicPracticeTiming.cue(elapsed: $0.time).round == round }
            let squeeze = drawn.filter { PelvicPracticeTiming.cue(elapsed: $0.time).phase == .squeeze }
            let release = drawn.filter { PelvicPracticeTiming.cue(elapsed: $0.time).phase == .release }
            XCTAssertEqual(squeeze.map(\.frame), Array(1..<frameCount))
            XCTAssertEqual(release.map(\.frame), Array((0..<(frameCount - 1)).reversed()))
        }
    }

    func testPracticeDefaultsOffAndRunsBeyondTwoIntervalsWhenEnabled() {
        XCTAssertEqual(ReminderSchedule().rules[.pelvicFloor], .init(enabled: false, minutes: 120))
        var schedule = ReminderSchedule(rules: practiceOnly())
        schedule.advance(to: 0, idle: 0, excluded: false, resting: false)
        for cycle in 1...3 {
            let time = Double(cycle * 120 * 60)
            schedule.advance(to: time - 1, idle: 0, excluded: false, resting: false)
            XCTAssertNil(schedule.due(now: time - 1))
            schedule.advance(to: time, idle: 0, excluded: false, resting: false)
            XCTAssertEqual(schedule.due(now: time)?.main, .pelvicFloor)
            schedule.finish(.init(main: .pelvicFloor))
        }
    }

    func testPracticeWaitsWhenAnEyeBreakIsDueWithinItsDuration() {
        var schedule = ReminderSchedule(rules: [.look: .init(minutes: 2), .pelvicFloor: .init(minutes: 1)])
        schedule.advance(to: 0, idle: 0, excluded: false, resting: false)
        schedule.advance(to: 75, idle: 0, excluded: false, resting: false)
        XCTAssertNil(schedule.due(now: 75))
        schedule.advance(to: 120, idle: 0, excluded: false, resting: false)
        XCTAssertEqual(schedule.due(now: 120)?.main, .look)
        schedule.finish(.init(main: .look))
        XCTAssertEqual(schedule.due(now: 120)?.main, .pelvicFloor)
    }

    func testWaterDueShortlyTakesPrecedenceOverPractice() {
        var rules = practiceOnly(minutes: 1)
        rules[.water] = .init(minutes: 2)
        var schedule = ReminderSchedule(rules: rules)
        schedule.advance(to: 0, idle: 0, excluded: false, resting: false)
        schedule.advance(to: 109, idle: 0, excluded: false, resting: false)
        XCTAssertNil(schedule.due(now: 109))
        schedule.advance(to: 120, idle: 0, excluded: false, resting: false)
        XCTAssertEqual(schedule.due(now: 120)?.main, .water)
        schedule.finish(.init(main: .water))
        XCTAssertEqual(schedule.due(now: 120)?.main, .pelvicFloor)
    }

    func testPracticeConsumesOnlyAnOverlappingBlinkCue() {
        var rules = practiceOnly(minutes: 1)
        rules[.blink] = .init(minutes: 1)
        var schedule = ReminderSchedule(rules: rules)
        schedule.advance(to: 0, idle: 0, excluded: false, resting: false)
        schedule.advance(to: 60, idle: 0, excluded: false, resting: false)
        XCTAssertEqual(schedule.due(now: 60)?.main, .pelvicFloor)
        schedule.notePresentation(.pelvicFloor, now: 60)
        schedule.finish(.init(main: .pelvicFloor))
        XCTAssertEqual(schedule.timeLeft(for: .blink, now: 60), 60)
        XCTAssertNil(schedule.due(now: 60))

        rules[.blink] = .init(minutes: 2)
        schedule = ReminderSchedule(rules: rules)
        schedule.advance(to: 0, idle: 0, excluded: false, resting: false)
        schedule.advance(to: 60, idle: 0, excluded: false, resting: false)
        schedule.notePresentation(.pelvicFloor, now: 60)
        XCTAssertEqual(schedule.timeLeft(for: .blink, now: 60), 60)
    }

    func testShortEyeBreakIntervalLeavesRoomForPractice() {
        var rules = practiceOnly(minutes: 1)
        rules[.look] = .init(minutes: 1)
        var schedule = ReminderSchedule(rules: rules)
        schedule.advance(to: 0, idle: 0, excluded: false, resting: false)
        schedule.advance(to: 60, idle: 0, excluded: false, resting: false)
        XCTAssertEqual(schedule.due(now: 60)?.main, .look)
        schedule.finish(.init(main: .look))
        schedule.advance(to: 66, idle: 0, excluded: false, resting: false)
        XCTAssertEqual(schedule.due(now: 66)?.main, .pelvicFloor)
    }

    private func practiceOnly(minutes: Int = 120) -> [Reminder: ReminderRule] {
        Dictionary(uniqueKeysWithValues: Reminder.allCases.map { kind in
            (kind, ReminderRule(enabled: kind == .pelvicFloor, minutes: minutes))
        })
    }
}
