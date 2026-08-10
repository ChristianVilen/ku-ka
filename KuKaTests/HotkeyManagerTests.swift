import XCTest
@testable import KuKa

/// Tests feed synthetic key events straight into `HotkeyManager.handleEvent`
/// — no event tap, no Accessibility permission needed. What's under test is
/// the routing decision: which key combos get swallowed (returning nil tells
/// the tap to drop the event) and which pass through to other apps.
final class HotkeyManagerTests: XCTestCase {
    private var manager: HotkeyManager!

    override func setUp() {
        super.setUp()
        manager = HotkeyManager()
    }

    /// Feeds one synthetic key press through `handleEvent` and reports
    /// whether it was swallowed (handleEvent returned nil). The Unmanaged
    /// return value never leaves this function: it holds the event pointer
    /// without retaining it, so letting an assertion stringify it after the
    /// event deallocates crashes the test host.
    private func isSwallowed(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return withExtendedLifetime(event) {
            manager.handleEvent(event) == nil
        }
    }

    private let tilingKeys: [(code: CGKeyCode, name: String)] = [
        (0x7B, "left arrow"), (0x7C, "right arrow"), (0x24, "return"),
    ]
    private let ctrlOption: CGEventFlags = [.maskControl, .maskAlternate]

    // MARK: - Tiling enabled (default)

    func testTilingKeysAreSwallowedAndFireCallbacksByDefault() {
        for (code, name) in tilingKeys {
            let fired = expectation(description: "callback fired for \(name)")
            switch code {
            case 0x7B: manager.onTileLeft = { fired.fulfill() }
            case 0x7C: manager.onTileRight = { fired.fulfill() }
            default: manager.onTileMaximize = { fired.fulfill() }
            }

            XCTAssertTrue(
                isSwallowed(code, flags: ctrlOption),
                "\(name) should be swallowed while tiling is enabled"
            )
            waitForExpectations(timeout: 1)
        }
    }

    // MARK: - Tiling disabled

    func testTilingKeysPassThroughWithoutFiringCallbacksWhenDisabled() {
        manager.tilingEnabled = false

        for (code, name) in tilingKeys {
            let notFired = expectation(description: "no callback for \(name)")
            notFired.isInverted = true
            switch code {
            case 0x7B: manager.onTileLeft = { notFired.fulfill() }
            case 0x7C: manager.onTileRight = { notFired.fulfill() }
            default: manager.onTileMaximize = { notFired.fulfill() }
            }

            XCTAssertFalse(
                isSwallowed(code, flags: ctrlOption),
                "\(name) should pass through to other apps while tiling is disabled"
            )
            waitForExpectations(timeout: 0.2)
        }
    }

    func testScreenshotHotkeysStillWorkWhenTilingIsDisabled() {
        manager.tilingEnabled = false

        let fired = expectation(description: "screenshot callback fired")
        manager.onHotkey = { fired.fulfill() }

        XCTAssertTrue(
            isSwallowed(0x15, flags: [.maskShift, .maskCommand]),
            "Shift+Cmd+4 should still be swallowed with tiling disabled"
        )
        waitForExpectations(timeout: 1)
    }

    func testReenablingTilingRestoresTheHotkeys() {
        manager.tilingEnabled = false
        manager.tilingEnabled = true

        let fired = expectation(description: "callback fired after re-enable")
        manager.onTileLeft = { fired.fulfill() }

        XCTAssertTrue(isSwallowed(0x7B, flags: ctrlOption))
        waitForExpectations(timeout: 1)
    }
}
