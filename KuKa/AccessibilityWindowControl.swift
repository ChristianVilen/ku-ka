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

@MainActor
protocol WindowControlling {
    func focusedWindow() -> FocusedWindow?
    /// Moves/resizes `handle` to `frame` (NS space), then re-reads the
    /// window's actual resulting frame and returns it (also NS space) — some
    /// apps snap to a cell grid or otherwise adjust what was asked for, and
    /// callers may want to compare against what actually happened. Returns
    /// nil if the set or the re-read failed.
    @discardableResult
    func setFrame(_ frame: CGRect, of handle: WindowHandle) -> CGRect?
}

/// Accessibility-API glue for reading and moving the frontmost window.
/// All coordinates crossing this boundary are NS space (bottom-left origin);
/// conversion to/from AX's top-left-origin global space happens internally.
@MainActor
struct AccessibilityWindowControl: WindowControlling {
    /// Caps how long a single AX round trip can block the main thread. A
    /// hung target app can otherwise stall an AX call for several seconds
    /// per attribute read/write.
    private static let messagingTimeout: Float = 0.5

    func focusedWindow() -> FocusedWindow? {
        guard let primaryScreenHeight = Self.primaryScreenHeight() else {
            NSLog("Ku-Ka: No screens available; cannot resolve focused window")
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)

        guard let app = Self.axElement(kAXFocusedApplicationAttribute as CFString, from: systemWide, label: "focused application") else {
            return nil
        }
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)

        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(app, &pid)
        guard pidError == .success else {
            NSLog("Ku-Ka: Failed to read focused application's pid (AXError \(pidError.rawValue))")
            return nil
        }
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            // Never tile Ku-Ka's own panels.
            return nil
        }

        guard let window = Self.axElement(kAXFocusedWindowAttribute as CFString, from: app, label: "focused window") else {
            return nil
        }
        guard let position: CGPoint = Self.axValue(kAXPositionAttribute as CFString, from: window, type: .cgPoint, zero: .zero, label: "window position") else {
            return nil
        }
        guard let size: CGSize = Self.axValue(kAXSizeAttribute as CFString, from: window, type: .cgSize, zero: .zero, label: "window size") else {
            return nil
        }

        let axFrame = CGRect(origin: position, size: size)
        let nsFrame = Self.axToNS(axFrame, primaryScreenHeight: primaryScreenHeight)
        return FocusedWindow(element: window, frame: nsFrame)
    }

    @discardableResult
    func setFrame(_ frame: CGRect, of handle: WindowHandle) -> CGRect? {
        guard let primaryScreenHeight = Self.primaryScreenHeight() else {
            NSLog("Ku-Ka: No screens available; cannot set window frame")
            return nil
        }

        let element = handle.element

        var positionSettable: DarwinBoolean = false
        let positionSettableError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        var sizeSettable: DarwinBoolean = false
        let sizeSettableError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        guard positionSettableError == .success, positionSettable.boolValue,
              sizeSettableError == .success, sizeSettable.boolValue else {
            NSLog("Ku-Ka: Window position/size not settable; leaving window untouched")
            return nil
        }

        let axFrame = Self.nsToAX(frame, primaryScreenHeight: primaryScreenHeight)
        var position = axFrame.origin
        var size = axFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            NSLog("Ku-Ka: Failed to create AXValue for target position/size")
            return nil
        }

        // Position, then size, then position again: setting the size can
        // shift a window that's near a screen edge, so re-asserting the
        // position afterward is a common window-manager reliability trick.
        let setPosition1Error = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if setPosition1Error != .success {
            NSLog("Ku-Ka: Failed to set window position (AXError \(setPosition1Error.rawValue))")
        }
        let setSizeError = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        if setSizeError != .success {
            NSLog("Ku-Ka: Failed to set window size (AXError \(setSizeError.rawValue))")
        }
        let setPosition2Error = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if setPosition2Error != .success {
            NSLog("Ku-Ka: Failed to re-set window position (AXError \(setPosition2Error.rawValue))")
        }

        guard let achievedPosition: CGPoint = Self.axValue(kAXPositionAttribute as CFString, from: element, type: .cgPoint, zero: .zero, label: "window position after set") else {
            return nil
        }
        guard let achievedSize: CGSize = Self.axValue(kAXSizeAttribute as CFString, from: element, type: .cgSize, zero: .zero, label: "window size after set") else {
            return nil
        }

        let achievedAXFrame = CGRect(origin: achievedPosition, size: achievedSize)
        return Self.axToNS(achievedAXFrame, primaryScreenHeight: primaryScreenHeight)
    }

    // MARK: - AX read helpers

    /// Reads an attribute expected to hold another `AXUIElement` (e.g. the
    /// focused application, the focused window), logging the attribute name
    /// and `AXError` on failure.
    private static func axElement(_ attribute: CFString, from element: AXUIElement, label: String) -> AXUIElement? {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard error == .success else {
            NSLog("Ku-Ka: Failed to read \(label) (AXError \(error.rawValue))")
            return nil
        }
        guard let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            NSLog("Ku-Ka: \(label) attribute was not an AXUIElement")
            return nil
        }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    /// Reads an attribute expected to hold an `AXValue` (position/size) and
    /// unpacks it as `T` (`CGPoint` or `CGSize`), logging the attribute name
    /// and `AXError`/unpack failure.
    private static func axValue<T>(_ attribute: CFString, from element: AXUIElement, type: AXValueType, zero: T, label: String) -> T? {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard error == .success else {
            NSLog("Ku-Ka: Failed to read \(label) (AXError \(error.rawValue))")
            return nil
        }
        guard let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else {
            NSLog("Ku-Ka: \(label) attribute was not an AXValue")
            return nil
        }
        var result = zero
        guard AXValueGetValue((value as! AXValue), type, &result) else { // swiftlint:disable:this force_cast
            NSLog("Ku-Ka: Failed to unpack \(label)")
            return nil
        }
        return result
    }

    /// The primary screen's height, or nil if no screens are available (so
    /// callers bail out instead of silently flipping coordinates around 0).
    private static func primaryScreenHeight() -> CGFloat? {
        NSScreen.screens.first?.frame.height
    }

    // MARK: - Coordinate conversion
    //
    // Pure math, independent of any actor/thread — marked `nonisolated` so
    // they stay callable from plain synchronous code (WindowListProvider,
    // tests) without hopping onto the main actor.

    /// NS (bottom-left origin) -> AX (top-left origin) global coordinates.
    nonisolated static func nsToAX(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        flipVertical(frame, primaryScreenHeight: primaryScreenHeight)
    }

    /// AX (top-left origin) -> NS (bottom-left origin) global coordinates.
    /// The flip is self-inverse, so this is the same transform as `nsToAX`.
    nonisolated static func axToNS(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        flipVertical(frame, primaryScreenHeight: primaryScreenHeight)
    }

    /// The shared vertical flip behind `nsToAX`/`axToNS`, also used by
    /// `CGWindowListProvider.cgToNS` (CG and AX share the same top-left
    /// global origin).
    nonisolated static func flipVertical(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
