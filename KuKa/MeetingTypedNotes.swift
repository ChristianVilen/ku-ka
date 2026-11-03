import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum MeetingTypedNotesFile {
    static let maximumBytes = 65_536

    static func read(in meeting: MeetingFolder) throws -> String {
        let descriptor = open(meeting.url(for: .notes).path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return "" }
            throw MeetingStepError("Could not read notes.md. Check the meeting folder and try again.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw MeetingStepError("notes.md must be a regular text file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw MeetingStepError(sizeMessage) }
        guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else {
            throw MeetingStepError("notes.md must be UTF-8 text without NUL characters.")
        }
        return text
    }

    static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else { throw MeetingStepError(sizeMessage) }
        guard !text.utf8.contains(0) else { throw MeetingStepError("Remove the NUL character before saving these notes.") }
    }

    static let sizeMessage = "Notes can contain up to 64 KiB of text. Shorten them before saving."
}

enum TypedNotesSummaryState: Equatable {
    case idle
    case waitingForSave
    case queued
    case processing
    case summarizing(snapshot: String)
    case updated(snapshot: String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .waitingForSave, .queued, .processing, .summarizing: true
        case .idle, .updated, .failed: false
        }
    }
}

enum TypedNotesSummaryResult {
    case updated(snapshot: String)
    case failed(String)

    var state: TypedNotesSummaryState {
        switch self {
        case .updated(let snapshot): return .updated(snapshot: snapshot)
        case .failed(let message): return .failed(message)
        }
    }
}

@MainActor
final class MeetingTypedNotesSession {
    private enum FirstContentTime {
        case pending
        case stamped(MeetingNoteTime)
    }

    let meeting: MeetingFolder
    private var lock: FileLock?
    private(set) var text: String
    private(set) var savedText: String
    private(set) var saveError: String?
    private(set) var entries: [MeetingNoteEntry]
    private var firstContentTimes: [UUID: FirstContentTime] = [:]
    var noteTime: () -> MeetingNoteTime = { .afterRecording }
    var context: () -> (recordingPhase: RecorderPhase, summaryState: TypedNotesSummaryState) = { (.idle, .idle) } {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    var onSaved: (() -> Void)?

    init(meeting: MeetingFolder) throws {
        self.meeting = meeting
        do {
            lock = try FileLock.acquire(at: meeting.url.appendingPathComponent(".notes.lock"))
        } catch FileLockError.held {
            throw MeetingStepError("Another Ku-Ka has these notes open. Close that notes window and try again.")
        }
        text = try MeetingTypedNotesFile.read(in: meeting)
        savedText = text
        entries = MeetingNoteDocument.parse(text)
    }

    var hasUnsavedChanges: Bool { text != savedText || saveError != nil }
    var canUpdateSummary: Bool {
        let context = context()
        return Self.canUpdateSummary(meeting, recordingPhase: context.recordingPhase,
                                     summaryState: context.summaryState, hasUnsavedChanges: hasUnsavedChanges)
    }

    static func canUpdateSummary(_ meeting: MeetingFolder, recordingPhase: RecorderPhase,
                                 summaryState: TypedNotesSummaryState, hasUnsavedChanges: Bool) -> Bool {
        !recordingPhase.isCapturing && !summaryState.isBusy && !hasUnsavedChanges && meeting.stage() == .done
    }

    func edit(_ text: String) {
        self.text = text
        entries = MeetingNoteDocument.parse(text)
        firstContentTimes.removeAll()
        save()
    }

    @discardableResult
    func insertEntry(after previous: UUID? = nil) -> UUID {
        let entry = MeetingNoteEntry(time: noteTime())
        firstContentTimes[entry.id] = .pending
        if let previous, let index = entries.firstIndex(where: { $0.id == previous }) {
            entries.insert(entry, at: index + 1)
        } else {
            entries.append(entry)
        }
        onChange?()
        return entry.id
    }

    func updateEntry(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = text
        stampFirstContent(at: index)
        self.text = MeetingNoteDocument.render(entries)
        save()
    }

    func replaceEntries(_ entries: [MeetingNoteEntry]) {
        self.entries = entries
        for index in self.entries.indices {
            stampFirstContent(at: index)
        }
        text = MeetingNoteDocument.render(self.entries)
        save()
    }

    private func stampFirstContent(at index: Int) {
        let entry = entries[index]
        switch firstContentTimes[entry.id] {
        case .pending where !entry.text.isEmpty || !entry.attachments.isEmpty:
            let time = noteTime()
            entries[index].time = time
            firstContentTimes[entry.id] = .stamped(time)
        case .stamped(let time):
            entries[index].time = time
        case .pending, nil:
            break
        }
    }

    func addScreenshot(_ data: Data, to id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_000, height <= 16_000,
              width * height <= 40_000_000, CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw MeetingStepError("The screenshot must be a valid PNG within the size limit.")
        }
        let root = meeting.url.path
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else { throw MeetingStepError("Could not open the meeting folder.") }
        defer { Darwin.close(rootFD) }
        if mkdirat(rootFD, "attachments", 0o700) != 0 && errno != EEXIST {
            throw MeetingStepError("Could not create the attachments folder.")
        }
        let directory = openat(rootFD, "attachments", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw MeetingStepError("Could not open the attachments folder.") }
        defer { Darwin.close(directory) }
        let name = UUID().uuidString + ".png"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MeetingStepError("Could not save the screenshot.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { unlinkat(directory, name, 0); throw error }
        entries[index].attachments.append(name)
        stampFirstContent(at: index)
        text = MeetingNoteDocument.render(entries)
        save()
    }

    func screenshot(named name: String) -> Data? {
        guard name.hasSuffix(".png"), UUID(uuidString: String(name.dropLast(4))) != nil else { return nil }
        let root = open(meeting.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { return nil }
        defer { Darwin.close(root) }
        let directory = openat(root, "attachments", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { return nil }
        defer { Darwin.close(directory) }
        let descriptor = openat(directory, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 20_000_000 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 20_000_001), data.count <= 20_000_000 else { return nil }
        return data
    }

    func save() {
        do {
            guard lock != nil else { throw MeetingStepError("Reopen the notes window before editing this meeting.") }
            try MeetingTypedNotesFile.validate(text)
            guard try MeetingTypedNotesFile.read(in: meeting) == savedText else {
                throw MeetingStepError("notes.md changed outside this window. Copy your draft, then choose Reload saved notes.")
            }
            if hasUnsavedChanges { try meeting.write(text, to: .notes) }
            savedText = text
            saveError = nil
            onSaved?()
        } catch {
            saveError = error.localizedDescription
        }
        onChange?()
    }

    func reloadSavedNotes() {
        do {
            let saved = try MeetingTypedNotesFile.read(in: meeting)
            text = saved
            savedText = saved
            entries = MeetingNoteDocument.parse(saved)
            firstContentTimes.removeAll()
            saveError = nil
            onSaved?()
        } catch {
            saveError = error.localizedDescription
        }
        onChange?()
    }

    @discardableResult
    func close() -> Bool {
        guard !hasUnsavedChanges else { return false }
        lock?.release()
        lock = nil
        return true
    }

    var summaryMessage: String {
        let (recordingPhase, summaryState) = context()
        if recordingPhase.isCapturing {
            return recordingPhase == .paused
                ? "Recording paused. You can keep writing."
                : "Recording. Your notes will be included after Stop."
        }
        switch summaryState {
        case .idle:
            return meeting.stage() == .done
                ? "Choose Update summary to use these saved notes."
                : "The summary will be available when processing finishes."
        case .waitingForSave: return "Save your notes to start the summary."
        case .queued: return "Waiting to make the summary."
        case .processing: return "Processing the recording. You can keep writing."
        case .summarizing(let snapshot):
            return snapshot == text
                ? "Making the summary. You can keep writing."
                : "Making the summary from earlier notes. Your latest edits will need an update."
        case .updated(let snapshot):
            return snapshot == text && !hasUnsavedChanges
                ? "Summary includes these saved notes."
                : "Saved notes have changed. Update the summary to include them."
        case .failed(let message): return message
        }
    }
}
