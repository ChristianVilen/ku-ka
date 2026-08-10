import Cocoa

/// Ties the tiling feature together: reads the focused window, picks its
/// screen, asks `TilingLayoutEngine` what to do, and carries that out through
/// `WindowControlling`. Owns the one piece of state the engine itself is
/// deliberately kept free of — the map of pre-maximize frames, so a second
/// maximize press can restore a window instead of moving it again.
///
/// Thin by design: every decision belongs to the engine, this class just
/// wires the adapters to it. `savedFrames` entries for windows that have
/// since closed are never cleaned up — accepted for v1, since a stale entry
/// is mostly harmless (its key is a handle that in practice will not come up
/// again as the focused window — pids do get recycled, but the odds of a
/// collision landing on a stale entry are low) and not worth extra
/// bookkeeping to garbage-collect. The one real cost: each entry keeps its
/// `AXUIElement` alive for as long as it sits in the map.
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
        let screens = NSScreen.screens
        guard let screenIndex = targetScreenIndex(for: focused.frame, screens: screens) else { return }
        let screen = screens[screenIndex]

        let context = TilingContext(
            visibleFrame: screen.visibleFrame,
            windowCount: TilingScreenRules.windowCount(on: screen.frame, windows: windowList.windowsOnScreen()),
            stageManagerEnabled: stageManager.isStageManagerEnabled,
            adjacentVisibleFrame: adjacentVisibleFrame(for: action, screenIndex: screenIndex, screens: screens)
        )

        let handle = focused.handle
        guard let resolution = engine.resolve(
            action: action,
            currentFrame: focused.frame,
            restoreState: savedFrames[handle],
            context: context
        ) else { return }

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
            // Symmetric with the move branch above: only drop the saved
            // entry once the restore actually landed. If setFrame fails, the
            // window never moved, so a later press should still be able to
            // restore it rather than starting over as a fresh maximize.
            guard windowControl.setFrame(saved, of: handle) != nil else { return }
            savedFrames.removeValue(forKey: handle)
        }
    }

    /// Index (into `screens`) of the screen `windowFrame` overlaps the most,
    /// with main-screen and first-screen fallbacks. Nil only when there are
    /// no screens.
    private func targetScreenIndex(for windowFrame: CGRect, screens: [NSScreen]) -> Int? {
        if let index = TilingScreenRules.bestScreenIndex(for: windowFrame, screenFrames: screens.map(\.frame)) {
            return index
        }
        if let main = NSScreen.main, let index = screens.firstIndex(of: main) {
            return index
        }
        return screens.isEmpty ? nil : 0
    }

    /// Visible frame of the screen a second half-press should hop to, or nil
    /// for actions without a direction and when there's no other screen.
    private func adjacentVisibleFrame(for action: TilingAction, screenIndex: Int, screens: [NSScreen]) -> CGRect? {
        guard let direction = action.horizontalDirection else { return nil }
        guard let index = TilingScreenRules.adjacentScreenIndex(
            of: screenIndex,
            direction: direction,
            screenFrames: screens.map(\.frame)
        ) else { return nil }
        return screens[index].visibleFrame
    }
}
