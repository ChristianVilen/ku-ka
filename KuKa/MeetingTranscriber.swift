import AVFAudio
import Speech

protocol Transcribing {
    func transcribe(_ audio: URL) async throws -> TrackTranscript
}

/// No dependency, no model for Ku-Ka to ship, and no speech-recognition
/// permission (measured).
struct SpeechTranscriberAdapter: Transcribing {
    private let locale = Locale(identifier: "en_US")

    func transcribe(_ audio: URL) async throws -> TrackTranscript {
        let file = try AVAudioFile(forReading: audio)
        guard file.length > 0 else { return TrackTranscript(segments: [], duration: 0) }
        let duration = Double(file.length) / file.processingFormat.sampleRate

        guard SpeechTranscriber.isAvailable else {
            throw MeetingStepError("On-device speech recognition is not available on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }),
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                segments.append(TranscriptSegment(start: result.range.start.seconds,
                                                  end: result.range.end.seconds,
                                                  text: String(result.text.characters)))
            }
            return segments
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return TrackTranscript(segments: try await collector.value, duration: duration)
    }
}
