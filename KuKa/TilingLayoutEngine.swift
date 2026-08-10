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
    /// Restore the window to a previously saved frame. What the caller does
    /// with the saved entry afterward — evict it or keep it around — is the
    /// caller's call; the engine itself doesn't track eviction.
    case restore(to: CGRect)
}

/// Pure window-tiling layout math: computes target frames for half-screen
/// and maximize actions, and decides whether a maximize should move the
/// window or toggle it back to its pre-maximize frame.
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
                let edgeInset = Self.stageManagerEdgeInsetFraction * context.visibleFrame.height
                return CGRect(
                    x: context.visibleFrame.minX + leftInset,
                    y: context.visibleFrame.minY + edgeInset,
                    width: context.visibleFrame.width - leftInset - edgeInset,
                    height: context.visibleFrame.height - 2 * edgeInset
                )
            }
            return context.visibleFrame
        }
    }

    /// Decides what a tiling action should do to a window.
    ///
    /// For `.maximize`, `achievedTargetFrame` — the frame the window actually
    /// landed on after a previous maximize, if any — takes priority over the
    /// freshly computed target when deciding whether the window "is" already
    /// maximized. Some apps (e.g. Terminal, which snaps windows to a
    /// character-cell grid) never land exactly on the ideal target, so
    /// comparing against the ideal target on every press would never
    /// recognize a second press as "already maximized" and would silently
    /// clobber the saved pre-maximize frame every time. Pass `nil` (the
    /// default) when there's no prior achieved frame to compare against —
    /// the freshly computed target is used instead, same as before this
    /// parameter existed.
    func resolve(
        action: TilingAction,
        currentFrame: CGRect,
        savedFrame: CGRect?,
        achievedTargetFrame: CGRect? = nil,
        context: TilingContext
    ) -> TilingResolution {
        let target = targetFrame(for: action, in: context)

        switch action {
        case .leftHalf, .rightHalf:
            return .move(to: target, savePrevious: false)
        case .maximize:
            let comparisonTarget = achievedTargetFrame ?? target
            if let savedFrame, Self.isWithinTolerance(currentFrame, comparisonTarget) {
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
