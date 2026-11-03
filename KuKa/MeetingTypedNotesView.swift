import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

@MainActor
final class MeetingTypedNotesView: NSView {
    let session: MeetingTypedNotesSession
    private let requestUpdate: () -> Void
    private let confirmReload: @MainActor (NSWindow) -> Bool
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let saveLabel = NSTextField.makeWrappingLabel(size: 12, color: .secondaryLabelColor)
    private let summaryLabel = NSTextField.makeWrappingLabel(size: 12, color: .secondaryLabelColor)
    private lazy var retry = NSButton(title: "Retry save", target: self, action: #selector(retrySave))
    private lazy var reload = NSButton(title: "Reload saved notes", target: self, action: #selector(reloadSaved))
    private lazy var update = NSButton(title: "Update summary", target: self, action: #selector(updateSummary))
    private var editors: [UUID: NoteRowTextView] = [:]
    private var timeLabels: [UUID: NSTextField] = [:]
    private var renderedIDs: [UUID] = []
    private var renderedAttachments: [[String]] = []
    private let editingUndo = UndoManager()
    private var focusedEntry: UUID?

    init(session: MeetingTypedNotesSession, requestUpdate: @escaping () -> Void,
         confirmReload: @escaping @MainActor (NSWindow) -> Bool = MeetingTypedNotesView.confirmReload) {
        self.session = session
        self.requestUpdate = requestUpdate
        self.confirmReload = confirmReload
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 330))
        registerForDraggedTypes([.png, .tiff, .fileURL])
        wantsLayer = true
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = NotesDocumentView()
        document.onDrop = { [weak self] in self?.dropImage(from: $0) ?? false }
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)
        ])
        scroll.documentView = document
        scroll.frame = NSRect(x: 0, y: 0, width: 444, height: 220)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [retry, reload, update])
        buttons.spacing = 8
        buttons.detachesHiddenViews = true
        let title = NSTextField.makeLabel(size: 13, weight: .semibold)
        title.stringValue = session.meeting.title
        title.toolTip = session.meeting.title
        let outer = NSStackView(views: [title, scroll, saveLabel, summaryLabel, buttons])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalTo: outer.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            saveLabel.widthAnchor.constraint(equalTo: outer.widthAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: outer.widthAnchor)
        ])
        session.onChange = { [weak self] in self?.render() }
        if session.entries.isEmpty { session.insertEntry() }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NoteRowTextView.acceptsImage(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropImage(from: sender.draggingPasteboard)
    }

    @discardableResult
    func dropImage(from board: NSPasteboard) -> Bool {
        let focused = window?.firstResponder as? NoteRowTextView
        let last = session.entries.last.flatMap { editors[$0.id] }
        return (focused ?? last)?.dropImage(from: board) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        MeetingControlsPanel.Colors.drawer.setFill()
        dirtyRect.fill()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let editor = window?.firstResponder as? NoteRowTextView, editors[editor.entryID] === editor {
            focusedEntry = editor.entryID
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func focus() {
        let editor = focusedEntry.flatMap { editors[$0] } ?? session.entries.first.flatMap { editors[$0.id] }
        if let editor { window?.makeFirstResponder(editor) }
    }

    private func render() {
        if session.entries.isEmpty {
            session.insertEntry()
            return
        }
        let ids = session.entries.map(\.id)
        let attachments = session.entries.map(\.attachments)
        if ids != renderedIDs || attachments != renderedAttachments {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            for entry in session.entries {
                let label = NSTextField.makeLabel(size: 11, color: .secondaryLabelColor)
                timeLabels[entry.id] = label
                let editor = editors[entry.id] ?? makeEditor(entry)
                editors[entry.id] = editor
                stack.addArrangedSubview(label)
                stack.addArrangedSubview(editor)
                editor.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
                for name in entry.attachments {
                    guard let data = session.screenshot(named: name), let image = NSImage(data: data) else { continue }
                    let imageView = NSImageView(image: image)
                    imageView.imageScaling = .scaleProportionallyDown
                    imageView.setAccessibilityLabel("Screenshot")
                    stack.addArrangedSubview(imageView)
                    imageView.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
                    imageView.heightAnchor.constraint(equalToConstant: 140).isActive = true
                }
            }
            renderedIDs = ids
            renderedAttachments = attachments
        }
        for entry in session.entries {
            switch entry.time {
            case .recording(let time): timeLabels[entry.id]?.stringValue = RecordedTime.format(time)
            case .afterRecording: timeLabels[entry.id]?.stringValue = "After recording"
            case .undated: timeLabels[entry.id]?.stringValue = "Undated"
            }
            if let editor = editors[entry.id], editor.string != entry.text {
                editor.replaceFromSession(entry.text)
            }
        }
        saveLabel.stringValue = session.saveError.map { "Not saved. " + $0 } ?? "Saved to notes.md"
        summaryLabel.stringValue = session.summaryMessage
        retry.isHidden = session.saveError == nil
        reload.isHidden = session.saveError == nil
        update.isEnabled = session.canUpdateSummary
    }

    private func makeEditor(_ entry: MeetingNoteEntry) -> NoteRowTextView {
        let editor = NoteRowTextView(entryID: entry.id)
        editor.editingUndo = editingUndo
        editor.string = entry.text
        editor.onEdit = { [weak self, weak editor] in
            guard let self, let editor else { return }
            editor.invalidateIntrinsicContentSize()
            self.session.updateEntry(id: editor.entryID, text: editor.string)
        }
        editor.font = .systemFont(ofSize: 15)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.onNewRow = { [weak self, weak editor] in
            guard let self, let editor else { return }
            let previous = self.session.entries
            let text = editor.string as NSString
            let selection = editor.selectedRange()
            let first = text.substring(to: selection.location)
            let rest = text.substring(from: NSMaxRange(selection))
            self.session.updateEntry(id: entry.id, text: first)
            let next = self.session.insertEntry(after: entry.id)
            self.session.updateEntry(id: next, text: rest)
            self.registerUndo(previous)
            self.window?.makeFirstResponder(self.editors[next])
        }
        editor.onImage = { [weak self] data in
            guard let self else { return }
            let previous = self.session.entries
            try self.session.addScreenshot(data, to: entry.id)
            self.registerUndo(previous)
        }
        return editor
    }

    private func registerUndo(_ previous: [MeetingNoteEntry]) {
        editingUndo.registerUndo(withTarget: self) { view in
            let current = view.session.entries
            view.session.replaceEntries(previous)
            view.registerUndo(current)
        }
    }

    @objc private func retrySave() { session.save() }
    @objc private func reloadSaved() {
        guard let window, confirmReload(window) else { return }
        session.reloadSavedNotes()
        if session.saveError == nil { editingUndo.removeAllActions() }
    }
    private static func confirmReload(_ window: NSWindow) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace your draft with the saved notes?"
        alert.informativeText = "Copy any text you want to keep first."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reload saved notes")
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func updateSummary() { if session.canUpdateSummary { requestUpdate() } }
}

private final class NotesDocumentView: NSView {
    override var isFlipped: Bool { true }
    var onDrop: ((NSPasteboard) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NoteRowTextView.acceptsImage(from: sender.draggingPasteboard) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

final class NoteRowTextView: NSTextView, NSTextStorageDelegate {
    let entryID: UUID
    var onNewRow: (() -> Void)?
    var onImage: ((Data) throws -> Void)?
    var onEdit: (() -> Void)?
    private var isReplacing = false
    var editingUndo: UndoManager?
    override var undoManager: UndoManager? { editingUndo }

    init(entryID: UUID) {
        self.entryID = entryID
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        textStorage?.delegate = self
        registerForDraggedTypes([.png, .tiff, .fileURL])
        setAccessibilityLabel("Meeting note")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if !isReplacing && editedMask.contains(.editedCharacters) { onEdit?() }
    }

    func replaceFromSession(_ text: String) {
        isReplacing = true
        string = text
        isReplacing = false
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return NSSize(width: NSView.noIntrinsicMetric, height: 24) }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(24, ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) { onNewRow?(); return }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        if pasteImage(from: .general) { return }
        super.paste(sender)
    }
    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return false }
        do { try onImage?(Self.png(data)); return true } catch { NSSound.beep(); return true }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.acceptsImage(from: sender.draggingPasteboard) ? .copy : []
    }
    static func acceptsImage(from board: NSPasteboard) -> Bool {
        let types = board.types ?? []
        return types.contains(.png) || types.contains(.tiff) || types.contains(.fileURL)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropImage(from: sender.draggingPasteboard)
    }
    @discardableResult
    func dropImage(from board: NSPasteboard) -> Bool {
        if pasteImage(from: board) { return true }
        guard let url = NSURL(from: board) as URL?, url.isFileURL else { return false }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 20_000_000 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 20_000_001), data.count <= 20_000_000 else { return false }
        do { try onImage?(Self.png(data)); return true } catch { NSSound.beep(); return false }
    }
    private static func png(_ data: Data) throws -> Data {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_000, height <= 16_000, width * height <= 40_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MeetingStepError("The screenshot is invalid or too large.")
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw MeetingStepError("Could not convert the screenshot.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), result.length <= 20_000_000 else {
            throw MeetingStepError("The screenshot is too large.")
        }
        return result as Data
    }
}
