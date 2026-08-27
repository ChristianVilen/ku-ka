import Cocoa
import Carbon.HIToolbox

/// Why hotkeys are currently dead, or `.healthy`. One cause at a time, in
/// causal "fix this first" order: without Accessibility the tap can't exist,
/// and a dead tap makes secure input moot.
enum HotkeyHealth: Equatable {
    case healthy
    /// Accessibility permission is missing, so no event tap can be created.
    case noPermission
    /// The event tap exists but the system has kept it disabled past the
    /// watchdog's ability to heal it.
    case tapDead
    /// Secure keyboard input has been held long enough to count as stuck.
    /// `holderName` is the app holding it, or nil when it can't be resolved.
    case secureInputStuck(holderName: String?)
}

/// The one place that answers "are hotkeys working, and if not why". Owns
/// raw system probes (injected for tests) and polls them on one timer; the
/// secure-input dwell rules live behind the internal `SecureInputMonitor`
/// seam. Consumers read `state` and listen on `onChange`.
@MainActor
final class HotkeyHealthMonitor {
    private(set) var state: HotkeyHealth = .healthy
    /// Fired whenever `state` changes.
    var onChange: (@MainActor () -> Void)?

    /// How long the tap must read dead continuously before it is reported.
    /// The watchdog usually revives a system-disabled tap within one 5s
    /// tick, so a self-healed blip never surfaces.
    static let tapDeadThreshold: TimeInterval = 10

    private let isAccessibilityTrusted: () -> Bool
    private let isTapDelivering: () -> Bool
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let secureInput: SecureInputMonitor
    private var tapDeadSince: Date?
    private var timer: Timer?

    /// The probes default to the real system calls; tests inject stand-ins.
    /// `isTapDelivering` has no default — only `HotkeyManager` can answer it.
    init(
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        isTapDelivering: @escaping () -> Bool,
        isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        holderName: @escaping () -> String? = SecureInputMonitor.systemHolderName,
        now: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 5
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isTapDelivering = isTapDelivering
        self.now = now
        self.pollInterval = pollInterval
        self.secureInput = SecureInputMonitor(
            isSecureInputEnabled: isSecureInputEnabled,
            holderName: holderName,
            now: now
        )
    }

    /// Poll for the app's lifetime. Every cause can appear (and heal) at any
    /// moment, and an accessory app gets no notification for any of them, so
    /// a timer is the only way to notice.
    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Timers scheduled from the main thread fire on the main run loop.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-read every probe and update `state`.
    func refresh() {
        // Always tick the secure-input dwell, even without permission: its
        // signal is valid regardless, so a grab that turned stuck while
        // permission was missing reports the moment permission is granted.
        secureInput.refresh()
        guard isAccessibilityTrusted() else {
            // Without permission the tap can't exist; don't let dwell time
            // accumulated here surface as an instant tapDead after a grant.
            tapDeadSince = nil
            setState(.noPermission)
            return
        }
        if isTapDelivering() {
            tapDeadSince = nil
        } else {
            let start = tapDeadSince ?? now()
            tapDeadSince = start
            if now().timeIntervalSince(start) >= Self.tapDeadThreshold {
                setState(.tapDead)
                return
            }
        }
        if case .blocked(let holder) = secureInput.state {
            setState(.secureInputStuck(holderName: holder))
            return
        }
        setState(.healthy)
    }

    private func setState(_ new: HotkeyHealth) {
        guard new != state else { return }
        state = new
        onChange?()
    }
}
