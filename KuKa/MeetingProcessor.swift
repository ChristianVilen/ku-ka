import Foundation

enum MeetingOutcome: Equatable {
    case done(summary: URL)
    case noSpeech
    case failed(MeetingStep, message: String)
    case cancelled
    /// Another recorder or processor holds the folder's lock.
    case busy
    /// The folder was moved or deleted.
    case gone
}

/// Update Notes never writes `error.md`: the meeting stays done, and its old `summary.md` stays
/// when every CLI fails.
enum NotesUpdateOutcome: Equatable {
    case updated(summary: URL)
    /// Every summary CLI failed. `transcript.md` was already written again, with the answers.
    case summaryToolFailed(message: String)
    /// Anything else failed, for example a read or a write in the meeting folder. `summary.md` did
    /// not change, and `transcript.md` may or may not have.
    case failed(message: String)
    case cancelled
    /// Another recorder or processor holds the folder's lock.
    case busy
    /// The meeting is not done, or its folder is gone.
    case notReady
}

@MainActor
struct MeetingProcessor {
    private let transcribers: [Transcribing]
    private let roomLabeller: RoomLabelling
    private let summarizer: Summarizer
    private let knownWords: () -> KnownWordsList
    private let locale: () -> Locale
    private let trash: (URL) throws -> Void
    private let now: () -> Date

    /// `roomLabeller` has no default value, so a test that forgets the fake does not compile
    /// instead of downloading a model. Nor has `knownWords`, so the app cannot forget the list. It is
    /// read once for each summary, never kept.
    init(transcribers: [Transcribing] = [WhisperKitTranscriber(), SpeechTranscriberAdapter()],
         roomLabeller: RoomLabelling,
         summarizer: Summarizer = Summarizer(),
         knownWords: @escaping () -> KnownWordsList,
         locale: @escaping () -> Locale = { Locale(identifier: "en-US") },
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         now: @escaping () -> Date = { Date() }) {
        self.transcribers = transcribers
        self.roomLabeller = roomLabeller
        self.summarizer = summarizer
        self.knownWords = knownWords
        self.locale = locale
        self.trash = trash
        self.now = now
    }

    /// Makes `transcript.md` and `summary.md` of a done meeting again, with the list as it is now.
    /// Asks no new questions, and leaves `review.json` and `review-skipped.json` alone.
    func updateNotes(_ meeting: MeetingFolder) async -> NotesUpdateOutcome {
        let lock: FileLock
        do {
            lock = try meeting.lock()
        } catch MeetingLockError.held {
            return .busy
        } catch {
            return .notReady
        }
        defer { lock.release() }
        guard meeting.stage() == .done else { return .notReady }
        do {
            try await writeNotes(meeting, asksQuestions: false)
        } catch {
            if Task.isCancelled { return .cancelled }
            if error is SummaryToolError { return .summaryToolFailed(message: error.localizedDescription) }
            return .failed(message: error.localizedDescription)
        }
        return .updated(summary: meeting.url(for: .summary))
    }

    func process(_ meeting: MeetingFolder, progress: (MeetingProgress) -> Void) async -> MeetingOutcome {
        let lock: FileLock
        do {
            lock = try meeting.lock()
        } catch MeetingLockError.held {
            return .busy
        } catch {
            switch meeting.stage() {
            case nil: return .gone
            case .done?: return .done(summary: meeting.url(for: .summary))
            case .pending(let step)?, .failed(let step)?: return fail(meeting, at: step, message: error.localizedDescription)
            }
        }
        defer { lock.release() }
        while true {
            if Task.isCancelled { return .cancelled }
            let stage = meeting.stage()
            switch stage {
            case nil:
                return .gone
            case .done?:
                return .done(summary: meeting.url(for: .summary))
            case .failed(let step)?:
                return .failed(step, message: "An earlier attempt failed. See error.md in the meeting folder.")
            case .pending(let step)?:
                progress(.step(step))
                do {
                    switch step {
                    case .transcribe:
                        guard try await transcribe(meeting, progress: progress) else { return .noSpeech }
                    case .summarize:
                        try await summarize(meeting)
                    }
                } catch {
                    if Task.isCancelled { return .cancelled }
                    return fail(meeting, at: step, message: error.localizedDescription)
                }
                if meeting.stage() == stage {
                    return fail(meeting, at: step, message: "The step finished, but the meeting folder did not change.")
                }
            }
        }
    }

    private func fail(_ meeting: MeetingFolder, at step: MeetingStep, message: String) -> MeetingOutcome {
        try? meeting.write(Self.failureText(step: step, message: message, at: now()), to: .failure)
        return .failed(step, message: message)
    }

    /// False when nobody spoke. The meeting is then done, and its audio stays
    /// in the folder.
    private func transcribe(_ meeting: MeetingFolder, progress: (MeetingProgress) -> Void) async throws -> Bool {
        let (tracks, transcriber, failures) = try await transcribeTracks(meeting, progress: progress)
        let rooms = try await labelRooms(meeting, tracks: tracks, progress: progress)
        try Task.checkCancellation()
        let lines = Transcript.merge(tracks, rooms: rooms)
        let duration = tracks.values.map(\.duration).max() ?? 0
        if lines.isEmpty {
            // Summary first: it marks the meeting done, so a crash before the
            // transcript is written cannot run the summary step, which would
            // trash the audio.
            try meeting.write(SummaryDocument.noSpeech(title: meeting.title), to: .summary)
        }
        let heard = Transcript.markdown(lines, title: meeting.title, duration: duration,
                                        by: transcriber, after: failures, rooms: rooms)
        try meeting.write(heard, to: .heardTranscript)
        try meeting.write(heard, to: .transcript)
        return !lines.isEmpty
    }

    /// The session lives only in here, so the Whisper model is released
    /// before the room labeller loads its own model.
    private func transcribeTracks(_ meeting: MeetingFolder, progress: (MeetingProgress) -> Void)
        async throws -> (tracks: [MeetingTrack: TrackTranscript], transcriber: String, failures: [TranscriberFailure]) {
        let (session, transcriber, failures) = try await startTranscriber(progress: progress)
        try Task.checkCancellation()
        var tracks: [MeetingTrack: TrackTranscript] = [:]
        for track in MeetingTrack.allCases where FileManager.default.fileExists(atPath: meeting.audioURL(track).path) {
            tracks[track] = try await session.transcribe(meeting.audioURL(track))
            try Task.checkCancellation()
        }
        return (tracks, transcriber, failures)
    }

    /// Without a microphone segment that the transcript keeps, nothing is downloaded or diarized.
    /// Throws only when the meeting folder cannot be written.
    private func labelRooms(_ meeting: MeetingFolder, tracks: [MeetingTrack: TrackTranscript],
                            progress: (MeetingProgress) -> Void) async throws -> RoomLabels {
        guard !Transcript.microphoneSpeech(tracks).isEmpty else { return .notDiarized }
        guard !meeting.roomLabelsStarted else { return .failed(.earlierAttemptStopped) }
        guard (tracks[.microphone]?.duration ?? 0) <= RoomLabelFailure.longestTrack else { return .failed(.tooLong) }
        if roomLabeller.needsDownload {
            do {
                try await downloading(.speaker, progress: progress) { try await roomLabeller.download(onStart: $0) }
            } catch {
                return .failed(.download(error.localizedDescription))
            }
        }
        try meeting.markRoomLabelsStarted()
        let rooms = await withTaskCancellationHandler {
            await roomLabeller.label(meeting.audioURL(.microphone))
        } onCancel: {
            // A quit ends the process before `label` returns. `onCancel` runs inside `cancel()`,
            // so the marker is gone before `MeetingNotesController.shutDown()` returns.
            try? meeting.clearRoomLabelsStarted()
        }
        try meeting.clearRoomLabelsStarted()
        return rooms
    }

    /// `download` calls its `onStart` right before the download really starts. Only then is the
    /// download reported, and when it ends, also after a failure, the step is Transcribing again.
    /// `download` does not escape. Swift does not let a non-escaping closure parameter get a
    /// closure that captures `progress`, so it is marked `@escaping`.
    private func downloading(_ model: MeetingModel, progress: (MeetingProgress) -> Void,
                             _ download: @escaping (_ onStart: @MainActor () -> Void) async throws -> Void) async throws {
        var started = false
        defer { if started { progress(.step(.transcribe)) } }
        try await download {
            started = true
            progress(.downloading(model))
        }
    }

    private func startTranscriber(progress: (MeetingProgress) -> Void) async throws
        -> (session: any TranscriptionSession, transcriber: String, failures: [TranscriberFailure]) {
        let locale = self.locale()
        var failures: [TranscriberFailure] = []
        for transcriber in transcribers {
            try Task.checkCancellation()
            var stage = TranscriberFailure.Stage.unavailable
            do {
                let needsDownload = try await transcriber.needsDownload(for: locale)
                try Task.checkCancellation()
                if needsDownload {
                    stage = .download
                    try await downloading(.speech, progress: progress) {
                        try await transcriber.download(for: locale, onStart: $0)
                    }
                }
                try Task.checkCancellation()
                stage = .load
                let session = try await transcriber.load(for: locale)
                try Task.checkCancellation()
                return (session, transcriber.name, failures)
            } catch {
                // URLSession reports a cancelled download as URLError(.cancelled),
                // not CancellationError, so the task is asked instead.
                if Task.isCancelled { throw error }
                failures.append(TranscriberFailure(transcriber: transcriber.name, stage: stage,
                                                   message: error.localizedDescription))
            }
        }
        throw MeetingStepError(failures.map(\.description).joined(separator: "\n"))
    }

    private func summarize(_ meeting: MeetingFolder) async throws {
        // Trash the audio here, not right after writing transcript.md: this
        // step runs only once transcript.md exists, so it also cleans up after
        // a crash between the two.
        do {
            try meeting.discardAudio(trash: trash)
        } catch {
            NSLog("Ku-Ka: could not move meeting audio to the Trash: \(error)")
        }
        try await writeNotes(meeting, asksQuestions: true)
    }

    /// The one place that applies known words. `transcript.md` is always made again from the heard
    /// copy and the list as it is now, so a second run gives the same file and a removed list line
    /// undoes its replacement. Writes `transcript.md`, then with `asksQuestions` the questions (or
    /// removes old ones), then `summary.md`, which marks the meeting done.
    private func writeNotes(_ meeting: MeetingFolder, asksQuestions: Bool) async throws {
        let heard = try meeting.heardTranscript()
        let list = knownWords()
        let corrected = Transcript.corrected(heard, by: list.corrector)
        try meeting.write(corrected.markdown, to: .transcript)
        let content = Transcript.contentForSummary(corrected.markdown)
        switch await summarizer.summarize(transcript: content, knownWords: list.relevant(to: content)) {
        case .written(let notes, let suspects, let cli, let earlier):
            if !earlier.isEmpty {
                NSLog("Ku-Ka: %@ wrote the notes of %@. Tried first: %@", cli.rawValue, meeting.name,
                      earlier.map(\.description).joined(separator: "; "))
            }
            if asksQuestions {
                try meeting.saveQuestions(WordQuestions.select(suspects, in: content, knownWords: list))
            }
            try meeting.write(SummaryDocument.markdown(title: meeting.title, body: notes), to: .summary)
        case .failed(let failures):
            throw SummaryToolError(errorDescription: failures.map(\.description).joined(separator: "\n"))
        }
    }

    static func failureText(step: MeetingStep, message: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return """
        # \(step.failureHeading)

        \(formatter.string(from: date))

        \(message)

        Choose Retry Failed Meeting in the Ku-Ka menu to try again.

        """
    }
}

struct MeetingStepError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Every summary CLI failed. `writeNotes` throws it only after it wrote `transcript.md`.
private struct SummaryToolError: LocalizedError {
    let errorDescription: String?
}
