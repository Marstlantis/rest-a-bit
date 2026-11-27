import CoreGraphics
import XCTest
import RestABitCore

final class FullScreenWindowTests: XCTestCase {
    func testMatchesFullScreenOnAnOffsetDisplay() {
        let display = CGRect(x: -1_680, y: 72, width: 1_680, height: 1_050)
        XCTAssertTrue(FullScreenWindow.matchesDisplay(display.offsetBy(dx: 1, dy: -1), display: display))
        XCTAssertFalse(FullScreenWindow.matchesDisplay(display.offsetBy(dx: 5, dy: 0), display: display))
    }

    func testMaximizedWindowWithMenuBarSpaceDoesNotCountAsFullScreen() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let maximized = CGRect(x: 0, y: 28, width: 1_440, height: 872)
        XCTAssertFalse(FullScreenWindow.matchesDisplay(maximized, display: display))
        XCTAssertFalse(FullScreenWindow.matchesDisplay(.zero, display: display))
    }
}
