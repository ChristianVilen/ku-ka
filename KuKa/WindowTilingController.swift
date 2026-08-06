import Cocoa

/// Ties the tiling feature together: reads the focused window, picks its
/// screen, asks `TilingLayoutEngine` what to do, and carries that out through
/// `WindowControlling`. Owns the one piece of state the engine itself is
/// deliberately kept free of — the map of pre-maximize frames, so a second
/// maximize press can restore a window instead of moving it again.
///
/// Thin by design: every decision belongs to the engine, this class just
/// wires the adapters to it.
@MainActor
final class WindowTilingController {
    private let windowControl: WindowControlling
    private let stageManager: StageManagerDetecting
    private let windowList: WindowListProvider
    private let engine: TilingLayoutEngine

    private var savedFrames: [WindowHandle: CGRect] = [:]

    init(
        windowControl: WindowControlling = AccessibilityWindowControl(),
        stageManager: StageManagerDetecting = StageManagerDetector(),
        windowList: WindowListProvider = CGWindowListProvider(),
        engine: TilingLayoutEngine = TilingLayoutEngine()
    ) {
        self.windowControl = windowControl
        self.stageManager = stageManager
        self.windowList = windowList
        self.engine = engine
    }

    func tile(_ action: TilingAction) {
        guard let focused = windowControl.focusedWindow() else { return }
        guard let screen = targetScreen(for: focused.frame) else { return }

        let context = TilingContext(
            visibleFrame: screen.visibleFrame,
            windowCount: TilingWindowCounter.windowCount(on: screen.frame, windows: windowList.windowsOnScreen()),
            stageManagerEnabled: stageManager.isStageManagerEnabled
        )

        let handle = focused.handle
        let resolution = engine.resolve(
            action: action,
            currentFrame: focused.frame,
            savedFrame: savedFrames[handle],
            context: context
        )

        switch resolution {
        case .move(let target, let savePrevious):
            if savePrevious {
                savedFrames[handle] = focused.frame
            }
            windowControl.setFrame(target, of: handle)
        case .restore(let saved):
            windowControl.setFrame(saved, of: handle)
            savedFrames.removeValue(forKey: handle)
        }
    }

    /// The screen with the largest overlap with `windowFrame`, falling back
    /// to the main screen and then the first screen when the window doesn't
    /// intersect any screen at all (e.g. it's slightly off-screen).
    private func targetScreen(for windowFrame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let bestMatch = screens.max { lhs, rhs in
            let lhsArea = lhs.frame.intersection(windowFrame).area
            let rhsArea = rhs.frame.intersection(windowFrame).area
            return lhsArea < rhsArea
        }
        if let bestMatch, bestMatch.frame.intersects(windowFrame) {
            return bestMatch
        }
        return NSScreen.main ?? screens.first
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
