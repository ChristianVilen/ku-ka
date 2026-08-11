import Cocoa

/// One screen's geometry, detached from AppKit so tests can fabricate
/// multi-display layouts. Frames are in NS coordinates (bottom-left origin,
/// global).
struct ScreenGeometry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Test seam for the screen layout. Ambient NSScreen reads live only in
/// system adapters — this one, and the AppKit/CG/AX-facing adapters that are
/// themselves the system edge.
protocol Screens {
    /// All screens, primary first (same order as NSScreen.screens).
    var all: [ScreenGeometry] { get }
    /// Index into `all` of the screen with the key window, if any.
    var mainIndex: Int? { get }
}

extension Screens {
    var main: ScreenGeometry? {
        guard let mainIndex, all.indices.contains(mainIndex) else { return nil }
        return all[mainIndex]
    }

    /// The primary screen's height, or nil when no screens are available (so
    /// callers bail out instead of silently flipping coordinates around 0).
    var primaryHeight: CGFloat? { all.first?.frame.height }
}

struct SystemScreens: Screens {
    var all: [ScreenGeometry] {
        NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    var mainIndex: Int? {
        guard let main = NSScreen.main else { return nil }
        return NSScreen.screens.firstIndex(of: main)
    }
}
