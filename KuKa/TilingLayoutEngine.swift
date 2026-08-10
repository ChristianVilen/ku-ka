import CoreGraphics

/// The hotkey-driven tiling actions the user can trigger.
enum TilingAction {
    case leftHalf
    case rightHalf
    case maximize
    case center

    /// The horizontal direction a half action pushes toward — the direction
    /// a second press hops screens in. Nil for actions with no direction.
    var horizontalDirection: HorizontalDirection? {
        switch self {
        case .leftHalf: return .left
        case .rightHalf: return .right
        case .maximize, .center: return nil
        }
    }
}

/// Left or right, as pressed on the arrow keys: which half of a screen a
/// window goes to, and which neighboring screen a second press hops to.
enum HorizontalDirection {
    case left
    case right
}

/// Everything the layout engine needs to compute a target frame, gathered
/// from the screen the window currently lives on. All rectangles this engine
/// takes and returns are in the same coordinate space as
/// `NSScreen.visibleFrame` (global screen coordinates, bottom-left origin).
/// Converting to/from Accessibility (top-left origin) coordinates is the
/// caller's job.
struct TilingContext {
    /// The screen's visible frame (excludes menu bar and Dock).
    let visibleFrame: CGRect
    /// Visible normal windows on that screen, including the window being tiled.
    let windowCount: Int
    let stageManagerEnabled: Bool
    /// Visible frame of the screen a second half-press should hop to: the
    /// next screen in the action's direction, wrapping around at the edges.
    /// Nil when there is no other screen, or the action has no direction
    /// (maximize, center).
    let adjacentVisibleFrame: CGRect?

    /// Whether the Stage Manager strip is actually reserving screen space.
    /// With only a single window, Stage Manager hides its strip, so a
    /// maximized window can use the full visible frame even when Stage
    /// Manager is turned on.
    var stageStripTakesSpace: Bool {
        stageManagerEnabled && windowCount >= 2
    }
}

/// What the caller should do to a window in response to a tiling action.
/// The engine is stateless: it decides, but the caller owns saved-frame
/// bookkeeping.
enum TilingResolution: Equatable {
    /// Move the window to `to`. When `savePrevious` is true, the caller
    /// should remember the window's current frame before moving it.
    case move(to: CGRect, savePrevious: Bool)
    /// Restore the window to a previously saved frame. What the caller does
    /// with the saved entry afterward — evict it or keep it around — is the
    /// caller's call; the engine itself doesn't track eviction.
    case restore(to: CGRect)
}

/// Per-window state kept between a maximize press and whatever press
/// restores it: the frame the window had right before maximizing
/// (`previousFrame`), and the frame it actually landed on (`achievedFrame`).
/// The two can differ — some apps (Terminal, snapping to a character-cell
/// grid, is the standing example) don't honor the exact frame Ku-Ka asks
/// for, so recognizing "the user pressed maximize again on an
/// already-maximized window" has to be judged against what's really on
/// screen, not the frame Ku-Ka originally requested.
struct TilingRestoreState {
    let previousFrame: CGRect
    let achievedFrame: CGRect
}

/// Pure window-tiling layout math: computes target frames for half-screen,
/// maximize, and center actions, and makes the per-action decisions —
/// whether a maximize should move the window or toggle it back to its
/// pre-maximize frame, whether a second half-press should hop to the
/// adjacent screen, and whether a center press should do nothing.
struct TilingLayoutEngine {
    /// Fraction of `visibleFrame.width` reserved on the left for the Stage
    /// Manager strip when maximizing with Stage Manager active.
    private static let stageManagerLeftInsetFraction: CGFloat = 0.07
    /// Fraction of `visibleFrame.height` reserved as breathing room at the
    /// top, bottom, and right (each) when maximizing with Stage Manager
    /// active. Height-based for all three edges so the gaps come out equal
    /// in points.
    private static let stageManagerEdgeInsetFraction: CGFloat = 0.02

    /// Tolerance, in points, used to decide whether a window's current frame
    /// "is" some target frame — the maximize target for the maximize toggle,
    /// a half target for the screen hop, the maximize size for center's
    /// no-op check. The Accessibility API doesn't position windows with
    /// exact precision, so an exact equality check would never match.
    private static let frameMatchTolerance: CGFloat = 2.0

    /// The frame the given half of the screen's visible frame occupies.
    func halfFrame(_ direction: HorizontalDirection, in context: TilingContext) -> CGRect {
        Self.halfFrame(direction, of: context.visibleFrame)
    }

    /// The frame a maximized window should occupy: the full visible frame,
    /// or the Stage Manager-inset version of it when the strip takes space.
    func maximizeFrame(in context: TilingContext) -> CGRect {
        guard context.stageStripTakesSpace else { return context.visibleFrame }
        let leftInset = Self.stageManagerLeftInsetFraction * context.visibleFrame.width
        let edgeInset = Self.stageManagerEdgeInsetFraction * context.visibleFrame.height
        return CGRect(
            x: context.visibleFrame.minX + leftInset,
            y: context.visibleFrame.minY + edgeInset,
            width: context.visibleFrame.width - leftInset - edgeInset,
            height: context.visibleFrame.height - 2 * edgeInset
        )
    }

    /// Decides what a tiling action should do to a window. Returns nil when
    /// the action should do nothing at all (center on an already
    /// maximize-sized window).
    ///
    /// For `.leftHalf`/`.rightHalf`, a window already sitting at the half
    /// target (within tolerance) hops to the same half of
    /// `context.adjacentVisibleFrame` instead, when one is available — the
    /// "press twice to send to the other monitor" rule. This is judged
    /// against the ideal target, not an achieved frame: halves don't record
    /// restore state, so an app that snaps its size by more than the
    /// tolerance (Terminal) just gets the same half re-applied and never
    /// hops. Accepted — maximize needed achieved-frame bookkeeping for
    /// restore correctness; a missed hop only costs an extra keypress.
    ///
    /// For `.maximize`, the current frame is judged against
    /// `restoreState.achievedFrame` — the frame the window actually landed
    /// on after the previous maximize — not against the freshly computed
    /// target. See `TilingRestoreState` for why the two can differ. Pass
    /// `nil` when no maximize has been recorded for the window; a maximize
    /// then always moves.
    ///
    /// For `.center`, the window keeps its size and moves to the middle of
    /// the visible frame — unless its size already matches the maximize
    /// target's size (within tolerance), in which case nothing happens.
    /// Size alone decides; position is ignored.
    func resolve(
        action: TilingAction,
        currentFrame: CGRect,
        restoreState: TilingRestoreState?,
        context: TilingContext
    ) -> TilingResolution? {
        switch action {
        case .leftHalf:
            return resolveHalf(.left, currentFrame: currentFrame, context: context)
        case .rightHalf:
            return resolveHalf(.right, currentFrame: currentFrame, context: context)
        case .maximize:
            if let restoreState, Self.isWithinTolerance(currentFrame, restoreState.achievedFrame) {
                return .restore(to: restoreState.previousFrame)
            }
            return .move(to: maximizeFrame(in: context), savePrevious: true)
        case .center:
            if Self.isWithinTolerance(currentFrame.size, maximizeFrame(in: context).size) {
                return nil
            }
            let centered = CGRect(
                x: context.visibleFrame.midX - currentFrame.width / 2,
                y: context.visibleFrame.midY - currentFrame.height / 2,
                width: currentFrame.width,
                height: currentFrame.height
            )
            return .move(to: centered, savePrevious: false)
        }
    }

    private func resolveHalf(_ direction: HorizontalDirection, currentFrame: CGRect, context: TilingContext) -> TilingResolution {
        let target = Self.halfFrame(direction, of: context.visibleFrame)
        if let adjacent = context.adjacentVisibleFrame, Self.isWithinTolerance(currentFrame, target) {
            return .move(to: Self.halfFrame(direction, of: adjacent), savePrevious: false)
        }
        return .move(to: target, savePrevious: false)
    }

    private static func halfFrame(_ direction: HorizontalDirection, of visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: direction == .left ? visibleFrame.minX : visibleFrame.midX,
            y: visibleFrame.minY,
            width: visibleFrame.width / 2,
            height: visibleFrame.height
        )
    }

    private static func isWithinTolerance(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameMatchTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= frameMatchTolerance
            && isWithinTolerance(lhs.size, rhs.size)
    }

    private static func isWithinTolerance(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= frameMatchTolerance
            && abs(lhs.height - rhs.height) <= frameMatchTolerance
    }
}
