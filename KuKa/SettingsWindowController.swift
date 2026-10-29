import Cocoa

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let thumbnailChoices: [(title: String, duration: Double)] = [
        ("3 seconds", 3), ("5 seconds", 5), ("15 seconds", 15), ("Forever", 0)
    ]
    typealias Picker = @MainActor (NSWindow, URL?, @escaping (URL?) -> Void) -> Void
    let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    let windowTiling = NSButton(checkboxWithTitle: "Enable window tiling", target: nil, action: nil)
    let clipboardHistory = NSButton(checkboxWithTitle: "Record clipboard history", target: nil, action: nil)
    let displayAwake = NSButton(checkboxWithTitle: "Keep display awake during Keep Awake", target: nil, action: nil)
    let thumbnailDuration = NSPopUpButton()
    let summaryTool = NSPopUpButton()
    let chooseMeetingsFolder = NSButton(title: "Choose…", target: nil, action: nil)
    let chooseBackground = NSButton(title: "Choose…", target: nil, action: nil)
    let clearBackground = NSButton(title: "Clear", target: nil, action: nil)
    let loginError = NSTextField(wrappingLabelWithString: "")
    private let folderPath = NSTextField(labelWithString: "")
    private let backgroundPath = NSTextField(labelWithString: "")
    private let settings: Settings
    private let chooseFolder: Picker
    private let chooseContext: Picker
    private let present: (NSWindow) -> Void
    private let activation: OrdinaryWindowActivation
    var onTilingChanged: ((Bool) -> Void)?
    var onClipboardChanged: ((Bool) -> Void)?
    var onDisplayAwakeChanged: ((Bool) -> Void)?
    var onMeetingsFolderChanged: ((URL) -> Void)?

    init(settings: Settings,
         chooseFolder: @escaping Picker = SettingsWindowController.folderPicker,
         chooseContext: @escaping Picker = SettingsWindowController.contextPicker,
         present: @escaping (NSWindow) -> Void = {
             if !$0.isVisible { $0.center() }
             NSApp.activate()
             $0.makeKeyAndOrderFront(nil)
         },
         activation: OrdinaryWindowActivation = .shared) {
        self.settings = settings
        self.chooseFolder = chooseFolder
        self.chooseContext = chooseContext
        self.present = present
        self.activation = activation
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "Ku-Ka Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 580, height: 400)
        window.maxSize = NSSize(width: 580, height: 1000)
        super.init(window: window)
        window.delegate = self
        buildForm()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        loginError.stringValue = ""
        loginError.isHidden = true
        refresh()
        guard let window else { return }
        activation.open(window)
        present(window)
    }

    func windowWillClose(_ notification: Notification) {
        if let window { activation.close(window) }
    }

    private func refresh() {
        launchAtLogin.state = settings.launchAtLogin ? .on : .off
        windowTiling.state = settings.windowTilingEnabled ? .on : .off
        clipboardHistory.state = settings.clipboardHistoryEnabled ? .on : .off
        displayAwake.state = settings.keepDisplayAwake ? .on : .off
        let duration = settings.thumbnailDuration
        thumbnailDuration.removeAllItems()
        for choice in Self.thumbnailChoices {
            thumbnailDuration.addItem(withTitle: choice.title)
            thumbnailDuration.lastItem?.representedObject = choice.duration
        }
        if let item = thumbnailDuration.itemArray.first(where: { $0.representedObject as? Double == duration }) {
            thumbnailDuration.select(item)
        } else {
            thumbnailDuration.addItem(withTitle: "Custom (\(duration) seconds)")
            thumbnailDuration.lastItem?.representedObject = duration
            thumbnailDuration.select(thumbnailDuration.lastItem)
        }
        summaryTool.selectItem(at: SummaryTool.allCases.firstIndex(of: settings.summaryTool)!)
        folderPath.stringValue = settings.meetingsFolder.path
        backgroundPath.stringValue = settings.meetingContextFile?.path ?? "None"
        folderPath.toolTip = folderPath.stringValue
        backgroundPath.toolTip = backgroundPath.stringValue
        folderPath.setAccessibilityValue(folderPath.stringValue)
        backgroundPath.setAccessibilityValue(backgroundPath.stringValue)
        clearBackground.isEnabled = settings.meetingContextFile != nil
    }

    private func buildForm() {
        for (control, action) in [
            (launchAtLogin, #selector(loginChanged)), (windowTiling, #selector(tilingChanged)),
            (clipboardHistory, #selector(clipboardChanged)), (displayAwake, #selector(displayChanged)),
            (chooseMeetingsFolder, #selector(folderClicked)), (chooseBackground, #selector(contextClicked)),
            (clearBackground, #selector(clearClicked)), (thumbnailDuration, #selector(durationChanged)),
            (summaryTool, #selector(toolChanged))
        ] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        thumbnailDuration.setAccessibilityLabel("Show thumbnail for")
        summaryTool.setAccessibilityLabel("Summary tool")
        chooseMeetingsFolder.setAccessibilityLabel("Choose meetings folder")
        chooseBackground.setAccessibilityLabel("Choose background file")
        clearBackground.setAccessibilityLabel("Clear background file")
        folderPath.setAccessibilityLabel("Meetings folder")
        backgroundPath.setAccessibilityLabel("Background file")
        for (index, tool) in SummaryTool.allCases.enumerated() {
            summaryTool.addItem(withTitle: tool.title)
            summaryTool.lastItem?.tag = index
        }
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        func heading(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            content.addArrangedSubview(label)
        }
        func row(_ title: String, _ views: [NSView]) {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 125).isActive = true
            let row = NSStackView(views: [label] + views)
            row.spacing = 8
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        heading("General")
        for view in [launchAtLogin, loginError, windowTiling, clipboardHistory, displayAwake] {
            content.addArrangedSubview(view)
        }
        loginError.textColor = .systemRed
        loginError.isHidden = true
        heading("Screenshots")
        row("Show thumbnail for", [thumbnailDuration])
        heading("Meeting Notes")
        row("Meetings folder", [folderPath, chooseMeetingsFolder])
        row("Summary tool", [summaryTool])
        let toolNote = NSTextField(wrappingLabelWithString: "Automatic tries Antigravity, then Claude Code. An explicit choice uses only that tool. Changes apply when the next job starts.")
        toolNote.textColor = .secondaryLabelColor
        content.addArrangedSubview(toolNote)
        row("Background file", [backgroundPath, chooseBackground, clearBackground])
        let contextNote = NSTextField(wrappingLabelWithString: "The complete background file goes with the transcript. Automatic may send it to both providers on fallback. Clear keeps the file.")
        contextNote.textColor = .secondaryLabelColor
        content.addArrangedSubview(contextNote)
        for label in [folderPath, backgroundPath] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = SettingsDocument()
        scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        for note in [toolNote, contextNote, loginError] {
            note.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        window?.contentView = scroll
        let controls: [NSView] = [launchAtLogin, windowTiling, clipboardHistory, displayAwake,
                                 thumbnailDuration, chooseMeetingsFolder, summaryTool, chooseBackground, clearBackground]
        for (control, next) in zip(controls, controls.dropFirst() + [launchAtLogin]) {
            control.nextKeyView = next
        }
        window?.initialFirstResponder = launchAtLogin
    }

    @objc private func loginChanged() {
        let failure = settings.setLaunchAtLogin(launchAtLogin.state == .on)
        loginError.stringValue = failure.map { "Could not change launch at login. \($0)" } ?? ""
        loginError.isHidden = failure == nil
        launchAtLogin.state = settings.launchAtLogin ? .on : .off
    }

    @objc private func tilingChanged() {
        settings.windowTilingEnabled = windowTiling.state == .on
        onTilingChanged?(settings.windowTilingEnabled)
    }

    @objc private func clipboardChanged() {
        settings.clipboardHistoryEnabled = clipboardHistory.state == .on
        onClipboardChanged?(settings.clipboardHistoryEnabled)
    }

    @objc private func displayChanged() {
        settings.keepDisplayAwake = displayAwake.state == .on
        onDisplayAwakeChanged?(settings.keepDisplayAwake)
    }

    @objc private func durationChanged() {
        guard let duration = thumbnailDuration.selectedItem?.representedObject as? Double else { return }
        settings.thumbnailDuration = duration
    }

    @objc private func toolChanged() {
        settings.summaryTool = SummaryTool.allCases[summaryTool.indexOfSelectedItem]
    }

    @objc private func folderClicked() {
        guard let window else { return }
        chooseFolder(window, settings.meetingsFolder) { [weak self] url in
            guard let self, let url else { return }
            settings.meetingsFolder = url
            refresh()
            onMeetingsFolderChanged?(url)
        }
    }

    @objc private func contextClicked() {
        guard let window else { return }
        chooseContext(window, settings.meetingContextFile) { [weak self] url in
            guard let self, let url else { return }
            settings.meetingContextFile = url
            refresh()
        }
    }

    @objc private func clearClicked() {
        settings.meetingContextFile = nil
        refresh()
    }

    static func folderPicker(_ window: NSWindow, _ current: URL?, _ completion: @escaping (URL?) -> Void) {
        pick(window, current: current, directory: true, completion: completion)
    }

    static func contextPicker(_ window: NSWindow, _ current: URL?, _ completion: @escaping (URL?) -> Void) {
        pick(window, current: current?.deletingLastPathComponent(), directory: false, completion: completion)
    }

    private static func pick(_ window: NSWindow, current: URL?, directory: Bool, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        panel.prompt = "Choose"
        panel.title = directory ? "Choose meetings folder" : "Choose background file"
        panel.beginSheetModal(for: window) { result in completion(result == .OK ? panel.url : nil) }
    }
}

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}
