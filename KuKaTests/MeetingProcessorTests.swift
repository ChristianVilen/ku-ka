import XCTest
@testable import KuKa

@MainActor
final class MeetingProcessorTests: XCTestCase {
    private struct TestError: LocalizedError {
        let errorDescription: String?
    }

    private var whisper: FakeTranscriber!
    private var apple: FakeTranscriber!
    private var labeller: FakeRoomLabeller!
    private var runner: FakeCommandRunner!
    private var trashed: [String] = []
    private var progress: [MeetingProgress] = []
    /// Read by the processor at each use, so a test can change the list between two runs.
    private var knownWords = KnownWordsList.empty

    override func setUp() async throws {
        whisper = makeTranscriber(named: "Whisper")
        apple = makeTranscriber(named: "Apple")
        labeller = FakeRoomLabeller()
        runner = FakeCommandRunner()
        runner.results["agy"] = .success(CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: ""))
        trashed = []
        progress = []
        knownWords = .empty
    }

    private func makeTranscriber(named name: String) -> FakeTranscriber {
        let transcriber = FakeTranscriber(name: name)
        transcriber.byFileName["them.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 1, end: 3, text: "Let's ship on Friday")], duration: 60))
        transcriber.byFileName["me.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 4, end: 5, text: "Sounds good")], duration: 59))
        return transcriber
    }

    /// Gives the microphone track two segments, each inside its own voice, so the transcript has
    /// room labels.
    private func twoVoices(on transcriber: FakeTranscriber) throws -> RoomLabels {
        transcriber.byFileName["me.caf"] = .success(TrackTranscript(segments: [
            TranscriptSegment(start: 4, end: 5, text: "Sounds good, I can ship it"),
            TranscriptSegment(start: 6, end: 7, text: "Friday works for me too"),
        ], duration: 59))
        return .voices(try XCTUnwrap(RoomVoices([VoiceTurn(voice: 7, start: 3.5, end: 5.5),
                                                 VoiceTurn(voice: 3, start: 5.5, end: 7.5)])))
    }

    private func makeProcessor(transcribers: [Transcribing]? = nil, runner: CommandRunning? = nil) -> MeetingProcessor {
        MeetingProcessor(
            transcribers: transcribers ?? [whisper, apple],
            roomLabeller: labeller,
            summarizer: Summarizer(runner: runner ?? self.runner, home: URL(fileURLWithPath: "/Users/test"),
                                   isExecutable: { _ in true }),
            knownWords: { [unowned self] in knownWords },
            trash: { [unowned self] url in
                trashed.append(url.lastPathComponent)
                try FileManager.default.removeItem(at: url)
            },
            now: { localDate(2026, 10, 23, 15, 0) })
    }

    private func makeMeeting() throws -> MeetingFolder {
        let meeting = try MeetingFolder.create(in: try makeTemporaryDirectory(), startingAt: localDate(2026, 10, 23, 14, 2))
        for track in MeetingTrack.allCases {
            FileManager.default.createFile(atPath: meeting.audioURL(track).path, contents: Data())
        }
        return meeting
    }

    private func process(_ meeting: MeetingFolder, with processor: MeetingProcessor? = nil) async -> MeetingOutcome {
        await (processor ?? makeProcessor()).process(meeting) { [unowned self] in progress.append($0) }
    }

    private func audioExists(_ meeting: MeetingFolder) -> Bool {
        FileManager.default.fileExists(atPath: meeting.audioURL(.system).path)
    }

    func testFirstRunWritesTranscriptAndSummaryAndTrashesTheAudio() async throws {
        let meeting = try makeMeeting()

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(progress, [.step(.transcribe), .step(.summarize)])
        XCTAssertEqual(try meeting.read(.transcript), """
        # Meeting on 2026-10-23 at 14:02

        Duration: 00:01:00

        Transcript by Whisper.

        "Me" is the microphone of the Mac that recorded the meeting. It hears the person who recorded the meeting and anyone in the same room. "Them" is everyone else on the call.

        **[00:00:01] Them:** Let's ship on Friday

        **[00:00:04] Me:** Sounds good

        """)
        XCTAssertEqual(try meeting.read(.summary), """
        # Meeting on 2026-10-23 at 14:02

        ## Summary
        Ship Friday.

        """)
        XCTAssertEqual(trashed, ["audio"])
        XCTAssertEqual(meeting.stage(), .done)
    }

    func testTheSummaryFromAFallbackCLIHasNoFooter() async throws {
        let meeting = try makeMeeting()
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: "authentication failed"))
        runner.results["claude"] = .success(CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: ""))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.summary), "# Meeting on 2026-10-23 at 14:02\n\n## Summary\nShip Friday.\n")
    }

    func testAMissingSpeechModelIsDownloadedForTheConfiguredLanguageFirst() async throws {
        let meeting = try makeMeeting()
        whisper.modelIsMissing = true
        let processor = MeetingProcessor(
            transcribers: [whisper, apple],
            roomLabeller: labeller,
            summarizer: Summarizer(runner: runner, home: URL(fileURLWithPath: "/Users/test"), isExecutable: { _ in true }),
            knownWords: { .empty },
            locale: { Locale(identifier: "de-DE") },
            trash: { try FileManager.default.removeItem(at: $0) })

        let outcome = await process(meeting, with: processor)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(progress, [.step(.transcribe), .downloading(.speech), .step(.transcribe), .step(.summarize)])
        XCTAssertEqual(whisper.downloads, ["de-DE"])
        XCTAssertEqual(whisper.loads, ["de-DE"])
    }

    func testWhisperTranscribesBothTracksWithOneLoadWhenItCanStart() async throws {
        let meeting = try makeMeeting()

        _ = await process(meeting)

        XCTAssertTrue(try meeting.read(.transcript).contains("\n\nTranscript by Whisper.\n\n"))
        XCTAssertEqual(whisper.loads, ["en-US"])
        XCTAssertEqual(whisper.transcribed, ["me.caf", "them.caf"])
        XCTAssertEqual(apple.loads, [])
        XCTAssertEqual(apple.downloads, [])
    }

    func testAppleTranscribesWhenWhisperCannotStartAndTheTranscriptSaysWhy() async throws {
        let rows: [(stage: TranscriberFailure.Stage, error: String, bullet: String, whisperDownloads: [String])] = [
            (.unavailable, "Whisper does not support eo.",
             "- Whisper cannot be used: Whisper does not support eo.", []),
            (.download, "The Internet connection appears to be offline.",
             "- Whisper could not download its model: The Internet connection appears to be offline.", ["en-US"]),
            (.load, "The model files are damaged.",
             "- Whisper could not load its model: The model files are damaged.", ["en-US"]),
        ]
        for row in rows {
            let meeting = try makeMeeting()
            whisper = makeTranscriber(named: "Whisper")
            apple = makeTranscriber(named: "Apple")
            whisper.modelIsMissing = true
            whisper.failure = (row.stage, MeetingStepError(row.error))

            let outcome = await process(meeting)

            XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)), "\(row.stage)")
            XCTAssertEqual(try meeting.read(.transcript), """
            # Meeting on 2026-10-23 at 14:02

            Duration: 00:01:00

            Transcript by Apple. Tried first:

            \(row.bullet)

            "Me" is the microphone of the Mac that recorded the meeting. It hears the person who recorded the meeting and anyone in the same room. "Them" is everyone else on the call.

            **[00:00:01] Them:** Let's ship on Friday

            **[00:00:04] Me:** Sounds good

            """, "\(row.stage)")
            XCTAssertEqual(whisper.downloads, row.whisperDownloads, "\(row.stage)")
            XCTAssertEqual(whisper.transcribed, [], "\(row.stage)")
            XCTAssertEqual(apple.loads, ["en-US"], "\(row.stage)")
        }
    }

    func testTheMenuLeavesTheDownloadStepWhenTheWhisperDownloadFails() async throws {
        let meeting = try makeMeeting()
        whisper.modelIsMissing = true
        whisper.failure = (.download, MeetingStepError("The Internet connection appears to be offline."))

        _ = await process(meeting)

        XCTAssertEqual(progress, [.step(.transcribe), .downloading(.speech), .step(.transcribe), .step(.summarize)])
    }

    func testNoSpeechModelDownloadShowsWhileAnotherKuKaHoldsTheDownloadLock() async throws {
        let meeting = try makeMeeting()
        whisper.modelIsMissing = true
        whisper.downloadStarts = false
        whisper.failure = (.download, MeetingStepError("Another Ku-Ka is downloading the Whisper model."))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(progress, [.step(.transcribe), .step(.summarize)])
        XCTAssertTrue(try meeting.read(.transcript).contains(
            "- Whisper could not download its model: Another Ku-Ka is downloading the Whisper model."))
        XCTAssertEqual(apple.loads, ["en-US"])
    }

    func testFallbackDiagnosticsStayOnDiskButDoNotEnterTheSummaryPrompt() async throws {
        let meeting = try makeMeeting()
        whisper.failure = (.load, MeetingStepError("The model could not load."))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertTrue(try meeting.read(.transcript).contains("Whisper could not load its model: The model could not load."))
        let prompt = try XCTUnwrap(runner.calls.first?.arguments.last)
        XCTAssertEqual(prompt.components(separatedBy: "Transcript:\n\n").last, """
        **[00:00:01] Them:** Let's ship on Friday

        **[00:00:04] Me:** Sounds good

        """)
    }

    func testRoomVoicesLabelTheMicrophoneLinesInTheTranscript() async throws {
        let meeting = try makeMeeting()
        labeller.result = try twoVoices(on: whisper)

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.transcript), """
        # Meeting on 2026-10-23 at 14:02

        Duration: 00:01:00

        Transcript by Whisper.

        "Room 1", "Room 2", and so on are voices on the microphone of the Mac that recorded the meeting. The microphone hears the person who recorded the meeting and anyone in the same room. Ku-Ka told the voices apart on this Mac and numbered them in the order they first spoke. Two people with similar voices can share one label, and one person can get two labels. No label tells which voice is the person who recorded the meeting. "Them" is everyone else on the call.

        **[00:00:01] Them:** Let's ship on Friday

        **[00:00:04] Room 1:** Sounds good, I can ship it

        **[00:00:06] Room 2:** Friday works for me too

        """)
    }

    func testTheRoomLabellerGetsTheMicrophoneTrackAfterBothTracksAreTranscribed() async throws {
        let meeting = try makeMeeting()
        let whisper = self.whisper!
        var transcribedBeforeLabelling: [String] = []
        labeller.onLabel = { transcribedBeforeLabelling = whisper.transcribed }

        _ = await process(meeting)

        XCTAssertEqual(labeller.calls, ["label me.caf"])
        XCTAssertEqual(transcribedBeforeLabelling, ["me.caf", "them.caf"])
    }

    func testRoomLabelsAlsoRunWhenAppleWroteTheText() async throws {
        let meeting = try makeMeeting()
        whisper.failure = (.load, MeetingStepError("The model files are damaged."))
        labeller.result = try twoVoices(on: apple)

        _ = await process(meeting)

        let transcript = try meeting.read(.transcript)
        XCTAssertTrue(transcript.contains("\n\nTranscript by Apple. Tried first:\n\n"))
        XCTAssertTrue(transcript.contains(
            "**[00:00:04] Room 1:** Sounds good, I can ship it\n\n**[00:00:06] Room 2:** Friday works for me too\n"))
    }

    func testARoomLabelFailureKeepsMeAndTheMeetingStillFinishes() async throws {
        let meeting = try makeMeeting()
        labeller.result = .failed(.load("Model is corrupt."))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.transcript), """
        # Meeting on 2026-10-23 at 14:02

        Duration: 00:01:00

        Transcript by Whisper.

        There are no room labels. SpeakerKit could not load its model: Model is corrupt.

        "Me" is the microphone of the Mac that recorded the meeting. It hears the person who recorded the meeting and anyone in the same room. "Them" is everyone else on the call.

        **[00:00:01] Them:** Let's ship on Friday

        **[00:00:04] Me:** Sounds good

        """)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.url(for: .failure).path))
        let prompt = try XCTUnwrap(runner.calls.first?.arguments.last)
        XCTAssertFalse(prompt.contains("There are no room labels"))
        XCTAssertEqual(labeller.calls, ["label me.caf"])
    }

    func testTheSpeakerModelDownloadStepEndsWhenTheDownloadEnds() async throws {
        let meeting = try makeMeeting()
        labeller.modelIsMissing = true
        var events: [String] = []
        labeller.onDownloadEnd = { events.append("download ended") }
        labeller.onLabel = { events.append("label") }

        let outcome = await makeProcessor().process(meeting) { events.append($0.title) }

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(events, ["Transcribing", "Downloading speaker model", "download ended", "Transcribing", "label",
                                "Summarizing"])
    }

    func testAFailedSpeakerModelDownloadKeepsMeWithTheReasonAndNeverLabels() async throws {
        let meeting = try makeMeeting()
        labeller.modelIsMissing = true
        labeller.downloadError = MeetingStepError("The Internet connection appears to be offline.")

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(progress, [.step(.transcribe), .downloading(.speaker), .step(.transcribe), .step(.summarize)])
        XCTAssertEqual(labeller.calls, ["download"])
        let transcript = try meeting.read(.transcript)
        XCTAssertTrue(transcript.contains(
            "\n\nThere are no room labels. SpeakerKit could not download its model: The Internet connection appears to be offline.\n\n"))
        XCTAssertTrue(transcript.contains("**[00:00:04] Me:** Sounds good"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.url(for: .failure).path))
    }

    private func roomLabelsMarker(_ meeting: MeetingFolder) -> String {
        meeting.url.appendingPathComponent(".room-labels-started").path
    }

    func testAMarkerExistsOnlyWhileTheLabellerLabels() async throws {
        let meeting = try makeMeeting()
        var markerWhileLabelling: Bool?
        labeller.onLabel = { [unowned self] in
            markerWhileLabelling = FileManager.default.fileExists(atPath: roomLabelsMarker(meeting))
        }

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(markerWhileLabelling, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: roomLabelsMarker(meeting)))
    }

    func testAMarkerLeftByAnEarlierAttemptSkipsRoomLabels() async throws {
        let meeting = try makeMeeting()
        FileManager.default.createFile(atPath: roomLabelsMarker(meeting), contents: Data())
        labeller.modelIsMissing = true
        labeller.result = try twoVoices(on: whisper)

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(labeller.calls, [])
        let transcript = try meeting.read(.transcript)
        XCTAssertTrue(transcript.contains("\n\nThere are no room labels. Ku-Ka skipped them, because an earlier attempt "
            + "stopped while it told the voices apart, for example in a crash.\n\n"), transcript)
        XCTAssertTrue(transcript.contains("**[00:00:04] Me:** Sounds good, I can ship it"), transcript)
    }

    func testAMicrophoneTrackLongerThanThreeHoursIsNeverLabelled() async throws {
        for (duration, calls) in [(3.0 * 60 * 60, ["download", "label me.caf"]), (3.0 * 60 * 60 + 1, [])] {
            let meeting = try makeMeeting()
            labeller = FakeRoomLabeller()
            labeller.modelIsMissing = true
            whisper.byFileName["me.caf"] = .success(TrackTranscript(
                segments: [TranscriptSegment(start: 4, end: 5, text: "Sounds good")], duration: duration))

            let outcome = await process(meeting)

            XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)), "\(duration) s")
            XCTAssertEqual(labeller.calls, calls, "\(duration) s")
            XCTAssertEqual(try meeting.read(.transcript).contains(
                "\n\nThere are no room labels. Ku-Ka skipped them, because the microphone track is longer than 3 hours.\n\n"),
                calls.isEmpty, "\(duration) s")
        }
    }

    func testAMicrophoneWithOnlyEchoesIsNeverLabelled() async throws {
        let meeting = try makeMeeting()
        whisper.byFileName["me.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 1.5, end: 3.2, text: "Let's ship on Friday")], duration: 59))
        labeller.modelIsMissing = true
        labeller.result = .failed(.load("Model is corrupt."))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(labeller.calls, [])
        XCTAssertEqual(progress, [.step(.transcribe), .step(.summarize)])
        XCTAssertFalse(try meeting.read(.transcript).contains("There are no room labels"))
    }

    func testAFailedTranscriptionNeverAsksForRoomLabels() async throws {
        let meeting = try makeMeeting()
        whisper.byFileName["them.caf"] = .failure(TestError(errorDescription: "Out of memory."))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .failed(.transcribe, message: "Out of memory."))
        XCTAssertEqual(labeller.calls, [])
    }

    func testWhenNoTranscriberCanStartErrorMdListsEachReason() async throws {
        let meeting = try makeMeeting()
        whisper.failure = (.unavailable, MeetingStepError("Whisper does not support eo."))
        apple.failure = (.load, MeetingStepError("The speech model is missing."))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .failed(.transcribe, message: """
        Whisper cannot be used: Whisper does not support eo.
        Apple could not load its model: The speech model is missing.
        """))
        XCTAssertEqual(try meeting.read(.failure), """
        # Transcription Failed

        2026-10-23 15:00

        Whisper cannot be used: Whisper does not support eo.
        Apple could not load its model: The speech model is missing.

        Choose Retry Failed Meeting in the Ku-Ka menu to try again.

        """)
        XCTAssertTrue(audioExists(meeting))
    }

    func testTheCLIGetsTheTranscriptFromDisk() async throws {
        let meeting = try makeMeeting()
        try meeting.write("**[00:00:07] Me:** This was saved by an earlier run.", to: .transcript)

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        let prompt = try XCTUnwrap(runner.calls.first?.arguments.last)
        XCTAssertEqual(prompt.components(separatedBy: "Transcript:\n\n").last,
                       "**[00:00:07] Me:** This was saved by an earlier run.")
    }

    func testTheSummaryLeavesOutTheReviewBlockOfTheReply() async throws {
        let meeting = try makeMeeting()
        runner.results["agy"] = .success(CommandResult(termination: .exited(0), stdout: """
        ## Summary
        Ship Friday.

        ```ku-ka-review
        [{"heard": "Friday", "suggestion": null, "kind": "term", "quote": "Let's ship on Friday", "reason": "a test"}]
        ```

        """, stderr: ""))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.summary), """
        # Meeting on 2026-10-23 at 14:02

        ## Summary
        Ship Friday.

        """)
    }

    func testATranscriptionFailureAfterLoadingWritesTheReasonKeepsTheAudioAndDoesNotFallBack() async throws {
        let meeting = try makeMeeting()
        whisper.byFileName["them.caf"] = .failure(TestError(errorDescription: "Whisper could not transcribe them.caf: Out of memory."))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .failed(.transcribe, message: "Whisper could not transcribe them.caf: Out of memory."))
        let errorText = """
        # Transcription Failed

        2026-10-23 15:00

        Whisper could not transcribe them.caf: Out of memory.

        Choose Retry Failed Meeting in the Ku-Ka menu to try again.

        """
        XCTAssertEqual(try meeting.read(.failure), errorText)
        XCTAssertEqual(meeting.stage(), .failed(.transcribe))
        XCTAssertTrue(audioExists(meeting))
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(runner.calls.count, 0)
        XCTAssertEqual(whisper.loads, ["en-US"])
        XCTAssertEqual(apple.loads, [])
    }

    func testNoSpeechEndsTheMeetingAndKeepsTheAudio() async throws {
        let meeting = try makeMeeting()
        whisper.byFileName = [:]

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .noSpeech)
        XCTAssertEqual(meeting.stage(), .done)
        XCTAssertEqual(try meeting.read(.transcript), """
        # Meeting on 2026-10-23 at 14:02

        Duration: 00:00:00

        Transcript by Whisper.

        "Me" is the microphone of the Mac that recorded the meeting. It hears the person who recorded the meeting and anyone in the same room. "Them" is everyone else on the call.

        No speech was detected.

        """)
        XCTAssertEqual(try meeting.read(.summary), """
        # Meeting on 2026-10-23 at 14:02

        No speech was detected, so there is no summary. The audio is in the meeting folder.

        """)
        XCTAssertTrue(audioExists(meeting))
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(runner.calls.count, 0)
    }

    func testAMeetingFolderThatIsGoneEndsWithoutAFailure() async throws {
        let meeting = try makeMeeting()
        try FileManager.default.removeItem(at: meeting.url)

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.url.path))
    }

    func testAMeetingThatAnotherWriterHoldsIsLeftAlone() async throws {
        let meeting = try makeMeeting()
        let otherWriter = try XCTUnwrap(meeting.lock())

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .busy)
        XCTAssertEqual(progress, [])
        XCTAssertEqual(meeting.stage(), .pending(.transcribe))
        otherWriter.release()
    }

    func testAMeetingFolderThatCannotBeLockedFailsWithTheReason() async throws {
        let meeting = try makeMeeting()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: meeting.url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.url.path) }

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .failed(.transcribe, message: "Ku-Ka could not lock the meeting folder \(meeting.url.path): Permission denied."))
        XCTAssertEqual(progress, [])
    }

    func testASummaryFailureKeepsTheTranscriptAndListsEachCLI() async throws {
        let meeting = try makeMeeting()
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: "authentication failed"))
        runner.results["claude"] = .success(CommandResult(termination: .timedOut, stdout: "", stderr: ""))

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .failed(.summarize, message: "agy exited with status 1: authentication failed\nclaude took too long and was stopped"))
        XCTAssertEqual(try meeting.read(.failure), """
        # Summary Failed

        2026-10-23 15:00

        agy exited with status 1: authentication failed
        claude took too long and was stopped

        Choose Retry Failed Meeting in the Ku-Ka menu to try again.

        """)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.url(for: .transcript).path))
        XCTAssertEqual(trashed, ["audio"])
    }

    func testAFailedMeetingWaitsForRetry() async throws {
        let meeting = try makeMeeting()
        try meeting.write("Earlier failure", to: .failure)

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .failed(.transcribe, message: "An earlier attempt failed. See error.md in the meeting folder."))
        XCTAssertEqual(progress, [])
    }

    func testRetryResumesAtTheFailedStep() async throws {
        let meeting = try makeMeeting()
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: ""))
        _ = await process(meeting)
        try meeting.clearFailure()
        runner.results["claude"] = .success(CommandResult(termination: .exited(0), stdout: "## Summary\nShip Friday.", stderr: ""))
        whisper.byFileName["them.caf"] = .failure(TestError(errorDescription: "must not transcribe again"))
        progress = []

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(progress, [.step(.summarize)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.url(for: .failure).path))
    }

    func testRecoveryAfterAStopAtEachPointRunsOnlyTheMissingSteps() async throws {
        let cases: [(name: String, files: [MeetingDocument], keepAudio: Bool, steps: [MeetingStep], trashed: [String])] = [
            ("stopped before the transcript", [], true, [.transcribe, .summarize], ["audio"]),
            ("stopped before the audio went to the Trash", [.transcript], true, [.summarize], ["audio"]),
            ("stopped while summarizing", [.transcript], false, [.summarize], []),
            ("already done", [.transcript, .summary], false, [], []),
        ]
        for row in cases {
            let meeting = try makeMeeting()
            for document in row.files { try meeting.write("# \(document.rawValue)", to: document) }
            if !row.keepAudio { try FileManager.default.removeItem(at: meeting.audioURL(.system).deletingLastPathComponent()) }
            progress = []
            trashed = []

            let outcome = await process(meeting)

            XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)), row.name)
            XCTAssertEqual(progress, row.steps.map { .step($0) }, row.name)
            XCTAssertEqual(trashed, row.trashed, row.name)
        }
    }

    func testCancellingLeavesTheMeetingPendingWithoutAnErrorFile() async throws {
        let meeting = try makeMeeting()
        let processor = makeProcessor(transcribers: [SuspendedTranscriber(name: "Whisper"), apple])
        let run = Task { await process(meeting, with: processor) }
        await waitUntil { !progress.isEmpty }
        XCTAssertEqual(progress, [.step(.transcribe)])

        run.cancel()

        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(meeting.stage(), .pending(.transcribe))
    }

    func testCancellationDiscardsEvenSuccessfulTrackResultsBeforeWritingDocuments() async throws {
        for empty in [true, false] {
            let meeting = try makeMeeting()
            let transcriber = CancelledReturningTranscriber(empty: empty)
            let processor = makeProcessor(transcribers: [transcriber, apple])
            let run = Task { await process(meeting, with: processor) }

            let outcome = await run.value

            XCTAssertEqual(outcome, .cancelled)
            XCTAssertEqual(meeting.stage(), .pending(.transcribe))
            XCTAssertTrue(audioExists(meeting))
            for document in MeetingDocument.allCases {
                XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.url(for: document).path), document.rawValue)
            }
            XCTAssertEqual(apple.loads, [])
        }
    }

    func testCancellingDuringRoomLabellingWritesNothingAndLeavesTheMeetingPending() async throws {
        for result in [try twoVoices(on: whisper), .failed(.download("cancelled"))] {
            let meeting = try makeMeeting()
            labeller.result = result
            labeller.cancelsItsTask = true
            let processor = makeProcessor()
            let run = Task { await process(meeting, with: processor) }

            let outcome = await run.value

            XCTAssertEqual(outcome, .cancelled, "\(result)")
            XCTAssertEqual(meeting.stage(), .pending(.transcribe), "\(result)")
            XCTAssertTrue(audioExists(meeting), "\(result)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: roomLabelsMarker(meeting)), "\(result)")
            for document in MeetingDocument.allCases {
                XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.url(for: document).path),
                               "\(result): \(document.rawValue)")
            }
        }
    }

    func testCancellingDuringTheWhisperDownloadNeitherFailsNorFallsBack() async throws {
        let meeting = try makeMeeting()
        let suspended = SuspendedTranscriber(name: "Whisper")
        suspended.modelIsMissing = true
        let run = Task { await process(meeting, with: makeProcessor(transcribers: [suspended, apple])) }
        await waitUntil { progress.contains(.downloading(.speech)) }

        run.cancel()

        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(meeting.stage(), .pending(.transcribe))
        XCTAssertEqual(apple.downloads, [])
        XCTAssertEqual(apple.loads, [])
    }

    // MARK: - Known words

    private func hearConvio() {
        whisper.byFileName["them.caf"] = .success(TrackTranscript(
            segments: [TranscriptSegment(start: 1, end: 3, text: "Let's ask Convio and Yuri about Friday")], duration: 60))
    }

    private func reply(_ stdout: String) -> Result<CommandResult, Error> {
        .success(CommandResult(termination: .exited(0), stdout: stdout, stderr: ""))
    }

    private func promptTranscript() throws -> String {
        try XCTUnwrap(runner.calls.last?.arguments.last?.components(separatedBy: "Transcript:\n\n").last)
    }

    private func exists(_ document: MeetingDocument, in meeting: MeetingFolder) -> Bool {
        FileManager.default.fileExists(atPath: meeting.url(for: document).path)
    }

    private func removeAudio(of meeting: MeetingFolder) throws {
        try FileManager.default.removeItem(at: meeting.audioURL(.system).deletingLastPathComponent())
    }

    private let correctedLines = """
    **[00:00:01] Them:** Let's ask Konvio and Yuri about Friday

    **[00:00:04] Me:** Sounds good

    """

    func testTheTranscribeStepWritesTheHeardCopyWithTheTextOfTheTranscript() async throws {
        let meeting = try makeMeeting()
        var heardCopyBeforeSummarizing: String?

        _ = await makeProcessor().process(meeting) { event in
            if event == .step(.summarize) { heardCopyBeforeSummarizing = try? meeting.read(.heardTranscript) }
        }

        XCTAssertEqual(heardCopyBeforeSummarizing, try meeting.read(.transcript))

        let silent = try makeMeeting()
        whisper.byFileName = [:]
        let outcome = await process(silent)
        XCTAssertEqual(outcome, .noSpeech)
        XCTAssertEqual(try silent.read(.heardTranscript), try silent.read(.transcript))
    }

    func testAConfirmedFormIsFixedInTheTranscriptAndInTheTextTheCLIGets() async throws {
        let meeting = try makeMeeting()
        hearConvio()
        knownWords = KnownWordsList(markdown: "- Convio → **Konvio** ✓\n")

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.transcript), """
        # Meeting on 2026-10-23 at 14:02

        Duration: 00:01:00

        Transcript by Whisper.

        "Me" is the microphone of the Mac that recorded the meeting. It hears the person who recorded the meeting and anyone in the same room. "Them" is everyone else on the call.

        \(correctedLines)
        ---

        Known words applied: Convio → Konvio (1).

        """)
        XCTAssertEqual(try promptTranscript(), correctedLines, "no note for the CLI")
        XCTAssertTrue(try meeting.read(.heardTranscript).contains("**[00:00:01] Them:** Let's ask Convio and Yuri about Friday"))
    }

    func testOnlyTheKnownWordsThatOccurInTheTranscriptReachThePrompt() async throws {
        let meeting = try makeMeeting()
        hearConvio()
        knownWords = KnownWordsList(markdown: "- Convio → **Konvio** ✓\n- Brightlane → **Brytlane**\n")

        _ = await process(meeting)

        let prompt = try XCTUnwrap(runner.calls.first?.arguments.last)
        XCTAssertTrue(prompt.contains("\n- Convio -> Konvio\n"), prompt)
        XCTAssertFalse(prompt.contains("Brytlane"), prompt)
    }

    func testSummarizingAgainAfterAStopStartsFromTheHeardCopyWithTheListAsItIsNow() async throws {
        let meeting = try makeMeeting()
        try removeAudio(of: meeting)
        try meeting.write("**[00:00:01] Them:** Ask Convio and Yuri.\n", to: .heardTranscript)
        try meeting.write("**[00:00:01] Them:** Ask Konvio and Yuri.\n\n---\n\nKnown words applied: Convio → Konvio (1).\n",
                          to: .transcript)
        knownWords = KnownWordsList(markdown: "- Convio → **Konvio** ✓\n- Yuri → **Jyri** ✓\n")

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.transcript),
                       "**[00:00:01] Them:** Ask Konvio and Jyri.\n\n---\n\nKnown words applied: Convio → Konvio (1), Yuri → Jyri (1).\n")
        XCTAssertEqual(try meeting.read(.heardTranscript), "**[00:00:01] Them:** Ask Convio and Yuri.\n")
    }

    func testAFormConfirmedAfterAFailedSummaryIsFixedOnRetry() async throws {
        let meeting = try makeMeeting()
        hearConvio()
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: "authentication failed"))
        _ = await process(meeting)
        XCTAssertTrue(try meeting.read(.transcript).contains("Let's ask Convio"))
        knownWords = KnownWordsList(markdown: "- Convio → **Konvio** ✓\n")
        try meeting.clearFailure()
        runner.results["agy"] = reply("## Summary\nAsk Konvio.")

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertTrue(try meeting.read(.transcript).hasSuffix(correctedLines + "\n---\n\nKnown words applied: Convio → Konvio (1).\n"))
    }

    func testAMeetingTranscribedBeforeKnownWordsGetsAHeardCopyAndACorrectedTranscript() async throws {
        let meeting = try makeMeeting()
        try removeAudio(of: meeting)
        try meeting.write("**[00:00:01] Them:** Ask Convio.\n", to: .transcript)
        knownWords = KnownWordsList(markdown: "- Convio → **Konvio** ✓\n")

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.heardTranscript), "**[00:00:01] Them:** Ask Convio.\n")
        XCTAssertEqual(try meeting.read(.transcript),
                       "**[00:00:01] Them:** Ask Konvio.\n\n---\n\nKnown words applied: Convio → Konvio (1).\n")
    }

    func testAReplyWithAReviewBlockSavesItsQuestionsAndTheSummaryLeavesTheBlockOut() async throws {
        let meeting = try makeMeeting()
        hearConvio()
        runner.results["agy"] = reply("""
        ## Summary
        Ask Convio.

        ```ku-ka-review
        [{"heard": "Convio", "suggestion": "Konvio", "kind": "company", "quote": "Let's ask Convio and Yuri about Friday", "reason": "unknown company"},
         {"heard": "Quorix", "kind": "term", "quote": "Quorix is late.", "reason": "not in the transcript"}]
        ```
        """)

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.summary), "# Meeting on 2026-10-23 at 14:02\n\n## Summary\nAsk Convio.\n")
        let review = try XCTUnwrap(meeting.wordReview(knownWords: .empty))
        XCTAssertEqual(review.questions.map(\.heard), ["Convio"])
        XCTAssertEqual(review.questions.first?.suggestion, "Konvio")
        XCTAssertEqual(review.questions.first?.place, "Them at 00:00:01")
    }

    func testTheQuestionsAreSavedBeforeTheSummary() async throws {
        let meeting = try makeMeeting()
        hearConvio()
        runner.results["agy"] = reply("""
        ## Summary
        Ask Convio.

        ```ku-ka-review
        [{"heard": "Convio", "kind": "company", "quote": "Let's ask Convio and Yuri about Friday"}]
        ```
        """)
        let blocked = meeting.url(for: .questions).appendingPathComponent("a folder in the way")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        let outcome = await process(meeting)

        guard case .failed(.summarize, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(exists(.summary, in: meeting))
    }

    func testABrokenReviewBlockNeverFailsTheSummaryAndSavesNoQuestions() async throws {
        let meeting = try makeMeeting()
        runner.results["agy"] = reply("## Summary\nShip Friday.\n\n```ku-ka-review\n[{\"heard\": \n```\n")

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.summary), "# Meeting on 2026-10-23 at 14:02\n\n## Summary\nShip Friday.\n")
        XCTAssertFalse(exists(.questions, in: meeting))
    }

    func testARunWithoutQuestionsRemovesTheQuestionsOfAnEarlierStoppedRun() async throws {
        let meeting = try makeMeeting()
        try removeAudio(of: meeting)
        try meeting.write("**[00:00:01] Them:** Let's ship on Friday\n", to: .transcript)
        try meeting.write(#"{"questions": [{"heard": "Friday", "kind": "term", "quote": "Let's ship on Friday"}]}"#, to: .questions)

        let outcome = await process(meeting)

        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        XCTAssertFalse(exists(.questions, in: meeting))
    }

    // MARK: - Update Notes

    /// A done meeting whose notes Ku-Ka made with an empty list.
    private func makeDoneMeeting() async throws -> MeetingFolder {
        let meeting = try makeMeeting()
        hearConvio()
        let outcome = await process(meeting)
        XCTAssertEqual(outcome, .done(summary: meeting.url(for: .summary)))
        return meeting
    }

    func testUpdateNotesMakesTheNotesAgainWithTheListAsItIsNowAndKeepsTheReviewFiles() async throws {
        let meeting = try await makeDoneMeeting()
        let questions = #"{"questions": [{"heard": "Convio", "kind": "company", "quote": "Let's ask Convio and Yuri about Friday"}]}"#
        let answers = #"{"answers": [{"heard": "Convio", "answer": "right word", "word": "Konvio"}]}"#
        try meeting.write(questions, to: .questions)
        try meeting.write(answers, to: .answers)
        knownWords = KnownWordsList(markdown: "- Convio → **Konvio** ✓\n")
        runner.results["agy"] = reply("""
        ## Summary
        Ask Konvio.

        ```ku-ka-review
        [{"heard": "Yuri", "kind": "person", "quote": "Let's ask Konvio and Yuri about Friday"}]
        ```
        """)

        let outcome = await makeProcessor().updateNotes(meeting)

        XCTAssertEqual(outcome, .updated(summary: meeting.url(for: .summary)))
        XCTAssertTrue(try meeting.read(.transcript).hasSuffix(correctedLines + "\n---\n\nKnown words applied: Convio → Konvio (1).\n"))
        XCTAssertEqual(try promptTranscript(), correctedLines)
        XCTAssertEqual(try meeting.read(.summary), "# Meeting on 2026-10-23 at 14:02\n\n## Summary\nAsk Konvio.\n")
        XCTAssertEqual(try meeting.read(.questions), questions)
        XCTAssertEqual(try meeting.read(.answers), answers)
        XCTAssertEqual(meeting.stage(), .done)
        XCTAssertFalse(exists(.failure, in: meeting))
    }

    func testUpdateNotesAsksNoNewQuestions() async throws {
        let meeting = try await makeDoneMeeting()
        runner.results["agy"] = reply("""
        ## Summary
        Ask Convio.

        ```ku-ka-review
        [{"heard": "Convio", "kind": "company", "quote": "Let's ask Convio and Yuri about Friday"}]
        ```
        """)

        let outcome = await makeProcessor().updateNotes(meeting)

        XCTAssertEqual(outcome, .updated(summary: meeting.url(for: .summary)))
        XCTAssertEqual(try meeting.read(.summary), "# Meeting on 2026-10-23 at 14:02\n\n## Summary\nAsk Convio.\n")
        XCTAssertFalse(exists(.questions, in: meeting))
    }

    func testWhenEveryCLIFailsUpdateNotesKeepsTheOldSummaryAndWritesNoErrorFile() async throws {
        let meeting = try await makeDoneMeeting()
        let summary = try meeting.read(.summary)
        runner.results["agy"] = .success(CommandResult(termination: .exited(1), stdout: "", stderr: "authentication failed"))
        runner.results["claude"] = .success(CommandResult(termination: .timedOut, stdout: "", stderr: ""))

        let outcome = await makeProcessor().updateNotes(meeting)

        XCTAssertEqual(outcome, .summaryToolFailed(message: "agy exited with status 1: authentication failed\nclaude took too long and was stopped"))
        XCTAssertEqual(try meeting.read(.summary), summary)
        XCTAssertFalse(exists(.failure, in: meeting))
        XCTAssertEqual(meeting.stage(), .done)
    }

    func testAnUpdateThatCannotReadTheTranscriptFailsBeforeTheCLIAndWritesNoErrorFile() async throws {
        let meeting = try await makeDoneMeeting()
        let summary = try meeting.read(.summary)
        let callsBefore = runner.calls.count
        try FileManager.default.removeItem(at: meeting.url(for: .heardTranscript))
        try FileManager.default.removeItem(at: meeting.url(for: .transcript))

        let outcome = await makeProcessor().updateNotes(meeting)

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("transcript.md"), message)
        XCTAssertEqual(runner.calls.count, callsBefore, "no CLI ran")
        XCTAssertEqual(try meeting.read(.summary), summary)
        XCTAssertFalse(exists(.failure, in: meeting))
    }

    func testUpdateNotesLeavesALockedUnfinishedOrMissingMeetingAlone() async throws {
        let done = try await makeDoneMeeting()
        let callsBefore = runner.calls.count
        let otherWriter = try done.lock()
        let busy = await makeProcessor().updateNotes(done)
        otherWriter.release()

        let unfinished = try makeMeeting()
        try removeAudio(of: unfinished)
        try unfinished.write("**[00:00:01] Them:** Ask Convio.\n", to: .transcript)
        let notReady = await makeProcessor().updateNotes(unfinished)

        let gone = try makeMeeting()
        try FileManager.default.removeItem(at: gone.url)
        let missing = await makeProcessor().updateNotes(gone)

        XCTAssertEqual(busy, .busy)
        XCTAssertEqual(notReady, .notReady)
        XCTAssertEqual(missing, .notReady)
        XCTAssertEqual(runner.calls.count, callsBefore, "no CLI ran")
        XCTAssertEqual(unfinished.stage(), .pending(.summarize))
        XCTAssertFalse(exists(.heardTranscript, in: unfinished))
    }

    func testCancellingUpdateNotesReturnsCancelledAndKeepsTheSummary() async throws {
        let meeting = try await makeDoneMeeting()
        let summary = try meeting.read(.summary)
        let waiting = WaitingCommandRunner()
        let processor = makeProcessor(runner: waiting)
        let run = Task { await processor.updateNotes(meeting) }
        await waitUntil { waiting.started }

        run.cancel()

        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(try meeting.read(.summary), summary)
        XCTAssertEqual(meeting.stage(), .done)
        XCTAssertFalse(exists(.failure, in: meeting))
    }
}

/// Waits until its task is cancelled.
private final class WaitingCommandRunner: CommandRunning {
    private(set) var started = false

    func run(executable: URL, arguments: [String], input: String?, searchPath: [String],
             timeout: Duration) async throws -> CommandResult {
        started = true
        try await Task.sleep(for: .seconds(60))
        return CommandResult(termination: .exited(0), stdout: "## Summary\nToo late.", stderr: "")
    }
}

private final class CancelledReturningTranscriber: FakeTranscriber {
    let empty: Bool

    init(empty: Bool) {
        self.empty = empty
        super.init(name: "Cancelled Whisper")
    }

    override func transcribe(_ audio: URL) async throws -> TrackTranscript {
        withUnsafeCurrentTask { $0?.cancel() }
        return TrackTranscript(segments: empty ? [] : [TranscriptSegment(start: 0, end: 1, text: "Synthetic speech")],
                               duration: 61)
    }
}

private final class SuspendedTranscriber: FakeTranscriber {
    override func download(for locale: Locale, onStart: @MainActor () -> Void) async throws {
        await onStart()
        try await Task.sleep(for: .seconds(60))
    }

    override func transcribe(_ audio: URL) async throws -> TrackTranscript {
        try await Task.sleep(for: .seconds(60))
        return TrackTranscript(segments: [], duration: 0)
    }
}
