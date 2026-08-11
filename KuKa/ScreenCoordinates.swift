import CoreGraphics

/// The vertical flip shared by every top-left/bottom-left screen coordinate
/// conversion in the app: CG (window server) and AX (Accessibility) both use
/// a top-left global origin; NS (AppKit) uses bottom-left. Kept as a neutral,
/// dependency-free namespace so both `WindowListProvider` and
/// `AccessibilityWindowControl` can call it without depending on each other.
enum ScreenCoordinates {
    static func flipVertical(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// CG capture rect for a selection made on the screen with `screenFrame`
    /// (`rect` is view-local, bottom-left origin). Preserves the app's
    /// long-standing formula, which flips against the screen's own height
    /// rather than the primary's — suspected wrong for selections on a
    /// secondary display (the SCK adapter's display-origin subtraction may be
    /// compensating). Verify on two-display hardware before changing.
    static func cgRect(forSelection rect: CGRect, inScreenFrame screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.origin.x + rect.origin.x,
            y: screenFrame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
