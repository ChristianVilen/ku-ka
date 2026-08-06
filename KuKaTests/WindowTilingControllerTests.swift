import XCTest
import ApplicationServices
@testable import KuKa

@MainActor
final class WindowTilingControllerTests: XCTestCase {

    // A stable AXUIElement identity so the controller's saved-frame map sees
    // the "same window" across calls in a test, the same way it would for a
    // single real window being tiled repeatedly.
    private let handleElement = AXUIElementCreateApplication(424_242)

    override func setUpWithError() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "No screen available in this environment")
    }

    private var mainScreen: NSScreen {
        NSScreen.main ?? NSScreen.screens[0]
    }

    private func focusedWindow(frame: CGRect) -> FocusedWindow {
        FocusedWindow(element: handleElement, frame: frame)
    }

    private func makeController(_ windowControl: MockWindowControlling) -> WindowTilingController {
        WindowTilingController(
            windowControl: windowControl,
            stageManager: MockStageManagerDetecting(),
            windowList: MockWindowListProvider(),
            engine: TilingLayoutEngine()
        )
    }

    // MARK: - Save on success, restore on second press

    func testMaximizeThenSecondPressRestoresRecordedPreviousFrame() {
        let mock = MockWindowControlling()
        let controller = makeController(mock)
        let screen = mainScreen
        let idealTarget = screen.visibleFrame
        let originalFrame = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 300, height: 300)
        // Simulates an app that snaps the requested maximize frame to
        // something else (a character-cell grid, say) rather than landing
        // exactly on the ideal target.
        let achievedFrame = CGRect(x: screen.frame.minX + 5, y: screen.frame.minY + 5, width: 400, height: 400)

        mock.focusedWindowToReturn = focusedWindow(frame: originalFrame)
        mock.achievedFrameToReturn = achievedFrame
        controller.tile(.maximize)

        XCTAssertEqual(mock.setFrameCalls.count, 1)
        XCTAssertEqual(mock.setFrameCalls[0].frame, idealTarget)

        // Second press: the window is sitting at the achieved frame, not the
        // ideal target — exactly the case the achieved-frame comparison
        // exists for. It should read as "already maximized" and restore to
        // the ORIGINAL frame, proving both previousFrame and achievedFrame
        // were recorded correctly on the first press.
        mock.focusedWindowToReturn = focusedWindow(frame: achievedFrame)
        controller.tile(.maximize)

        XCTAssertEqual(mock.setFrameCalls.count, 2)
        XCTAssertEqual(mock.setFrameCalls[1].frame, originalFrame)
    }

    // MARK: - Failed move saves nothing

    func testFailedSetFrameDuringMaximizeSavesNothing() {
        let mock = MockWindowControlling()
        let controller = makeController(mock)
        let screen = mainScreen
        let idealTarget = screen.visibleFrame
        let originalFrame = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 300, height: 300)

        // setFrame fails (returns nil, as AccessibilityWindowControl does
        // when the AX call or the re-read fails) — the window never moved.
        mock.focusedWindowToReturn = focusedWindow(frame: originalFrame)
        mock.achievedFrameToReturn = nil
        controller.tile(.maximize)

        XCTAssertEqual(mock.setFrameCalls.count, 1)

        // A second press, with the window still unmoved, should be treated
        // as a fresh maximize rather than a restore — nothing should have
        // been saved from the failed attempt.
        mock.focusedWindowToReturn = focusedWindow(frame: originalFrame)
        controller.tile(.maximize)

        XCTAssertEqual(mock.setFrameCalls.count, 2)
        XCTAssertEqual(mock.setFrameCalls[1].frame, idealTarget)
    }

    // MARK: - Restore clears the entry

    func testEntryIsRemovedAfterRestoreSoThirdPressMaximizesAgain() {
        let mock = MockWindowControlling()
        let controller = makeController(mock)
        let screen = mainScreen
        let idealTarget = screen.visibleFrame
        let originalFrame = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 300, height: 300)
        let achievedFrame = CGRect(x: screen.frame.minX + 5, y: screen.frame.minY + 5, width: 400, height: 400)

        mock.focusedWindowToReturn = focusedWindow(frame: originalFrame)
        mock.achievedFrameToReturn = achievedFrame
        controller.tile(.maximize) // move + save

        mock.focusedWindowToReturn = focusedWindow(frame: achievedFrame)
        controller.tile(.maximize) // restore, entry removed

        XCTAssertEqual(mock.setFrameCalls.count, 2)
        XCTAssertEqual(mock.setFrameCalls[1].frame, originalFrame)

        // Third press: the window is still sitting at achievedFrame (nothing
        // else moved it), but the entry was removed by the restore above, so
        // this has to be judged against the ideal target again, not the
        // stale achieved frame, and treated as a fresh maximize.
        mock.focusedWindowToReturn = focusedWindow(frame: achievedFrame)
        controller.tile(.maximize)

        XCTAssertEqual(mock.setFrameCalls.count, 3)
        XCTAssertEqual(mock.setFrameCalls[2].frame, idealTarget)
    }

    // MARK: - Halves never touch the map

    func testHalfTilingNeverTouchesSavedFrameMap() {
        let mock = MockWindowControlling()
        let controller = makeController(mock)
        let screen = mainScreen
        let idealTarget = screen.visibleFrame
        let leftHalfTarget = CGRect(
            x: screen.visibleFrame.minX,
            y: screen.visibleFrame.minY,
            width: screen.visibleFrame.width / 2,
            height: screen.visibleFrame.height
        )

        mock.focusedWindowToReturn = focusedWindow(
            frame: CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 300, height: 300)
        )
        mock.achievedFrameToReturn = leftHalfTarget
        controller.tile(.leftHalf)

        XCTAssertEqual(mock.setFrameCalls.count, 1)
        XCTAssertEqual(mock.setFrameCalls[0].frame, leftHalfTarget)

        // The window is now sitting exactly at what left-half asked for. If
        // leftHalf had written to the saved-frame map the way maximize does,
        // a maximize press now could misread this as "already maximized"
        // and restore instead of moving. It shouldn't have written anything.
        mock.focusedWindowToReturn = focusedWindow(frame: leftHalfTarget)
        controller.tile(.maximize)

        XCTAssertEqual(mock.setFrameCalls.count, 2)
        XCTAssertEqual(mock.setFrameCalls[1].frame, idealTarget)
    }
}
