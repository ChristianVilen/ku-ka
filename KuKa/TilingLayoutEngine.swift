import CoreGraphics

/// The three hotkey-driven tiling actions the user can trigger.
enum TilingAction {
    case leftHalf
    case rightHalf
    case maximize
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
    /// Restore the window to a previously saved frame. The caller may keep
    /// the saved frame around afterward — the next maximize simply
    /// overwrites it, so there's no eviction to do in v1.
    case restore(to: CGRect)
}

/// Pure window-tiling layout math: computes target frames for half-screen
/// and maximize actions, and decides whether a maximize should move the
/// window or toggle it back to its pre-maximize frame.
struct TilingLayoutEngine {
    /// Fraction of `visibleFrame.width` reserved on the left for the Stage
    /// Manager strip when maximizing with Stage Manager active. The window
    /// fills the remaining width, reaching the right edge.
    private static let stageManagerLeftInsetFraction: CGFloat = 0.07
    /// Fraction of `visibleFrame.height` reserved as breathing room at the
    /// top and bottom (each) when maximizing with Stage Manager active.
    private static let stageManagerVerticalInsetFraction: CGFloat = 0.01

    /// Tolerance, in points, used to decide whether a window's current frame
    /// "is" the maximize target. The Accessibility API doesn't position
    /// windows with exact precision, so an exact equality check would never
    /// match.
    private static let maximizeTolerance: CGFloat = 2.0

    func targetFrame(for action: TilingAction, in context: TilingContext) -> CGRect {
        switch action {
        case .leftHalf:
            return CGRect(
                x: context.visibleFrame.minX,
                y: context.visibleFrame.minY,
                width: context.visibleFrame.width / 2,
                height: context.visibleFrame.height
            )
        case .rightHalf:
            return CGRect(
                x: context.visibleFrame.midX,
                y: context.visibleFrame.minY,
                width: context.visibleFrame.width / 2,
                height: context.visibleFrame.height
            )
        case .maximize:
            if context.stageStripTakesSpace {
                let leftInset = Self.stageManagerLeftInsetFraction * context.visibleFrame.width
                let verticalInset = Self.stageManagerVerticalInsetFraction * context.visibleFrame.height
                return CGRect(
                    x: context.visibleFrame.minX + leftInset,
                    y: context.visibleFrame.minY + verticalInset,
                    width: context.visibleFrame.width - leftInset,
                    height: context.visibleFrame.height - 2 * verticalInset
                )
            }
            return context.visibleFrame
        }
    }

    func resolve(
        action: TilingAction,
        currentFrame: CGRect,
        savedFrame: CGRect?,
        context: TilingContext
    ) -> TilingResolution {
        let target = targetFrame(for: action, in: context)

        switch action {
        case .leftHalf, .rightHalf:
            return .move(to: target, savePrevious: false)
        case .maximize:
            if let savedFrame, Self.isWithinTolerance(currentFrame, target) {
                return .restore(to: savedFrame)
            }
            return .move(to: target, savePrevious: true)
        }
    }

    private static func isWithinTolerance(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= maximizeTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= maximizeTolerance
            && abs(lhs.width - rhs.width) <= maximizeTolerance
            && abs(lhs.height - rhs.height) <= maximizeTolerance
    }
}
