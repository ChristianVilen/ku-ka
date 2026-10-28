import Foundation

struct TranscriptSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct TrackTranscript: Equatable {
    let segments: [TranscriptSegment]
    let duration: TimeInterval
}

struct TranscriptLine: Equatable {
    let speaker: Speaker
    let start: TimeInterval
    let text: String
}

enum Transcript {
    /// Joins a speaker's segments while the gap between them is under `joinGap`. With nil, each
    /// segment is a line of its own.
    static func merge(_ tracks: [MeetingTrack: TrackTranscript], joinGap: TimeInterval? = 2) -> [TranscriptLine] {
        let them = tracks[.system]?.segments ?? []
        let me = (tracks[.microphone]?.segments ?? []).filter { mic in !them.contains { isEcho(mic, of: $0) } }
        let spoken = [(MeetingTrack.system, them), (.microphone, me)]
            .flatMap { track, segments in segments.map { (speaker: track.speaker, segment: $0) } }
            .filter { !$0.segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // sorted(by:) is stable, so Them, listed first, stays first on an equal start.
            .sorted { $0.segment.start < $1.segment.start }

        var lines: [TranscriptLine] = []
        var lastEnd = -TimeInterval.infinity
        for (speaker, segment) in spoken {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let joinGap, let last = lines.last, last.speaker == speaker, segment.start - lastEnd < joinGap {
                lines[lines.count - 1] = TranscriptLine(speaker: speaker, start: last.start, text: last.text + " " + text)
            } else {
                lines.append(TranscriptLine(speaker: speaker, start: segment.start, text: text))
            }
            lastEnd = segment.end
        }
        return lines
    }

    static func isEcho(_ microphone: TranscriptSegment, of system: TranscriptSegment) -> Bool {
        guard microphone.start <= system.end + slack, system.start <= microphone.end + slack else { return false }
        let micWords = words(microphone.text)
        guard micWords.count >= minimumMicrophoneWords else { return false }
        let systemWords = Set(words(system.text))
        let shared = micWords.filter(systemWords.contains).count
        return Double(shared) >= sharedWordFraction * Double(micWords.count)
    }

    private static let slack: TimeInterval = 1
    /// Shorter microphone segments are never echoes: a short reply such as
    /// "okay" or "yes please" often shares its words with the other side.
    private static let minimumMicrophoneWords = 3
    private static let sharedWordFraction = 0.6
    /// `markdown` writes the first legend. The older ones stay so that `contentForSummary` still finds
    /// the content of a transcript that waits for its summary across an app update.
    private static let speakerLegends = [
        "\"Me\" is the microphone of the Mac that recorded the meeting. It hears the person who recorded the meeting and anyone in the same room. \"Them\" is everyone else on the call.",
        "\"Me\" is the person who recorded the meeting. \"Them\" is everyone else on the call.",
    ]

    static func contentForSummary(_ markdown: String) -> String {
        for legend in speakerLegends {
            if let boundary = markdown.range(of: legend + "\n\n") { return String(markdown[boundary.upperBound...]) }
        }
        return markdown
    }

    static func markdown(_ lines: [TranscriptLine], title: String, duration: TimeInterval,
                         by transcriber: String, after failures: [TranscriberFailure]) -> String {
        let byline = failures.isEmpty
            ? "Transcript by \(transcriber)."
            : "Transcript by \(transcriber). Tried first:\n\n" + failures.map { "- \($0)" }.joined(separator: "\n")
        var text = """
        # \(title)

        Duration: \(clock(duration))

        \(byline)

        \(speakerLegends[0])


        """
        for line in lines {
            text += "**[\(clock(line.start))] \(line.speaker.rawValue):** \(line.text)\n\n"
        }
        if lines.isEmpty {
            text += "No speech was detected.\n\n"
        }
        return String(text.dropLast())
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
