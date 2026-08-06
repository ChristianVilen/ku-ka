import CoreGraphics

/// Counts how many windows "belong" to a given screen, for
/// `TilingContext.windowCount`.
enum TilingWindowCounter {
    /// Owner name of Stage Manager's strip/backdrop process. Its windows
    /// never count toward a screen's window count.
    static let stageManagerOwnerName = "WindowManager"

    /// A window counts for `screenFrame` if the area of its intersection
    /// with the screen is at least half the window's own area. Zero-area
    /// windows never count. `windows` is expected to already be filtered by
    /// the caller to on-screen, layer-0, non-Ku-Ka windows.
    ///
    /// v1 limitation: a window wider (or taller) than twice the screen it's
    /// centered on will never clear the 50% threshold for any screen, so it
    /// counts on none of them. Accepted for now — not a case we expect in
    /// practice.
    static func windowCount(on screenFrame: CGRect, windows: [WindowInfo]) -> Int {
        windows.filter { window in
            guard window.ownerName != stageManagerOwnerName else { return false }
            let windowArea = window.frame.width * window.frame.height
            guard windowArea > 0 else { return false }
            let intersection = window.frame.intersection(screenFrame)
            guard !intersection.isNull else { return false }
            let intersectionArea = intersection.width * intersection.height
            return intersectionArea >= windowArea * 0.5
        }.count
    }
}
