import XCTest
@testable import KuKa

@MainActor
final class EditorWindowTests: XCTestCase {
    private var store: FakeImageStore!
    private var fileURL: URL!
    private var editor: EditorWindow!

    override func setUp() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "No screen available in this environment")
        store = FakeImageStore()
        fileURL = URL(fileURLWithPath: "/tmp/kuka-test/shot.png")
        editor = EditorWindow(image: NSImage(size: NSSize(width: 20, height: 20)), fileURL: fileURL, store: store)
    }

    override func tearDown() {
        editor?.close()
        editor = nil
        super.tearDown()
    }

    func testDoneSavesAnnotatedImageToItsOwnURL() {
        editor.doneTapped()

        XCTAssertEqual(store.annotatedCalls.count, 1)
        XCTAssertEqual(store.annotatedCalls[0].url, fileURL)
        XCTAssertTrue(store.deletedURLs.isEmpty)
    }

    func testDeleteRemovesItsOwnFile() {
        editor.deleteTapped()

        XCTAssertEqual(store.deletedURLs, [fileURL])
        XCTAssertTrue(store.annotatedCalls.isEmpty)
    }
}
