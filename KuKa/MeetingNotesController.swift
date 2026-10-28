import Cocoa

/// The recorder's state as the rest of the app sees it.
enum RecorderPhase: Equatable {
    case idle
    case starting
    case recording
    case paused

    /// The stream runs and the folder lock is held.
    var isCapturing: Bool { self == .recording || self == .paused }

    /// For the status item's accessibility label and tooltip. Nil when there is nothing to say.
    var statusDescription: String? {
        switch self {
        case .recording: return "recording meeting"
        case .paused: return "recording paused"
        case .idle, .starting: return nil
        }
    }

    var recordingMark: RecordingMark? {
        switch self {
        case .recording: return .recording
        case .paused: return .paused
        case .idle, .starting: return nil
        }
    }
}

/// Everything the meeting controls panel draws. The controller builds it on demand from its
/// one recorder state, and the panel keeps no copy of it.
struct MeetingControls: Equatable {
    enum Status: Equatable {
        case starting
        /// Recorded seconds.
        case recording(TimeInterval)
        case paused(TimeInterval)
        case saved
        case interrupted(reason: String)
    }

    let status: Status
    let isTranscriptOpen: Bool
    /// Nil while starting, after the meeting, and while the transcript is closed.
    let preview: LivePreview?
}

/// One-shot requests from the controller to the panel, for things that are not state.
enum MeetingControlsRequest: Equatable {
    /// Show Meeting Controls: make the panel key, so Tab reaches its buttons.
    case focus
    case restoreDefaultPosition
}

@MainActor
final class MeetingNotesController: NSObject, NSMenuItemValidation, MenuSection {
    private enum Recorder {
        /// `notice` is what the panel says about the meeting that just ended, until it closes.
        case idle(notice: EndNotice?)
        case starting
        case active(ActiveMeeting)

        var phase: RecorderPhase {
            switch self {
            case .idle: return .idle
            case .starting: return .starting
            case .active(let meeting): return meeting.clock.isPaused ? .paused : .recording
            }
        }
    }

    private enum EndNotice {
        case saved(MeetingFolder)
        /// Stays until the user closes it, so the end of a recording is never missed.
        case interrupted(reason: String)
    }

    /// One meeting while it records or is paused. Dropped at Stop, interruption, or quit,
    /// which releases the folder lock. So nothing in it, the live text and the drawer flag
    /// included, can show in the next meeting.
    private struct ActiveMeeting: Equatable {
        let folder: MeetingFolder
        let lock: FileLock
        let handle: ActiveRecording
        /// The only clock that changes. `handle` gets a copy after each change.
        var clock: RecordingClock
        /// Applies the live engine's updates to `live`.
        let liveTask: Task<Void, Never>
        var live = LiveTranscript()
        var isHidden = false
        var isTranscriptOpen = false

        /// Written out, because the lock and the handle compare by identity.
        static func == (lhs: ActiveMeeting, rhs: ActiveMeeting) -> Bool {
            lhs.folder == rhs.folder && lhs.lock === rhs.lock && lhs.handle === rhs.handle && lhs.clock == rhs.clock
                && lhs.liveTask == rhs.liveTask && lhs.live == rhs.live && lhs.isHidden == rhs.isHidden
                && lhs.isTranscriptOpen == rhs.isTranscriptOpen
        }
    }

    private let permissions: PermissionsManager
    private let root: () -> URL
    private let locale: () -> Locale
    private let capture: MeetingAudioCapturing
    private let liveTranscriber: LiveTranscribing
    private let processor: MeetingProcessor
    private let notifier: Notifying
    /// Returns true when the user chose Open Permissions.
    private let alertStartFailure: @MainActor (_ reason: String, _ offersPermissions: Bool) -> Bool
    private let openURL: (URL) -> Void
    private let now: () -> Date
    private let hostNow: () -> HostTime
    /// Runs its work once, a few seconds later.
    private let closeSavedNoticeLater: @MainActor (@escaping @MainActor () -> Void) -> Void

    private var recorder: Recorder = .idle(notice: nil) {
        didSet {
            updateMenu()
            reconcileDisplayTimer()
            if oldValue.phase != recorder.phase { onStateChange?() }
            onControlsChange?()
        }
    }
    private var queue: [MeetingFolder] = []
    private var current: (meeting: MeetingFolder, activity: String)?
    private var processingTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var meterTimer: Timer?
    /// Redraws the panel's recorded time. Runs only while recording, so the time stops while
    /// paused.
    private var displayTimer: Timer?

    private let statusLineItem: NSMenuItem
    private let meterItem: NSMenuItem
    private let meterView = RecordingAudioMeterView()
    private let recordItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let showControlsItem: NSMenuItem
    private let restorePositionItem: NSMenuItem
    private let progressItem: NSMenuItem
    private let waitingItem: NSMenuItem
    private let retryItem: NSMenuItem
    private let openFolderItem: NSMenuItem

    /// Fires on every change of `phase`, Starting and quit included.
    var onStateChange: (() -> Void)?
    var onShowPermissions: (() -> Void)?
    /// The meeting controls panel: anything it draws changed.
    var onControlsChange: (@MainActor () -> Void)?
    var onControlsRequest: (@MainActor (MeetingControlsRequest) -> Void)?

    var phase: RecorderPhase { recorder.phase }

    /// Nil when the panel is off screen.
    var controls: MeetingControls? {
        let status: MeetingControls.Status
        switch recorder {
        case .idle(nil):
            return nil
        case .idle(.saved?):
            status = .saved
        case .idle(.interrupted(let reason)?):
            status = .interrupted(reason: reason)
        case .starting:
            status = .starting
        case .active(let meeting):
            guard !meeting.isHidden else { return nil }
            let recorded = meeting.clock.recordedTime(at: hostNow())
            return MeetingControls(status: meeting.clock.isPaused ? .paused(recorded) : .recording(recorded),
                                   isTranscriptOpen: meeting.isTranscriptOpen,
                                   preview: meeting.isTranscriptOpen ? meeting.live.preview(on: meeting.clock) : nil)
        }
        return MeetingControls(status: status, isTranscriptOpen: false, preview: nil)
    }

    init(permissions: PermissionsManager,
         root: @escaping () -> URL,
         locale: @escaping () -> Locale = { Locale(identifier: "en-US") },
         capture: MeetingAudioCapturing = ScreenCaptureMeetingAudio(),
         liveTranscriber: LiveTranscribing = AppleLiveTranscriber(),
         processor: MeetingProcessor = MeetingProcessor(),
         notifier: Notifying = SystemNotifier.shared,
         alertStartFailure: @escaping @MainActor (String, Bool) -> Bool = MeetingNotesController.showStartFailureAlert,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         now: @escaping () -> Date = { Date() },
         hostNow: @escaping () -> HostTime = HostTime.now,
         closeSavedNoticeLater: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = MeetingNotesController.afterSixSeconds) {
        self.permissions = permissions
        self.root = root
        self.locale = locale
        self.capture = capture
        self.liveTranscriber = liveTranscriber
        self.processor = processor
        self.notifier = notifier
        self.alertStartFailure = alertStartFailure
        self.openURL = openURL
        self.now = now
        self.hostNow = hostNow
        self.closeSavedNoticeLater = closeSavedNoticeLater
        statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        meterItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recordItem = NSMenuItem(title: "", action: #selector(recordClicked), keyEquivalent: "")
        pauseItem = NSMenuItem(title: "", action: #selector(pauseClicked), keyEquivalent: "")
        showControlsItem = NSMenuItem(title: "Show Meeting Controls", action: #selector(showControlsClicked), keyEquivalent: "")
        restorePositionItem = NSMenuItem(title: "Restore Default Position", action: #selector(restorePositionClicked),
                                         keyEquivalent: "")
        progressItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        waitingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        retryItem = NSMenuItem(title: "", action: #selector(retryClicked), keyEquivalent: "")
        openFolderItem = NSMenuItem(title: "Open Meetings Folder", action: #selector(openFolderClicked), keyEquivalent: "")
        super.init()
        meterItem.view = meterView
        for item in [recordItem, pauseItem, showControlsItem, restorePositionItem, retryItem, openFolderItem] {
            item.target = self
        }
        for item in [statusLineItem, meterItem, pauseItem, showControlsItem, restorePositionItem, progressItem, waitingItem,
                     retryItem] {
            item.isHidden = true
        }
    }

    isolated deinit {
        meterTimer?.invalidate()
        displayTimer?.invalidate()
    }

    func buildMenuSection(into menu: NSMenu) {
        let header = NSMenuItem(title: "Meeting Notes", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in [statusLineItem, meterItem, recordItem, pauseItem, showControlsItem, restorePositionItem, progressItem,
                     waitingItem, retryItem, openFolderItem] {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        updateMenu()
    }

    func menuWillOpen() {
        menuIsOpen = true
        updateMenu()
        reloadFailedMeetingsFromDisk()
    }

    func menuTick() {
        updateMenu()
    }

    func menuDidClose() {
        menuIsOpen = false
        meterTimer?.invalidate()
        meterTimer = nil
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
        if case .active(let meeting) = recorder {
            meeting.liveTask.cancel()
            meeting.handle.stop()
        }
        recorder = .idle(notice: nil)
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
        case .active: stopRecording()
        case .starting: break
        }
    }

    private func start() async {
        recorder = .starting
        notifier.requestPermission()
        if let reason = await missingGrant() {
            recorder = .idle(notice: nil)
            if alertStartFailure(reason, true) { onShowPermissions?() }
            return
        }
        do {
            let meeting = try MeetingFolder.create(in: root(), startingAt: now())
            do {
                let lock = try meeting.lock()
                // Read just before the capture starts, so no captured buffer starts earlier.
                let clock = RecordingClock(origin: hostNow())
                let handle = try await capture.start(into: meeting, clock: clock) { [weak self] reason in
                    self?.handleInterruption(of: meeting, reason: reason)
                }
                if let reason = handle.endReason {
                    endRecording(meeting, interruptedBecause: reason)
                } else {
                    let updates = liveTranscriber.updates(locale: locale(), audio: handle.writtenAudio)
                    let liveTask = Task { [weak self] in
                        for await update in updates { self?.applyLive(update, to: meeting) }
                    }
                    recorder = .active(ActiveMeeting(folder: meeting, lock: lock, handle: handle, clock: clock,
                                                     liveTask: liveTask))
                }
            } catch {
                try? FileManager.default.removeItem(at: meeting.url)
                throw error
            }
        } catch {
            recorder = .idle(notice: nil)
            _ = alertStartFailure(error.localizedDescription, false)
        }
    }

    /// Nil when recording can start, otherwise the reason it cannot.
    private func missingGrant() async -> String? {
        permissions.refresh()
        guard permissions.screenRecording else {
            return "Ku-Ka needs Screen Recording permission to record the other people on the call."
        }
        guard permissions.microphone != .denied, await permissions.requestMicrophone() else {
            return "Ku-Ka needs Microphone permission to record your side of the call."
        }
        return nil
    }

    /// The one Stop, for the menu and the meeting controls. Never starts a meeting.
    func stopRecording() {
        guard case .active(let meeting) = recorder else { return }
        meeting.liveTask.cancel()
        meeting.handle.stop()
        // Not `meeting`: it holds the folder lock, which processing needs now.
        let folder = meeting.folder
        recorder = .idle(notice: .saved(folder))
        closeSavedNoticeLater { [weak self] in self?.closeNotice(ifSavedFor: folder) }
        enqueue(folder)
    }

    private func closeNotice(ifSavedFor meeting: MeetingFolder) {
        guard case .idle(.saved(let saved)?) = recorder, saved == meeting else { return }
        recorder = .idle(notice: nil)
    }

    func pause() {
        updateActive { meeting in
            guard meeting.clock.pause(at: hostNow()) else { return }
            meeting.handle.apply(meeting.clock)
            meeting.live.settleTails()
        }
    }

    func resume() {
        updateActive { meeting in
            guard meeting.clock.resume(at: hostNow()) else { return }
            meeting.handle.apply(meeting.clock)
        }
    }

    func togglePause() {
        phase == .paused ? resume() : pause()
    }

    @objc private func pauseClicked() {
        togglePause()
    }

    func setTranscriptOpen(_ isOpen: Bool) {
        updateActive { $0.isTranscriptOpen = isOpen }
    }

    /// The panel's Hide while recording, or its Close on a notice.
    func dismissControls() {
        switch recorder {
        case .active: updateActive { $0.isHidden = true }
        case .idle(_?): recorder = .idle(notice: nil)
        case .idle(nil), .starting: break
        }
    }

    func showControls() {
        updateActive { $0.isHidden = false }
        if controls != nil { onControlsRequest?(.focus) }
    }

    @objc private func showControlsClicked() {
        showControls()
    }

    @objc private func restorePositionClicked() {
        onControlsRequest?(.restoreDefaultPosition)
    }

    /// The live task can already hold an update when Stop cancels it, and apply it once a
    /// later meeting is active. The folder check drops it.
    private func applyLive(_ update: LiveUpdate, to meeting: MeetingFolder) {
        updateActive(of: meeting) { $0.live.apply(update, now: hostNow(), clock: $0.clock) }
    }

    /// With `meeting`, only while it is the active meeting. A change that leaves the meeting as it
    /// was, such as a Pause the clock refuses, tells no one.
    private func updateActive(of meeting: MeetingFolder? = nil, _ change: (inout ActiveMeeting) -> Void) {
        guard case .active(var active) = recorder, meeting == nil || active.folder == meeting else { return }
        let before = active
        change(&active)
        guard active != before else { return }
        recorder = .active(active)
    }

    private func handleInterruption(of meeting: MeetingFolder, reason: String) {
        guard case .active(let active) = recorder, active.folder == meeting else { return }
        active.liveTask.cancel()
        endRecording(meeting, interruptedBecause: reason)
    }

    private func endRecording(_ meeting: MeetingFolder, interruptedBecause reason: String) {
        recorder = .idle(notice: .interrupted(reason: reason))
        notifier.post(title: "Recording Stopped", body: MeetingPanelCopy.interruptedNote(reason), opening: nil)
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
            let outcome = await processor.process(meeting, onStep: { [weak self] step in
                self?.current = (meeting, step.progressVerb)
                self?.updateMenu()
            }, onDownload: { [weak self] in
                self?.current = (meeting, "Downloading speech model")
                self?.updateMenu()
            })
            current = nil
            report(outcome, for: meeting)
        }
        processingTask = nil
        updateMenu()
        reloadFailedMeetingsFromDisk()
    }

    private func report(_ outcome: MeetingOutcome, for meeting: MeetingFolder) {
        // The tool output stays in error.md; a notification is too short for it.
        switch outcome {
        case .done(let summary):
            notifier.post(title: "Meeting Notes Ready", body: "\(meeting.title). Click to open the summary.", opening: summary)
        case .failed(.transcribe, _):
            notifier.post(title: MeetingStep.transcribe.failureHeading,
                          body: "\(meeting.title). Choose Retry Failed Meeting in the Ku-Ka menu to try again. Click to see what went wrong.",
                          opening: meeting.url(for: .failure))
        case .failed(.summarize, _):
            notifier.post(title: MeetingStep.summarize.failureHeading,
                          body: "The transcript of \(meeting.title) is ready. Choose Retry Failed Meeting in the Ku-Ka menu to try the summary again. Click to see what went wrong.",
                          opening: meeting.url(for: .failure))
        case .noSpeech:
            notifier.post(title: "No Speech Detected",
                          body: "\(meeting.title). The audio is in the meeting folder. Click to open it.",
                          opening: meeting.url)
        case .cancelled, .busy, .gone:
            break
        }
    }

    private func updateMenu() {
        switch recorder {
        case .idle:
            statusLineItem.isHidden = true
        case .starting:
            statusLineItem.title = "Starting Recording"
            statusLineItem.isHidden = false
        case .active(let meeting):
            let recorded = Self.formatElapsed(meeting.clock.recordedTime(at: hostNow()))
            statusLineItem.title = meeting.clock.isPaused ? "Paused · \(recorded)" : "● Recording · \(recorded)"
            statusLineItem.isHidden = false
        }
        recordItem.title = phase.isCapturing ? "Stop Recording Meeting" : "Start Recording Meeting"
        pauseItem.title = phase == .paused ? "Resume Recording" : "Pause Recording"
        for item in [pauseItem, showControlsItem, restorePositionItem, meterItem] { item.isHidden = !phase.isCapturing }
        reconcileMeterTimer()
        progressItem.isHidden = current == nil
        waitingItem.isHidden = current == nil || queue.isEmpty
        if let current {
            progressItem.title = "\(current.activity): \(current.meeting.title)"
            waitingItem.title = queue.count == 1 ? "1 more meeting waiting" : "\(queue.count) more meetings waiting"
        }
    }

    private func reconcileMeterTimer() {
        guard menuIsOpen, phase.isCapturing else {
            meterTimer?.invalidate()
            meterTimer = nil
            if !phase.isCapturing { meterView.show(.silent) }
            return
        }
        refreshMeters()
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func reconcileDisplayTimer() {
        guard case .active(let meeting) = recorder, !meeting.clock.isPaused else {
            displayTimer?.invalidate()
            displayTimer = nil
            return
        }
        guard displayTimer == nil else { return }
        // The first tick comes on the next whole recorded second, so the shown seconds change on time.
        let recorded = meeting.clock.recordedTime(at: hostNow())
        let firstTick = Date().addingTimeInterval(1 - recorded.truncatingRemainder(dividingBy: 1))
        let timer = Timer(fire: firstTick, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onControlsChange?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func refreshMeters() {
        guard menuIsOpen, case .active(let meeting) = recorder else { return }
        meterView.show(meeting.handle.audioLevels())
    }

    private func reloadFailedMeetingsFromDisk() {
        let failed = MeetingFolder.all(in: root()).filter {
            if case .failed = $0.1 { return true }
            return false
        }
        retryItem.isHidden = failed.isEmpty
        retryItem.title = failed.count == 1 ? "Retry Failed Meeting" : "Retry \(failed.count) Failed Meetings"
    }

    nonisolated static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
            : String(format: "%d:%02d", minutes, seconds % 60)
    }

    static func afterSixSeconds(_ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func showStartFailureAlert(reason: String, offersPermissions: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Recording Did Not Start"
        alert.informativeText = reason
        alert.addButton(withTitle: offersPermissions ? "Open Permissions" : "OK")
        if offersPermissions { alert.addButton(withTitle: "Cancel") }
        NSApp.activate()
        return offersPermissions && alert.runModal() == .alertFirstButtonReturn
    }
}
