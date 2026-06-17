import Foundation
import IOKit.pwr_mgt

/// Seam over the IOKit power assertion so the orchestration logic can be
/// tested without touching real system sleep state.
protocol SleepPreventing: AnyObject {
    /// Create the assertion if not already held. Idempotent.
    func begin(reason: String)
    /// Release the assertion if held. Idempotent.
    func end()
    var isPreventing: Bool { get }
}

/// Production implementation backed by `IOPMAssertionCreateWithName` with the
/// `PreventUserIdleSystemSleep` assertion type — keeps the system awake while
/// allowing the display to sleep.
final class IOKitSleepPreventer: SleepPreventing {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isPreventing = false

    func begin(reason: String) {
        guard !isPreventing else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isPreventing = true
        } else {
            NSLog("Ku-Ka: failed to create power assertion (code \(result))")
        }
    }

    func end() {
        guard isPreventing else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isPreventing = false
    }
}
