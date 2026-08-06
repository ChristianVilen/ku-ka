import Cocoa

/// Per-window state kept between a maximize press and whatever press
/// restores it: the frame the window had right before maximizing
/// (`previousFrame`), and the frame it actually landed on (`achievedFrame`).
/// The two can differ — some apps (Terminal, snapping to a character-cell
/// grid, is the standing example) don't honor the exact frame Ku-Ka asks
/// for, so recognizing "the user pressed maximize again on an
/// already-maximized window" has to be judged against what's really on
/// screen, not the frame Ku-Ka originally requested.
private struct TilingRestoreState {
    let previousFrame: CGRect
    let achievedFrame: CGRect
}

/// Ties the tiling feature together: reads the focused window, picks its
/// screen, asks `TilingLayoutEngine` what to do, and carries that out through
/// `WindowControlling`. Owns the one piece of state the engine itself is
/// deliberately kept free of — the map of pre-maximize frames, so a second
/// maximize press can restore a window instead of moving it again.
///
/// Thin by design: every decision belongs to the engine, this class just
/// wires the adapters to it. `savedFrames` entries for windows that have
/// since closed are never cleaned up — accepted for v1, since a stale entry
/// is harmless (its key is a handle that will simply never come up as the
/// focused window again) and not worth extra bookkeeping to garbage-collect.
@MainActor
final class WindowTilingController {
    private let windowControl: WindowControlling
    private let stageManager: StageManagerDetecting
    private let windowList: WindowListProvider
    private let engine: TilingLayoutEngine

    private var savedFrames: [WindowHandle: TilingRestoreState] = [:]

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
        let restoreState = savedFrames[handle]
        let resolution = engine.resolve(
            action: action,
            currentFrame: focused.frame,
            savedFrame: restoreState?.previousFrame,
            achievedTargetFrame: restoreState?.achievedFrame,
            context: context
        )

        switch resolution {
        case .move(let target, let savePrevious):
            let previousFrame = focused.frame
            let achievedFrame = windowControl.setFrame(target, of: handle)
            // Only remember state when the move actually landed somewhere.
            // Recording a "previous" frame for a move that failed would let
            // a later restore snap the window to a frame it never left.
            if savePrevious, let achievedFrame {
                savedFrames[handle] = TilingRestoreState(previousFrame: previousFrame, achievedFrame: achievedFrame)
            }
        case .restore(let saved):
            windowControl.setFrame(saved, of: handle)
            savedFrames.removeValue(forKey: handle)
        }
    }

    /// The screen `windowFrame` overlaps the most, falling back to the main
    /// screen and then the first screen when the window doesn't intersect
    /// any screen at all (e.g. it's slightly off-screen).
    private func targetScreen(for windowFrame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let index = TilingWindowCounter.bestScreenIndex(for: windowFrame, screenFrames: screens.map(\.frame)) {
            return screens[index]
        }
        return NSScreen.main ?? screens.first
    }
}
