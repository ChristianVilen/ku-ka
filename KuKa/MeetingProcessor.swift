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

@MainActor
struct MeetingProcessor {
    private let transcribers: [Transcribing]
    private let roomLabeller: RoomLabelling
    private let summarizer: Summarizer
    private let locale: () -> Locale
    private let trash: (URL) throws -> Void
    private let now: () -> Date

    /// `roomLabeller` has no default value, so a test that forgets the fake does not compile
    /// instead of downloading a model.
    init(transcribers: [Transcribing] = [WhisperKitTranscriber(), SpeechTranscriberAdapter()],
         roomLabeller: RoomLabelling,
         summarizer: Summarizer = Summarizer(),
         locale: @escaping () -> Locale = { Locale(identifier: "en-US") },
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         now: @escaping () -> Date = { Date() }) {
        self.transcribers = transcribers
        self.roomLabeller = roomLabeller
        self.summarizer = summarizer
        self.locale = locale
        self.trash = trash
        self.now = now
    }

    func process(_ meeting: MeetingFolder, onStep: (MeetingStep) -> Void,
                 onDownload: (MeetingModel) -> Void = { _ in }) async -> MeetingOutcome {
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
                onStep(step)
                do {
                    switch step {
                    case .transcribe:
                        guard try await transcribe(meeting, onStep: onStep, onDownload: onDownload) else { return .noSpeech }
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
    private func transcribe(_ meeting: MeetingFolder, onStep: (MeetingStep) -> Void,
                            onDownload: (MeetingModel) -> Void) async throws -> Bool {
        let (tracks, transcriber, failures) = try await transcribeTracks(meeting, onStep: onStep, onDownload: onDownload)
        let rooms = try await labelRooms(meeting, tracks: tracks, onStep: onStep, onDownload: onDownload)
        try Task.checkCancellation()
        let lines = Transcript.merge(tracks, rooms: rooms)
        let duration = tracks.values.map(\.duration).max() ?? 0
        if lines.isEmpty {
            // Summary first: it marks the meeting done, so a crash before the
            // transcript is written cannot run the summary step, which would
            // trash the audio.
            try meeting.write(SummaryDocument.noSpeech(title: meeting.title), to: .summary)
        }
        try meeting.write(Transcript.markdown(lines, title: meeting.title, duration: duration,
                                              by: transcriber, after: failures, rooms: rooms), to: .transcript)
        return !lines.isEmpty
    }

    /// The session lives only in here, so the Whisper model is released
    /// before the room labeller loads its own model.
    private func transcribeTracks(_ meeting: MeetingFolder, onStep: (MeetingStep) -> Void, onDownload: (MeetingModel) -> Void)
        async throws -> (tracks: [MeetingTrack: TrackTranscript], transcriber: String, failures: [TranscriberFailure]) {
        let (session, transcriber, failures) = try await startTranscriber(onStep: onStep, onDownload: onDownload)
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
                            onStep: (MeetingStep) -> Void, onDownload: (MeetingModel) -> Void) async throws -> RoomLabels {
        guard !Transcript.microphoneSpeech(tracks).isEmpty else { return .notDiarized }
        guard !meeting.roomLabelsStarted else { return .failed(.earlierAttemptStopped) }
        guard (tracks[.microphone]?.duration ?? 0) <= RoomLabelFailure.longestTrack else { return .failed(.tooLong) }
        if roomLabeller.needsDownload {
            var started = false
            do {
                defer { if started { onStep(.transcribe) } }
                try await roomLabeller.download {
                    started = true
                    onDownload(.speaker)
                }
            } catch {
                return .failed(.download(error.localizedDescription))
            }
        }
        try meeting.markRoomLabelsStarted()
        let rooms = await roomLabeller.label(meeting.audioURL(.microphone))
        try meeting.clearRoomLabelsStarted()
        return rooms
    }

    private func startTranscriber(onStep: (MeetingStep) -> Void, onDownload: (MeetingModel) -> Void) async throws
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
                    onDownload(.speech)
                    defer { onStep(.transcribe) }
                    try await transcriber.download(for: locale)
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
        let transcript = Transcript.contentForSummary(try meeting.read(.transcript))
        switch await summarizer.summarize(transcript: transcript) {
        case .written(let markdown, let cli, let earlier):
            try meeting.write(SummaryDocument.markdown(title: meeting.title, body: markdown, by: cli, after: earlier),
                              to: .summary)
        case .failed(let failures):
            throw MeetingStepError(failures.map(\.description).joined(separator: "\n"))
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
