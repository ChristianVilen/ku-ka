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
    private var liveTranscriber: FakeLiveTranscriber!
    private var transcriber: Transcribing!
    private var roomLabeller: FakeRoomLabeller!
    private var runner: FakeCommandRunner!
    /// Replaces `runner` in the next `makeController()` when set.
    private var gate: GatedCommandRunner?
    private var clock = localDate(2026, 10, 23, 14, 2)
    private var hostTime = HostTime(seconds: 1_000)
    private var notifier: FakeNotifier!
    private var notifications: [String] { notifier.posted.map { "\($0.title): \($0.body)" } }
    /// Read by the processor and the controller at each use.
    private var knownWords = KnownWordsList.empty
    private var alerts: [String] = []
    private var opened: [URL] = []
    private var permissionWindows = 0
    private var stateChanges = 0
    private var controlsRequests: [MeetingControlsRequest] = []
    /// The recorder of the newest `sut`.
    private var recorder: MeetingRecorder!
    private var sut: MeetingNotesController!
    private var menu: NSMenu!

    override func setUp() async throws {
        root = try makeTemporaryDirectory().appendingPathComponent("Meetings", isDirectory: true)
        capture = FakeMeetingAudioCapture()
        liveTranscriber = FakeLiveTranscriber()
        let fakeTranscriber = FakeTranscriber()
        fakeTranscriber.byFileName["them.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 1, end: 3, text: "Let's ship on Friday")], duration: 60))
        transcriber = fakeTranscriber
        roomLabeller = FakeRoomLabeller()
        runner = FakeCommandRunner()
        runner.results["agy"] = .success(CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: ""))
        notifier = FakeNotifier()
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
        recorder = MeetingRecorder(
            permissions: permissions,
            root: { [unowned self] in root },
            capture: capture,
            liveTranscriber: liveTranscriber,
            notifier: notifier,
            alertStartFailure: { [unowned self] reason, offersPermissions in
                alerts.append(reason)
                return offersPermissions
            },
            now: { [unowned self] in clock },
            hostNow: { [unowned self] in hostTime },
            closeSavedNoticeLater: { _ in })
        recorder.onShowPermissions = { [unowned self] in permissionWindows += 1 }
        recorder.onControlsRequest = { [unowned self] in controlsRequests.append($0) }
        let controller = MeetingNotesController(
            recorder: recorder,
            root: { [unowned self] in root },
            processor: MeetingProcessor(
                transcribers: [transcriber],
                roomLabeller: roomLabeller,
                summarizer: Summarizer(runner: gate ?? runner, home: URL(fileURLWithPath: "/Users/test"), isExecutable: { _ in true }),
                knownWords: { [unowned self] in knownWords },
                trash: { try FileManager.default.removeItem(at: $0) },
                now: { localDate(2026, 10, 23, 15, 0) }),
            wordsToCheck: { [unowned self] in WordReview.openQuestionCount(of: $0, in: root, knownWords: knownWords) },
            notifier: notifier,
            openURL: { [unowned self] in opened.append($0) })
        controller.onStateChange = { [unowned self] in stateChanges += 1 }
        menu = NSMenu()
        controller.buildMenuSection(into: menu)
        return controller
    }

    private var visibleTitles: [String] {
        menu.items.filter { !$0.isHidden && $0.view == nil }.map(\.title)
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
        XCTAssertEqual(recorder.phase, .idle)
    }

    func testHiddenControlsKeepRecordingAndShowMeetingControlsBringsThemBackWithFocus() async throws {
        await recorder.toggleRecording()

        recorder.dismissControls()
        XCTAssertNil(recorder.controls)
        XCTAssertEqual(recorder.phase, .recording)

        let show = try XCTUnwrap(item(titled: "Show Meeting Controls"))
        _ = (show.target as? NSObject)?.perform(show.action, with: show)

        XCTAssertEqual(recorder.controls, MeetingControls(status: .recording, recordedTime: 0, preview: nil))
        XCTAssertEqual(controlsRequests, [.focus])
    }

    func testRestoreDefaultPositionAsksThePanelToMoveBack() async throws {
        await recorder.toggleRecording()

        let restore = try XCTUnwrap(item(titled: "Restore Default Position"))
        _ = (restore.target as? NSObject)?.perform(restore.action, with: restore)

        XCTAssertEqual(controlsRequests, [.restoreDefaultPosition])
    }

    func testStartRecordsIntoANewMeetingFolderAndShowsTheElapsedTime() async {
        await recorder.toggleRecording()

        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertEqual(stateChanges, 2, "starting, then recording")
        XCTAssertEqual(meetingNames(), ["2026-10-23_14-02"])
        XCTAssertEqual(capture.recordings.count, 1)

        hostTime = hostTime + 245
        sut.menuTick()

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "● Recording · 4:05", "Stop Recording Meeting", "Pause Recording",
                                       "Show Meeting Controls", "Restore Default Position", "Open Meetings Folder", ""])
    }

    func testTheRecordedTimeStopsWhilePausedAndLeavesOutThePause() async {
        await recorder.toggleRecording()
        hostTime = HostTime(seconds: 1_010)
        recorder.pause()
        XCTAssertTrue(visibleTitles.contains("Paused · 0:10"), "\(visibleTitles)")

        hostTime = HostTime(seconds: 1_040)
        sut.menuTick()
        XCTAssertTrue(visibleTitles.contains("Paused · 0:10"), "\(visibleTitles)")

        recorder.resume()
        hostTime = HostTime(seconds: 1_045)
        sut.menuTick()
        XCTAssertTrue(visibleTitles.contains("● Recording · 0:15"), "\(visibleTitles)")
    }

    func testRecordingCommandsWhileIdleDoNothingAndStartNothing() {
        recorder.pause()
        recorder.resume()
        recorder.togglePause()
        recorder.stopRecording()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(stateChanges, 0)
        XCTAssertEqual(capture.recordings.count, 0)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testTheMenuOffersPauseWhileRecordingAndResumeWhilePaused() async throws {
        await recorder.toggleRecording()
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "● Recording · 0:00", "Stop Recording Meeting", "Pause Recording",
                                       "Show Meeting Controls", "Restore Default Position", "Open Meetings Folder", ""])

        hostTime = HostTime(seconds: 1_010)
        let pause = try XCTUnwrap(item(titled: "Pause Recording"))
        _ = (pause.target as? NSObject)?.perform(pause.action, with: pause)

        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Paused · 0:10", "Stop Recording Meeting", "Resume Recording",
                                       "Show Meeting Controls", "Restore Default Position", "Open Meetings Folder", ""])

        hostTime = HostTime(seconds: 1_040)
        let resume = try XCTUnwrap(item(titled: "Resume Recording"))
        _ = (resume.target as? NSObject)?.perform(resume.action, with: resume)

        XCTAssertEqual(recorder.phase, .recording)
    }

    func testStopWhilePausedStopsTheRecordingAndMakesTheNotes() async throws {
        await recorder.toggleRecording()
        hostTime = HostTime(seconds: 1_010)
        recorder.pause()
        XCTAssertEqual(recorder.phase, .paused)

        recorder.stopRecording()
        await sut.waitUntilIdle()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(capture.recordings.first?.stopCount, 1)
        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary."])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testAnInterruptionWhilePausedEndsTheMeeting() async {
        await recorder.toggleRecording()
        hostTime = HostTime(seconds: 1_010)
        recorder.pause()
        XCTAssertEqual(recorder.phase, .paused)

        capture.interrupt(reason: "The display was disconnected.")

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(notifications, ["Recording Stopped: The display was disconnected. Ku-Ka makes notes from what it recorded. To record the rest, choose Start Recording Meeting."])
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary.")
    }

    func testTheOpenMenuShowsIndependentMicrophoneAndMacAudioReadings() async throws {
        await recorder.toggleRecording()
        try XCTUnwrap(capture.recordings.last).levels = RecordingAudioLevels(microphone: 0.25, system: 0.75)

        sut.menuWillOpen()

        let meterItem = try XCTUnwrap(menu.items.first { $0.view != nil })
        XCTAssertFalse(meterItem.isHidden)
        let indicators = levelIndicators(in: try XCTUnwrap(meterItem.view))
        XCTAssertEqual(indicators.map { $0.accessibilityLabel() }, ["Microphone audio level", "Mac audio level"])
        XCTAssertEqual(indicators.map(\.doubleValue), [0.25, 0.75])
    }

    func testStoppingAndRestartingCannotShowThePreviousRecordingLevels() async throws {
        await recorder.toggleRecording()
        try XCTUnwrap(capture.recordings.last).levels = RecordingAudioLevels(microphone: 1, system: 0.5)
        sut.menuWillOpen()
        let meterItem = try XCTUnwrap(menu.items.first { $0.view != nil })
        XCTAssertEqual(levelIndicators(in: try XCTUnwrap(meterItem.view)).map(\.doubleValue), [1, 0.5])

        await recorder.toggleRecording()
        await sut.waitUntilIdle()
        XCTAssertTrue(meterItem.isHidden)

        await recorder.toggleRecording()
        XCTAssertFalse(meterItem.isHidden)
        XCTAssertEqual(levelIndicators(in: try XCTUnwrap(meterItem.view)).map(\.doubleValue), [0, 0])
    }

    func testAnInterruptionHidesTheRecordingMeters() async throws {
        await recorder.toggleRecording()
        sut.menuWillOpen()
        let meterItem = try XCTUnwrap(menu.items.first { $0.view != nil })
        XCTAssertFalse(meterItem.isHidden)

        capture.interrupt(reason: "The display disconnected.")

        XCTAssertTrue(meterItem.isHidden)
        await sut.waitUntilIdle()
    }

    func testAnInterruptionDuringStartNeverShowsMeters() async throws {
        capture.endsWhileStarting = "The microphone stopped."
        sut.menuWillOpen()

        await recorder.toggleRecording()

        let meterItem = try XCTUnwrap(menu.items.first { $0.view != nil })
        XCTAssertTrue(meterItem.isHidden)
        await sut.waitUntilIdle()
    }

    func testStatusMenuCloseStopsMeterUpdatesAndReopenReadsCurrentLevels() async throws {
        await recorder.toggleRecording()
        let handle = try XCTUnwrap(capture.recordings.last)
        handle.levels = RecordingAudioLevels(microphone: 0.2, system: 0.8)
        menu.removeAllItems()
        let statusMenu = StatusMenu(settings: Settings(defaults: UserDefaults(suiteName: "MeterMenuTests")!,
                                                       loginItem: FakeLoginItem()), sections: [sut])
        statusMenu.menuWillOpen(statusMenu.menu)
        defer { statusMenu.menuDidClose(statusMenu.menu) }
        let meterItem = try XCTUnwrap(statusMenu.menu.items.first { $0.view != nil })
        let indicators = levelIndicators(in: try XCTUnwrap(meterItem.view))
        XCTAssertEqual(indicators.map(\.doubleValue), [0.2, 0.8])

        handle.levels = RecordingAudioLevels(microphone: 0.7, system: 0.3)
        runMenuLoop(for: 0.2)
        XCTAssertEqual(indicators.map(\.doubleValue), [0.7, 0.3])

        statusMenu.menuDidClose(statusMenu.menu)
        handle.levels = RecordingAudioLevels(microphone: 0.1, system: 0.9)
        runMenuLoop(for: 0.2)
        XCTAssertEqual(indicators.map(\.doubleValue), [0.7, 0.3])

        statusMenu.menuWillOpen(statusMenu.menu)
        XCTAssertEqual(indicators.map(\.doubleValue), [0.1, 0.9])
        sut.shutDown()
        XCTAssertTrue(meterItem.isHidden)
    }

    private func levelIndicators(in view: NSView) -> [NSLevelIndicator] {
        if let indicator = view as? NSLevelIndicator { return [indicator] }
        return view.subviews.flatMap { levelIndicators(in: $0) }
    }

    private func runMenuLoop(for duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            RunLoop.current.run(mode: .eventTracking, before: until)
        }
    }

    func testStopProcessesTheMeetingAndSaysTheNotesAreReady() async throws {
        await recorder.toggleRecording()

        await recorder.toggleRecording()
        await sut.waitUntilIdle()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(stateChanges, 3, "starting, recording, then idle")
        XCTAssertEqual(capture.recordings.first?.stopCount, 1)
        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary."])
        let meeting = try XCTUnwrap(MeetingFolder.all(in: root).first?.0)
        XCTAssertEqual(meeting.stage(), .done)
        XCTAssertEqual(notifier.posted.last?.url?.resolvingSymlinksInPath(), meeting.url(for: .summary).resolvingSymlinksInPath(),
                       "a click opens the summary")
        XCTAssertEqual(notifier.permissionRequests, 1, "asked at Start, not at the first notice")
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testTheFallbackCLIWritesTheSummaryWithoutAFooter() async throws {
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: "authentication failed"))
        runner.results["claude"] = .success(CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: ""))

        await recorder.toggleRecording()
        await recorder.toggleRecording()
        await sut.waitUntilIdle()

        let meeting = try XCTUnwrap(MeetingFolder.all(in: root).first?.0)
        XCTAssertEqual(try meeting.read(.summary), "# Meeting on 2026-10-23 at 14:02\n\n## Summary\nShip Friday.\n")
    }

    func testCaptureEndingOnItsOwnSaysSoAtOnceAndProcessesWhatWasRecorded() async throws {
        await recorder.toggleRecording()

        capture.interrupt(reason: "The display was disconnected.")

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(notifications, ["Recording Stopped: The display was disconnected. Ku-Ka makes notes from what it recorded. To record the rest, choose Start Recording Meeting."])
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary.")
    }

    func testACaptureThatEndsWhileStartingIsReportedAndProcessed() async throws {
        capture.endsWhileStarting = "The microphone stopped."

        await recorder.toggleRecording()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(notifications, ["Recording Stopped: The microphone stopped. Ku-Ka makes notes from what it recorded. To record the rest, choose Start Recording Meeting."])
        XCTAssertEqual(liveTranscriber.starts.count, 0)
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary.")
    }

    func testCaptureThatCannotStartLeavesNoFolderAndSaysWhy() async {
        capture.startError = TestError(errorDescription: "No display is available to capture audio from.")

        await recorder.toggleRecording()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(alerts, ["No display is available to capture audio from."])
        XCTAssertEqual(permissionWindows, 0)
        XCTAssertEqual(notifications, [])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testMissingScreenRecordingSaysWhyAndOffersThePermissionsWindow() async {
        screenRecording = false

        await recorder.toggleRecording()

        XCTAssertEqual(alerts, ["Ku-Ka needs Screen Recording permission to record the other people on the call."])
        XCTAssertEqual(permissionWindows, 1)
        XCTAssertEqual(capture.recordings.count, 0)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testASecondClickWhileTheMicrophonePromptIsUpStartsNothing() async {
        microphone = .notDetermined
        var prompt: CheckedContinuation<Bool, Never>?
        answerMicrophonePrompt = { await withCheckedContinuation { prompt = $0 } }
        let firstClick = Task { await recorder.toggleRecording() }
        await waitUntil { prompt != nil }
        XCTAssertTrue(visibleTitles.contains("Starting Recording"))
        XCTAssertEqual(item(titled: "Start Recording Meeting").map(sut.validateMenuItem), false, "the record item is disabled while starting")

        await recorder.toggleRecording()
        microphone = .granted
        prompt?.resume(returning: true)
        await firstClick.value

        XCTAssertEqual(capture.recordings.count, 1)
        XCTAssertEqual(recorder.phase, .recording)
    }

    func testLaunchFinishesUnfinishedMeetingsOnceAndLeavesFailedOnesForRetry() async throws {
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        let failed = try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0), failure: "Speech model missing")

        sut.resumeUnfinished()
        sut.resumeUnfinished()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-22 at 09:00. Click to open the summary."])
        XCTAssertEqual(failed.stage(), .failed(.transcribe))
    }

    func testRetryRunsFailedMeetingsFromTheStepThatFailed() async throws {
        let failed = try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0), failure: "agy exited with status 1", transcript: true)
        sut.menuWillOpen()
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Retry Failed Meeting", "Open Meetings Folder", ""])

        let retry = try XCTUnwrap(item(titled: "Retry Failed Meeting"))
        _ = (retry.target as? NSObject)?.perform(retry.action, with: retry)
        await sut.waitUntilIdle()

        XCTAssertEqual(failed.stage(), .done)
        XCTAssertEqual(try failed.read(.summary).components(separatedBy: "\n").first, "# Meeting on 2026-10-22 at 10:00")
        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-22 at 10:00. Click to open the summary."])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testAMeetingsFolderThatIsASymlinkKeepsRecoveryRetryAndCheckWords() async throws {
        let base = try makeTemporaryDirectory()
        let target = base.appendingPathComponent("Cloud Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        root = base.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0), failure: "Speech model missing")
        try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])

        sut.menuWillOpen()
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Check Words (1)…", "Retry Failed Meeting",
                                       "Open Meetings Folder", ""])
        sut.resumeUnfinished()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-22 at 09:00. Click to open the summary."])
    }

    func testTheRetryItemCountsTheFailedMeetings() throws {
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0), failure: "Speech model missing")
        try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0), failure: "agy exited with status 1", transcript: true)

        sut.menuWillOpen()

        XCTAssertNotNil(item(titled: "Retry 2 Failed Meetings"))
    }

    func testAFailedTranscriptionIsReportedWithTheRetryHint() async throws {
        (transcriber as? FakeTranscriber)?.byFileName["them.caf"] = .failure(TestError(errorDescription: "The audio file could not be read."))
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))

        sut.resumeUnfinished()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Transcription Failed: Meeting on 2026-10-22 at 09:00. Choose Retry Failed Meeting in the Ku-Ka menu to try again. Click to see what went wrong."])
    }

    func testTheProgressItemNamesTheStepAndTheWaitingMeetings() async throws {
        transcriber = SuspendedTranscriber()
        sut = makeController()
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0))

        sut.resumeUnfinished()
        await waitUntil { visibleTitles.count > 4 }

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting",
                                       "Transcribing: Meeting on 2026-10-22 at 09:00", "1 more meeting waiting",
                                       "Open Meetings Folder", ""])
    }

    func testTheProgressItemSaysTranscribingAgainOnceTheSpeechModelIsDownloaded() async throws {
        let suspended = SuspendedTranscriber()
        suspended.modelIsMissing = true
        transcriber = suspended
        sut = makeController()
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))

        sut.resumeUnfinished()
        await waitUntil { suspended.downloads == ["en-US"] && visibleTitles.contains("Transcribing: Meeting on 2026-10-22 at 09:00") }

        XCTAssertEqual(suspended.downloads, ["en-US"])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting",
                                       "Transcribing: Meeting on 2026-10-22 at 09:00", "Open Meetings Folder", ""])
    }

    func testQuittingWhileRecordingClosesTheFilesAndLeavesTheMeetingForTheNextLaunch() async throws {
        await recorder.toggleRecording()

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
        XCTAssertNotNil(item(titled: "Transcribing: Meeting on 2026-10-22 at 09:00"))

        sut.shutDown()
        await sut.waitUntilIdle()

        XCTAssertEqual(meeting.stage(), .pending(.transcribe))
        XCTAssertEqual(notifications, [])
    }

    func testQuittingWhileLabellingRoomsRemovesTheMarkerSoTheNextRunLabelsTheMeeting() async throws {
        try XCTUnwrap(transcriber as? FakeTranscriber).byFileName["me.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 4, end: 5, text: "Sounds good")], duration: 59))
        roomLabeller = WaitingRoomLabeller()
        sut = makeController()
        let meeting = try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        FileManager.default.createFile(atPath: meeting.audioURL(.microphone).path, contents: Data())
        sut.resumeUnfinished()
        await waitUntil { [unowned self] in roomLabeller.calls == ["label me.caf"] }
        XCTAssertTrue(meeting.roomLabelsStarted)

        sut.shutDown()

        XCTAssertFalse(meeting.roomLabelsStarted, "the process ends before the processor removes the marker")
        await sut.waitUntilIdle()
        roomLabeller = FakeRoomLabeller()
        sut = makeController()
        sut.resumeUnfinished()
        await sut.waitUntilIdle()
        XCTAssertEqual(roomLabeller.calls, ["label me.caf"])
        XCTAssertFalse(try meeting.read(.transcript).contains("There are no room labels"))
    }

    func testQuittingWhileTranscribingKeepsTheMarkerThatACrashLeft() async throws {
        transcriber = SuspendedTranscriber()
        sut = makeController()
        let meeting = try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        FileManager.default.createFile(atPath: meeting.url.appendingPathComponent(".room-labels-started").path,
                                       contents: Data())
        sut.resumeUnfinished()
        await waitUntil { visibleTitles.count > 4 }
        XCTAssertNotNil(item(titled: "Transcribing: Meeting on 2026-10-22 at 09:00"))

        sut.shutDown()
        await sut.waitUntilIdle()

        XCTAssertTrue(meeting.roomLabelsStarted, "the next run must still skip room labels")
    }

    // MARK: - Known words

    private let askTheVendors = "Ask Convio, Brightlane and Yuri on Friday"

    /// The CLI's notes come with a review block that asks about `heard`, each quoted from `askTheVendors`.
    private func hearTheVendors(suspects heard: [String]) throws {
        try XCTUnwrap(transcriber as? FakeTranscriber).byFileName["them.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 1, end: 3, text: askTheVendors)], duration: 60))
        let items = heard.map { #"{"heard": "\#($0)", "kind": "company", "quote": "\#(askTheVendors)"}"# }
        runner.results["agy"] = .success(CommandResult(
            termination: .exited(0),
            stdout: "## Summary\nAsk the vendors.\n\n```ku-ka-review\n[\(items.joined(separator: ", "))]\n```\n",
            stderr: ""))
    }

    func testNotesWithQuestionsSayHowManyWordsToCheckAndAClickOpensTheReview() async throws {
        try hearTheVendors(suspects: ["Convio", "Brightlane", "Yuri"])
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))

        sut.resumeUnfinished()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-22 at 09:00. 3 words to check. Click to check them."])
        let meeting = try XCTUnwrap(MeetingFolder.all(in: root).first?.0)
        XCTAssertEqual(notifier.posted.last?.click, .checkWords(meeting))
        XCTAssertEqual(item(titled: "Check Words (3)…")?.isHidden, false, "read again when the queue ends")
    }

    /// A done meeting whose review asks about `heard`, with the first `skipped` of them skipped.
    @discardableResult
    private func reviewedMeeting(at date: Date, asking heard: [String], skipped: Int = 0) throws -> MeetingFolder {
        let meeting = try MeetingFolder.create(in: root, startingAt: date)
        try meeting.write("**[00:00:01] Them:** \(askTheVendors)\n", to: .transcript)
        try meeting.write("# \(meeting.title)\n\nAsk the vendors.\n", to: .summary)
        let questions = heard.map { #"{"heard": "\#($0)", "kind": "company", "quote": "\#(askTheVendors)"}"# }
        try meeting.write(#"{"questions": [\#(questions.joined(separator: ", "))]}"#, to: .questions)
        let skips = heard.prefix(skipped).map { #""\#($0)""# }
        try meeting.write(#"{"skipped": [\#(skips.joined(separator: ", "))]}"#, to: .skipped)
        return meeting
    }

    func testCheckWordsCountsTheOpenQuestionsOfEveryDoneMeetingWhenTheMenuOpens() throws {
        sut.menuWillOpen()
        XCTAssertFalse(visibleTitles.contains { $0.hasPrefix("Check Words") }, "hidden without questions")

        try reviewedMeeting(at: localDate(2026, 10, 22, 9, 0), asking: ["Convio", "Yuri"], skipped: 1)
        try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Brightlane", "Convio"])
        try reviewedMeeting(at: localDate(2026, 10, 24, 9, 0), asking: ["Quorix"], skipped: 1)
        sut.menuWillOpen()

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Check Words (3)…", "Open Meetings Folder", ""])
    }

    func testCheckWordsLeavesOutTheQuestionsWhoseWordTheListLearnedSince() throws {
        try reviewedMeeting(at: localDate(2026, 10, 22, 9, 0), asking: ["Convio", "Yuri"])
        try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        knownWords = KnownWordsList(markdown: "- Convio → **Konvio** ✓\n")

        sut.menuWillOpen()

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Check Words (1)…", "Open Meetings Folder", ""])
    }

    func testTheMenuListsTheProgressThenCheckWordsThenRetry() async throws {
        transcriber = SuspendedTranscriber()
        sut = makeController()
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))
        try leftoverMeeting(at: localDate(2026, 10, 22, 10, 0))
        try leftoverMeeting(at: localDate(2026, 10, 22, 11, 0), failure: "Speech model missing")
        try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])

        sut.resumeUnfinished()
        sut.menuWillOpen()
        await waitUntil { visibleTitles.count > 6 }

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting",
                                       "Transcribing: Meeting on 2026-10-22 at 09:00", "1 more meeting waiting",
                                       "Check Words (1)…", "Retry Failed Meeting", "Open Meetings Folder", ""])
    }

    func testChoosingCheckWordsAsksForTheOldestUnfinishedReview() throws {
        try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        var asked: [MeetingFolder?] = []
        sut.onCheckWords = { asked.append($0) }
        sut.menuWillOpen()

        let checkWords = try XCTUnwrap(item(titled: "Check Words (1)…"))
        _ = (checkWords.target as? NSObject)?.perform(checkWords.action, with: checkWords)

        XCTAssertEqual(asked, [nil])
    }

    // MARK: - Update Notes

    func testUpdateNotesWaitsForTheMeetingThatIsProcessedAndThenSaysWhatItDoes() async throws {
        let gate = GatedCommandRunner()
        self.gate = gate
        sut = makeController()
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0), transcript: true)
        let reviewed = try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        sut.resumeUnfinished()
        await waitUntil { gate.waiting == 1 }

        sut.updateNotes(reviewed)

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting",
                                       "Summarizing: Meeting on 2026-10-22 at 09:00", "1 more meeting waiting",
                                       "Open Meetings Folder", ""])
        gate.letOneThrough()
        await waitUntil { gate.runs == 2 && gate.waiting == 1 }
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting",
                                       "Updating notes: Meeting on 2026-10-23 at 09:00", "Open Meetings Folder", ""])
        gate.letOneThrough()
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-22 at 09:00. Click to open the summary.",
                                       "Notes Updated: Meeting on 2026-10-23 at 09:00. Click to open the summary."])
        XCTAssertEqual(notifier.posted.last?.click, .open(reviewed.url(for: .summary)))
        XCTAssertEqual(try reviewed.read(.summary), "# Meeting on 2026-10-23 at 09:00\n\n## Summary\nShip Friday.\n")
    }

    func testTheSameUpdateNotesAskedAgainWhileItWaitsOrRunsRunsOnceAlsoThroughASymlink() async throws {
        let base = try makeTemporaryDirectory()
        let target = base.appendingPathComponent("Cloud Drive", isDirectory: true)
        let link = base.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        root = link.appendingPathComponent("Meetings", isDirectory: true)
        let gate = GatedCommandRunner()
        self.gate = gate
        sut = makeController()
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0), transcript: true)
        let created = try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        let listed = try XCTUnwrap(WordReview.unfinished(in: root, knownWords: .empty).first?.meeting)
        XCTAssertEqual(created, listed, "the review window and the notification name one folder")
        sut.resumeUnfinished()
        await waitUntil { gate.waiting == 1 }

        sut.updateNotes(created)
        sut.updateNotes(listed)
        sut.updateNotes(created)
        XCTAssertTrue(visibleTitles.contains("1 more meeting waiting"))
        gate.letOneThrough()
        await waitUntil { gate.runs == 2 && gate.waiting == 1 }
        sut.updateNotes(listed)
        for _ in 0..<3 { gate.letOneThrough() }
        await sut.waitUntilIdle()

        XCTAssertEqual(gate.runs, 2, "one summary, then one update")
        XCTAssertEqual(notifications.filter { $0.hasPrefix("Notes Updated") }.count, 1)
    }

    func testAnUpdateWithoutANewSummarySaysTheSummaryDidNotChange() async throws {
        let reviewed = try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        let summary = try reviewed.read(.summary)
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: "authentication failed"))
        runner.results["claude"] = .success(CommandResult(termination: .timedOut, stdout: "", stderr: ""))

        sut.updateNotes(reviewed)
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Notes Not Updated: Meeting on 2026-10-23 at 09:00. The summary tool did not answer, so the summary did not change. The transcript has your answers."])
        XCTAssertEqual(notifier.posted.last?.click, .open(reviewed.url(for: .summary)))
        XCTAssertEqual(try reviewed.read(.summary), summary)
    }

    func testAnUpdateThatFailsBeforeTheSummaryToolClaimsNothingAboutTheTranscript() async throws {
        let reviewed = try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        let summary = try reviewed.read(.summary)
        try FileManager.default.removeItem(at: reviewed.url(for: .transcript))

        sut.updateNotes(reviewed)
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Notes Not Updated: Meeting on 2026-10-23 at 09:00. Ku-Ka could not update the notes, so the summary did not change."])
        XCTAssertEqual(notifier.posted.last?.click, .open(reviewed.url(for: .summary)))
        XCTAssertEqual(try reviewed.read(.summary), summary)
        XCTAssertEqual(runner.calls.count, 0, "no CLI ran")
    }

    func testAnUpdateOfABusyOrGoneMeetingSaysWhyTheNotesDidNotChange() async throws {
        let busy = try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        let gone = try reviewedMeeting(at: localDate(2026, 10, 24, 9, 0), asking: ["Yuri"])
        let otherKuKa = try busy.lock()
        try FileManager.default.removeItem(at: gone.url)

        sut.updateNotes(busy)
        sut.updateNotes(gone)
        await sut.waitUntilIdle()
        otherKuKa.release()

        XCTAssertEqual(notifications, [
            "Notes Not Updated: Meeting on 2026-10-23 at 09:00. The meeting folder was in use, for example by another Ku-Ka, so the notes did not change. Click to open Check Words and choose Update Notes again.",
            "Notes Not Updated: Meeting on 2026-10-24 at 09:00. The meeting is not finished, or its folder was moved or deleted, so the notes did not change.",
        ])
        XCTAssertEqual(notifier.posted.map(\.click), [.checkWords(busy), nil])
    }

    func testQuittingCancelsTheUpdateThatRunsAndTheOneThatWaitsAndPostsNothing() async throws {
        let gate = GatedCommandRunner()
        self.gate = gate
        sut = makeController()
        let running = try reviewedMeeting(at: localDate(2026, 10, 23, 9, 0), asking: ["Convio"])
        let waiting = try reviewedMeeting(at: localDate(2026, 10, 24, 9, 0), asking: ["Yuri"])
        let summary = try running.read(.summary)
        sut.updateNotes(running)
        sut.updateNotes(waiting)
        await waitUntil { gate.waiting == 1 }

        sut.shutDown()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, [])
        XCTAssertEqual(try running.read(.summary), summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: waiting.url(for: .heardTranscript).path), "never started")
    }

    func testNotesWithOneQuestionSayOneWord() async throws {
        try hearTheVendors(suspects: ["Convio"])
        try leftoverMeeting(at: localDate(2026, 10, 22, 9, 0))

        sut.resumeUnfinished()
        await sut.waitUntilIdle()

        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-22 at 09:00. 1 word to check. Click to check them."])
    }

    func testOpenMeetingsFolderCreatesAndOpensTheConfiguredFolder() throws {
        let open = try XCTUnwrap(item(titled: "Open Meetings Folder"))

        _ = (open.target as? NSObject)?.perform(open.action, with: open)

        XCTAssertEqual(opened, [root])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
}

private final class SuspendedTranscriber: FakeTranscriber {
    override func transcribe(_ audio: URL) async throws -> TrackTranscript {
        try await Task.sleep(for: .seconds(60))
        return TrackTranscript(segments: [], duration: 0)
    }
}

/// Each run waits until the test lets one through, or until its task is cancelled, and then
/// replies with notes. `run` is called off the main actor, so the counts are behind a lock.
private final class GatedCommandRunner: CommandRunning {
    private let lock = NSLock()
    private var started = 0
    private var finished = 0
    private var passes = 0

    /// Runs that started.
    var runs: Int { lock.withLock { started } }
    /// Runs that wait now.
    var waiting: Int { lock.withLock { started - finished } }

    func letOneThrough() {
        lock.withLock { passes += 1 }
    }

    func run(executable: URL, arguments: [String], input: String?, searchPath: [String],
             timeout: Duration) async throws -> CommandResult {
        lock.withLock { started += 1 }
        defer { lock.withLock { finished += 1 } }
        while !takePass() {
            try await Task.sleep(for: .milliseconds(10))
        }
        return CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: "")
    }

    private func takePass() -> Bool {
        lock.withLock {
            guard passes > 0 else { return false }
            passes -= 1
            return true
        }
    }
}

/// `label` waits until its task is cancelled.
private final class WaitingRoomLabeller: FakeRoomLabeller {
    override func label(_ microphone: URL) async -> RoomLabels {
        let result = await super.label(microphone)
        try? await Task.sleep(for: .seconds(60))
        return result
    }
}
