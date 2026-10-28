import Carbon.HIToolbox
import Cocoa

/// Pure geometry for the pill and its drawer, in NS coordinates (bottom-left origin).
enum MeetingPanelPlacement {
    static let inset: CGFloat = 16
    static let drawerHeights: ClosedRange<CGFloat> = 140...460
    static let defaultDrawerHeight: CGFloat = 280

    /// The pill's top-right corner: the saved corner, moved so the whole pill lies in the
    /// visible frame of the screen it is on. With no saved corner, or one on no screen (a
    /// display was unplugged), the top-right of the primary screen's visible frame, `inset` in.
    /// Anchored top-right, so the pill grows to the left when a state makes it wider.
    static func pillTopRight(saved: CGPoint?, pillSize: CGSize, screens: [ScreenGeometry]) -> CGPoint? {
        if let saved, let screen = screen(of: pillRect(topRight: saved, size: pillSize), in: screens) {
            let visible = screen.visibleFrame
            return CGPoint(x: min(max(saved.x, visible.minX + pillSize.width), visible.maxX),
                           y: min(max(saved.y, visible.minY + pillSize.height), visible.maxY))
        }
        guard let primary = screens.first?.visibleFrame else { return nil }
        return CGPoint(x: primary.maxX - inset, y: primary.maxY - inset)
    }

    /// The window frame for the pill plus, when open, the drawer. The drawer opens below the
    /// pill, or above it when it would not fit below on the pill's screen.
    static func frame(pillTopRight: CGPoint, pillSize: CGSize, drawerHeight: CGFloat?,
                      screens: [ScreenGeometry]) -> (frame: CGRect, drawerAbove: Bool) {
        let pill = pillRect(topRight: pillTopRight, size: pillSize)
        guard let drawerHeight else { return (pill, false) }
        let bottom = screen(of: pill, in: screens)?.visibleFrame.minY ?? -.infinity
        let drawerAbove = pill.minY - drawerHeight < bottom
        let frame = CGRect(x: pill.minX, y: drawerAbove ? pill.minY : pill.minY - drawerHeight,
                           width: pill.width, height: pill.height + drawerHeight)
        return (frame, drawerAbove)
    }

    static func clampedDrawerHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, drawerHeights.lowerBound), drawerHeights.upperBound)
    }

    private static func pillRect(topRight: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height)
    }

    /// The screen that holds most of `rect`. Nil when it is on none.
    private static func screen(of rect: CGRect, in screens: [ScreenGeometry]) -> ScreenGeometry? {
        let overlaps = screens.map { (screen: $0, area: area($0.frame.intersection(rect))) }
        return overlaps.filter { $0.area > 0 }.max { $0.area < $1.area }?.screen
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

/// The floating meeting controls: a glass pill with the status, the recorded time, Pause or
/// Resume, Stop, and the transcript toggle, above or below a drawer with the live transcript.
///
/// Pure view, like `ClipboardPanel`. Every recording fact it draws comes from
/// `controller.controls`, and its buttons call the controller. It owns only presentation: its
/// frame, the drawer height while a resize lasts, `TranscriptFollow`, and fades. It writes
/// `Settings` only when a user drag or resize ends, never at launch or for a move of its own,
/// because tests run inside the app with the user's defaults.
///
/// It never calls `NSApp.activate` and never makes itself key when it appears, so the meeting
/// app keeps the keyboard. Unlike `ClipboardPanel`, it does not close on `resignKey`.
final class MeetingControlsPanel: FloatingPanel {
    private struct Placement {
        let frame: CGRect
        let pillHeight: CGFloat
        let pillTopRight: CGPoint
        /// Where the drawer is, or would be when it opens.
        let drawerAbove: Bool
    }

    /// What the full render draws: the status without its time, the drawer, and the drawer's
    /// message.
    private struct Shape: Equatable {
        let status: MeetingControls.Status
        let isTranscriptOpen: Bool
        let liveStatus: LiveTranscript.Status?

        init(_ controls: MeetingControls) {
            switch controls.status {
            case .recording: status = .recording(0)
            case .paused: status = .paused(0)
            case .starting, .saved, .interrupted: status = controls.status
            }
            isTranscriptOpen = controls.isTranscriptOpen
            liveStatus = controls.preview?.status
        }
    }

    private static let speechCell = NSUserInterfaceItemIdentifier("MeetingSpeechCell")
    private static let pauseCell = NSUserInterfaceItemIdentifier("MeetingPauseCell")

    private let controller: MeetingNotesController
    private let settings: Settings
    private let screens: Screens
    private let announce: (String, NSAccessibilityPriorityLevel) -> Void
    private let displayOptions: () -> (reduceMotion: Bool, reduceTransparency: Bool)

    private var follow = TranscriptFollow()
    private var rows: [LiveRow] = []
    /// The status the last reload drew, only to announce a change. The buttons never read it.
    private var announcedStatus: MeetingControls.Status?
    /// The shape the last full render drew, only to skip that work. The buttons never read it.
    private var drawnShape: Shape?
    private var placement: Placement?
    private var targetFrame: CGRect?
    private var dragStart: CGPoint?
    private var dragCorner: CGPoint?
    private var resizeStart: (height: CGFloat, drawerAbove: Bool)?
    private var resizeHeight: CGFloat?
    /// True while the panel itself scrolls or resizes the transcript, so only a scroll by the
    /// user changes `follow`.
    private var isMovingTranscript = false

    private let root = RootView()
    private var pillBackground: NSView?
    private let pill = MeetingPillView()
    private let spinner = NSProgressIndicator()
    private let mark = MeetingStatusMark()
    private let timeLabel = MeetingPanelLabel(size: 13, weight: .semibold, digits: true)
    private let wordLabel = MeetingPanelLabel(size: 13, weight: .semibold)
    private lazy var pauseButton = MeetingPanelButton(target: self, action: #selector(pauseClicked))
    private lazy var stopButton = MeetingPanelButton(target: self, action: #selector(stopClicked))
    private lazy var closeButton = MeetingPanelButton(target: self, action: #selector(closeClicked))
    private lazy var transcriptButton = MeetingPanelButton(target: self, action: #selector(transcriptClicked))
    private let buttonSeparator = MeetingPanelFill(color: .separatorColor, rounded: .none)
    private let noteLabel = MeetingPanelLabel(wrapping: .systemFont(ofSize: 12), color: .secondaryLabelColor)

    private let drawer = MeetingPanelFill(color: Colors.drawer, radius: Layout.cornerRadius, rounded: .bottom)
    private let drawerEdge = MeetingPanelFill(color: .separatorColor, rounded: .none)
    private let header = NSStackView()
    private let behindChip = MeetingPanelFill(color: Colors.button, radius: 6)
    private let behindLabel = MeetingPanelLabel(size: 11, weight: .semibold, digits: true)
    private lazy var hideButton = NSButton(title: "", target: self, action: #selector(hideClicked))
    private let messageTitle = MeetingPanelLabel(size: 13, weight: .semibold)
    private let messageBody = MeetingPanelLabel(wrapping: .systemFont(ofSize: 12.5), color: .secondaryLabelColor)
    private let messageStack = NSStackView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let transcriptFade = MeetingTranscriptFade()
    private lazy var returnToLiveButton = MeetingPanelButton(fill: Colors.solid, floats: true, target: self,
                                                             action: #selector(returnToLiveClicked))
    private let grip = MeetingDrawerGrip()
    private var drawerBelowConstraints: [NSLayoutConstraint] = []
    private var drawerAboveConstraints: [NSLayoutConstraint] = []
    private var scrollBelowMessage: NSLayoutConstraint!
    private var scrollAtBodyTop: NSLayoutConstraint!

    init(controller: MeetingNotesController, settings: Settings, screens: Screens = SystemScreens(),
         announce: @escaping (String, NSAccessibilityPriorityLevel) -> Void = MeetingControlsPanel.postAnnouncement,
         displayOptions: @escaping () -> (reduceMotion: Bool, reduceTransparency: Bool) = MeetingControlsPanel.systemDisplayOptions,
         mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.controller = controller
        self.settings = settings
        self.screens = screens
        self.announce = announce
        self.displayOptions = displayOptions
        super.init(contentRect: NSRect(x: 0, y: 0, width: Layout.recordingWidth, height: Layout.pillHeight))
        pill.mouseLocation = mouseLocation
        grip.mouseLocation = mouseLocation
        // Ku-Ka never activates, and an NSPanel hides when its app deactivates.
        hidesOnDeactivate = false
        // A click on Pause or Stop leaves the keyboard with the meeting app.
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        autorecalculatesKeyViewLoop = true

        buildPill()
        buildDrawer()
        root.wantsLayer = true
        root.layer?.cornerRadius = Layout.cornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        contentView = root
        // A zero frame would break every inner constraint until the first layout.
        drawer.frame = root.bounds
        root.addSubview(drawer)
        root.drawer = drawer
        applyAccessibilityDisplay()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(transcriptScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    /// Claims both controller slots. The owner calls this once, at launch, before any meeting.
    func bindController() {
        controller.onControlsChange = { [weak self] in self?.reload() }
        controller.onControlsRequest = { [weak self] in self?.handle($0) }
    }

    /// For keyboard use after Show Meeting Controls. A click on a button never makes it key.
    override var canBecomeKey: Bool { true }

    /// Esc closes the drawer.
    override func cancelOperation(_ sender: Any?) {
        controller.setTranscriptOpen(false)
    }

    /// End returns to live from any control. Keys a control does not use come here.
    override func keyDown(with event: NSEvent) {
        guard Int(event.keyCode) == kVK_End else { return super.keyDown(with: event) }
        returnToLive()
    }

    static func postAnnouncement(_ text: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    static func systemDisplayOptions() -> (reduceMotion: Bool, reduceTransparency: Bool) {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
         NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    // MARK: - Rendering

    /// Redraws what the controller says. The single entry point for every change. Only a new
    /// `Shape` configures the panel and lays it out again, so a time tick or new text sets only
    /// the time, the chip, and the rows.
    func reload() {
        let controls = controller.controls
        if let announcement = MeetingPanelCopy.announcement(from: announcedStatus, to: controls?.status) {
            announce(announcement.text, announcement.priority)
        }
        announcedStatus = controls?.status
        guard let controls else { return disappear() }

        let wasOpen = !drawer.isHidden
        let isAppearing = !isVisible
        renderTime(controls.status)
        renderBehind(controls.preview?.behind)
        let shape = Shape(controls)
        if isAppearing || shape != drawnShape {
            drawnShape = shape
            render(controls)
            relayout(controls, animated: !isAppearing && !displayOptions().reduceMotion)
        }
        updateRows(controls.preview?.rows ?? [])
        if controls.isTranscriptOpen, !wasOpen { drawerOpened() }
        if isAppearing { appear() }
    }

    private func renderTime(_ status: MeetingControls.Status) {
        guard let recorded = recordedTime(status) else { return }
        let time = MeetingNotesController.formatElapsed(recorded)
        guard time != timeLabel.stringValue else { return }
        timeLabel.stringValue = time
        timeLabel.setAccessibilityLabel(MeetingPanelCopy.timeLabel(recorded))
    }

    private func renderBehind(_ behind: TimeInterval?) {
        let chip = MeetingPanelCopy.behindChip(behind)
        behindChip.isHidden = chip == nil
        if let chip, chip != behindLabel.stringValue { behindLabel.stringValue = chip }
    }

    private func render(_ controls: MeetingControls) {
        let status = controls.status
        let isRecorder: Bool
        switch status {
        case .starting:
            isRecorder = true
        case .recording, .paused:
            isRecorder = true
            mark.kind = isPaused(status) ? .paused : .recording
        case .saved:
            isRecorder = false
            mark.kind = .saved
        case .interrupted:
            isRecorder = false
            mark.kind = .interrupted
        }
        let isStarting = status == .starting
        spinner.isHidden = !isStarting
        mark.isHidden = isStarting
        if isStarting, !displayOptions().reduceMotion { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        timeLabel.isHidden = recordedTime(status) == nil
        timeLabel.textColor = isPaused(status) ? .secondaryLabelColor : .labelColor
        let word = MeetingPanelCopy.word(for: status)
        wordLabel.isHidden = word == nil
        wordLabel.stringValue = word ?? ""

        for view in [pauseButton, stopButton, transcriptButton, buttonSeparator] { view.isHidden = !isRecorder }
        closeButton.isHidden = isRecorder
        pauseButton.isEnabled = !isStarting
        stopButton.isEnabled = !isStarting
        transcriptButton.isEnabled = !isStarting
        pauseButton.configure(symbol: isPaused(status) ? Self.symbol("circle.fill", size: 9, color: .systemRed)
                                                       : Self.symbol("pause.fill", size: 12, color: .labelColor),
                              copy: MeetingPanelCopy.pauseButton(isPaused: isPaused(status)))

        let note = MeetingPanelCopy.note(for: status)
        noteLabel.isHidden = note == nil
        noteLabel.stringValue = note ?? ""

        drawer.isHidden = !controls.isTranscriptOpen
        let message = controls.preview.flatMap { MeetingPanelCopy.message(for: $0.status) }
        messageStack.isHidden = message == nil
        messageTitle.stringValue = message?.title ?? ""
        messageBody.stringValue = message?.body ?? ""
        scrollAtBodyTop.isActive = false
        scrollBelowMessage.isActive = false
        (message == nil ? scrollAtBodyTop : scrollBelowMessage).isActive = true
    }

    private func isPaused(_ status: MeetingControls.Status) -> Bool {
        if case .paused = status { return true }
        return false
    }

    private func recordedTime(_ status: MeetingControls.Status) -> TimeInterval? {
        switch status {
        case .recording(let time), .paused(let time): return time
        case .starting, .saved, .interrupted: return nil
        }
    }

    private func pillSize(for controls: MeetingControls) -> CGSize {
        guard !controls.isTranscriptOpen else { return CGSize(width: Layout.openWidth, height: Layout.pillHeight) }
        switch controls.status {
        case .starting: return CGSize(width: Layout.startingWidth, height: Layout.pillHeight)
        case .recording: return CGSize(width: Layout.recordingWidth, height: Layout.pillHeight)
        case .paused: return CGSize(width: Layout.pausedWidth, height: Layout.pillHeight)
        case .saved, .interrupted:
            let width = Layout.noticeWidth - Layout.noteLeading - Layout.noteTrailing
            let note = noteLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: Layout.noticeWidth, height: Layout.noteTop + ceil(note.height) + Layout.noteBottom)
        }
    }

    private var drawerHeight: CGFloat {
        resizeHeight ?? MeetingPanelPlacement.clampedDrawerHeight(CGFloat(settings.meetingTranscriptHeight))
    }

    private func placement(for controls: MeetingControls) -> Placement? {
        let size = pillSize(for: controls)
        let layout = screens.all
        guard let corner = MeetingPanelPlacement.pillTopRight(saved: dragCorner ?? settings.meetingControlsTopRight,
                                                              pillSize: size, screens: layout) else { return nil }
        let open = MeetingPanelPlacement.frame(pillTopRight: corner, pillSize: size, drawerHeight: drawerHeight, screens: layout)
        let frame = controls.isTranscriptOpen
            ? open.frame
            : MeetingPanelPlacement.frame(pillTopRight: corner, pillSize: size, drawerHeight: nil, screens: layout).frame
        return Placement(frame: frame, pillHeight: size.height, pillTopRight: corner, drawerAbove: open.drawerAbove)
    }

    private func relayout(_ controls: MeetingControls, animated: Bool) {
        guard let placement = placement(for: controls) else { return }
        apply(placement, isOpen: controls.isTranscriptOpen, animated: animated)
    }

    private func apply(_ placement: Placement, isOpen: Bool, animated: Bool) {
        self.placement = placement
        let above = placement.drawerAbove
        root.pillHeight = placement.pillHeight
        root.drawerAbove = above
        NSLayoutConstraint.deactivate(above ? drawerBelowConstraints : drawerAboveConstraints)
        NSLayoutConstraint.activate(above ? drawerAboveConstraints : drawerBelowConstraints)
        drawer.rounded = above ? .top : .bottom
        (pillBackground as? NSGlassEffectView)?.cornerRadius = isOpen ? 0 : Layout.cornerRadius
        (pillBackground as? MeetingPanelFill)?.rounded = isOpen ? (above ? .bottom : .top) : .all
        let points = isOpen != above ? "chevron.up" : "chevron.down"
        transcriptButton.configure(symbol: Self.symbol(points, size: 11, color: .labelColor),
                                   copy: MeetingPanelCopy.transcriptButton(isOpen: isOpen))

        setFrame(placement.frame, animated: animated)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        invalidateShadow()
    }

    private func setFrame(_ frame: CGRect, animated: Bool) {
        guard frame != targetFrame else { return }
        targetFrame = frame
        let wasMoving = isMovingTranscript
        isMovingTranscript = true
        setFrame(frame, display: true, animate: animated)
        isMovingTranscript = wasMoving
    }

    /// Reduce Motion: the frame changes at once, and only the drawer fades.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        displayOptions().reduceMotion ? 0 : Layout.resizeDuration
    }

    private func appear() {
        setAlphaImmediately(0)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeDuration
            animator().alphaValue = 1
        }
    }

    private func disappear() {
        guard isVisible else { return }
        orderOut(nil)
        setAlphaImmediately(1)
        dragStart = nil
        dragCorner = nil
        resizeStart = nil
        resizeHeight = nil
    }

    /// A zero-length animation, so a fade still running cannot overwrite it.
    private func setAlphaImmediately(_ value: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = value
        }
    }

    private func handle(_ request: MeetingControlsRequest) {
        switch request {
        case .focus:
            makeKeyAndOrderFront(nil)
        case .restoreDefaultPosition:
            settings.meetingControlsTopRight = nil
            guard let controls = controller.controls else { return }
            relayout(controls, animated: !displayOptions().reduceMotion)
        }
    }

    // MARK: - The transcript

    /// Replaces only the rows after the unchanged start, so new text measures only new rows.
    private func updateRows(_ newRows: [LiveRow]) {
        guard newRows != rows else { return }
        let old = rows
        let kept = zip(old, newRows).prefix { $0 == $1 }.count
        rows = newRows
        let wasMoving = isMovingTranscript
        isMovingTranscript = true
        tableView.beginUpdates()
        if old.count > kept { tableView.removeRows(at: IndexSet(kept..<old.count), withAnimation: []) }
        if newRows.count > kept { tableView.insertRows(at: IndexSet(kept..<newRows.count), withAnimation: []) }
        tableView.endUpdates()
        follow.rowsChanged(from: old.count, to: newRows.count)
        if follow.isFollowing { scrollToEnd(animated: false) }
        isMovingTranscript = wasMoving
        renderReturnToLive()
    }

    private func drawerOpened() {
        follow.returnToLive()
        scrollToEnd(animated: false)
        renderReturnToLive()
        drawer.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeDuration
            drawer.animator().alphaValue = 1
        }
    }

    private func returnToLive() {
        follow.returnToLive()
        scrollToEnd(animated: !displayOptions().reduceMotion)
        renderReturnToLive()
    }

    private func scrollToEnd(animated: Bool) {
        guard !rows.isEmpty else { return }
        root.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let end = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: tableView.bounds.maxY),
                                                  size: clip.bounds.size)).origin
        guard animated else {
            let wasMoving = isMovingTranscript
            isMovingTranscript = true
            clip.scroll(to: end)
            scrollView.reflectScrolledClipView(clip)
            isMovingTranscript = wasMoving
            return
        }
        isMovingTranscript = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.resizeDuration
            clip.animator().setBoundsOrigin(end)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isMovingTranscript = false
                self?.scrollView.reflectScrolledClipView(clip)
            }
        })
    }

    @objc private func transcriptScrolled() {
        guard !isMovingTranscript, !rows.isEmpty else { return }
        follow.scrolled(lastRowVisible: tableView.rect(ofRow: rows.count - 1).intersects(tableView.visibleRect))
        renderReturnToLive()
    }

    private func renderReturnToLive() {
        let title = follow.returnToLiveTitle
        returnToLiveButton.isHidden = title == nil
        guard let title else { return }
        returnToLiveButton.configure(symbol: Self.symbol("arrow.down", size: 11, color: .labelColor),
                                     copy: MeetingPanelCopy.Button(title: title, label: title, tooltip: title))
    }

    // MARK: - Actions

    @objc private func pauseClicked() { controller.togglePause() }
    @objc private func stopClicked() { controller.stopRecording() }
    @objc private func closeClicked() { controller.dismissControls() }
    @objc private func hideClicked() { controller.dismissControls() }
    @objc private func returnToLiveClicked() { returnToLive() }

    @objc private func transcriptClicked() {
        controller.setTranscriptOpen(!(controller.controls?.isTranscriptOpen ?? false))
    }

    private func dragBegan() {
        dragStart = placement?.pillTopRight
    }

    private func dragMoved(by offset: CGSize) {
        guard let dragStart, let controls = controller.controls else { return }
        dragCorner = CGPoint(x: dragStart.x + offset.width, y: dragStart.y + offset.height)
        relayout(controls, animated: false)
    }

    /// Saves the corner as placed, so on a screen. A click without a move saves nothing.
    private func dragEnded() {
        dragStart = nil
        guard dragCorner != nil else { return }
        dragCorner = nil
        if let corner = placement?.pillTopRight { settings.meetingControlsTopRight = corner }
    }

    private func resizeBegan() {
        guard let placement else { return }
        resizeStart = (drawerHeight, placement.drawerAbove)
    }

    /// Keeps the drawer on its side: a height that would flip it is not taken.
    private func resizeMoved(by offset: CGSize) {
        guard let start = resizeStart, let controls = controller.controls else { return }
        let previous = resizeHeight
        resizeHeight = MeetingPanelPlacement.clampedDrawerHeight(start.height + (start.drawerAbove ? offset.height : -offset.height))
        guard let placement = placement(for: controls), placement.drawerAbove == start.drawerAbove else {
            resizeHeight = previous
            return
        }
        apply(placement, isOpen: controls.isTranscriptOpen, animated: false)
    }

    private func resizeEnded() {
        resizeStart = nil
        guard let height = resizeHeight else { return }
        resizeHeight = nil
        settings.meetingTranscriptHeight = Double(height)
    }

    // MARK: - Observers

    @objc private func screensChanged() {
        guard isVisible, let controls = controller.controls else { return }
        relayout(controls, animated: false)
    }

    @objc private func displayOptionsChanged() {
        applyAccessibilityDisplay()
        guard isVisible else { return }
        drawnShape = nil
        reload()
    }

    /// Reduce Transparency: a solid pill instead of glass.
    private func applyAccessibilityDisplay() {
        let solid = displayOptions().reduceTransparency
        if let pillBackground, solid == (pillBackground is MeetingPanelFill) { return }
        (pillBackground as? NSGlassEffectView)?.contentView = nil
        pill.removeFromSuperview()
        pillBackground?.removeFromSuperview()
        let background: NSView
        if solid {
            background = MeetingPanelFill(color: Colors.solid, radius: Layout.cornerRadius)
            background.addSubview(pill)
        } else {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Layout.cornerRadius
            glass.contentView = pill
            background = glass
        }
        background.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: root.pillHeight)
        root.addSubview(background)
        root.pill = background
        pillBackground = background
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            pill.topAnchor.constraint(equalTo: background.topAnchor),
            pill.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        if let placement { apply(placement, isOpen: !drawer.isHidden, animated: false) }
    }

    // MARK: - Building

    private func buildPill() {
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.onBegan = { [weak self] in self?.dragBegan() }
        pill.onMoved = { [weak self] in self?.dragMoved(by: $0) }
        pill.onEnded = { [weak self] in self?.dragEnded() }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = true
        spinner.setAccessibilityElement(false)
        wordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [spinner, mark, timeLabel, wordLabel])
        status.orientation = .horizontal
        status.spacing = Layout.statusSpacing
        status.detachesHiddenViews = true
        status.translatesAutoresizingMaskIntoConstraints = false

        stopButton.configure(symbol: Self.symbol("stop.fill", size: 11, color: .systemRed), copy: MeetingPanelCopy.stopButton)
        closeButton.configure(symbol: Self.symbol("xmark", size: 11, color: .labelColor), copy: MeetingPanelCopy.closeButton)
        buttonSeparator.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [pauseButton, stopButton, closeButton, buttonSeparator, transcriptButton])
        buttons.orientation = .horizontal
        buttons.spacing = Layout.buttonSpacing
        buttons.detachesHiddenViews = true
        buttons.translatesAutoresizingMaskIntoConstraints = false

        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.preferredMaxLayoutWidth = Layout.noticeWidth - Layout.noteLeading - Layout.noteTrailing
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [status, buttons, noteLabel] { pill.addSubview(view) }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: Layout.pillLeading),
            status.centerYAnchor.constraint(equalTo: pill.topAnchor, constant: Layout.pillHeight / 2),
            status.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -Layout.buttonSpacing),
            buttons.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -Layout.pillTrailing),
            buttons.centerYAnchor.constraint(equalTo: pill.topAnchor, constant: Layout.pillHeight / 2),
            buttonSeparator.widthAnchor.constraint(equalToConstant: 0.5),
            buttonSeparator.heightAnchor.constraint(equalToConstant: 18),
            noteLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: Layout.noteLeading),
            noteLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -Layout.noteTrailing),
            noteLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: Layout.noteTop),
        ])
    }

    private func buildDrawer() {
        let title = MeetingPanelLabel(size: 12, weight: .semibold)
        title.stringValue = MeetingPanelCopy.transcriptTitle
        let draft = MeetingPanelLabel(size: 11.5, color: .secondaryLabelColor)
        draft.stringValue = MeetingPanelCopy.draftNote
        draft.toolTip = MeetingPanelCopy.draftTooltip
        draft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        draft.setContentHuggingPriority(.defaultLow, for: .horizontal)

        behindLabel.translatesAutoresizingMaskIntoConstraints = false
        behindChip.addSubview(behindLabel)
        NSLayoutConstraint.activate([
            behindLabel.leadingAnchor.constraint(equalTo: behindChip.leadingAnchor, constant: 7),
            behindLabel.trailingAnchor.constraint(equalTo: behindChip.trailingAnchor, constant: -7),
            behindLabel.topAnchor.constraint(equalTo: behindChip.topAnchor, constant: 3),
            behindLabel.bottomAnchor.constraint(equalTo: behindChip.bottomAnchor, constant: -3),
        ])

        hideButton.isBordered = false
        hideButton.attributedTitle = NSAttributedString(string: MeetingPanelCopy.hideButton.title ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        hideButton.setAccessibilityLabel(MeetingPanelCopy.hideButton.label)
        hideButton.toolTip = MeetingPanelCopy.hideButton.tooltip

        header.setViews([title, draft], in: .leading)
        header.setViews([behindChip, hideButton], in: .trailing)
        header.orientation = .horizontal
        header.spacing = 8
        header.detachesHiddenViews = true
        header.edgeInsets = NSEdgeInsets(top: 0, left: Layout.rowInset, bottom: 0, right: 10)

        messageStack.setViews([messageTitle, messageBody], in: .top)
        messageStack.orientation = .vertical
        messageStack.alignment = .leading
        messageStack.spacing = 6
        messageBody.preferredMaxLayoutWidth = Layout.openWidth - 2 * Layout.messageInset

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MeetingTranscriptColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        // A list the user reads, not a live region: rows are never announced.
        tableView.setAccessibilityLabel(MeetingPanelCopy.transcriptLabel)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)

        grip.toolTip = MeetingPanelCopy.heightGripTooltip
        grip.onBegan = { [weak self] in self?.resizeBegan() }
        grip.onMoved = { [weak self] in self?.resizeMoved(by: $0) }
        grip.onEnded = { [weak self] in self?.resizeEnded() }
        returnToLiveButton.isHidden = true

        let body = NSLayoutGuide()
        drawer.addLayoutGuide(body)
        for view in [drawerEdge, header, messageStack, scrollView, transcriptFade, returnToLiveButton, grip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            drawer.addSubview(view)
        }
        // While the window grows from the pill alone, the drawer is shorter than its parts.
        let gripAtFarEdgeBelow = grip.bottomAnchor.constraint(equalTo: drawer.bottomAnchor)
        let headerAtFarEdgeAbove = header.bottomAnchor.constraint(equalTo: drawer.bottomAnchor)
        for constraint in [gripAtFarEdgeBelow, headerAtFarEdgeAbove] { constraint.priority = .defaultHigh }

        NSLayoutConstraint.activate([
            drawerEdge.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            drawerEdge.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            drawerEdge.heightAnchor.constraint(equalToConstant: 0.5),
            header.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Layout.headerHeight),
            body.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            messageStack.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: Layout.messageInset),
            messageStack.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -Layout.messageInset),
            messageStack.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            transcriptFade.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            transcriptFade.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            transcriptFade.topAnchor.constraint(equalTo: scrollView.topAnchor),
            transcriptFade.heightAnchor.constraint(equalToConstant: 14),
            returnToLiveButton.centerXAnchor.constraint(equalTo: drawer.centerXAnchor),
            returnToLiveButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Layout.returnToLiveBottom),
            grip.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: Layout.gripHeight),
        ])
        scrollAtBodyTop = scrollView.topAnchor.constraint(equalTo: body.topAnchor)
        scrollBelowMessage = scrollView.topAnchor.constraint(equalTo: messageStack.bottomAnchor, constant: 8)
        drawerBelowConstraints = [
            drawerEdge.topAnchor.constraint(equalTo: drawer.topAnchor),
            header.topAnchor.constraint(equalTo: drawer.topAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: grip.topAnchor),
            gripAtFarEdgeBelow,
        ]
        drawerAboveConstraints = [
            drawerEdge.bottomAnchor.constraint(equalTo: drawer.bottomAnchor),
            grip.topAnchor.constraint(equalTo: drawer.topAnchor),
            body.topAnchor.constraint(equalTo: grip.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: header.topAnchor),
            headerAtFarEdgeAbove,
        ]
        NSLayoutConstraint.activate(drawerBelowConstraints + [scrollAtBodyTop])
        drawer.isHidden = true
    }
}

/// Puts the pill at its edge of the window and gives the drawer the rest, at every size while
/// the window's frame animates.
private final class RootView: NSView {
    var pillHeight = MeetingControlsPanel.Layout.pillHeight
    var drawerAbove = false
    weak var pill: NSView?
    weak var drawer: NSView?

    override func layout() {
        pill?.frame = NSRect(x: 0, y: drawerAbove ? 0 : bounds.height - pillHeight, width: bounds.width, height: pillHeight)
        drawer?.frame = NSRect(x: 0, y: drawerAbove ? pillHeight : 0, width: bounds.width,
                               height: max(0, bounds.height - pillHeight))
        super.layout()
    }
}

extension MeetingControlsPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row].content {
        case .pause:
            return Layout.pauseRowHeight
        case .speech(_, let text, let isFinal):
            return TranscriptSpeechCell.height(text: text, isFinal: isFinal, isContinuation: isContinuation(row))
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        switch item.content {
        case .pause(let duration):
            let cell = tableView.makeView(withIdentifier: Self.pauseCell, owner: self) as? TranscriptPauseCell
                ?? TranscriptPauseCell()
            cell.identifier = Self.pauseCell
            cell.configure(at: item.at, duration: duration)
            return cell
        case .speech(let speaker, let text, let isFinal):
            let cell = tableView.makeView(withIdentifier: Self.speechCell, owner: self) as? TranscriptSpeechCell
                ?? TranscriptSpeechCell()
            cell.identifier = Self.speechCell
            cell.configure(speaker: speaker, at: item.at, text: text, isFinal: isFinal, isContinuation: isContinuation(row))
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// The same speaker as the row before: the label and time are not repeated.
    private func isContinuation(_ row: Int) -> Bool {
        guard row > 0, case .speech(let speaker, _, _) = rows[row].content,
              case .speech(let previous, _, _) = rows[row - 1].content else { return false }
        return speaker == previous
    }
}

/// Whether the drawer follows new text. View state, kept as a value so its rule has tests.
struct TranscriptFollow: Equatable {
    private(set) var isFollowing = true
    private(set) var unseenRows = 0

    /// The user scrolled. Following stops when the last row is out of view and starts again
    /// when it is back in view.
    mutating func scrolled(lastRowVisible: Bool) {
        isFollowing = lastRowVisible
        if lastRowVisible { unseenRows = 0 }
    }

    /// While not following, new rows are counted for Return to live.
    mutating func rowsChanged(from old: Int, to new: Int) {
        guard !isFollowing else { return }
        unseenRows += max(0, new - old)
    }

    /// Return to live, or End in the transcript.
    mutating func returnToLive() {
        isFollowing = true
        unseenRows = 0
    }

    /// Nil while following.
    var returnToLiveTitle: String? {
        isFollowing ? nil : MeetingPanelCopy.returnToLive(newRows: unseenRows)
    }
}
