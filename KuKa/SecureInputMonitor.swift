import Cocoa
import Carbon.HIToolbox

/// Whether the hotkey event tap can currently receive key events.
enum SecureInputState: Equatable {
    case inactive
    /// Secure input has been held long enough to count as stuck. `holderName`
    /// is the app holding it, or nil when it can't be resolved (the holder
    /// may already have quit and leaked the grab).
    case blocked(holderName: String?)
}

/// Watches macOS secure keyboard input, which silently starves every CGEvent
/// tap (all Ku-Ka hotkeys) while any app holds it. Normal holds are short — a
/// focused password field — so only a hold lasting `stuckThreshold` counts as
/// stuck. Nobody but the holder can release the grab; all Ku-Ka can do is
/// tell the user who to blame, which is what `state` feeds.
@MainActor
final class SecureInputMonitor {
    /// How long secure input must be held continuously before it is reported
    /// as stuck. Long enough to type a password, short enough to catch a
    /// leaked grab while the user is still wondering why hotkeys are dead.
    static let stuckThreshold: TimeInterval = 10

    private(set) var state: SecureInputState = .inactive
    /// Fired whenever `state` changes.
    var onChange: (@MainActor () -> Void)?

    private let isSecureInputEnabled: () -> Bool
    private let holderName: () -> String?
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private var activeSince: Date?
    private var timer: Timer?

    /// The probes default to the real system calls; tests inject stand-ins.
    init(
        isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        holderName: @escaping () -> String? = SecureInputMonitor.systemHolderName,
        now: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 5
    ) {
        self.isSecureInputEnabled = isSecureInputEnabled
        self.holderName = holderName
        self.now = now
        self.pollInterval = pollInterval
    }

    /// Poll for the app's lifetime. Secure input can be grabbed (and leaked)
    /// at any moment, and an accessory app gets no notification for it, so a
    /// timer is the only way to notice.
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

    /// Re-read secure input and update `state`.
    func refresh() {
        guard isSecureInputEnabled() else {
            activeSince = nil
            setState(.inactive)
            return
        }
        let start = activeSince ?? now()
        activeSince = start
        // Resolve the holder once, when the grab first counts as stuck: the
        // holder can quit while still holding the grab (the leaked case),
        // and a later lookup would lose its name.
        if now().timeIntervalSince(start) >= Self.stuckThreshold, state == .inactive {
            setState(.blocked(holderName: holderName()))
        }
    }

    private func setState(_ new: SecureInputState) {
        guard new != state else { return }
        state = new
        onChange?()
    }

    /// Name of the app holding secure input, from the session dictionary's
    /// holder pid. Nil when the pid is missing or no longer maps to a running
    /// app (a quit app can leak the grab, and the pid outlives it).
    nonisolated static func systemHolderName() -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
