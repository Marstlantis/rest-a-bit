import CoreGraphics
import XCTest
import RestABitCore

final class LandingTests: XCTestCase {
    let leftDisplay = CGRect(x: -1_920, y: -150, width: 1_870, height: 950)

    func testEveryDirectionStaysInTheVisibleFrameOnALeftDisplay() throws {
        var random = SeededRandom(seed: 42)
        for origin in EntranceOrigin.allCases {
            let landing = try XCTUnwrap(Landing.choose(in: leftDisplay, pointer: .zero,
                                                       previous: nil, force: origin, using: &random))
            XCTAssertEqual(landing.origin, origin)
            XCTAssertTrue(leftDisplay.contains(landing.card))
            XCTAssertTrue(leftDisplay.contains(landing.stage))
        }
    }

    func testSelectionReplaysASeedAndAvoidsTheLastDirection() throws {
        var first = SeededRandom(seed: 120)
        var second = SeededRandom(seed: 120)
        let pointer = CGPoint(x: leftDisplay.midX, y: leftDisplay.midY)
        var previous: EntranceOrigin?
        for _ in 0..<25 {
            let a = try XCTUnwrap(Landing.choose(in: leftDisplay, pointer: pointer,
                                                 previous: previous, force: nil, using: &first))
            let b = Landing.choose(in: leftDisplay, pointer: pointer, previous: previous, force: nil, using: &second)
            XCTAssertEqual(a, b)
            XCTAssertNotEqual(a.origin, previous)
            previous = a.origin
        }
    }

    func testEveryOriginEndsAtTheCenterWithItsOwnCardPlacement() throws {
        var random = SeededRandom(seed: 53)
        let center = CGPoint(x: leftDisplay.midX, y: leftDisplay.midY)
        for origin in EntranceOrigin.allCases {
            let landing = try XCTUnwrap(Landing.choose(in: leftDisplay, pointer: center,
                                                       previous: nil, force: origin, using: &random))
            XCTAssertEqual(landing.stop, center)
            XCTAssertTrue(landing.stage.contains(center))
            XCTAssertFalse(landing.card.contains(center))
            XCTAssertEqual(landing.callout.arrow, origin.calloutSide)
            switch origin {
            case .left, .topLeft, .bottomLeft: XCTAssertEqual(landing.entry.x, leftDisplay.minX)
            case .right, .topRight, .bottomRight: XCTAssertEqual(landing.entry.x, leftDisplay.maxX)
            case .top: XCTAssertEqual(landing.entry.y, leftDisplay.maxY)
            case .bottom: XCTAssertEqual(landing.entry.y, leftDisplay.minY)
            }
        }
    }

    func testEachEdgeHasFiveEntryPositionsAndAllFourCornersAreAvailable() {
        let center = CGPoint(x: leftDisplay.midX, y: leftDisplay.midY)
        let candidates = Landing.candidates(in: leftDisplay, pointer: center)
        for origin in EntranceOrigin.allCases {
            let matches = candidates.filter { $0.origin == origin }
            let positions = Set(matches.map { $0.entry.x.description + "," + $0.entry.y.description })
            XCTAssertEqual(positions.count, origin.isCorner ? 1 : 5)
        }

        XCTAssertEqual(candidates.filter { $0.origin.isCorner }.map(\.entry), [
            CGPoint(x: leftDisplay.minX, y: leftDisplay.maxY),
            CGPoint(x: leftDisplay.maxX, y: leftDisplay.maxY),
            CGPoint(x: leftDisplay.minX, y: leftDisplay.minY),
            CGPoint(x: leftDisplay.maxX, y: leftDisplay.minY)
        ])
    }

    func testCardMovesToTheOtherSideWhenThePointerCoversItsPreferredSlot() throws {
        let center = CGPoint(x: leftDisplay.midX, y: leftDisplay.midY)
        let pointer = CGPoint(x: center.x + 140, y: center.y)
        let card = try XCTUnwrap(Landing.callout(near: center, in: leftDisplay, pointer: pointer, preferred: .left))
        XCTAssertEqual(card.arrow, .right)
        XCTAssertFalse(card.frame.insetBy(dx: -16, dy: -16).contains(pointer))
        XCTAssertTrue(leftDisplay.contains(card.frame))
    }

    func testFittedBodyHasOnlyTheRequestedArrowSpace() throws {
        let center = CGPoint(x: leftDisplay.midX, y: leftDisplay.midY)
        let size = CGSize(width: 152, height: 63)
        let side = try XCTUnwrap(Landing.callout(near: center, in: leftDisplay, pointer: center,
                                                 preferred: .left, fittedBody: size))
        let below = try XCTUnwrap(Landing.callout(near: center, in: leftDisplay, pointer: center,
                                                  preferred: .top, fittedBody: size))
        XCTAssertEqual(side.frame.size, CGSize(width: 159, height: 63))
        XCTAssertEqual(below.frame.size, CGSize(width: 152, height: 70))
        XCTAssertEqual(side.frame.midY, center.y)
        XCTAssertEqual(below.frame.midX, center.x)
    }

    func testUnsafeSmallAreaOffersOnlyAContainedCard() throws {
        let small = CGRect(x: 0, y: 0, width: 302, height: 180)
        XCTAssertTrue(Landing.candidates(in: small, pointer: .zero).isEmpty)
        let card = try XCTUnwrap(Landing.fallback(in: small, pointer: .zero))
        XCTAssertTrue(small.contains(card))
    }
}
