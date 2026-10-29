import Cocoa

@MainActor
final class OrdinaryWindowActivation {
    static let shared = OrdinaryWindowActivation()
    private var windows: Set<ObjectIdentifier> = []
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void

    init(setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.setPolicy = setPolicy
    }

    func open(_ window: NSWindow) {
        if windows.isEmpty { setPolicy(.regular) }
        windows.insert(ObjectIdentifier(window))
    }

    func close(_ window: NSWindow) {
        guard windows.remove(ObjectIdentifier(window)) != nil else { return }
        if windows.isEmpty { setPolicy(.accessory) }
    }
}
