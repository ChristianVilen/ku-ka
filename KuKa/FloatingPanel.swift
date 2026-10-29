import Cocoa

/// Base class for the app's borderless, floating overlay panels (thumbnails,
/// combine button). Centralizes the shared appearance and — importantly — the
/// `isReleasedWhenClosed = false` lifecycle invariant so callers can safely
/// `close()` these panels and let ARC deallocate them.
class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    /// Writes alpha through a zero-duration animation, which also replaces
    /// any fade still in flight. A plain `alphaValue =` would be overwritten
    /// by the running animation on its next tick.
    func setAlphaImmediately(_ value: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = value
        }
    }

    /// Fades the panel from its current alpha to fully opaque.
    func fadeIn(duration: TimeInterval, timingFunction: CAMediaTimingFunction? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timingFunction
            animator().alphaValue = 1
        }
    }
}
