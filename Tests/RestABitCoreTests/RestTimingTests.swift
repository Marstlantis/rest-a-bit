import XCTest
import RestABitCore

final class RestTimingTests: XCTestCase {
    func testRestCountdownUsesTheSameDeadlineAsItsProgress() {
        let timing = RestTiming(startedAt: 200, duration: 20)
        XCTAssertEqual(timing.endsAt, 220)
        XCTAssertEqual(timing.secondsRemaining(at: 200), 20)
        XCTAssertEqual(timing.secondsRemaining(at: 201.4), 19)
        XCTAssertEqual(timing.remaining(at: 210), 10)
        XCTAssertEqual(timing.secondsRemaining(at: 219.6), 1)
        XCTAssertEqual(timing.secondsRemaining(at: 220.3), 0)
    }
}
