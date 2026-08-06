import CoreGraphics

/// The three hotkey-driven tiling actions the user can trigger.
enum TilingAction {
    case leftHalf
    case rightHalf
    case maximize
}

/// Everything the layout engine needs to compute a target frame, gathered
/// from the screen the window currently lives on. All geometry is in
/// bottom-left-origin coordinates relative to `visibleFrame`, matching
/// `NSScreen.visibleFrame` semantics.
struct TilingContext {
    /// The screen's visible frame (excludes menu bar and Dock).
    let visibleFrame: CGRect
    /// Visible normal windows on that screen, including the window being tiled.
    let windowCount: Int
    let stageManagerEnabled: Bool
}

/// What the caller should do to a window in response to a tiling action.
/// The engine is stateless: it decides, but the caller owns saved-frame
/// bookkeeping.
enum TilingResolution: Equatable {
    /// Move the window to `to`. When `savePrevious` is true, the caller
    /// should remember the window's current frame before moving it.
    case move(to: CGRect, savePrevious: Bool)
    /// Restore the window to a previously saved frame.
    case restore(to: CGRect)
}

/// Pure window-tiling layout math: computes target frames for half-screen
/// and maximize actions, and decides whether a maximize should move the
/// window or toggle it back to its pre-maximize frame.
struct TilingLayoutEngine {
    /// Fraction of `visibleFrame.width` reserved on the left for the Stage
    /// Manager strip when maximizing with Stage Manager active.
    private static let stageManagerXInset: CGFloat = 0.07
    /// Fraction of `visibleFrame.width` the maximized window occupies when
    /// Stage Manager is active (reaches the right edge).
    private static let stageManagerWidthFraction: CGFloat = 0.93
    /// Fraction of `visibleFrame.height` reserved as breathing room at the
    /// bottom when maximizing with Stage Manager active.
    private static let stageManagerYInset: CGFloat = 0.01
    /// Fraction of `visibleFrame.height` the maximized window occupies when
    /// Stage Manager is active (1% breathing room top and bottom).
    private static let stageManagerHeightFraction: CGFloat = 0.98

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
            if context.stageManagerEnabled && context.windowCount >= 2 {
                return CGRect(
                    x: context.visibleFrame.minX + Self.stageManagerXInset * context.visibleFrame.width,
                    y: context.visibleFrame.minY + Self.stageManagerYInset * context.visibleFrame.height,
                    width: Self.stageManagerWidthFraction * context.visibleFrame.width,
                    height: Self.stageManagerHeightFraction * context.visibleFrame.height
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
