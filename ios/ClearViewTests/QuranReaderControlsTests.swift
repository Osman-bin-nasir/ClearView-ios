import XCTest
import UIKit
@testable import ClearView

final class QuranReaderControlsTests: XCTestCase {
    func testAutoScrollMovesAtTheSameSpeedAcrossDisplayRefreshRates() {
        for speed in QuranAutoScrollSpeed.allCases {
            let at60 = offset(afterFrames: 60, framesPerSecond: 60, speed: speed)
            let at120 = offset(afterFrames: 120, framesPerSecond: 120, speed: speed)
            XCTAssertEqual(at60, speed.pointsPerSecond, accuracy: 0.0001)
            XCTAssertEqual(at60, at120, accuracy: 0.0001)
        }
        XCTAssertLessThan(QuranAutoScrollSpeed.slow.pointsPerSecond, QuranAutoScrollSpeed.medium.pointsPerSecond)
        XCTAssertLessThan(QuranAutoScrollSpeed.medium.pointsPerSecond, QuranAutoScrollSpeed.fast.pointsPerSecond)
    }

    func testAutoScrollStopsAtTheEndAndDoesNotJumpAfterALongFrame() {
        XCTAssertEqual(QuranScrollMotion.nextOffset(current: 99.9, minimum: 0, maximum: 100,
                                                    elapsed: 1 / 60.0, speed: .fast), 100)
        XCTAssertEqual(QuranScrollMotion.nextOffset(current: 0, minimum: 0, maximum: -100,
                                                    elapsed: 1, speed: .medium), 0)
        XCTAssertEqual(QuranScrollMotion.nextOffset(current: -20, minimum: -20, maximum: 100,
                                                    elapsed: 60, speed: .fast), -15.8, accuracy: 0.0001)
        XCTAssertEqual(QuranScrollMotion.nextOffset(current: 10, minimum: 0, maximum: 100,
                                                    elapsed: -1, speed: .fast), 10)
    }

    @MainActor
    func testPauseAndDetachStopTheDriverAndLeaveTheListsDelegateAlone() {
        let scroll = UIScrollView()
        let delegate = ScrollDelegate()
        scroll.delegate = delegate
        let initialGestures = scroll.gestureRecognizers?.count ?? 0
        let driver = QuranReaderAutoScroll()
        driver.attach(scroll)
        XCTAssertTrue(scroll.delegate === delegate)
        XCTAssertEqual(scroll.gestureRecognizers?.count, initialGestures + 1)
        driver.start()
        XCTAssertTrue(driver.isRunning)
        driver.pause()
        XCTAssertFalse(driver.isRunning)
        driver.start()
        driver.detach()
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(scroll.gestureRecognizers?.count, initialGestures)
        driver.start()
        XCTAssertFalse(driver.isRunning, "a detached reader must not resume")
    }

    private func offset(afterFrames frames: Int, framesPerSecond: Double, speed: QuranAutoScrollSpeed) -> Double {
        (0..<frames).reduce(0) { current, _ in
            QuranScrollMotion.nextOffset(current: current, minimum: 0, maximum: 1000,
                                         elapsed: 1 / framesPerSecond, speed: speed)
        }
    }
}

private final class ScrollDelegate: NSObject, UIScrollViewDelegate {}
