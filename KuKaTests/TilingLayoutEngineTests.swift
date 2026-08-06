import XCTest
@testable import KuKa

final class TilingLayoutEngineTests: XCTestCase {
    private let engine = TilingLayoutEngine()

    // A non-trivial visible frame with origin != (0,0), mimicking a secondary
    // screen positioned to the right of a primary display. Catches bugs that
    // assume minX/minY are zero.
    private let screen = CGRect(x: 1920, y: 25, width: 1600, height: 975)

    // MARK: - Left / right half math

    func testLeftHalfMath() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let frame = engine.targetFrame(for: .leftHalf, in: context)
        XCTAssertEqual(frame, CGRect(x: 1920, y: 25, width: 800, height: 975))
    }

    func testRightHalfMath() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let frame = engine.targetFrame(for: .rightHalf, in: context)
        XCTAssertEqual(frame, CGRect(x: 2720, y: 25, width: 800, height: 975))
    }

    func testLeftHalfIgnoresStageManagerAndWindowCount() {
        let smOff = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let smOn = TilingContext(visibleFrame: screen, windowCount: 3, stageManagerEnabled: true)
        XCTAssertEqual(
            engine.targetFrame(for: .leftHalf, in: smOff),
            engine.targetFrame(for: .leftHalf, in: smOn)
        )
    }

    func testRightHalfIgnoresStageManagerAndWindowCount() {
        let smOff = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let smOn = TilingContext(visibleFrame: screen, windowCount: 3, stageManagerEnabled: true)
        XCTAssertEqual(
            engine.targetFrame(for: .rightHalf, in: smOff),
            engine.targetFrame(for: .rightHalf, in: smOn)
        )
    }

    // MARK: - Maximize math

    func testMaximizeStageLayoutExactMathWhenStageManagerOnWithMultipleWindows() {
        let context = TilingContext(visibleFrame: screen, windowCount: 2, stageManagerEnabled: true)
        let frame = engine.targetFrame(for: .maximize, in: context)

        // Hand-computed from screen = (x:1920, y:25, w:1600, h:975):
        // x = 1920 + 0.07*1600 = 2032
        // width = 0.93*1600 = 1488
        // y = 25 + 0.01*975 = 34.75
        // height = 0.98*975 = 955.5
        XCTAssertEqual(frame.origin.x, 2032, accuracy: 0.0001)
        XCTAssertEqual(frame.origin.y, 34.75, accuracy: 0.0001)
        XCTAssertEqual(frame.width, 1488, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 955.5, accuracy: 0.0001)
    }

    func testMaximizeFillsScreenWhenOnlyOneWindowEvenWithStageManagerOn() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: true)
        XCTAssertEqual(engine.targetFrame(for: .maximize, in: context), screen)
    }

    func testMaximizeFillsScreenWhenStageManagerOffEvenWithManyWindows() {
        let context = TilingContext(visibleFrame: screen, windowCount: 5, stageManagerEnabled: false)
        XCTAssertEqual(engine.targetFrame(for: .maximize, in: context), screen)
    }

    // MARK: - resolve()

    func testResolveHalvesAlwaysMoveWithoutSaving() {
        let context = TilingContext(visibleFrame: screen, windowCount: 2, stageManagerEnabled: false)
        let current = CGRect(x: 0, y: 0, width: 100, height: 100)

        let left = engine.resolve(action: .leftHalf, currentFrame: current, savedFrame: nil, context: context)
        XCTAssertEqual(left, .move(to: engine.targetFrame(for: .leftHalf, in: context), savePrevious: false))

        let right = engine.resolve(
            action: .rightHalf,
            currentFrame: current,
            savedFrame: CGRect(x: 1, y: 1, width: 1, height: 1),
            context: context
        )
        XCTAssertEqual(right, .move(to: engine.targetFrame(for: .rightHalf, in: context), savePrevious: false))
    }

    func testResolveMaximizeFromRandomFrameMovesAndSaves() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let current = CGRect(x: 100, y: 100, width: 300, height: 300)

        let result = engine.resolve(action: .maximize, currentFrame: current, savedFrame: nil, context: context)

        XCTAssertEqual(result, .move(to: screen, savePrevious: true))
    }

    func testResolveMaximizeWithinToleranceAndSavedFrameRestores() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let target = screen
        let current = CGRect(
            x: target.minX + 1,
            y: target.minY - 1,
            width: target.width + 1.5,
            height: target.height - 1.5
        )
        let saved = CGRect(x: 500, y: 500, width: 400, height: 400)

        let result = engine.resolve(action: .maximize, currentFrame: current, savedFrame: saved, context: context)

        XCTAssertEqual(result, .restore(to: saved))
    }

    func testResolveMaximizeWithinToleranceButNoSavedFrameReappliesAndSaves() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let target = screen
        let current = CGRect(x: target.minX + 1, y: target.minY, width: target.width, height: target.height)

        let result = engine.resolve(action: .maximize, currentFrame: current, savedFrame: nil, context: context)

        XCTAssertEqual(result, .move(to: target, savePrevious: true))
    }

    func testResolveMaximizeToleranceEdgeExactlyTwoPointsStillRestores() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let target = screen
        let current = CGRect(x: target.minX + 2.0, y: target.minY, width: target.width, height: target.height)
        let saved = CGRect(x: 10, y: 10, width: 10, height: 10)

        let result = engine.resolve(action: .maximize, currentFrame: current, savedFrame: saved, context: context)

        XCTAssertEqual(result, .restore(to: saved))
    }

    func testResolveMaximizeToleranceEdgeJustOverTwoPointsMovesInstead() {
        let context = TilingContext(visibleFrame: screen, windowCount: 1, stageManagerEnabled: false)
        let target = screen
        let current = CGRect(x: target.minX + 2.1, y: target.minY, width: target.width, height: target.height)
        let saved = CGRect(x: 10, y: 10, width: 10, height: 10)

        let result = engine.resolve(action: .maximize, currentFrame: current, savedFrame: saved, context: context)

        XCTAssertEqual(result, .move(to: target, savePrevious: true))
    }
}
