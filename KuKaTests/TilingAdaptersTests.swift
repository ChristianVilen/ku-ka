import XCTest
@testable import KuKa

final class TilingAdaptersTests: XCTestCase {

    // MARK: - CGWindowListProvider.windowCount(on:windows:)

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    private func window(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, ownerName: String = "SomeApp") -> WindowInfo {
        WindowInfo(windowID: 1, frame: CGRect(x: x, y: y, width: width, height: height), ownerName: ownerName, layer: 0)
    }

    func testWindowFullyOnScreenCounts() {
        let windows = [window(x: 100, y: 100, width: 200, height: 200)]
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: windows), 1)
    }

    func testWindowMostlyOnThisScreenCounts() {
        // 800x1000 window straddling the right edge: 600 of its 800 width
        // (75%) is on this screen.
        let windows = [window(x: 400, y: 0, width: 800, height: 1000)]
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: windows), 1)
    }

    func testWindowMostlyOnNeighboringScreenDoesNotCount() {
        // Mirror of the above: only 25% of the window's width is on this screen.
        let windows = [window(x: 800, y: 0, width: 800, height: 1000)]
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: windows), 0)
    }

    func testWindowAtExactlyFiftyPercentBoundaryCounts() {
        // 200x1000 window: exactly 100 (50%) of its width overlaps this screen.
        let windows = [window(x: 900, y: 0, width: 200, height: 1000)]
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: windows), 1)
    }

    func testWindowManagerOwnedWindowIsExcluded() {
        let windows = [window(x: 100, y: 100, width: 200, height: 200, ownerName: "WindowManager")]
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: windows), 0)
    }

    func testZeroSizeWindowIsExcluded() {
        let windows = [window(x: 100, y: 100, width: 0, height: 0)]
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: windows), 0)
    }

    func testEmptyWindowListReturnsZero() {
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: []), 0)
    }

    func testMultipleWindowsCountsOnlyThoseQualifying() {
        let windows = [
            window(x: 100, y: 100, width: 200, height: 200),   // fully on screen: counts
            window(x: 800, y: 0, width: 800, height: 1000),    // mostly off screen: doesn't count
            window(x: 100, y: 100, width: 200, height: 200, ownerName: "WindowManager") // excluded by owner
        ]
        XCTAssertEqual(CGWindowListProvider.windowCount(on: screen, windows: windows), 1)
    }

    // MARK: - AccessibilityWindowControl coordinate conversion

    func testNSToAXHandComputed() {
        // primaryScreenHeight 1200, NS frame (x:50, y:100, w:400, h:300):
        // y_ax = 1200 - 100 - 300 = 800
        let ns = CGRect(x: 50, y: 100, width: 400, height: 300)
        let ax = AccessibilityWindowControl.nsToAX(ns, primaryScreenHeight: 1200)
        XCTAssertEqual(ax, CGRect(x: 50, y: 800, width: 400, height: 300))
    }

    func testAXToNSHandComputed() {
        // primaryScreenHeight 1000, AX frame (x:20, y:50, w:200, h:150):
        // y_ns = 1000 - 50 - 150 = 800
        let ax = CGRect(x: 20, y: 50, width: 200, height: 150)
        let ns = AccessibilityWindowControl.axToNS(ax, primaryScreenHeight: 1000)
        XCTAssertEqual(ns, CGRect(x: 20, y: 800, width: 200, height: 150))
    }

    func testNSToAXToNSRoundTrips() {
        let ns = CGRect(x: 123, y: 456, width: 789, height: 321)
        let ax = AccessibilityWindowControl.nsToAX(ns, primaryScreenHeight: 1600)
        let roundTripped = AccessibilityWindowControl.axToNS(ax, primaryScreenHeight: 1600)
        XCTAssertEqual(roundTripped, ns)
    }

    func testAXToNSToAXRoundTrips() {
        let ax = CGRect(x: 10, y: 20, width: 640, height: 480)
        let ns = AccessibilityWindowControl.axToNS(ax, primaryScreenHeight: 1440)
        let roundTripped = AccessibilityWindowControl.nsToAX(ns, primaryScreenHeight: 1440)
        XCTAssertEqual(roundTripped, ax)
    }
}
