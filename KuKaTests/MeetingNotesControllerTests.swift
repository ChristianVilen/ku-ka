import XCTest
@testable import KuKa

@MainActor
final class MeetingNotesControllerTests: XCTestCase {
    private struct TestError: LocalizedError {
        let errorDescription: String?
    }

    private var root: URL!
    private var screenRecording = true
    private var microphone = MicrophoneAccess.granted
    private var answerMicrophonePrompt: () async -> Bool = { false }
    private var capture: FakeMeetingAudioCapture!
    private var transcriber: Transcribing!
    private var runner: FakeCommandRunner!
    private var clock = localDate(2026, 10, 23, 14, 2)
    private var notifications: [String] = []
    private var opened: [URL] = []
    private var permissionWindows = 0
    private var stateChanges = 0
    private var sut: MeetingNotesController!
    private var menu: NSMenu!

    override func setUp() async throws {
        root = try makeTemporaryDirectory().appendingPathComponent("Meetings", isDirectory: true)
        capture = FakeMeetingAudioCapture()
        let fakeTranscriber = FakeTranscriber()
        fakeTranscriber.byFileName["them.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 1, end: 3, text: "Let's ship on Friday")], duration: 60))
        transcriber = fakeTranscriber
        runner = FakeCommandRunner()
        runner.results["agy"] = .success(CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: ""))
        sut = makeController()
    }

    override func tearDown() async throws {
        sut.shutDown()
        await sut.waitUntilIdle()
    }

    private func makeController() -> MeetingNotesController {
        let permissions = PermissionsManager(
            isAccessibilityTrusted: { true },
            hasScreenCaptureAccess: { [unowned self] in screenRecording },
            microphoneAccess: { [unowned self] in microphone },
            requestMicrophoneAccess: { [unowned self] in await answerMicrophonePrompt() })
        let controller = MeetingNotesController(
            permissions: permissions,
            root: { [unowned self] in root },
            capture: capture,
            processor: MeetingProcessor(
                transcriber: transcriber,
                summarizer: Summarizer(runner: runner, home: URL(fileURLWithPath: "/Users/test"), isExecutable: { _ in true }),
                trash: { try FileManager.default.removeItem(at: $0) },
                now: { localDate(2026, 10, 23, 15, 0) }),
            notify: { [unowned self] title, body in notifications.append("\(title): \(body)") },
            openURL: { [unowned self] in opened.append($0) },
            now: { [unowned self] in clock })
        controller.onShowPermissions = { [unowned self] in permissionWindows += 1 }
        controller.onStateChange = { [unowned self] in stateChanges += 1 }
        menu = NSMenu()
        controller.buildMenuSection(into: menu)
        return controller
    }

    private var visibleTitles: [String] {
        menu.items.filter { !$0.isHidden }.map(\.title)
    }

    private func item(titled title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func meetingNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    @discardableResult
    private func leftoverMeeting(at date: Date, failure: String? = nil, transcript: Bool = false) throws -> MeetingFolder {
        let meeting = try MeetingFolder.create(in: root, startingAt: date)
        FileManager.default.createFile(atPath: meeting.audioURL(.system).path, contents: Data())
        if transcript { try meeting.write("**[00:00:01] Them:** Hello", to: .transcript) }
        if let failure { try meeting.write(failure, to: .failure) }
        return meeting
    }

    func testTheIdleMenuOffersToStartRecording() {
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
        XCTAssertFalse(sut.isRecording)
    }

    func testStartRecordsIntoANewMeetingFolderAndShowsTheElapsedTime() async {
        await sut.toggleRecording()

        XCTAssertTrue(sut.isRecording)
        XCTAssertEqual(stateChanges, 1)
        XCTAssertEqual(meetingNames(), ["2026-10-23_14-02"])
        XCTAssertEqual(capture.recordings.count, 1)

        clock = clock.addingTimeInterval(245)
        sut.refreshMenuSection()

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Stop Recording · 4:05", "Open Meetings Folder", ""])
    }

    func testStopProcessesTheMeetingAndSaysTheNotesAreReady() async throws {
        await sut.toggleRecording()

        await sut.toggleRecording()
        await sut.waitUntilIdle()

        XCTAssertFalse(sut.isRecording)
        XCTAssertEqual(stateChanges, 2)
        XCTAssertEqual(capture.recordings.first?.stopCount, 1)
        XCTAssertEqual(notifications, ["Meeting notes ready: Meeting on 2026-10-23 at 14:02"])
        let meeting = try XCTUnwrap(MeetingFolder.all(in: root).first?.0)
        XCTAssertEqual(meeting.stage(), .done)
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testTheSummaryFooterSaysWhyThePreferredCLIWasSkipped() async throws {
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: "authentication failed"))
        runner.results["claude"] = .success(CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: ""))

        await sut.toggleRecording()
        await sut.toggleRecording()
        await sut.waitUntilIdle()

        let meeting = try XCTUnwrap(MeetingFolder.all(in: root).first?.0)
        XCTAssertTrue(try meeting.read(.summary).hasSuffix("Summary by `claude`. Tried first:\n\n- agy exited with status 1: authentication failed\n"))
    }

    func testCaptureEndingOnItsOwnSaysSoAtOnceAndProcessesWhatWasRecorded() async throws {
        await sut.toggleRecording()

        capture.interrupt(reason: "The display was disconnected.")

        XCTAssertFalse(sut.isRecording)
        XCTAssertEqual(notifications, ["Recording stopped: The display was disconnected. Ku-Ka will transcribe what it recorded. Start a new recording to capture the rest."])
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting notes ready: Meeting on 2026-10-23 at 14:02")
    }

    func testACaptureThatEndsWhileStartingIsReportedAndProcessed() async throws {
        capture.endsWhileStarting = "The microphone stopped."

        await sut.toggleRecording()

        XCTAssertFalse(sut.isRecording)
        XCTAssertEqual(notifications, ["Recording stopped: The microphone stopped. Ku-Ka will transcribe what it recorded. Start a new recording to capture the rest."])
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting notes ready: Meeting on 2026-10-23 at 14:02")
    }

    func testCaptureThatCannotStartLeavesNoFolderAndSaysWhy() async {
        capture.startError = TestError(errorDescription: "No display is available to capture audio from.")

        await sut.toggleRecording()

        XCTAssertFalse(sut.isRecording)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(notifications, ["Could not start recording: No display is available to capture audio from."])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testMissingScreenRecordingOpensThePermissionsWindowAndRecordsNothing() async {
        screenRecording = false

        await sut.toggleRecording()

        XCTAssertEqual(permissionWindows, 1)
        XCTAssertEqual(capture.recordings.count, 0)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testADeniedMicrophoneOpensThePermissionsWindow() async {
        microphone = .denied

        await sut.toggleRecording()

        XCTAssertEqual(permissionWindows, 1)
        XCTAssertFalse(sut.isRecording)
    }

    func testAllowingTheMicrophonePromptStartsTheRecording() async {
        microphone = .notDetermined
        answerMicrophonePrompt = { [unowned self] in microphone = .granted; return true }

        await sut.toggleRecording()

        XCTAssertTrue(sut.isRecording)
        XCTAssertEqual(permissionWindows, 0)
    }

    func testRefusingTheMicrophonePromptRecordsNothing() async {
        microphone = .notDetermined
        var prompts = 0
        answerMicrophonePrompt = { [unowned self] in prompts += 1; microphone = .denied; return false }

        await sut.toggleRecording()

        XCTAssertEqual(prompts, 1)
        XCTAssertFalse(sut.isRecording)
        XCTAssertEqual(capture.recordings.count, 0)
        XCTAssertEqual(permissionWindows, 0)
    }

    func testASecondClickWhileTheMicrophonePromptIsUpStartsNothing() async {
        microphone = .notDetermined
        var prompt: CheckedContinuation<Bool, Never>?
        answerMicrophonePrompt = { await withCheckedContinuation { prompt = $0 } }
        let firstClick = Task { await sut.toggleRecording() }
        await waitUntil { prompt != nil }
        XCTAssertEqual(item(titled: "Starting…").map(sut.validateMenuItem), false, "the record item is disabled while starting")

        await sut.toggleRecording()
        microphone = .granted
        prompt?.resume(returning: true)
        await firstClick.value

        XCTAssertEqual(capture.recordings.count, 1)
        XCTAssertTrue(sut.isRecording)
    }

    func testLaunchFinishesUnfinishedMeetingsOnceAndLeavesFailedOnesForRetry() async throws {
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        let failed = try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0), failure: "Speech model missing")

        sut.resumeUnfinished()
        sut.resumeUnfinished()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Meeting notes ready: Meeting on 2026-10-22 at 09:00"])
        XCTAssertEqual(failed.stage(), .failed(.transcribe))
    }

    func testRetryRunsFailedMeetingsFromTheStepThatFailed() async throws {
        let failed = try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0), failure: "agy exited with status 1", transcript: true)
        sut.refreshMenuSection()
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Retry Failed Meeting", "Open Meetings Folder", ""])

        let retry = try XCTUnwrap(item(titled: "Retry Failed Meeting"))
        _ = (retry.target as? NSObject)?.perform(retry.action, with: retry)
        await sut.waitUntilIdle()

        XCTAssertEqual(failed.stage(), .done)
        XCTAssertEqual(try failed.read(.summary).components(separatedBy: "\n").first, "# Meeting on 2026-10-22 at 10:00")
        XCTAssertEqual(notifications, ["Meeting notes ready: Meeting on 2026-10-22 at 10:00"])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testTheRetryItemCountsTheFailedMeetings() throws {
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0), failure: "Speech model missing")
        try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0), failure: "agy exited with status 1", transcript: true)

        sut.refreshMenuSection()

        XCTAssertNotNil(item(titled: "Retry 2 Failed Meetings"))
    }

    func testAFailedTranscriptionIsReportedWithTheRetryHint() async throws {
        (transcriber as? FakeTranscriber)?.byFileName["them.caf"] = .failure(TestError(errorDescription: "The audio file could not be read."))
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))

        sut.resumeUnfinished()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Transcription failed: The audio file could not be read. Retry from the Ku-Ka menu."])
    }

    func testTheProgressItemNamesTheStepAndTheWaitingMeetings() async throws {
        transcriber = SuspendedTranscriber()
        sut = makeController()
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0))

        sut.resumeUnfinished()
        await waitUntil { visibleTitles.count > 4 }

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting",
                                       "Transcribing Meeting on 2026-10-22 at 09:00… (+1 waiting)",
                                       "Open Meetings Folder", ""])
    }

    func testQuittingWhileRecordingClosesTheFilesAndLeavesTheMeetingForTheNextLaunch() async throws {
        await sut.toggleRecording()

        sut.shutDown()
        await sut.waitUntilIdle()

        XCTAssertEqual(capture.recordings.first?.stopCount, 1)
        XCTAssertEqual(MeetingFolder.all(in: root).map { $0.1 }, [.pending(.transcribe)])
        XCTAssertEqual(notifications, [])
    }

    func testQuittingWhileProcessingMarksNothingFailed() async throws {
        transcriber = SuspendedTranscriber()
        sut = makeController()
        let meeting = try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        sut.resumeUnfinished()
        await waitUntil { visibleTitles.count > 4 }
        XCTAssertNotNil(item(titled: "Transcribing Meeting on 2026-10-22 at 09:00…"))

        sut.shutDown()
        await sut.waitUntilIdle()

        XCTAssertEqual(meeting.stage(), .pending(.transcribe))
        XCTAssertEqual(notifications, [])
    }

    func testOpenMeetingsFolderCreatesAndOpensTheConfiguredFolder() throws {
        let open = try XCTUnwrap(item(titled: "Open Meetings Folder"))

        _ = (open.target as? NSObject)?.perform(open.action, with: open)

        XCTAssertEqual(opened, [root])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testElapsedTimeShowsHoursOnlyWhenNeeded() {
        XCTAssertEqual(MeetingNotesController.formatElapsed(0), "0:00")
        XCTAssertEqual(MeetingNotesController.formatElapsed(245), "4:05")
        XCTAssertEqual(MeetingNotesController.formatElapsed(3729), "1:02:09")
    }
}

private struct SuspendedTranscriber: Transcribing {
    func transcribe(_ audio: URL) async throws -> TrackTranscript {
        try await Task.sleep(for: .seconds(60))
        return TrackTranscript(segments: [], duration: 0)
    }
}
