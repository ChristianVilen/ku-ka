import Foundation

enum MeetingOutcome: Equatable {
    case done(summary: URL)
    case failed(MeetingStep, message: String)
    case cancelled
}

@MainActor
struct MeetingProcessor {
    private let transcriber: Transcribing
    private let summarizer: Summarizer
    private let trash: (URL) throws -> Void
    private let now: () -> Date

    init(transcriber: Transcribing = SpeechTranscriberAdapter(),
         summarizer: Summarizer = Summarizer(),
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         now: @escaping () -> Date = { Date() }) {
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.trash = trash
        self.now = now
    }

    func process(_ meeting: MeetingFolder, onStep: (MeetingStep) -> Void) async -> MeetingOutcome {
        while true {
            if Task.isCancelled { return .cancelled }
            switch meeting.stage() {
            case nil:
                return .failed(.transcribe, message: "The meeting folder has no audio and no transcript.")
            case .done?:
                return .done(summary: meeting.url(for: .summary))
            case .failed(let step, let message)?:
                return .failed(step, message: message)
            case .pending(let step)?:
                onStep(step)
                do {
                    switch step {
                    case .transcribe: try await transcribe(meeting)
                    case .summarize: try await summarize(meeting)
                    }
                } catch {
                    if Task.isCancelled { return .cancelled }
                    let message = (error as? MeetingStepError)?.message ?? error.localizedDescription
                    try? meeting.write(Self.failureText(step: step, message: message, at: now()), to: .failure)
                    return .failed(step, message: message)
                }
            }
        }
    }

    private func transcribe(_ meeting: MeetingFolder) async throws {
        var tracks: [MeetingTrack: TrackTranscript] = [:]
        for track in MeetingTrack.allCases where FileManager.default.fileExists(atPath: meeting.audioURL(track).path) {
            tracks[track] = try await transcriber.transcribe(meeting.audioURL(track))
        }
        let lines = Transcript.merge(tracks)
        guard !lines.isEmpty else {
            throw MeetingStepError("No speech was detected. The audio is still in the meeting folder.")
        }
        let duration = tracks.values.map(\.duration).max() ?? 0
        try meeting.write(Transcript.markdown(lines, title: meeting.title, duration: duration), to: .transcript)
    }

    private func summarize(_ meeting: MeetingFolder) async throws {
        // This is the first moment a transcript is known to be on disk. Doing
        // it here also cleans up after a crash between writing the transcript
        // and this step.
        do {
            try meeting.discardAudio(trash: trash)
        } catch {
            NSLog("Ku-Ka: could not move meeting audio to the Trash: \(error)")
        }
        let transcript = try meeting.read(.transcript)
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
        let heading = switch step {
        case .transcribe: "Transcription failed"
        case .summarize: "Summary failed"
        }
        return """
        # \(heading)

        \(formatter.string(from: date))

        \(message)

        Choose Retry Failed Meeting in the Ku-Ka menu to try again.

        """
    }
}

struct MeetingStepError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
