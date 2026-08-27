import XCTest
@testable import KuKa

@MainActor
final class SecureInputMonitorTests: XCTestCase {
    func testSustainedGrabBecomesBlockedWithHolderName() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = SecureInputMonitor(
            isSecureInputEnabled: { true },
            holderName: { "Arc" },
            now: { clock }
        )
        var changes = 0
        sut.onChange = { changes += 1 }

        sut.refresh()
        XCTAssertEqual(sut.state, .inactive, "a fresh grab is not yet stuck")

        clock = clock.addingTimeInterval(10)
        sut.refresh()

        XCTAssertEqual(sut.state, .blocked(holderName: "Arc"))
        XCTAssertEqual(changes, 1)
    }

    func testMomentaryGrabNeverReportsBlocked() {
        var secureInputOn = true
        var clock = Date(timeIntervalSince1970: 0)
        let sut = SecureInputMonitor(
            isSecureInputEnabled: { secureInputOn },
            holderName: { "Arc" },
            now: { clock }
        )
        var changes = 0
        sut.onChange = { changes += 1 }

        sut.refresh()
        clock = clock.addingTimeInterval(5)
        secureInputOn = false
        sut.refresh()
        // A new grab starts its own clock: 5 more seconds must not be
        // added onto the released one.
        secureInputOn = true
        sut.refresh()
        clock = clock.addingTimeInterval(5)
        sut.refresh()

        XCTAssertEqual(sut.state, .inactive)
        XCTAssertEqual(changes, 0)
    }

    func testReleaseAfterBlockedClearsAndFiresChange() {
        var secureInputOn = true
        var clock = Date(timeIntervalSince1970: 0)
        let sut = SecureInputMonitor(
            isSecureInputEnabled: { secureInputOn },
            holderName: { "Arc" },
            now: { clock }
        )
        sut.refresh()
        clock = clock.addingTimeInterval(10)
        sut.refresh()
        var changes = 0
        sut.onChange = { changes += 1 }

        secureInputOn = false
        sut.refresh()

        XCTAssertEqual(sut.state, .inactive)
        XCTAssertEqual(changes, 1)
    }

    func testUnresolvableHolderReportsBlockedWithNilName() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = SecureInputMonitor(
            isSecureInputEnabled: { true },
            holderName: { nil },
            now: { clock }
        )

        sut.refresh()
        clock = clock.addingTimeInterval(10)
        sut.refresh()

        XCTAssertEqual(sut.state, .blocked(holderName: nil))
    }

    func testPollingPicksUpAStuckGrabWithoutManualRefresh() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = SecureInputMonitor(
            isSecureInputEnabled: {
                // Each poll moves the fake clock past the stuck threshold,
                // so the second tick must report blocked.
                clock = clock.addingTimeInterval(10)
                return true
            },
            holderName: { "Arc" },
            now: { clock },
            pollInterval: 0.01
        )
        let changed = expectation(description: "onChange fired by the poll timer")
        sut.onChange = { changed.fulfill() }

        sut.startMonitoring()

        wait(for: [changed], timeout: 2)
        sut.stopMonitoring()
        XCTAssertEqual(sut.state, .blocked(holderName: "Arc"))
    }
}
