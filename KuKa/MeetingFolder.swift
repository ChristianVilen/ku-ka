import Foundation

enum MeetingTrack: CaseIterable, Hashable {
    case microphone
    case system

    var speaker: Speaker {
        switch self {
        case .microphone: return .me
        case .system: return .them
        }
    }

    var fileName: String {
        switch self {
        case .microphone: return "me.caf"
        case .system: return "them.caf"
        }
    }
}

enum Speaker: String {
    case me = "Me"
    case them = "Them"
}

enum MeetingDocument: String, CaseIterable {
    case transcript = "transcript.md"
    case summary = "summary.md"
    case failure = "error.md"
}

enum MeetingStep: Equatable {
    case transcribe
    case summarize
}

struct MeetingFolderContents: Equatable {
    var audio: Set<MeetingTrack> = []
    var hasTranscript = false
    var hasSummary = false
    var failureMessage: String?
}

enum MeetingStage: Equatable {
    case pending(MeetingStep)
    case failed(MeetingStep, message: String)
    case done

    init?(_ contents: MeetingFolderContents) {
        let next: MeetingStep?
        if contents.hasSummary {
            next = nil
        } else if contents.hasTranscript {
            next = .summarize
        } else if !contents.audio.isEmpty {
            next = .transcribe
        } else {
            return nil
        }
        switch (next, contents.failureMessage) {
        case (nil, _): self = .done
        case (let step?, let message?): self = .failed(step, message: message)
        case (let step?, nil): self = .pending(step)
        }
    }
}

struct MeetingFolder: Hashable {
    let url: URL

    var name: String { url.lastPathComponent }

    static func folderName(startingAt date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter.string(from: date)
    }

    var title: String {
        guard let match = name.wholeMatch(of: #/(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})(?:-(\d+))?/#) else {
            return name
        }
        let title = "Meeting on \(match.1) at \(match.2):\(match.3)"
        return match.4.map { "\(title) (\($0))" } ?? title
    }

    static func create(in root: URL, startingAt date: Date) throws -> MeetingFolder {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = folderName(startingAt: date)
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let meeting = MeetingFolder(url: root.appendingPathComponent(name, isDirectory: true))
            do {
                // Without intermediate directories this fails when the folder
                // exists, so the check and the claim are one step.
                try fileManager.createDirectory(at: meeting.url, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                suffix += 1
                continue
            }
            try fileManager.createDirectory(at: meeting.audioFolder, withIntermediateDirectories: false)
            return meeting
        }
    }

    static func all(in root: URL) -> [(MeetingFolder, MeetingStage)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(MeetingFolder.init(url:))
            .sorted { $0.name < $1.name }
            .compactMap { meeting in meeting.stage().map { (meeting, $0) } }
    }

    func audioURL(_ track: MeetingTrack) -> URL {
        audioFolder.appendingPathComponent(track.fileName)
    }

    func url(for document: MeetingDocument) -> URL {
        url.appendingPathComponent(document.rawValue)
    }

    func stage() -> MeetingStage? {
        let fileManager = FileManager.default
        return MeetingStage(MeetingFolderContents(
            audio: Set(MeetingTrack.allCases.filter { fileManager.fileExists(atPath: audioURL($0).path) }),
            hasTranscript: fileManager.fileExists(atPath: url(for: .transcript).path),
            hasSummary: fileManager.fileExists(atPath: url(for: .summary).path),
            failureMessage: try? read(.failure)))
    }

    func write(_ text: String, to document: MeetingDocument) throws {
        try Data(text.utf8).write(to: url(for: document), options: .atomic)
    }

    func read(_ document: MeetingDocument) throws -> String {
        try String(contentsOf: url(for: document), encoding: .utf8)
    }

    func clearFailure() throws {
        let failure = url(for: .failure)
        guard FileManager.default.fileExists(atPath: failure.path) else { return }
        try FileManager.default.removeItem(at: failure)
    }

    func discardAudio(trash: (URL) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: audioFolder.path) else { return }
        try trash(audioFolder)
    }

    private var audioFolder: URL {
        url.appendingPathComponent("audio", isDirectory: true)
    }
}
