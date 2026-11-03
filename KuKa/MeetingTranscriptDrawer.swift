import Cocoa

/// Owns rows, follow state, and scroll position. The panel owns visibility and geometry.
final class MeetingTranscriptDrawer: NSView {
    private typealias Layout = MeetingControlsPanel.Layout
    private typealias Colors = MeetingControlsPanel.Colors

    private let reduceMotion: () -> Bool
    private var follow = TranscriptFollow()
    private var rows: [LiveRow] = []
    private var rowLengths: [Int] = []
    /// True while the panel or the drawer itself scrolls or resizes the transcript, so only a
    /// scroll by the user changes `follow`.
    private var isMovingTranscript = false

    private let background = MeetingPanelFill(color: Colors.drawer, radius: Layout.cornerRadius, rounded: .bottom)
    private let pillEdge = MeetingPanelFill(color: .separatorColor, rounded: .none)
    private let header = NSStackView()
    private let behindChip = MeetingPanelFill(color: Colors.button, radius: 6)
    private let behindLabel = NSTextField.makeLabel(size: 11, weight: .semibold, digits: true)
    private lazy var hideButton = NSButton(title: "", target: self, action: #selector(hideClicked))
    private let messageTitle = NSTextField.makeLabel(size: 13, weight: .semibold)
    private let messageBody = NSTextField.makeWrappingLabel(size: 12.5, color: .secondaryLabelColor)
    private let messageStack = NSStackView()
    private let transcriptView = NSTextView()
    private let scrollView = NSScrollView()
    private let transcriptFade = MeetingTranscriptFade()
    private lazy var returnToLiveButton = MeetingPanelButton(fill: Colors.solid, floats: true, target: self,
                                                             action: #selector(returnToLiveClicked))
    private let grip = MeetingDrawerGrip()
    private var belowPillConstraints: [NSLayoutConstraint] = []
    private var abovePillConstraints: [NSLayoutConstraint] = []
    private var scrollBelowMessage: NSLayoutConstraint!
    private var scrollAtBodyTop: NSLayoutConstraint!

    var onHide: (() -> Void)?
    var onResizeBegan: (() -> Void)? {
        get { grip.onBegan }
        set { grip.onBegan = newValue }
    }
    var onResizeMoved: ((CGSize) -> Void)? {
        get { grip.onMoved }
        set { grip.onMoved = newValue }
    }
    var onResizeEnded: (() -> Void)? {
        get { grip.onEnded }
        set { grip.onEnded = newValue }
    }

    init(mouseLocation: @escaping () -> CGPoint, reduceMotion: @escaping () -> Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        grip.mouseLocation = mouseLocation
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(transcriptScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: NSTextView.didChangeSelectionNotification, object: transcriptView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The header always lies next to the pill and the grip at the far edge.
    func setAbovePill(_ above: Bool) {
        NSLayoutConstraint.deactivate(above ? belowPillConstraints : abovePillConstraints)
        NSLayoutConstraint.activate(above ? abovePillConstraints : belowPillConstraints)
        background.rounded = above ? .top : .bottom
    }

    /// Nil while the drawer is closed.
    func showMessage(for status: LiveTranscript.Status?) {
        let message = status.flatMap(MeetingPanelCopy.message(for:))
        messageStack.isHidden = message == nil
        messageTitle.stringValue = message?.title ?? ""
        messageBody.stringValue = message?.body ?? ""
        scrollAtBodyTop.isActive = false
        scrollBelowMessage.isActive = false
        (message == nil ? scrollAtBodyTop : scrollBelowMessage).isActive = true
    }

    func showBehind(_ behind: TimeInterval?) {
        let chip = MeetingPanelCopy.behindChip(behind)
        behindChip.isHidden = chip == nil
        if let chip, chip != behindLabel.stringValue { behindLabel.stringValue = chip }
    }

    func showRows(_ newRows: [LiveRow]) {
        guard newRows != rows else { return }
        let oldCount = rows.count
        let keptRows = zip(rows, newRows).prefix { $0 == $1 }.count
        let prefixLength = rowLengths.prefix(keptRows).reduce(0, +)
        let rendered = render(Array(newRows.dropFirst(keptRows)))
        let oldText = transcriptView.string as NSString
        var kept = prefixLength + zip(oldText.substring(from: prefixLength).utf16, rendered.text.string.utf16)
            .prefix { $0 == $1 }.count
        if kept > 0, (0xD800...0xDBFF).contains(oldText.character(at: kept - 1)) { kept -= 1 }
        let selection = transcriptView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin
        let wasSelected = selection.length > 0
        let editingNotes = (window?.firstResponder as? NSTextView).map { $0 !== transcriptView && $0.isEditable } ?? false
        rows = newRows
        rowLengths = Array(rowLengths.prefix(keptRows)) + rendered.lengths
        ignoringScroll {
            transcriptView.textStorage?.replaceCharacters(in: NSRange(location: kept, length: oldText.length - kept),
                with: rendered.text.attributedSubstring(from: NSRange(location: kept - prefixLength,
                    length: rendered.text.length - (kept - prefixLength))))
            if NSMaxRange(selection) <= kept {
                transcriptView.setSelectedRange(selection)
            } else {
                transcriptView.setSelectedRange(NSRange(location: min(selection.location, kept), length: 0))
            }
            sizeTranscript()
            if wasSelected { follow.scrolled(lastRowVisible: false) }
            follow.rowsChanged(from: oldCount, to: newRows.count)
            if follow.isFollowing && !editingNotes {
                scrollToEnd(animated: false)
            } else {
                scrollView.contentView.scroll(to: scrollOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        renderReturnToLive()
    }

    private func render(_ rows: [LiveRow]) -> (text: NSAttributedString, lengths: [Int]) {
        let text = NSMutableAttributedString(string: "")
        var lengths: [Int] = []
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 3
        for row in rows {
            let start = text.length
            switch row.content {
            case .speech(let speaker, let words, let isFinal):
                let heading = "\(RecordedTime.format(row.at))  \(speaker.label)" + (isFinal ? "" : " · Draft") + "\n"
                text.append(NSAttributedString(string: heading, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: Colors.speaker(speaker),
                ]))
                text.append(NSAttributedString(string: MeetingPanelCopy.speech(words, isFinal: isFinal) + "\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: Layout.textSize),
                    .foregroundColor: isFinal ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: body,
                ]))
            case .pause(let duration):
                text.append(NSAttributedString(string: MeetingPanelCopy.pauseRow(at: row.at, duration: duration) + "\n\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
            }
            lengths.append(text.length - start)
        }
        return (text, lengths)
    }

    override func layout() {
        super.layout()
        sizeTranscript()
    }

    private func sizeTranscript() {
        guard let container = transcriptView.textContainer, let manager = transcriptView.layoutManager else { return }
        let width = max(1, scrollView.contentSize.width)
        transcriptView.setFrameSize(NSSize(width: width, height: transcriptView.frame.height))
        container.containerSize = NSSize(width: max(1, width - 2 * transcriptView.textContainerInset.width),
                                         height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(scrollView.contentSize.height, ceil(manager.usedRect(for: container).height) + 2 * transcriptView.textContainerInset.height)
        transcriptView.setFrameSize(NSSize(width: width, height: height))
    }

    func opened() {
        follow.returnToLive()
        scrollToEnd(animated: false)
        renderReturnToLive()
        guard !reduceMotion() else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeDuration
            animator().alphaValue = 1
        }
    }

    func returnToLive() {
        transcriptView.setSelectedRange(NSRange(location: (transcriptView.string as NSString).length, length: 0))
        follow.returnToLive()
        scrollToEnd(animated: !reduceMotion())
        renderReturnToLive()
    }

    /// Runs `work`, which moves or resizes the transcript, without a change to `follow`.
    func ignoringScroll(_ work: () -> Void) {
        let wasMoving = isMovingTranscript
        isMovingTranscript = true
        work()
        isMovingTranscript = wasMoving
    }

    private func scrollToEnd(animated: Bool) {
        guard !rows.isEmpty else { return }
        // The panel's root view sets this view's frame, so the layout starts there.
        superview?.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        sizeTranscript()
        let end = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: transcriptView.bounds.maxY),
                                                  size: clip.bounds.size)).origin
        guard animated else {
            ignoringScroll {
                clip.scroll(to: end)
                scrollView.reflectScrolledClipView(clip)
            }
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
        follow.scrolled(lastRowVisible: transcriptView.selectedRange().length == 0 &&
                        scrollView.contentView.bounds.maxY >= transcriptView.bounds.maxY - 4)
        renderReturnToLive()
    }

    @objc private func selectionChanged() {
        guard !isMovingTranscript, transcriptView.selectedRange().length > 0 else { return }
        follow.scrolled(lastRowVisible: false)
        renderReturnToLive()
    }

    private func renderReturnToLive() {
        let title = follow.returnToLiveTitle
        returnToLiveButton.isHidden = title == nil
        guard let title else { return }
        returnToLiveButton.configure(symbol: MeetingControlsPanel.symbol("arrow.down", size: 11, color: .labelColor),
                                     copy: MeetingPanelCopy.Button(title: title, label: title, tooltip: title))
    }

    @objc private func hideClicked() { onHide?() }
    @objc private func returnToLiveClicked() { returnToLive() }

    private func build() {
        let title = NSTextField.makeLabel(size: 12, weight: .semibold)
        title.stringValue = MeetingPanelCopy.transcriptTitle
        let draft = NSTextField.makeLabel(size: 11.5, color: .secondaryLabelColor)
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

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.isRichText = true
        transcriptView.drawsBackground = false
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.textContainerInset = NSSize(width: Layout.rowInset, height: 10)
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.setAccessibilityLabel(MeetingPanelCopy.transcriptLabel)

        scrollView.documentView = transcriptView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)

        grip.toolTip = MeetingPanelCopy.heightGripTooltip
        returnToLiveButton.isHidden = true

        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        let body = NSLayoutGuide()
        addLayoutGuide(body)
        for view in [pillEdge, header, messageStack, scrollView, transcriptFade, returnToLiveButton, grip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // While the window grows from the pill alone, the drawer is shorter than its parts.
        let gripAtFarEdgeBelow = grip.bottomAnchor.constraint(equalTo: bottomAnchor)
        let headerAtFarEdgeAbove = header.bottomAnchor.constraint(equalTo: bottomAnchor)
        for constraint in [gripAtFarEdgeBelow, headerAtFarEdgeAbove] { constraint.priority = .defaultHigh }

        NSLayoutConstraint.activate([
            pillEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillEdge.heightAnchor.constraint(equalToConstant: 0.5),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Layout.headerHeight),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.messageInset),
            messageStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.messageInset),
            messageStack.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            transcriptFade.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            transcriptFade.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            transcriptFade.topAnchor.constraint(equalTo: scrollView.topAnchor),
            transcriptFade.heightAnchor.constraint(equalToConstant: 14),
            returnToLiveButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            returnToLiveButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Layout.returnToLiveBottom),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: Layout.gripHeight),
        ])
        scrollAtBodyTop = scrollView.topAnchor.constraint(equalTo: body.topAnchor)
        scrollBelowMessage = scrollView.topAnchor.constraint(equalTo: messageStack.bottomAnchor, constant: 8)
        belowPillConstraints = [
            pillEdge.topAnchor.constraint(equalTo: topAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: grip.topAnchor),
            gripAtFarEdgeBelow,
        ]
        abovePillConstraints = [
            pillEdge.bottomAnchor.constraint(equalTo: bottomAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor),
            body.topAnchor.constraint(equalTo: grip.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: header.topAnchor),
            headerAtFarEdgeAbove,
        ]
        NSLayoutConstraint.activate(belowPillConstraints + [scrollAtBodyTop])
        isHidden = true
    }
}
