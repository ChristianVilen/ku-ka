import Cocoa

// Test seams for CaptureFlow's collaborators; the concrete classes
// already match the signatures, so conformances are empty.

@MainActor
protocol SelectionRunning {
    func run(on screens: [NSScreen], mouseLocation: CGPoint) async -> SelectionResult
}

protocol CaptureProviding {
    func capture(rect: CGRect, screen: NSScreen) async -> CaptureResult?
    func captureWindow(windowID: CGWindowID) async -> CaptureResult?
    func captureFullScreen(screen: NSScreen) async -> CaptureResult?
}

@MainActor
protocol ThumbnailPresenting {
    func add(image: NSImage, result: CaptureResult, screen: NSScreen, duration: TimeInterval)
}

extension SelectionSession: SelectionRunning {}
extension CaptureManager: CaptureProviding {}
extension ThumbnailStackManager: ThumbnailPresenting {}

/// Owns the capture pipeline from hotkey to thumbnail: selection (or screen
/// pick for fullscreen), the overlay-settle delay, capture, flash, and
/// handing the result to the thumbnail stack.
@MainActor
final class CaptureFlow {
    enum Mode { case interactive, fullScreen }

    private let selection: SelectionRunning
    private let capture: CaptureProviding
    private let thumbnails: ThumbnailPresenting
    private let thumbnailDuration: () -> TimeInterval
    private let flash: (NSScreen) -> Void
    private let settleDelay: TimeInterval

    init(selection: SelectionRunning,
         capture: CaptureProviding,
         thumbnails: ThumbnailPresenting,
         thumbnailDuration: @escaping () -> TimeInterval = {
             UserDefaults.standard.object(forKey: "thumbnailDuration") as? Double ?? 5.0
         },
         flash: @escaping (NSScreen) -> Void = { FlashView.flash(on: $0) },
         settleDelay: TimeInterval = 0.05) {
        self.selection = selection
        self.capture = capture
        self.thumbnails = thumbnails
        self.thumbnailDuration = thumbnailDuration
        self.flash = flash
        self.settleDelay = settleDelay
    }

    func start(_ mode: Mode, screens: [NSScreen], mouseLocation: CGPoint) async {
        switch mode {
        case .interactive:
            switch await selection.run(on: screens, mouseLocation: mouseLocation) {
            case .rect(let rect, let screen):
                await settleAndShow(screen: screen) {
                    await self.capture.capture(rect: rect, screen: screen)
                }
            case .window(let windowID, let screen):
                await settleAndShow(screen: screen) {
                    await self.capture.captureWindow(windowID: windowID)
                }
            case .cancelled:
                break
            }

        case .fullScreen:
            guard let screen = screens.first(where: { $0.frame.contains(mouseLocation) }) ?? screens.first else { return }
            guard let result = await capture.captureFullScreen(screen: screen) else { return }
            flash(screen)
            show(result: result, screen: screen)
        }
    }

    private func settleAndShow(screen: NSScreen, _ produce: () async -> CaptureResult?) async {
        // The overlay has just closed; give it a moment to disappear before capturing
        if settleDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }
        guard let result = await produce() else { return }
        show(result: result, screen: screen)
    }

    private func show(result: CaptureResult, screen: NSScreen) {
        thumbnails.add(image: result.image, result: result, screen: screen, duration: thumbnailDuration())
    }
}
