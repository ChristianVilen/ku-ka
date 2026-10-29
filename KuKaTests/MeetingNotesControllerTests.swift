import AVFAudio
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
    private var meetingLocale = Locale(identifier: "en-US")
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
    private var controlsChanges = 0
    private var controlsRequests: [MeetingControlsRequest] = []
    /// Each saved notice's delayed close, in order. A test runs one to end its delay.
    private var noticeCloses: [@MainActor () -> Void] = []
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
        let controller = MeetingNotesController(
            permissions: permissions,
            root: { [unowned self] in root },
            locale: { [unowned self] in meetingLocale },
            capture: capture,
            liveTranscriber: liveTranscriber,
            processor: MeetingProcessor(
                transcribers: [transcriber],
                roomLabeller: roomLabeller,
                summarizer: Summarizer(runner: gate ?? runner, home: URL(fileURLWithPath: "/Users/test"), isExecutable: { _ in true }),
                knownWords: { [unowned self] in knownWords },
                trash: { try FileManager.default.removeItem(at: $0) },
                now: { localDate(2026, 10, 23, 15, 0) }),
            knownWords: { [unowned self] in knownWords },
            notifier: notifier,
            alertStartFailure: { [unowned self] reason, offersPermissions in
                alerts.append(reason)
                return offersPermissions
            },
            openURL: { [unowned self] in opened.append($0) },
            now: { [unowned self] in clock },
            hostNow: { [unowned self] in hostTime },
            closeSavedNoticeLater: { [unowned self] in noticeCloses.append($0) })
        controller.onShowPermissions = { [unowned self] in permissionWindows += 1 }
        controller.onStateChange = { [unowned self] in stateChanges += 1 }
        controller.onControlsChange = { [unowned self] in controlsChanges += 1 }
        controller.onControlsRequest = { [unowned self] in controlsRequests.append($0) }
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
        XCTAssertEqual(sut.phase, .idle)
    }

    func testTheControlsShowStartingThenTheRecordedTimeAndNothingWhileIdle() async {
        XCTAssertNil(sut.controls)
        microphone = .notDetermined
        var prompt: CheckedContinuation<Bool, Never>?
        answerMicrophonePrompt = { await withCheckedContinuation { prompt = $0 } }
        let start = Task { await sut.toggleRecording() }
        await waitUntil { prompt != nil }

        XCTAssertEqual(sut.controls, MeetingControls(status: .starting, isTranscriptOpen: false, preview: nil))
        sut.dismissControls()
        XCTAssertEqual(sut.controls?.status, .starting, "Starting cannot be hidden")

        microphone = .granted
        prompt?.resume(returning: true)
        await start.value
        hostTime = hostTime + 245
        XCTAssertEqual(sut.controls?.status, .recording(245))

        sut.pause()
        hostTime = hostTime + 30
        XCTAssertEqual(sut.controls?.status, .paused(245))
    }

    func testEveryMeetingStartsWithTheControlsShownAndTheTranscriptClosed() async {
        await sut.toggleRecording()
        XCTAssertEqual(sut.controls?.isTranscriptOpen, false)
        sut.setTranscriptOpen(true)
        XCTAssertEqual(sut.controls?.isTranscriptOpen, true)
        sut.dismissControls()

        await sut.toggleRecording()
        await sut.toggleRecording()

        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(sut.controls?.status, .recording(0))
        XCTAssertEqual(sut.controls?.isTranscriptOpen, false)
    }

    func testHiddenControlsKeepRecordingAndShowMeetingControlsBringsThemBackWithFocus() async throws {
        await sut.toggleRecording()

        sut.dismissControls()
        XCTAssertNil(sut.controls)
        XCTAssertEqual(sut.phase, .recording)

        let show = try XCTUnwrap(item(titled: "Show Meeting Controls"))
        _ = (show.target as? NSObject)?.perform(show.action, with: show)

        XCTAssertEqual(sut.controls?.status, .recording(0))
        XCTAssertEqual(controlsRequests, [.focus])
    }

    func testStopShowsTheSavedNoticeUntilItsDelayEnds() async {
        await sut.toggleRecording()
        sut.setTranscriptOpen(true)

        sut.stopRecording()

        XCTAssertEqual(sut.controls, MeetingControls(status: .saved, isTranscriptOpen: false, preview: nil))
        XCTAssertEqual(noticeCloses.count, 1)
        noticeCloses[0]()
        XCTAssertNil(sut.controls)
    }

    func testADelayFromAnEarlierMeetingDoesNotCloseALaterNotice() async {
        await sut.toggleRecording()
        await sut.toggleRecording()
        await sut.toggleRecording()
        XCTAssertEqual(sut.controls?.status, .recording(0), "Start replaces the notice")
        await sut.toggleRecording()
        XCTAssertEqual(noticeCloses.count, 2)

        noticeCloses[0]()
        XCTAssertEqual(sut.controls?.status, .saved)

        noticeCloses[1]()
        XCTAssertNil(sut.controls)
    }

    func testAnInterruptionLeavesItsReasonOnScreenUntilTheUserClosesIt() async {
        await sut.toggleRecording()
        await sut.toggleRecording()
        await sut.toggleRecording()

        capture.interrupt(reason: "The display was disconnected.")

        let stopped = MeetingControls(status: .interrupted(reason: "The display was disconnected."),
                                      isTranscriptOpen: false, preview: nil)
        XCTAssertEqual(sut.controls, stopped)
        XCTAssertEqual(noticeCloses.count, 1, "only the first meeting's saved notice has a delay")
        noticeCloses[0]()
        XCTAssertEqual(sut.controls, stopped)

        sut.dismissControls()
        XCTAssertNil(sut.controls)
    }

    func testThePanelHearsOfStartPauseResumeADrawerChangeStopAndTheNoticeClosing() async {
        await sut.toggleRecording()
        XCTAssertEqual(controlsChanges, 2, "starting, then recording")

        hostTime = HostTime(seconds: 1_010)
        sut.pause()
        XCTAssertEqual(controlsChanges, 3)
        hostTime = HostTime(seconds: 1_020)
        sut.resume()
        XCTAssertEqual(controlsChanges, 4)
        sut.setTranscriptOpen(true)
        XCTAssertEqual(controlsChanges, 5)
        sut.stopRecording()
        XCTAssertEqual(controlsChanges, 6)
        noticeCloses[0]()
        XCTAssertEqual(controlsChanges, 7)
    }

    func testThePanelTicksEverySecondOnlyWhileRecordingAlsoWhileAMenuIsOpen() async {
        await sut.toggleRecording()
        var before = controlsChanges
        runMenuLoop(for: 1.15)
        XCTAssertEqual(controlsChanges, before + 1)

        hostTime = HostTime(seconds: 1_010)
        sut.pause()
        before = controlsChanges
        runMenuLoop(for: 1.15)
        XCTAssertEqual(controlsChanges, before, "the time stands still while paused")

        hostTime = HostTime(seconds: 1_020)
        sut.resume()
        sut.stopRecording()
        before = controlsChanges
        runMenuLoop(for: 1.15)
        XCTAssertEqual(controlsChanges, before, "no tick after the meeting")
    }

    func testStartBeginsOneLiveTranscriptInTheMeetingLocaleOfTheAudioTheRecordingWrites() async throws {
        meetingLocale = Locale(identifier: "fi-FI")

        await sut.toggleRecording()
        hostTime = HostTime(seconds: 1_010)
        sut.pause()
        hostTime = HostTime(seconds: 1_020)
        sut.resume()

        XCTAssertEqual(liveTranscriber.starts.map(\.locale), ["fi-FI"])
        let audio = try XCTUnwrap(liveTranscriber.starts.first?.audio)
        XCTAssertEqual(Set(audio.keys), Set(MeetingTrack.allCases))
        let handle = try XCTUnwrap(capture.recordings.last)
        for (track, position) in [(MeetingTrack.microphone, 4.0), (.system, 7.0)] {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioTrackWriter.fileFormat, frameCapacity: 160))
            handle.feeds[track]?.offer(WrittenAudio(buffer: buffer, filePosition: position, rms: 0.5))
            var written = try XCTUnwrap(audio[track]).makeAsyncIterator()
            let first = await written.next()
            XCTAssertEqual(first?.filePosition, position)
        }
    }

    func testLiveTextReachesThePreview() async {
        await sut.toggleRecording()
        sut.setTranscriptOpen(true)
        XCTAssertEqual(sut.controls?.preview, LivePreview(status: .preparing, rows: [], behind: nil))

        liveTranscriber.send(.started)
        liveTranscriber.send(.result(LiveResult(track: .system, start: 1, end: 2, text: "Let's ship on Friday",
                                                isFinal: true, finalizedThrough: 2)))
        await waitUntil { sut.controls?.preview?.rows.isEmpty == false }

        XCTAssertEqual(sut.controls?.preview, LivePreview(
            status: .live, rows: [LiveRow(at: 1, content: .speech(.them, text: "Let's ship on Friday", isFinal: true))],
            behind: nil))
    }

    func testThePreviewIsBuiltOnlyWhileTheTranscriptIsOpen() async {
        await sut.toggleRecording()
        let changes = controlsChanges
        liveTranscriber.send(.started)
        liveTranscriber.send(.result(LiveResult(track: .system, start: 1, end: 2, text: "Let's ship on Friday",
                                                isFinal: true, finalizedThrough: 2)))
        await waitUntil { controlsChanges == changes + 2 }

        XCTAssertNil(sut.controls?.preview)

        sut.setTranscriptOpen(true)
        XCTAssertEqual(sut.controls?.preview?.rows,
                       [LiveRow(at: 1, content: .speech(.them, text: "Let's ship on Friday", isFinal: true))])
    }

    func testALiveTranscriptThatIsUnavailableOrFailsLeavesTheRecordingAlone() async throws {
        await sut.toggleRecording()
        sut.setTranscriptOpen(true)
        liveTranscriber.send(.unavailable("Live transcript is not available for Finnish on this Mac."))
        await waitUntil { sut.controls?.preview?.status != .preparing }

        XCTAssertEqual(sut.controls?.preview?.status, .unavailable("Live transcript is not available for Finnish on this Mac."))
        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(capture.recordings.last?.stopCount, 0)

        await sut.toggleRecording()
        await sut.toggleRecording()
        sut.setTranscriptOpen(true)
        liveTranscriber.send(.started)
        liveTranscriber.send(.failed("The speech model stopped."))
        await waitUntil { sut.controls?.preview?.status == .failed("The speech model stopped.") }

        XCTAssertEqual(sut.controls?.preview?.status, .failed("The speech model stopped."))
        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(capture.recordings.last?.stopCount, 0)
    }

    func testStopAnInterruptionAndQuitEachEndTheLiveTranscript() async {
        await sut.toggleRecording()
        sut.stopRecording()
        await waitUntil { liveTranscriber.terminations == 1 }
        XCTAssertEqual(liveTranscriber.terminations, 1)

        let changesAfterStop = controlsChanges
        liveTranscriber.send(.result(LiveResult(track: .system, start: 1, end: 2, text: "Too late",
                                                isFinal: true, finalizedThrough: 2)))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controlsChanges, changesAfterStop)
        XCTAssertEqual(sut.controls, MeetingControls(status: .saved, isTranscriptOpen: false, preview: nil))

        await sut.toggleRecording()
        capture.interrupt(reason: "The display was disconnected.")
        await waitUntil { liveTranscriber.terminations == 2 }
        XCTAssertEqual(liveTranscriber.terminations, 2)

        await sut.toggleRecording()
        sut.shutDown()
        await waitUntil { liveTranscriber.terminations == 3 }
        XCTAssertEqual(liveTranscriber.terminations, 3)
    }

    func testALiveUpdateFromTheFirstMeetingDoesNotShowInTheSecond() async {
        await sut.toggleRecording()
        sut.setTranscriptOpen(true)
        liveTranscriber.send(.started)
        await waitUntil { sut.controls?.preview?.status == .live }
        liveTranscriber.send(.result(LiveResult(track: .system, start: 1, end: 2, text: "From the first meeting",
                                                isFinal: true, finalizedThrough: 2)))

        sut.stopRecording()
        await sut.toggleRecording()
        sut.setTranscriptOpen(true)
        liveTranscriber.send(.started)
        await waitUntil { sut.controls?.preview?.status == .live }

        XCTAssertEqual(sut.controls?.preview?.rows, [])
    }

    func testPauseShowsTheUnfinishedLiveTextAsFinal() async {
        await sut.toggleRecording()
        sut.setTranscriptOpen(true)
        liveTranscriber.send(.result(LiveResult(track: .system, start: 1, end: 2, text: "So the plan",
                                                isFinal: false, finalizedThrough: 0)))
        await waitUntil { sut.controls?.preview?.rows.isEmpty == false }
        XCTAssertEqual(sut.controls?.preview?.rows, [LiveRow(at: 1, content: .speech(.them, text: "So the plan", isFinal: false))])

        hostTime = HostTime(seconds: 1_010)
        sut.pause()

        XCTAssertEqual(sut.controls?.preview?.rows, [LiveRow(at: 1, content: .speech(.them, text: "So the plan", isFinal: true)),
                                                     LiveRow(at: 10, content: .pause(duration: nil))])
    }

    func testRestoreDefaultPositionAsksThePanelToMoveBack() async throws {
        await sut.toggleRecording()

        let restore = try XCTUnwrap(item(titled: "Restore Default Position"))
        _ = (restore.target as? NSObject)?.perform(restore.action, with: restore)

        XCTAssertEqual(controlsRequests, [.restoreDefaultPosition])
    }

    func testOnlyRecordingAndPausedAreCapturingAndEachSaysWhatTheStatusItemShows() {
        let phases: [RecorderPhase] = [.idle, .starting, .recording, .paused]

        XCTAssertEqual(phases.map(\.isCapturing), [false, false, true, true])
        XCTAssertEqual(phases.map(\.statusDescription), [nil, nil, "recording meeting", "recording paused"])
        XCTAssertEqual(phases.map(\.recordingMark), [nil, nil, .recording, .paused])
    }

    func testStartRecordsIntoANewMeetingFolderAndShowsTheElapsedTime() async {
        await sut.toggleRecording()

        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(stateChanges, 2, "starting, then recording")
        XCTAssertEqual(meetingNames(), ["2026-10-23_14-02"])
        XCTAssertEqual(capture.recordings.count, 1)

        hostTime = hostTime + 245
        sut.menuTick()

        XCTAssertEqual(visibleTitles, ["Meeting Notes", "● Recording · 4:05", "Stop Recording Meeting", "Pause Recording",
                                       "Show Meeting Controls", "Restore Default Position", "Open Meetings Folder", ""])
    }

    func testTheCaptureStartsWithAClockFromTheHostTimeJustBeforeIt() async {
        microphone = .notDetermined
        answerMicrophonePrompt = { [unowned self] in
            hostTime = HostTime(seconds: 1_007)
            microphone = .granted
            return true
        }

        await sut.toggleRecording()

        XCTAssertEqual(capture.clocks, [RecordingClock(origin: HostTime(seconds: 1_007))])
    }

    /// The clock the controller makes at host time 1 000, with these boundaries applied.
    private func clock(pausedAt pause: TimeInterval, resumedAt resume: TimeInterval? = nil) -> RecordingClock {
        var clock = RecordingClock(origin: HostTime(seconds: 1_000))
        clock.pause(at: HostTime(seconds: pause))
        if let resume { clock.resume(at: HostTime(seconds: resume)) }
        return clock
    }

    func testPauseHandsTheRecordingAClockPausedAtTheHostTimeOfTheClick() async throws {
        await sut.toggleRecording()
        let handle = try XCTUnwrap(capture.recordings.last)
        let changesBeforePause = stateChanges
        hostTime = HostTime(seconds: 1_010)

        sut.pause()

        XCTAssertEqual(handle.appliedClocks, [clock(pausedAt: 1_010)])
        XCTAssertEqual(sut.phase, .paused)
        XCTAssertEqual(stateChanges, changesBeforePause + 1)
    }

    func testPauseKeepsTheCaptureAndTheFolderLock() async throws {
        await sut.toggleRecording()
        hostTime = HostTime(seconds: 1_010)

        sut.pause()

        XCTAssertEqual(sut.phase, .paused)
        XCTAssertEqual(capture.recordings.count, 1)
        XCTAssertEqual(capture.recordings.first?.stopCount, 0)
        let meeting = try XCTUnwrap(MeetingFolder.all(in: root).first?.0)
        XCTAssertThrowsError(try meeting.lock()) { error in
            XCTAssertEqual(error as? MeetingLockError, .held(meeting))
        }
    }

    func testTheRecordedTimeStopsWhilePausedAndLeavesOutThePause() async {
        await sut.toggleRecording()
        hostTime = HostTime(seconds: 1_010)
        sut.pause()
        XCTAssertTrue(visibleTitles.contains("Paused · 0:10"), "\(visibleTitles)")

        hostTime = HostTime(seconds: 1_040)
        sut.menuTick()
        XCTAssertTrue(visibleTitles.contains("Paused · 0:10"), "\(visibleTitles)")

        sut.resume()
        hostTime = HostTime(seconds: 1_045)
        sut.menuTick()
        XCTAssertTrue(visibleTitles.contains("● Recording · 0:15"), "\(visibleTitles)")
    }

    func testResumeHandsTheRecordingTheResumedClock() async throws {
        await sut.toggleRecording()
        let handle = try XCTUnwrap(capture.recordings.last)
        hostTime = HostTime(seconds: 1_010)
        sut.pause()
        let changesBeforeResume = stateChanges
        hostTime = HostTime(seconds: 1_040)

        sut.resume()

        XCTAssertEqual(handle.appliedClocks, [clock(pausedAt: 1_010), clock(pausedAt: 1_010, resumedAt: 1_040)])
        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(stateChanges, changesBeforeResume + 1)
    }

    func testTogglePausePausesWhileRecordingAndResumesWhilePaused() async throws {
        await sut.toggleRecording()
        let handle = try XCTUnwrap(capture.recordings.last)
        hostTime = HostTime(seconds: 1_010)

        sut.togglePause()
        XCTAssertEqual(sut.phase, .paused)

        hostTime = HostTime(seconds: 1_040)
        sut.togglePause()
        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(handle.appliedClocks, [clock(pausedAt: 1_010), clock(pausedAt: 1_010, resumedAt: 1_040)])
    }

    func testPauseWhilePausedAndResumeWhileRecordingChangeNothingAndTellNoOne() async throws {
        await sut.toggleRecording()
        let handle = try XCTUnwrap(capture.recordings.last)
        let controlsChangesWhileRecording = controlsChanges
        hostTime = HostTime(seconds: 1_010)
        sut.resume()
        XCTAssertEqual(handle.appliedClocks, [])
        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(controlsChanges, controlsChangesWhileRecording)

        sut.pause()
        let changesAfterPause = stateChanges
        let controlsChangesAfterPause = controlsChanges
        hostTime = HostTime(seconds: 1_020)
        sut.pause()

        XCTAssertEqual(handle.appliedClocks, [clock(pausedAt: 1_010)])
        XCTAssertEqual(sut.phase, .paused)
        XCTAssertEqual(stateChanges, changesAfterPause)
        XCTAssertEqual(controlsChanges, controlsChangesAfterPause)
    }

    func testRecordingCommandsWhileIdleDoNothingAndStartNothing() {
        sut.pause()
        sut.resume()
        sut.togglePause()
        sut.stopRecording()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(stateChanges, 0)
        XCTAssertEqual(capture.recordings.count, 0)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testRecordingCommandsWhileStartingDoNothing() async throws {
        microphone = .notDetermined
        var prompt: CheckedContinuation<Bool, Never>?
        answerMicrophonePrompt = { await withCheckedContinuation { prompt = $0 } }
        let firstClick = Task { await sut.toggleRecording() }
        await waitUntil { prompt != nil }

        sut.pause()
        sut.resume()
        sut.togglePause()
        sut.stopRecording()
        XCTAssertEqual(sut.phase, .starting)

        microphone = .granted
        prompt?.resume(returning: true)
        await firstClick.value

        let handle = try XCTUnwrap(capture.recordings.first)
        XCTAssertEqual(capture.recordings.count, 1)
        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(handle.appliedClocks, [])
        XCTAssertEqual(handle.stopCount, 0)
    }

    func testTheMenuOffersPauseWhileRecordingAndResumeWhilePaused() async throws {
        await sut.toggleRecording()
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "● Recording · 0:00", "Stop Recording Meeting", "Pause Recording",
                                       "Show Meeting Controls", "Restore Default Position", "Open Meetings Folder", ""])

        hostTime = HostTime(seconds: 1_010)
        let pause = try XCTUnwrap(item(titled: "Pause Recording"))
        _ = (pause.target as? NSObject)?.perform(pause.action, with: pause)

        XCTAssertEqual(sut.phase, .paused)
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Paused · 0:10", "Stop Recording Meeting", "Resume Recording",
                                       "Show Meeting Controls", "Restore Default Position", "Open Meetings Folder", ""])

        hostTime = HostTime(seconds: 1_040)
        let resume = try XCTUnwrap(item(titled: "Resume Recording"))
        _ = (resume.target as? NSObject)?.perform(resume.action, with: resume)

        XCTAssertEqual(sut.phase, .recording)
    }

    func testStopWhilePausedStopsTheRecordingAndMakesTheNotes() async throws {
        await sut.toggleRecording()
        hostTime = HostTime(seconds: 1_010)
        sut.pause()
        XCTAssertEqual(sut.phase, .paused)

        sut.stopRecording()
        await sut.waitUntilIdle()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(capture.recordings.first?.stopCount, 1)
        XCTAssertEqual(notifications, ["Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary."])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testAnInterruptionWhilePausedEndsTheMeeting() async {
        await sut.toggleRecording()
        hostTime = HostTime(seconds: 1_010)
        sut.pause()
        XCTAssertEqual(sut.phase, .paused)

        capture.interrupt(reason: "The display was disconnected.")

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(notifications, ["Recording Stopped: The display was disconnected. Ku-Ka makes notes from what it recorded. To record the rest, choose Start Recording Meeting."])
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary.")
    }

    func testTheOpenMenuShowsIndependentMicrophoneAndMacAudioReadings() async throws {
        await sut.toggleRecording()
        try XCTUnwrap(capture.recordings.last).levels = RecordingAudioLevels(microphone: 0.25, system: 0.75)

        sut.menuWillOpen()

        let meterItem = try XCTUnwrap(menu.items.first { $0.view != nil })
        XCTAssertFalse(meterItem.isHidden)
        let indicators = levelIndicators(in: try XCTUnwrap(meterItem.view))
        XCTAssertEqual(indicators.map { $0.accessibilityLabel() }, ["Microphone audio level", "Mac audio level"])
        XCTAssertEqual(indicators.map(\.doubleValue), [0.25, 0.75])
    }

    func testStoppingAndRestartingCannotShowThePreviousRecordingLevels() async throws {
        await sut.toggleRecording()
        try XCTUnwrap(capture.recordings.last).levels = RecordingAudioLevels(microphone: 1, system: 0.5)
        sut.menuWillOpen()
        let meterItem = try XCTUnwrap(menu.items.first { $0.view != nil })
        XCTAssertEqual(levelIndicators(in: try XCTUnwrap(meterItem.view)).map(\.doubleValue), [1, 0.5])

        await sut.toggleRecording()
        await sut.waitUntilIdle()
        XCTAssertTrue(meterItem.isHidden)

        await sut.toggleRecording()
        XCTAssertFalse(meterItem.isHidden)
        XCTAssertEqual(levelIndicators(in: try XCTUnwrap(meterItem.view)).map(\.doubleValue), [0, 0])
    }

    func testAnInterruptionHidesTheRecordingMeters() async throws {
        await sut.toggleRecording()
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

        await sut.toggleRecording()

        let meterItem = try XCTUnwrap(menu.items.first { $0.view != nil })
        XCTAssertTrue(meterItem.isHidden)
        await sut.waitUntilIdle()
    }

    func testStatusMenuCloseStopsMeterUpdatesAndReopenReadsCurrentLevels() async throws {
        await sut.toggleRecording()
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
        await sut.toggleRecording()

        await sut.toggleRecording()
        await sut.waitUntilIdle()

        XCTAssertEqual(sut.phase, .idle)
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

        await sut.toggleRecording()
        await sut.toggleRecording()
        await sut.waitUntilIdle()

        let meeting = try XCTUnwrap(MeetingFolder.all(in: root).first?.0)
        XCTAssertEqual(try meeting.read(.summary), "# Meeting on 2026-10-23 at 14:02\n\n## Summary\nShip Friday.\n")
    }

    func testCaptureEndingOnItsOwnSaysSoAtOnceAndProcessesWhatWasRecorded() async throws {
        await sut.toggleRecording()

        capture.interrupt(reason: "The display was disconnected.")

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(notifications, ["Recording Stopped: The display was disconnected. Ku-Ka makes notes from what it recorded. To record the rest, choose Start Recording Meeting."])
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary.")
    }

    func testACaptureThatEndsWhileStartingIsReportedAndProcessed() async throws {
        capture.endsWhileStarting = "The microphone stopped."

        await sut.toggleRecording()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(notifications, ["Recording Stopped: The microphone stopped. Ku-Ka makes notes from what it recorded. To record the rest, choose Start Recording Meeting."])
        XCTAssertEqual(liveTranscriber.starts.count, 0)
        await sut.waitUntilIdle()
        XCTAssertEqual(notifications.last, "Meeting Notes Ready: Meeting on 2026-10-23 at 14:02. Click to open the summary.")
    }

    func testCaptureThatCannotStartLeavesNoFolderAndSaysWhy() async {
        capture.startError = TestError(errorDescription: "No display is available to capture audio from.")

        await sut.toggleRecording()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(alerts, ["No display is available to capture audio from."])
        XCTAssertEqual(permissionWindows, 0)
        XCTAssertEqual(notifications, [])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testMissingScreenRecordingSaysWhyAndOffersThePermissionsWindow() async {
        screenRecording = false

        await sut.toggleRecording()

        XCTAssertEqual(alerts, ["Ku-Ka needs Screen Recording permission to record the other people on the call."])
        XCTAssertEqual(permissionWindows, 1)
        XCTAssertEqual(capture.recordings.count, 0)
        XCTAssertEqual(meetingNames(), [])
        XCTAssertEqual(visibleTitles, ["Meeting Notes", "Start Recording Meeting", "Open Meetings Folder", ""])
    }

    func testADeniedMicrophoneSaysWhyAndOffersThePermissionsWindow() async {
        microphone = .denied

        await sut.toggleRecording()

        XCTAssertEqual(alerts, ["Ku-Ka needs Microphone permission to record your side of the call."])
        XCTAssertEqual(permissionWindows, 1)
        XCTAssertEqual(sut.phase, .idle)
    }

    func testAllowingTheMicrophonePromptStartsTheRecording() async {
        microphone = .notDetermined
        answerMicrophonePrompt = { [unowned self] in microphone = .granted; return true }

        await sut.toggleRecording()

        XCTAssertEqual(sut.phase, .recording)
        XCTAssertEqual(alerts, [])
        XCTAssertEqual(permissionWindows, 0)
    }

    func testRefusingTheMicrophonePromptRecordsNothingAndSaysWhy() async {
        microphone = .notDetermined
        var prompts = 0
        answerMicrophonePrompt = { [unowned self] in prompts += 1; microphone = .denied; return false }

        await sut.toggleRecording()

        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(capture.recordings.count, 0)
        XCTAssertEqual(alerts, ["Ku-Ka needs Microphone permission to record your side of the call."])
    }

    func testASecondClickWhileTheMicrophonePromptIsUpStartsNothing() async {
        microphone = .notDetermined
        var prompt: CheckedContinuation<Bool, Never>?
        answerMicrophonePrompt = { await withCheckedContinuation { prompt = $0 } }
        let firstClick = Task { await sut.toggleRecording() }
        await waitUntil { prompt != nil }
        XCTAssertTrue(visibleTitles.contains("Starting Recording"))
        XCTAssertEqual(item(titled: "Start Recording Meeting").map(sut.validateMenuItem), false, "the record item is disabled while starting")

        await sut.toggleRecording()
        microphone = .granted
        prompt?.resume(returning: true)
        await firstClick.value

        XCTAssertEqual(capture.recordings.count, 1)
        XCTAssertEqual(sut.phase, .recording)
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
        let answers = heard.prefix(skipped).map { #"{"heard": "\#($0)", "answer": "skipped"}"# }
        try meeting.write(#"{"answers": [\#(answers.joined(separator: ", "))]}"#, to: .answers)
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

    func testElapsedTimeShowsHoursOnlyWhenNeeded() {
        XCTAssertEqual(MeetingNotesController.formatElapsed(0), "0:00")
        XCTAssertEqual(MeetingNotesController.formatElapsed(245), "4:05")
        XCTAssertEqual(MeetingNotesController.formatElapsed(3729), "1:02:09")
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
