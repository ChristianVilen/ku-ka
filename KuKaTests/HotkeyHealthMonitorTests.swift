import XCTest
@testable import KuKa

@MainActor
final class HotkeyHealthMonitorTests: XCTestCase {
    /// Builds a monitor whose probes all report healthy unless overridden.
    private func makeSUT(
        accessibilityTrusted: @escaping () -> Bool = { true },
        tapDelivering: @escaping () -> Bool = { true },
        secureInputEnabled: @escaping () -> Bool = { false },
        holderName: @escaping () -> String? = { nil },
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 0) },
        pollInterval: TimeInterval = 5
    ) -> HotkeyHealthMonitor {
        HotkeyHealthMonitor(
            isAccessibilityTrusted: accessibilityTrusted,
            isTapDelivering: tapDelivering,
            isSecureInputEnabled: secureInputEnabled,
            holderName: holderName,
            now: now,
            pollInterval: pollInterval
        )
    }

    func testHealthyWhenEveryProbeIsFine() {
        let sut = makeSUT()

        sut.refresh()

        XCTAssertEqual(sut.state, .healthy)
    }

    func testMissingAccessibilityReportsNoPermission() {
        let sut = makeSUT(accessibilityTrusted: { false })

        sut.refresh()

        XCTAssertEqual(sut.state, .noPermission)
    }

    func testTapDeadReportsOnlyAfterTheDwellThreshold() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = makeSUT(tapDelivering: { false }, now: { clock })

        sut.refresh()
        XCTAssertEqual(sut.state, .healthy, "a fresh dead read is not yet reported")

        clock = clock.addingTimeInterval(10)
        sut.refresh()

        XCTAssertEqual(sut.state, .tapDead)
    }

    func testTapRevivalResetsTheDwellClock() {
        var clock = Date(timeIntervalSince1970: 0)
        var delivering = false
        let sut = makeSUT(tapDelivering: { delivering }, now: { clock })

        sut.refresh()
        delivering = true
        clock = clock.addingTimeInterval(5)
        sut.refresh()
        // Dead again: a new dwell starts; 5 more seconds must not be added
        // onto the healed one.
        delivering = false
        clock = clock.addingTimeInterval(5)
        sut.refresh()
        clock = clock.addingTimeInterval(5)
        sut.refresh()

        XCTAssertEqual(sut.state, .healthy)
    }

    func testStuckSecureInputReportsWithHolderName() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = makeSUT(
            secureInputEnabled: { true },
            holderName: { "Arc" },
            now: { clock }
        )

        sut.refresh()
        XCTAssertEqual(sut.state, .healthy, "a fresh grab is not yet stuck")

        clock = clock.addingTimeInterval(10)
        sut.refresh()

        XCTAssertEqual(sut.state, .secureInputStuck(holderName: "Arc"))
    }

    func testNoPermissionOutranksEveryOtherCause() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = makeSUT(
            accessibilityTrusted: { false },
            tapDelivering: { false },
            secureInputEnabled: { true },
            holderName: { "Arc" },
            now: { clock }
        )

        sut.refresh()
        clock = clock.addingTimeInterval(10)
        sut.refresh()

        XCTAssertEqual(sut.state, .noPermission)
    }

    func testTapDeadOutranksStuckSecureInput() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = makeSUT(
            tapDelivering: { false },
            secureInputEnabled: { true },
            holderName: { "Arc" },
            now: { clock }
        )

        sut.refresh()
        clock = clock.addingTimeInterval(10)
        sut.refresh()

        XCTAssertEqual(sut.state, .tapDead)
    }

    func testOnChangeFiresOnlyOnTransitions() {
        var clock = Date(timeIntervalSince1970: 0)
        var secureOn = true
        let sut = makeSUT(
            secureInputEnabled: { secureOn },
            holderName: { "Arc" },
            now: { clock }
        )
        var changes = 0
        sut.onChange = { changes += 1 }

        sut.refresh()
        clock = clock.addingTimeInterval(10)
        sut.refresh()
        clock = clock.addingTimeInterval(5)
        sut.refresh()
        secureOn = false
        sut.refresh()

        XCTAssertEqual(changes, 2, "healthy→stuck and stuck→healthy, nothing else")
        XCTAssertEqual(sut.state, .healthy)
    }

    func testPollingPicksUpAStuckGrabWithoutManualRefresh() {
        var clock = Date(timeIntervalSince1970: 0)
        let sut = makeSUT(
            secureInputEnabled: {
                // Each poll moves the fake clock past the stuck threshold,
                // so the second tick must report stuck.
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
        XCTAssertEqual(sut.state, .secureInputStuck(holderName: "Arc"))
    }
}
