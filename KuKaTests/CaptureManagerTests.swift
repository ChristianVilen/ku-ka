import XCTest
@testable import KuKa

final class SpyScreenCapture: ScreenCapturing {
    var onCapture: ((CGRect) -> Void)?

    func captureScreen(rect: CGRect) async -> CGImage? {
        onCapture?(rect)
        return MockScreenCapture.make1x1Image()
    }

    func captureWindow(windowID: CGWindowID) async -> CGImage? { nil }
}

final class CaptureManagerTests: XCTestCase {
    var mockScreenCapture: MockScreenCapture!
    var fakeStore: FakeImageStore!
    var sut: CaptureManager!

    override func setUp() {
        super.setUp()
        mockScreenCapture = MockScreenCapture()
        fakeStore = FakeImageStore()
        sut = CaptureManager(screenCapture: mockScreenCapture, store: fakeStore)
    }

    // MARK: - captureFullScreen()

    func testCaptureFullScreenReturnsResultOnSuccess() async {
        mockScreenCapture.imageToReturn = MockScreenCapture.make1x1Image()
        let result = await sut.captureFullScreen(screen: NSScreen.main!)
        XCTAssertNotNil(result)
    }

    func testCaptureFullScreenReturnsNilOnFailure() async {
        mockScreenCapture.imageToReturn = nil
        let result = await sut.captureFullScreen(screen: NSScreen.main!)
        XCTAssertNil(result)
    }

    func testCaptureFullScreenStoresCapturedImage() async {
        mockScreenCapture.imageToReturn = MockScreenCapture.make1x1Image()
        _ = await sut.captureFullScreen(screen: NSScreen.main!)
        XCTAssertEqual(fakeStore.storedImages.count, 1)
    }

    // MARK: - captureWindow()

    func testCaptureWindowReturnsResultOnSuccess() async {
        mockScreenCapture.imageToReturn = MockScreenCapture.make1x1Image()
        let result = await sut.captureWindow(windowID: 42)
        XCTAssertNotNil(result)
    }

    func testCaptureWindowReturnsNilOnFailure() async {
        mockScreenCapture.imageToReturn = nil
        let result = await sut.captureWindow(windowID: 42)
        XCTAssertNil(result)
    }

    func testCaptureWindowStoresCapturedImage() async {
        mockScreenCapture.imageToReturn = MockScreenCapture.make1x1Image()
        _ = await sut.captureWindow(windowID: 42)
        XCTAssertEqual(fakeStore.storedImages.count, 1)
    }

    // MARK: - capture()

    func testCaptureReturnsNilWhenScreenCaptureReturnsNil() async {
        mockScreenCapture.imageToReturn = nil
        let screen = NSScreen.main!
        let result = await sut.capture(rect: CGRect(x: 0, y: 0, width: 100, height: 100), screen: screen)
        XCTAssertNil(result)
    }

    func testCaptureReturnsResultOnSuccess() async {
        mockScreenCapture.imageToReturn = MockScreenCapture.make1x1Image()
        let screen = NSScreen.main!
        let result = await sut.capture(rect: CGRect(x: 10, y: 20, width: 100, height: 50), screen: screen)
        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.image)
        XCTAssertNotNil(result?.fileURL)
    }

    func testCaptureDoesNotStoreOnFailure() async {
        mockScreenCapture.imageToReturn = nil
        let screen = NSScreen.main!
        _ = await sut.capture(rect: CGRect(x: 0, y: 0, width: 10, height: 10), screen: screen)
        XCTAssertTrue(fakeStore.storedImages.isEmpty)
    }

    // MARK: - Screens seam

    func testCaptureFullScreenFlipsAgainstInjectedPrimaryHeight() async {
        // The flip must use the injected layout's primary height, not the
        // real display's. Synthetic primary: 2000pt tall.
        var capturedRect: CGRect?
        let spy = SpyScreenCapture()
        spy.onCapture = { capturedRect = $0 }
        let fakeScreens = FakeScreens(
            all: [ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1000, height: 2000),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1975))],
            mainIndex: 0
        )
        let manager = CaptureManager(screenCapture: spy, store: fakeStore, screens: fakeScreens)

        let screen = NSScreen.main!
        _ = await manager.captureFullScreen(screen: screen)

        XCTAssertNotNil(capturedRect)
        let expectedY = 2000 - screen.frame.origin.y - screen.frame.height
        XCTAssertEqual(capturedRect!.origin.y, expectedY, accuracy: 0.01)
    }

    func testCaptureFullScreenWithNoScreensReturnsNilInsteadOfCrashing() async {
        let spy = SpyScreenCapture()
        spy.onCapture = { _ in XCTFail("must not capture without a screen layout") }
        let manager = CaptureManager(screenCapture: spy, store: fakeStore, screens: FakeScreens())

        let result = await manager.captureFullScreen(screen: NSScreen.main!)

        XCTAssertNil(result)
        XCTAssertTrue(fakeStore.storedImages.isEmpty)
    }

    // MARK: - Coordinate Conversion

    func testCoordinateConversion() async {
        // The capture method converts from NSView (bottom-left origin) to CG (top-left origin)
        // For a screen of height 1000, a rect at y=200 with height=100 should become y=700 in CG coords
        // y_cg = screenHeight - rect.y - rect.height = 1000 - 200 - 100 = 700
        let screenFrame = NSScreen.main!.frame
        let rect = CGRect(x: 50, y: 200, width: 100, height: 100)
        let expectedY = screenFrame.height - rect.origin.y - rect.height

        // We can verify by checking what rect the screen capture receives
        var capturedRect: CGRect?
        let spy = SpyScreenCapture()
        spy.onCapture = { capturedRect = $0 }
        let manager = CaptureManager(screenCapture: spy, store: fakeStore)

        let screen = NSScreen.main!
        _ = await manager.capture(rect: rect, screen: screen)

        XCTAssertNotNil(capturedRect)
        XCTAssertEqual(capturedRect!.origin.x, screenFrame.origin.x + 50, accuracy: 0.01)
        XCTAssertEqual(capturedRect!.origin.y, expectedY, accuracy: 0.01)
        XCTAssertEqual(capturedRect!.width, 100, accuracy: 0.01)
        XCTAssertEqual(capturedRect!.height, 100, accuracy: 0.01)
    }
}
