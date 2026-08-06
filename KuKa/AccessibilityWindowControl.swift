import Cocoa
import ApplicationServices

/// Stable identity for an `AXUIElement`, for use as a dictionary key (e.g. the
/// controller's saved-frame map). AXUIElement is a CFTypeRef without value
/// semantics, so identity/equality go through `CFHash`/`CFEqual` rather than
/// Swift's default `Hashable` synthesis.
struct WindowHandle: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

struct FocusedWindow {
    let element: AXUIElement
    let frame: CGRect // NS screen coordinates (bottom-left origin)

    var handle: WindowHandle { WindowHandle(element: element) }
}

protocol WindowControlling {
    func focusedWindow() -> FocusedWindow?
    func setFrame(_ frame: CGRect, of window: FocusedWindow) // frame in NS space
}

/// Accessibility-API glue for reading and moving the frontmost window.
/// All coordinates crossing this boundary are NS space (bottom-left origin);
/// conversion to/from AX's top-left-origin global space happens internally.
struct AccessibilityWindowControl: WindowControlling {
    func focusedWindow() -> FocusedWindow? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef) == .success,
              let focusedApp = focusedAppRef, CFGetTypeID(focusedApp) == AXUIElementGetTypeID() else { return nil }
        let app = focusedApp as! AXUIElement

        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let windowRef = focusedWindowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement

        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        guard AXValueGetValue((positionValue as! AXValue), .cgPoint, &position) else { return nil }

        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue((sizeValue as! AXValue), .cgSize, &size) else { return nil }

        let axFrame = CGRect(origin: position, size: size)
        let nsFrame = Self.axToNS(axFrame, primaryScreenHeight: Self.primaryScreenHeight())

        return FocusedWindow(element: window, frame: nsFrame)
    }

    func setFrame(_ frame: CGRect, of window: FocusedWindow) {
        let axFrame = Self.nsToAX(frame, primaryScreenHeight: Self.primaryScreenHeight())

        var position = axFrame.origin
        var size = axFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }

        // Position, then size, then position again: setting the size can
        // shift a window that's near a screen edge, so re-asserting the
        // position afterward is a common window-manager reliability trick.
        AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
    }

    private static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// NS (bottom-left origin) -> AX (top-left origin) global coordinates.
    static func nsToAX(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// AX (top-left origin) -> NS (bottom-left origin) global coordinates.
    /// The flip is self-inverse, so this applies the same formula as
    /// `nsToAX`.
    static func axToNS(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
