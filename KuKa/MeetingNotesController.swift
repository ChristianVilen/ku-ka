import Cocoa
import UserNotifications

@MainActor
final class MeetingNotesController: NSObject, NSMenuItemValidation, MenuSection {
    private enum Recorder {
        case idle
        case starting
        case recording(MeetingFolder, since: Date, ActiveRecording, MeetingLock)
    }

    private let permissions: PermissionsManager
    private let root: () -> URL
    private let capture: MeetingAudioCapturing
    private let processor: MeetingProcessor
    private let notify: (_ title: String, _ body: String) -> Void
    private let openURL: (URL) -> Void
    private let now: () -> Date

    private var recorder: Recorder = .idle
    private var queue: [MeetingFolder] = []
    private var current: (meeting: MeetingFolder, step: MeetingStep)?
    private var processingTask: Task<Void, Never>?

    private let recordItem: NSMenuItem
    private let progressItem: NSMenuItem
    private let retryItem: NSMenuItem
    private let openFolderItem: NSMenuItem

    var onStateChange: (() -> Void)?
    var onShowPermissions: (() -> Void)?

    var isRecording: Bool {
        if case .recording = recorder { return true }
        return false
    }

    init(permissions: PermissionsManager,
         root: @escaping () -> URL,
         capture: MeetingAudioCapturing = ScreenCaptureMeetingAudio(),
         processor: MeetingProcessor = MeetingProcessor(),
         notify: @escaping (String, String) -> Void = MeetingNotesController.postNotification,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         now: @escaping () -> Date = { Date() }) {
        self.permissions = permissions
        self.root = root
        self.capture = capture
        self.processor = processor
        self.notify = notify
        self.openURL = openURL
        self.now = now
        recordItem = NSMenuItem(title: "", action: #selector(recordClicked), keyEquivalent: "")
        progressItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        retryItem = NSMenuItem(title: "", action: #selector(retryClicked), keyEquivalent: "")
        openFolderItem = NSMenuItem(title: "Open Meetings Folder", action: #selector(openFolderClicked), keyEquivalent: "")
        super.init()
        for item in [recordItem, retryItem, openFolderItem] { item.target = self }
        progressItem.isHidden = true
        retryItem.isHidden = true
    }

    func buildMenuSection(into menu: NSMenu) {
        let header = NSMenuItem(title: "Meeting Notes", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in [recordItem, progressItem, retryItem, openFolderItem] { menu.addItem(item) }
        menu.addItem(.separator())
        updateMenu()
    }

    func refreshMenuSection() {
        updateMenu()
        reloadFailedMeetingsFromDisk()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === recordItem, case .starting = recorder else { return true }
        return false
    }

    func resumeUnfinished() {
        for (meeting, stage) in MeetingFolder.all(in: root()) {
            if case .pending = stage { enqueue(meeting) }
        }
    }

    func shutDown() {
        if case .recording(_, _, let handle, _) = recorder { handle.stop() }
        recorder = .idle
        processingTask?.cancel()
    }

    func waitUntilIdle() async {
        await processingTask?.value
    }

    @objc private func recordClicked() {
        Task { await toggleRecording() }
    }

    func toggleRecording() async {
        switch recorder {
        case .idle: await start()
        case .recording: stop()
        case .starting: break
        }
    }

    private func start() async {
        recorder = .starting
        updateMenu()
        guard await hasGrants() else {
            recorder = .idle
            updateMenu()
            return
        }
        let startedAt = now()
        do {
            let meeting = try MeetingFolder.create(in: root(), startingAt: startedAt)
            do {
                guard let lock = meeting.lock() else { throw CocoaError(.fileLocking) }
                let handle = try await capture.start(into: meeting) { [weak self] reason in
                    self?.handleInterruption(of: meeting, reason: reason)
                }
                if let reason = handle.endReason {
                    endRecording(meeting, interruptedBecause: reason)
                } else {
                    recorder = .recording(meeting, since: startedAt, handle, lock)
                    onStateChange?()
                }
            } catch {
                try? FileManager.default.removeItem(at: meeting.url)
                throw error
            }
        } catch {
            recorder = .idle
            notify("Could not start recording", error.localizedDescription)
        }
        updateMenu()
    }

    private func hasGrants() async -> Bool {
        permissions.refresh()
        guard permissions.screenRecording, permissions.microphone != .denied else {
            onShowPermissions?()
            return false
        }
        return await permissions.requestMicrophone()
    }

    private func stop() {
        guard case .recording(let meeting, _, let handle, _) = recorder else { return }
        handle.stop()
        recorder = .idle
        updateMenu()
        onStateChange?()
        enqueue(meeting)
    }

    private func handleInterruption(of meeting: MeetingFolder, reason: String) {
        guard case .recording(let recording, _, _, _) = recorder, recording == meeting else { return }
        endRecording(meeting, interruptedBecause: reason)
    }

    private func endRecording(_ meeting: MeetingFolder, interruptedBecause reason: String) {
        recorder = .idle
        updateMenu()
        onStateChange?()
        notify("Recording stopped", "\(reason) Ku-Ka will transcribe what it recorded. Start a new recording to capture the rest.")
        enqueue(meeting)
    }

    @objc private func retryClicked() {
        retryFailed()
    }

    func retryFailed() {
        for (meeting, stage) in MeetingFolder.all(in: root()) {
            guard case .failed = stage else { continue }
            do {
                try meeting.clearFailure()
                enqueue(meeting)
            } catch {
                NSLog("Ku-Ka: could not clear the failure of \(meeting.name): \(error)")
            }
        }
        reloadFailedMeetingsFromDisk()
    }

    @objc private func openFolderClicked() {
        let root = root()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        openURL(root)
    }

    private func enqueue(_ meeting: MeetingFolder) {
        guard !queue.contains(meeting), current?.meeting != meeting else { return }
        queue.append(meeting)
        updateMenu()
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in await self?.processQueue() }
    }

    private func processQueue() async {
        while !queue.isEmpty, !Task.isCancelled {
            let meeting = queue.removeFirst()
            let outcome = await processor.process(meeting) { [weak self] step in
                self?.current = (meeting, step)
                self?.updateMenu()
            }
            current = nil
            report(outcome, for: meeting)
        }
        processingTask = nil
        updateMenu()
        reloadFailedMeetingsFromDisk()
    }

    private func report(_ outcome: MeetingOutcome, for meeting: MeetingFolder) {
        switch outcome {
        case .done:
            notify("Meeting notes ready", meeting.title)
        case .failed(.transcribe, let message):
            notify(MeetingStep.transcribe.failureHeading, message + " Retry from the Ku-Ka menu.")
        case .failed(.summarize, let message):
            notify("\(MeetingStep.summarize.failureHeading). The transcript is ready.", message + " Retry from the Ku-Ka menu.")
        case .noSpeech:
            notify("No speech detected", "\(meeting.title). The audio is in the meeting folder.")
        case .cancelled, .busy, .gone:
            break
        }
    }

    private func updateMenu() {
        switch recorder {
        case .idle: recordItem.title = "Start Recording Meeting"
        case .starting: recordItem.title = "Starting…"
        case .recording(_, let since, _, _): recordItem.title = "Stop Recording · \(Self.formatElapsed(now().timeIntervalSince(since)))"
        }
        if let current {
            let waiting = queue.isEmpty ? "" : " (+\(queue.count) waiting)"
            progressItem.title = "\(current.step.progressVerb) \(current.meeting.title)…\(waiting)"
            progressItem.isHidden = false
        } else {
            progressItem.isHidden = true
        }
    }

    private func reloadFailedMeetingsFromDisk() {
        let failed = MeetingFolder.all(in: root()).filter {
            if case .failed = $0.1 { return true }
            return false
        }
        retryItem.isHidden = failed.isEmpty
        retryItem.title = failed.count == 1 ? "Retry Failed Meeting" : "Retry \(failed.count) Failed Meetings"
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
            : String(format: "%d:%02d", minutes, seconds % 60)
    }

    /// Asks for notification permission on first use; macOS shows the prompt
    /// once and answers from the stored choice after that. A unique
    /// identifier per post, so two meetings' notices do not replace each other.
    nonisolated static func postNotification(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
