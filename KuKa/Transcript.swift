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

/// A transcript after known words, with what changed.
struct CorrectedTranscript: Equatable, Sendable {
    let markdown: String
    let applied: [AppliedCorrection]
}

enum Transcript {
    /// Joins a speaker's segments while the gap between them is under `joinGap`. With nil, each
    /// segment is a line of its own. With `.voices`, the microphone lines get room labels: see
    /// `microphoneLines`.
    static func merge(_ tracks: [MeetingTrack: TrackTranscript], rooms: RoomLabels,
                      joinGap: TimeInterval? = 2) -> [TranscriptLine] {
        let them = withText(tracks[.system]?.segments ?? [])
        // sorted(by:) is stable, so Them, listed first, stays first on an equal start.
        let spoken = (them.map { (speaker: Speaker.them, segment: $0) }
            + microphoneLines(microphoneSpeech(tracks), them: them, rooms: rooms))
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

    /// The microphone segments that `merge` keeps, in time order: each has text and is no echo of
    /// a "Them" segment.
    static func microphoneSpeech(_ tracks: [MeetingTrack: TrackTranscript]) -> [TranscriptSegment] {
        let them = tracks[.system]?.segments ?? []
        return withText(tracks[.microphone]?.segments ?? [])
            .filter { mic in !them.contains { isEcho(mic, of: $0) } }
            .sorted { $0.start < $1.start }
    }

    private static func withText(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Room labels come only from the voices that count. An echo voice speaks while Them speaks
    /// for at least `echoVoiceTimeShare` of its time, and at least `echoVoiceWordShare` of its words
    /// are in the Them segments near its own; its lines are dropped. A voice with fewer than
    /// `minimumRoomVoiceWords` words is too small to count; its lines take the counted voice whose
    /// turn is nearest. With fewer than two counted voices, every line is "Me". Room numbers follow
    /// each counted voice's first line.
    private static func microphoneLines(_ me: [TranscriptSegment], them: [TranscriptSegment], rooms: RoomLabels)
        -> [(speaker: Speaker, segment: TranscriptSegment)] {
        guard case .voices(let voices) = rooms else { return me.map { (.me, $0) } }
        let voiceOfSegment = me.map(voices.voice(for:))
        let echoes = echoVoices(me, voices: voiceOfSegment, them: them)
        let kept = zip(me, voiceOfSegment).filter { !echoes.contains($0.1) }

        var wordCount: [Int: Int] = [:]
        for (segment, voice) in kept { wordCount[voice, default: 0] += words(segment.text).count }
        let counted = Set(wordCount.keys.filter { wordCount[$0]! >= minimumRoomVoiceWords })
        guard counted.count > 1, let countedVoices = voices.keeping(counted) else { return kept.map { (.me, $0.0) } }
        var numbers: [Int: Int] = [:]
        return kept.map { segment, voice in
            let room = counted.contains(voice) ? voice : countedVoices.voice(for: segment)
            if numbers[room] == nil { numbers[room] = numbers.count + 1 }
            return (.room(numbers[room]!), segment)
        }
    }

    /// `voices[i]` is the voice of `me[i]`.
    private static func echoVoices(_ me: [TranscriptSegment], voices: [Int], them: [TranscriptSegment]) -> Set<Int> {
        var time: [Int: TimeInterval] = [:]
        var overlap: [Int: TimeInterval] = [:]
        var wordCount: [Int: Int] = [:]
        var repeated: [Int: Int] = [:]
        for (segment, (voice, shared)) in zip(me, zip(voices, timeOverlapping(them, for: me))) {
            time[voice, default: 0] += segment.end - segment.start
            overlap[voice, default: 0] += shared
            let heard = Set(them.filter { nearInTime(segment, $0) }.flatMap { words($0.text) })
            let said = words(segment.text)
            wordCount[voice, default: 0] += said.count
            repeated[voice, default: 0] += said.filter(heard.contains).count
        }
        return Set(time.keys.filter {
            time[$0]! > 0 && overlap[$0]! >= echoVoiceTimeShare * time[$0]!
                && Double(repeated[$0]!) >= echoVoiceWordShare * Double(wordCount[$0]!)
        })
    }

    /// Short echoes pass the echo rule, and diarization can give them a voice of their own. A person
    /// in the room can also talk while Them speaks, but only an echo repeats Them's words.
    private static let echoVoiceTimeShare = 0.7
    private static let echoVoiceWordShare = 0.5
    private static let minimumRoomVoiceWords = 5

    /// The seconds of each of `segments` inside any segment of `other`. `segments` must be in time order.
    private static func timeOverlapping(_ other: [TranscriptSegment], for segments: [TranscriptSegment]) -> [TimeInterval] {
        var spans: [(start: TimeInterval, end: TimeInterval)] = []
        for segment in other.sorted(by: { $0.start < $1.start }) where segment.end > segment.start {
            if let last = spans.last, segment.start <= last.end {
                spans[spans.count - 1].end = max(last.end, segment.end)
            } else {
                spans.append((segment.start, segment.end))
            }
        }
        var first = 0
        return segments.map { segment in
            while first < spans.count, spans[first].end <= segment.start { first += 1 }
            var time: TimeInterval = 0
            for span in spans[first...] {
                guard span.start < segment.end else { break }
                time += min(span.end, segment.end) - max(span.start, segment.start)
            }
            return time
        }
    }

    static func isEcho(_ microphone: TranscriptSegment, of system: TranscriptSegment) -> Bool {
        guard nearInTime(microphone, system) else { return false }
        let micWords = words(microphone.text)
        guard micWords.count >= minimumMicrophoneWords else { return false }
        let systemWords = Set(words(system.text))
        let shared = micWords.filter(systemWords.contains).count
        return Double(shared) >= sharedWordFraction * Double(micWords.count)
    }

    private static func nearInTime(_ microphone: TranscriptSegment, _ system: TranscriptSegment) -> Bool {
        microphone.start <= system.end + slack && system.start <= microphone.end + slack
    }

    private static let slack: TimeInterval = 1
    /// Shorter microphone segments are never echoes: a short reply such as
    /// "okay" or "yes please" often shares its words with the other side.
    private static let minimumMicrophoneWords = 3
    private static let sharedWordFraction = 0.6

    /// Everything after the speaker legend and before the known-words note, so the summary CLI gets
    /// no header, no failure lines, and no list of corrections.
    static func contentForSummary(_ markdown: String) -> String {
        let content = withoutCorrectionNote(markdown)
        for legend in Legend.allCases {
            if let boundary = content.range(of: legend.rawValue + "\n\n") {
                return String(content[boundary.upperBound...])
            }
        }
        return content
    }

    /// Applies `corrector` to the spoken text of each transcript line, after `**[hh:mm:ss] Label:** `.
    /// The title, duration, byline, legend, and labels never change. With no replacement the result
    /// is `heard` byte for byte. Otherwise a note at the end lists each replacement once, in the order
    /// of its first use: "Known words applied: Convio → Konvio (3), Yuri → Jyri (1)."
    ///
    /// `heard` must be the text as the transcriber wrote it, so a replacement is never applied twice.
    static func corrected(_ heard: String, by corrector: Corrector) -> CorrectedTranscript {
        var found: [AppliedCorrection] = []
        let lines = heard.components(separatedBy: "\n").map { line -> String in
            guard let spoken = spokenLine(line[...]) else { return line }
            let corrected = corrector.correct(String(spoken.text))
            found += corrected.applied
            return line[..<spoken.text.startIndex] + corrected.text
        }
        let applied = summed(found)
        guard !applied.isEmpty else { return CorrectedTranscript(markdown: heard, applied: []) }
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        let pairs = applied.map { "\($0.heard) → \($0.right) (\($0.count))" }.joined(separator: ", ")
        return CorrectedTranscript(markdown: text + correctionNoteStart + pairs + ".\n", applied: applied)
    }

    /// `markdown` without the note that `corrected` adds.
    static func withoutCorrectionNote(_ markdown: String) -> String {
        guard let note = markdown.range(of: correctionNoteStart, options: .backwards) else { return markdown }
        return String(markdown[..<note.lowerBound])
    }

    /// "Them at 00:12:31": the label and time of the first transcript line whose spoken text has
    /// `quote`, both folded with `Phrase.fold`. Nil when no line has it.
    static func place(of quote: String, in markdown: String) -> String? {
        let quote = Phrase.fold(quote)
        guard !quote.isEmpty else { return nil }
        for line in markdown.components(separatedBy: "\n") {
            if let spoken = spokenLine(line[...]), Phrase.fold(String(spoken.text)).contains(quote) {
                return "\(spoken.label) at \(spoken.time)"
            }
        }
        return nil
    }

    private static let correctionNoteStart = "\n---\n\nKnown words applied: "

    /// Each pair once, in the order of its first use, with its counts added up.
    private static func summed(_ corrections: [AppliedCorrection]) -> [AppliedCorrection] {
        var summed: [AppliedCorrection] = []
        for correction in corrections {
            if let index = summed.firstIndex(where: { $0.heard == correction.heard && $0.right == correction.right }) {
                summed[index] = AppliedCorrection(heard: correction.heard, right: correction.right,
                                                  count: summed[index].count + correction.count)
            } else {
                summed.append(correction)
            }
        }
        return summed
    }

    /// The time, the label, and the spoken text of a line `**[00:12:31] Them:** text`.
    private static func spokenLine(_ line: Substring) -> (time: Substring, label: Substring, text: Substring)? {
        guard let prefix = line.prefixMatch(of: #/\*\*\[(\d{2,}:\d{2}:\d{2})\] ([^*\n]+):\*\* /#) else { return nil }
        return (prefix.1, prefix.2, line[prefix.range.upperBound...])
    }

    static func markdown(_ lines: [TranscriptLine], title: String, duration: TimeInterval,
                         by transcriber: String, after failures: [TranscriberFailure], rooms: RoomLabels) -> String {
        let byline = failures.isEmpty
            ? "Transcript by \(transcriber)."
            : "Transcript by \(transcriber). Tried first:\n\n" + failures.map { "- \($0)" }.joined(separator: "\n")
        var header = [byline]
        if case .failed(let failure) = rooms { header.append("There are no room labels. \(failure)") }
        let hasRooms = lines.contains { line in
            if case .room = line.speaker { return true }
            return false
        }
        header.append((hasRooms ? Legend.rooms : .microphone).rawValue)
        var text = """
        # \(title)

        Duration: \(clock(duration))

        \(header.joined(separator: "\n\n"))


        """
        for line in lines {
            text += "**[\(clock(line.start))] \(line.speaker.label):** \(line.text)\n\n"
        }
        if lines.isEmpty {
            text += "No speech was detected.\n\n"
        }
        return String(text.dropLast())
    }

    /// Every legend that any Ku-Ka version wrote. `markdown` writes `rooms` or `microphone`.
    /// `contentForSummary` must still find a legend in a transcript that waits for its summary
    /// across an app update, so add a case for a new legend, and never edit or delete one.
    private enum Legend: String, CaseIterable {
        case rooms = "\"Room 1\", \"Room 2\", and so on are voices on the microphone of the Mac that recorded the meeting. The microphone hears the person who recorded the meeting and anyone in the same room. Ku-Ka told the voices apart on this Mac and numbered them in the order they first spoke. Two people with similar voices can share one label, and one person can get two labels. No label tells which voice is the person who recorded the meeting. \"Them\" is everyone else on the call."
        case microphone = "\"Me\" is the microphone of the Mac that recorded the meeting. It hears the person who recorded the meeting and anyone in the same room. \"Them\" is everyone else on the call."
        case person = "\"Me\" is the person who recorded the meeting. \"Them\" is everyone else on the call."
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
