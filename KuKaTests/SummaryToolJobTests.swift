import XCTest
@testable import KuKa

@MainActor
final class SummaryToolJobTests: MeetingNotesTestCase {
    private var tool = SummaryTool.antigravity
    private var reads = 0

    private func installController(transcriber: Transcribing) {
        sut.shutDown()
        sut = MeetingNotesController(
            recorder: recorder,
            root: { [unowned self] in root },
            processor: makeMeetingProcessor(transcribers: [transcriber], runner: runner),
            wordsToCheck: { _ in 0 },
            summaryTool: { [unowned self] in reads += 1; return tool },
            notifier: notifier,
            openURL: { _ in })
        menu = NSMenu()
        sut.buildMenuSection(into: menu)
        runner.results["claude"] = .reply(defaultNotes)
    }

    func testRunningTranscriptionKeepsItsToolAndNextQueuedJobReadsTheNewTool() async throws {
        let held = HeldTranscriber()
        installController(transcriber: held)
        let first = try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        let second = try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0))
        sut.resumeUnfinished()
        await waitUntil { held.waiting }
        XCTAssertTrue(held.waiting)
        XCTAssertEqual(reads, 1)
        tool = .claude
        held.release()
        await sut.waitUntilIdle()
        XCTAssertEqual(runner.calls.map { $0.executable.lastPathComponent }, ["agy", "claude"])
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(first.stage(), .done)
        XCTAssertEqual(second.stage(), .done)
    }

    func testRetryAndUpdateNotesReadTheLatestChoiceWhenTheyStart() async throws {
        installController(transcriber: transcriber)
        let meeting = try leftoverMeeting(at: clock, failure: "failed", transcript: true)
        tool = .claude
        sut.menuWillOpen()
        let retry = try XCTUnwrap(item(titled: "Retry Failed Meeting"))
        _ = (retry.target as? NSObject)?.perform(retry.action, with: retry)
        await sut.waitUntilIdle()
        XCTAssertEqual(meeting.stage(), .done)
        tool = .antigravity
        sut.updateNotes(meeting)
        await sut.waitUntilIdle()
        XCTAssertEqual(runner.calls.map { $0.executable.lastPathComponent }, ["claude", "agy"])
        XCTAssertEqual(reads, 2)
    }

    func testProcessorUsesExplicitChoiceForProcessingAndUpdating() async throws {
        let meeting = try leftoverMeeting(at: clock, transcript: true)
        runner.results["claude"] = .reply(defaultNotes)
        let processor = makeMeetingProcessor(runner: runner)
        let outcome = await processor.process(meeting, tool: .claude) { _ in }
        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        let update = await processor.updateNotes(meeting, tool: .antigravity)
        XCTAssertEqual(update, .updated(summary: meeting.url(for: .summary)))
        XCTAssertEqual(runner.calls.map { $0.executable.lastPathComponent }, ["claude", "agy"])
    }
}

@MainActor
private final class HeldTranscriber: FakeTranscriber {
    private var continuation: CheckedContinuation<Void, Never>?
    private var held = false
    var waiting: Bool { continuation != nil }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    override func transcribe(_ audio: URL) async throws -> TrackTranscript {
        if !held {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        return TrackTranscript(segments: [TranscriptSegment(start: 1, end: 3, text: "Ship Friday")], duration: 60)
    }
}
