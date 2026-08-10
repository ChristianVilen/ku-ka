import Cocoa

/// Result of one selection session: what the user picked, and the screen
/// the capture belongs on.
enum SelectionResult: Equatable {
    case rect(CGRect, on: NSScreen)
    case window(CGWindowID, on: NSScreen)
    case cancelled
}

/// Event emitted by the overlay layer while a session is active.
/// `screen` is the screen whose overlay emitted the event.
enum OverlayEvent {
    case rectSelected(CGRect, screen: NSScreen)
    case windowSelected(WindowInfo, screen: NSScreen)
    case cancelled
}

/// Internal seam: how a session puts selection overlays on screen.
/// The production adapter drives real OverlayWindows; tests drive a fake.
@MainActor
protocol OverlayPresenting {
    func present(on screens: [NSScreen], keyScreen: NSScreen?, handler: @escaping (OverlayEvent) -> Void)
    func dismissAll()
}

/// Owns the overlay + selection lifecycle: one overlay per screen, key-window
/// election on the cursor screen, mode toggling inside the views, teardown.
/// `run` resumes only after the overlays are gone.
@MainActor
final class SelectionSession {
    private let presenter: OverlayPresenting
    private var continuation: CheckedContinuation<SelectionResult, Never>?
    private var isActive = false

    init(presenter: OverlayPresenting = OverlayPresenter(windowListProvider: CGWindowListProvider())) {
        self.presenter = presenter
    }

    func run(on screens: [NSScreen], mouseLocation: CGPoint) async -> SelectionResult {
        guard !isActive, !screens.isEmpty else { return .cancelled }
        isActive = true
        defer { isActive = false }

        let keyScreen = screens.first { $0.frame.contains(mouseLocation) }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presenter.present(on: screens, keyScreen: keyScreen) { [weak self] event in
                self?.handle(event, screens: screens)
            }
        }
    }

    private func handle(_ event: OverlayEvent, screens: [NSScreen]) {
        // Overlays can emit more than one event (e.g. Esc from a second
        // screen while the first is resolving); only the first one counts.
        guard let continuation else { return }
        self.continuation = nil
        presenter.dismissAll()
        continuation.resume(returning: result(for: event, screens: screens))
    }

    private func result(for event: OverlayEvent, screens: [NSScreen]) -> SelectionResult {
        switch event {
        case .rectSelected(let rect, let screen):
            return .rect(rect, on: screen)
        case .windowSelected(let info, let overlayScreen):
            let owner = Self.owningScreenIndex(windowFrame: info.frame, screenFrames: screens.map(\.frame))
                .map { screens[$0] }
            return .window(info.windowID, on: owner ?? overlayScreen)
        case .cancelled:
            return .cancelled
        }
    }

    /// Index of the screen owning the largest share of `windowFrame`,
    /// or nil when no screen overlaps it. Frames in NS coordinates.
    static func owningScreenIndex(windowFrame: CGRect, screenFrames: [CGRect]) -> Int? {
        let overlaps = screenFrames.map { frame -> CGFloat in
            let intersection = frame.intersection(windowFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }),
              overlaps[best] > 0 else { return nil }
        return best
    }
}

/// Production adapter at the OverlayPresenting seam: real OverlayWindows,
/// app activation, cursor teardown.
@MainActor
final class OverlayPresenter: OverlayPresenting {
    private let windowListProvider: WindowListProvider
    private var overlayWindows: [OverlayWindow] = []

    init(windowListProvider: WindowListProvider) {
        self.windowListProvider = windowListProvider
    }

    func present(on screens: [NSScreen], keyScreen: NSScreen?, handler: @escaping (OverlayEvent) -> Void) {
        var keyOverlay: OverlayWindow?

        for screen in screens {
            let overlay = OverlayWindow(screen: screen)
            overlay.selectionView.windowListProvider = windowListProvider
            overlay.selectionView.onSelection = { rect in
                handler(.rectSelected(rect, screen: screen))
            }
            overlay.selectionView.onWindowSelection = { info in
                handler(.windowSelected(info, screen: screen))
            }
            overlay.selectionView.onCancel = {
                handler(.cancelled)
            }
            overlayWindows.append(overlay)
            if screen == keyScreen {
                keyOverlay = overlay
            }
        }

        NSApp.activate(ignoringOtherApps: true)

        for overlay in overlayWindows {
            if overlay === keyOverlay {
                overlay.makeKeyAndOrderFront(nil)
                overlay.makeFirstResponder(overlay.selectionView)
            } else {
                overlay.orderFront(nil)
            }
        }
    }

    func dismissAll() {
        NSCursor.pop()
        for overlay in overlayWindows {
            overlay.close()
        }
        overlayWindows.removeAll()
    }
}
