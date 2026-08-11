import XCTest
@testable import KuKa

/// ScreenCoordinates owns the app's NS/CG coordinate conversions — the math
/// shared by CG (window list), AX (window control), and screen capture is
/// pinned here.
final class ScreenCoordinatesTests: XCTestCase {

    // MARK: - flipVertical

    func testFlipVerticalHandComputed() {
        // Top-left origin -> bottom-left origin.
        // For primary screen height 1440, a rect at (100, 200, 800, 600)
        // should become (100, 1440-200-600, 800, 600) = (100, 640, 800, 600)
        let rect = CGRect(x: 100, y: 200, width: 800, height: 600)
        let flipped = ScreenCoordinates.flipVertical(rect, primaryScreenHeight: 1440)
        XCTAssertEqual(flipped, CGRect(x: 100, y: 640, width: 800, height: 600))
    }

    func testFlipVerticalAtTopEdge() {
        // Window at the very top of the screen in top-left coords (y=0)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let flipped = ScreenCoordinates.flipVertical(rect, primaryScreenHeight: 900)
        XCTAssertEqual(flipped, CGRect(x: 0, y: 600, width: 400, height: 300))
    }

    func testFlipVerticalAtBottomEdge() {
        // Window at the very bottom of the screen in top-left coords
        let rect = CGRect(x: 0, y: 600, width: 400, height: 300)
        let flipped = ScreenCoordinates.flipVertical(rect, primaryScreenHeight: 900)
        XCTAssertEqual(flipped, CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testFlipVerticalIsItsOwnInverse() {
        let rect = CGRect(x: 123, y: 456, width: 789, height: 321)
        let there = ScreenCoordinates.flipVertical(rect, primaryScreenHeight: 1600)
        let back = ScreenCoordinates.flipVertical(there, primaryScreenHeight: 1600)
        XCTAssertEqual(back, rect)
    }

    // MARK: - cgRect(forSelection:)

    func testSelectionRectHandComputed() {
        // Selection at (10, 20, 300, 200) on a 1000pt-high screen at the
        // origin: x = 0 + 10, y = 1000 - 20 - 200 = 780.
        let cg = ScreenCoordinates.cgRect(
            forSelection: CGRect(x: 10, y: 20, width: 300, height: 200),
            inScreenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        XCTAssertEqual(cg, CGRect(x: 10, y: 780, width: 300, height: 200))
    }

    func testSelectionRectOffsetsByScreenOriginX() {
        // On a screen at x=1920 the selection's x is offset by the screen's
        // origin; y still flips against the screen's own height (the
        // long-standing formula this function preserves).
        let cg = ScreenCoordinates.cgRect(
            forSelection: CGRect(x: 100, y: 0, width: 200, height: 100),
            inScreenFrame: CGRect(x: 1920, y: 0, width: 1600, height: 900)
        )
        XCTAssertEqual(cg, CGRect(x: 2020, y: 800, width: 200, height: 100))
    }
}
