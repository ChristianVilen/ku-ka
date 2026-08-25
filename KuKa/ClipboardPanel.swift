import Cocoa
import ImageIO

/// Every size and inset the panel draws with, in one place, so the
/// alignments between the search row and the list rows stay in step when
/// they are tuned by eye at first run. File scope rather than nested, so
/// the row and cell views below read the same numbers.
private enum Metrics {
    static let size = NSSize(width: 560, height: 400)
    /// Matches the macOS 26 rounding of a panel this wide.
    static let cornerRadius: CGFloat = 20
    /// Panel edge to the search glyph, and to a row's type icon.
    static let contentInset: CGFloat = 20
    static let iconSlot: CGFloat = 18
    static let iconGap: CGFloat = 10
    static let rowHeight: CGFloat = 34
    /// The table sits nearer the panel edge than the text does, so the
    /// selection highlight can reach past the label without touching the
    /// glass edge.
    static let tableInset: CGFloat = 12
    /// Inset of a row's content inside its cell. `tableInset` plus this
    /// equals `contentInset`, which is what puts a row's icon on the same
    /// vertical line as the search glyph.
    static let cellInset = contentInset - tableInset
    static let thumbnailBox = NSSize(width: 44, height: 24)
    static let searchFontSize: CGFloat = 18
    static let rowFontSize: CGFloat = 13
    static let headerFontSize: CGFloat = 11
    static let headerHeight: CGFloat = 16
    /// Panel top edge down to the search field.
    static let searchTopInset: CGFloat = 16
    /// Search field down to the separator.
    static let separatorGap: CGFloat = 14
    static let separatorHeight: CGFloat = 1
    /// Last row down to the panel's bottom edge.
    static let bottomInset: CGFloat = 10
    /// Gap under the separator in list mode.
    static let listTopGap: CGFloat = 10
    /// Chooser header line down to the first row.
    static let headerGap: CGFloat = 8
    /// Gap under the separator in chooser mode: the list gap, plus the
    /// header line and the space below it.
    static let chooserTopGap = listTopGap + headerHeight + headerGap
    static let selectionInset: CGFloat = 4
    static let selectionVerticalInset: CGFloat = 2
    static let selectionRadius: CGFloat = 8
    /// The panel's top edge sits this far down the screen's visible
    /// height — high enough to read at a glance, low enough not to crowd
    /// the menu bar.
    static let topFraction: CGFloat = 0.25
    static let fadeDuration: TimeInterval = 0.12
}

/// The clipboard-history overlay: a filter field above a list of recorded
/// items, floating on `NSGlassEffectView` glass roughly where Spotlight
/// appears.
///
/// Pure view. Every piece of state it draws — the visible items, the
/// selected row, list-versus-chooser mode — belongs to
/// `ClipboardHistoryController`; the panel reads that state to render and
/// pushes key events back into the controller's entry points. It reads no
/// history, no `NSPasteboard`, and no `Settings` (the one `ClipboardHistory`
/// mention below is a size constant, not stored content).
///
/// Focus discipline matters here: the panel is borderless and
/// `.nonactivatingPanel`, so it takes key status without activating Ku-Ka.
/// The app the user was working in stays frontmost, which is what the
/// synthetic Cmd+V after a paste needs. Never call `NSApp.activate` from
/// this file.
final class ClipboardPanel: FloatingPanel {

    private static let emptyStateText = "Nothing copied yet"
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ClipboardRowCell")
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("ClipboardRowView")

    /// The two chooser rows in the order `ClipboardHistoryController`
    /// indexes them: 0 is "without formatting" and is pre-selected, 1 is
    /// "with formatting".
    private static let chooserRows: [(symbol: String, title: String)] = [
        ("text.alignleft", "Paste without formatting"),
        ("textformat", "Paste with formatting"),
    ]

    // MARK: - Collaborators

    private let controller: ClipboardHistoryController
    private let screens: Screens

    // MARK: - Views

    private let searchGlyph = NSImageView()
    private let searchField = NSTextField()
    private let headerLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var scrollTopConstraint: NSLayoutConstraint!

    /// Thumbnails only — each one is at most 2× `Metrics.thumbnailBox`, so
    /// the panel never holds a full-size bitmap. Keyed by content hash,
    /// which is what makes a row identity stable across reloads. Sized from
    /// the history's own item cap: a smaller cache would evict rows the
    /// list still shows, and arrowing through a history full of images
    /// would re-decode on the main thread all the way down.
    private let thumbnailCache = NSCache<NSString, NSImage>()

    /// Guards against re-entry: `orderOut` makes the panel resign key, and
    /// `resignKey` dismisses.
    private var isDismissing = false

    // MARK: - Init

    init(controller: ClipboardHistoryController, screens: Screens = SystemScreens()) {
        self.controller = controller
        self.screens = screens
        super.init(contentRect: NSRect(origin: .zero, size: Metrics.size))

        // An NSPanel hides itself when its app deactivates. Ku-Ka is a menu
        // bar app that deliberately never activates, so that default would
        // hide the panel the moment it appears.
        hidesOnDeactivate = false
        // A clipboard panel is reached by a global hotkey, so it has to
        // follow the user across spaces and over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        thumbnailCache.countLimit = ClipboardHistory.maxItems

        buildChrome()
    }

    /// Claims *both* of the controller's callback slots: a list change
    /// redraws the panel, and a close request dismisses it. The owner calls
    /// this once, straight after building the panel.
    ///
    /// Deliberately not part of `init`: the claim belongs at the owner's
    /// call site, where anything else that wants to hear about list changes
    /// can see that these two slots are already taken and route through the
    /// panel instead of quietly overwriting them.
    func bindController() {
        controller.onListChanged = { [weak self] in self?.reload() }
        controller.onPanelShouldClose = { [weak self] in self?.dismiss() }
    }

    // MARK: - Key status

    /// The panel has to be key to receive typing, but `.nonactivatingPanel`
    /// keeps Ku-Ka itself in the background while it is.
    override var canBecomeKey: Bool { true }

    /// Clicking away or switching apps closes the panel. Dismissal is
    /// view-side only: the controller's state resets on the next `show()`
    /// through `prepareForPresentation()`.
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// Backstop for Esc when the search field is not handling it (the field
    /// normally is — see `control(_:textView:doCommandBy:)`).
    override func cancelOperation(_ sender: Any?) {
        controller.escPressed()
    }

    // MARK: - Presentation

    /// Opens the panel on the screen under the pointer, with an empty
    /// filter and the newest item selected.
    func show() {
        assert(controller.onListChanged != nil, "call bindController() before show()")
        controller.prepareForPresentation()
        searchField.stringValue = ""
        reload()

        if let origin = targetOrigin(mouseLocation: NSEvent.mouseLocation) {
            setFrameOrigin(origin)
        }

        // A second hotkey press while the panel is already up re-homes it
        // on the cursor's screen and refreshes the list, but must not
        // restart the fade — that would blink a panel being read.
        if !isVisible {
            setAlphaImmediately(shouldFade ? 0 : 1)
        }

        // Not `NSApp.activate`: the app the user was in must stay frontmost.
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)

        guard shouldFade, alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Hides the panel at once. No fade out: a paste dismisses the panel
    /// and then sends Cmd+V a moment later, and a window still fading would
    /// be in the way of that keystroke.
    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        // Ends the field editor before the window goes away, so the next
        // `show()` starts from a clean one rather than inheriting a stale
        // editing session. `show()` re-establishes first responder.
        makeFirstResponder(nil)
        orderOut(nil)
        setAlphaImmediately(1)
        // Thumbnails are per-session: a screenshot deleted between two
        // openings of the panel must not come back from this cache.
        thumbnailCache.removeAllObjects()
        isDismissing = false
    }

    private var shouldFade: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Writes alpha through a zero-duration animation, which also replaces
    /// any fade still in flight. A plain `alphaValue =` would be overwritten
    /// by the running animation on its next tick.
    private func setAlphaImmediately(_ value: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = value
        }
    }

    /// Horizontally centered on the screen under the pointer, with the top
    /// edge a quarter of the way down that screen's visible height.
    private func targetOrigin(mouseLocation: CGPoint) -> NSPoint? {
        let layout = screens.all
        // A cursor parked in the menu bar sits exactly on its screen's top
        // edge, and `contains` treats maxY as outside the frame. Without
        // the second rule the panel would jump to the primary screen every
        // time the hotkey is pressed from up there.
        let screen = layout.first { $0.frame.contains(mouseLocation) }
            ?? layout.first {
                mouseLocation.x >= $0.frame.minX
                    && mouseLocation.x < $0.frame.maxX
                    && abs(mouseLocation.y - $0.frame.maxY) < 1
            }
            ?? layout.first
        guard let screen else { return nil }

        let visible = screen.visibleFrame
        let x = visible.midX - Metrics.size.width / 2
        let topEdge = visible.maxY - visible.height * Metrics.topFraction
        // Keep the whole panel on screen: not past the visible bottom, and
        // not past the visible top. The top clamp is applied last so it
        // wins on a display shorter than the panel, where the two disagree
        // — a panel running off the bottom is far better than one whose
        // search field is off the top.
        var y = max(topEdge - Metrics.size.height, visible.minY)
        y = min(y, visible.maxY - Metrics.size.height)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    // MARK: - Rendering

    /// Redraws everything the controller currently says to show. Cheap
    /// enough to be the single entry point for every change — the list
    /// caps out at `ClipboardHistory.maxItems` rows.
    func reload() {
        let isChooser = controller.mode == .chooser
        headerLabel.isHidden = !isChooser
        headerLabel.stringValue = isChooser ? "Paste “\(controller.chooserItem?.previewLabel ?? "")”" : ""
        scrollTopConstraint.constant = isChooser ? Metrics.chooserTopGap : Metrics.listTopGap

        tableView.reloadData()
        syncSelection()
    }

    private func syncSelection() {
        let row = controller.selectionIndex
        guard row >= 0, row < tableView.numberOfRows, rowsAreSelectable else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// False only while the list mode shows its empty-state row, which is a
    /// message rather than something to paste. Every other row, in either
    /// mode, can be selected.
    private var rowsAreSelectable: Bool {
        !(controller.mode == .list && controller.visibleItems.isEmpty)
    }

    // MARK: - Mouse

    /// The clicked row when it is a real, selectable one — nil for a click
    /// on the empty-state message or on blank space below the last row.
    private var clickedSelectableRow: Int? {
        let row = tableView.clickedRow
        guard row >= 0, rowsAreSelectable else { return nil }
        return row
    }

    /// `selectRow` is list mode only, by design — the chooser's two rows
    /// are not history rows. Since the chooser is exactly two rows, a
    /// single step there always lands on the clicked one.
    private func selectClickedRow(_ row: Int) {
        guard controller.mode == .chooser else {
            controller.selectRow(row)
            return
        }
        if row > controller.selectionIndex {
            controller.moveSelectionDown()
        } else if row < controller.selectionIndex {
            controller.moveSelectionUp()
        }
    }

    @objc private func rowClicked() {
        guard let row = clickedSelectableRow else { return }
        selectClickedRow(row)
    }

    @objc private func rowDoubleClicked() {
        guard let row = clickedSelectableRow else { return }
        selectClickedRow(row)
        controller.enterPressed()
    }

    // MARK: - Chrome

    private func buildChrome() {
        // Frameless: the constraints below own its geometry.
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.cornerRadius = Metrics.cornerRadius
        // The list scrolls right up to the glass edge, so the rounding has
        // to clip it rather than only being painted behind it.
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        configureSearchRow()
        configureHeader()
        configureTable()

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for view in [searchGlyph, searchField, separator, headerLabel, scrollView] {
            container.addSubview(view)
        }

        scrollTopConstraint = scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Metrics.listTopGap)

        NSLayoutConstraint.activate([
            searchGlyph.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.contentInset),
            searchGlyph.widthAnchor.constraint(equalToConstant: Metrics.iconSlot),
            searchGlyph.heightAnchor.constraint(equalToConstant: Metrics.iconSlot),
            searchGlyph.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.searchTopInset),
            searchField.leadingAnchor.constraint(equalTo: searchGlyph.trailingAnchor, constant: Metrics.iconGap),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.contentInset),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Metrics.separatorGap),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: Metrics.separatorHeight),

            headerLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Metrics.listTopGap),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.contentInset),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.contentInset),
            headerLabel.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),

            scrollTopConstraint,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.tableInset),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.tableInset),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metrics.bottomInset),
        ])

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Metrics.size))
        // `.regular` rather than `.clear`: this panel is mostly text, and
        // regular glass is the one tuned to keep text legible over any
        // wallpaper. `tintColor` is left unset so the glass stays neutral;
        // it is the knob to reach for if the panel turns out short of
        // contrast on a busy light desktop at first run.
        glass.style = .regular
        glass.cornerRadius = Metrics.cornerRadius
        glass.contentView = container
        contentView = glass

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            container.topAnchor.constraint(equalTo: glass.topAnchor),
            container.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
    }

    private func configureSearchRow() {
        let font = NSFont.systemFont(ofSize: Metrics.searchFontSize)

        searchGlyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchGlyph.contentTintColor = .secondaryLabelColor
        searchGlyph.imageScaling = .scaleProportionallyUpOrDown
        searchGlyph.translatesAutoresizingMaskIntoConstraints = false

        // A plain borderless field rather than an NSSearchField: a search
        // field brings its own bezel, and a second rounded surface inside
        // the glass reads as clutter.
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = font
        searchField.textColor = .labelColor
        searchField.maximumNumberOfLines = 1
        searchField.cell?.usesSingleLineMode = true
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Type to filter…",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        searchField.delegate = self
        searchField.setAccessibilityLabel("Filter clipboard history")
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureHeader() {
        headerLabel.font = .systemFont(ofSize: Metrics.headerFontSize, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.maximumNumberOfLines = 1
        headerLabel.cell?.lineBreakMode = .byTruncatingTail
        headerLabel.isHidden = true
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipboardColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = Metrics.rowHeight
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        // Transparent so the glass carries the background.
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        // Arrow keys and Return are read by the search field, which keeps
        // first responder for the whole life of the panel.
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        // The clip view paints its own background too, and that one would
        // sit between the rows and the glass.
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Row content

    private func symbolName(for item: ClipboardItem) -> String {
        switch item.kind {
        case .image:
            return "photo"
        case .text:
            // Rich text earns a different glyph because it behaves
            // differently: Return on it opens the formatting chooser.
            return item.hasRichFlavors ? "textformat" : "text.alignleft"
        }
    }

    /// Decodes at thumbnail size on demand and caches the small result. The
    /// item's own PNG bytes belong to the controller's history; nothing
    /// full-size is ever built or kept here.
    private func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard case .image(let png, _) = item.kind else { return nil }
        let key = item.contentHash as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = Self.decodeThumbnail(png: png, fitting: Metrics.thumbnailBox) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    private static func decodeThumbnail(png: Data, fitting box: NSSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        // 2× the box keeps the thumbnail crisp on Retina. ImageIO decodes
        // straight to this size, so the full-resolution bitmap is never
        // created in the first place.
        let maxPixelSize = Int(max(box.width, box.height) * 2)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(box.width / pixelWidth, box.height / pixelHeight)
        let displaySize = NSSize(
            width: max((pixelWidth * scale).rounded(), 1),
            height: max((pixelHeight * scale).rounded(), 1)
        )
        return NSImage(cgImage: cgImage, size: displaySize)
    }
}

// MARK: - Search field

extension ClipboardPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        // Chooser mode has nothing to filter, so stray typing is put back
        // at once rather than sitting in the field until the chooser
        // closes. Otherwise the field is the query's only writer, which is
        // what keeps the two in step without a second sync point.
        guard controller.mode == .list else {
            searchField.stringValue = controller.searchQuery
            return
        }
        controller.setSearchQuery(searchField.stringValue)
    }

    /// The four keys the panel steers with. Everything else falls through
    /// to the field editor and edits the filter.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            controller.moveSelectionUp()
        case #selector(NSResponder.moveDown(_:)):
            controller.moveSelectionDown()
        case #selector(NSResponder.insertNewline(_:)):
            controller.enterPressed()
        case #selector(NSResponder.cancelOperation(_:)):
            controller.escPressed()
        default:
            return false
        }
        return true
    }
}

// MARK: - Table

extension ClipboardPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch controller.mode {
        case .chooser:
            return Self.chooserRows.count
        case .list:
            // An empty list still draws one row: the "nothing copied yet"
            // message.
            return max(controller.visibleItems.count, 1)
        }
    }
}

extension ClipboardPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? ClipboardHistoryRowView {
            return reused
        }
        let rowView = ClipboardHistoryRowView()
        rowView.identifier = Self.rowIdentifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rowsAreSelectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? ClipboardHistoryCellView)
            ?? ClipboardHistoryCellView(identifier: Self.cellIdentifier)

        if controller.mode == .chooser {
            let option = Self.chooserRows[row]
            cell.configure(symbolName: option.symbol, text: option.title, thumbnail: nil, isMessage: false)
        } else if row < controller.visibleItems.count {
            let item = controller.visibleItems[row]
            cell.configure(
                symbolName: symbolName(for: item),
                text: item.previewLabel,
                thumbnail: thumbnail(for: item),
                isMessage: false
            )
        } else {
            // The icon slot is left empty rather than removed, so the
            // message starts on the same line as every real row's label.
            cell.configure(symbolName: nil, text: Self.emptyStateText, thumbnail: nil, isMessage: true)
        }
        return cell
    }
}

// MARK: - Row views

/// Draws the selection as an inset rounded bar rather than the full-width
/// system band: on glass a bar that runs edge to edge fights the panel's
/// own rounding.
private final class ClipboardHistoryRowView: NSTableRowView {
    /// The glass is the background. Anything AppKit would paint here would
    /// only sit in front of it and mute it.
    override func drawBackground(in dirtyRect: NSRect) {}

    /// The search field holds first responder, so the table is never
    /// "focused" in AppKit's sense. Reporting `.emphasized` anyway keeps
    /// the selected row vivid, which is the whole point of it.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: Metrics.selectionInset, dy: Metrics.selectionVerticalInset)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.selectionRadius, yRadius: Metrics.selectionRadius).fill()
    }
}

/// One row: type icon, one-line label, and — for images — a small
/// thumbnail on the trailing edge. The thumbnail sits last so that every
/// row's label starts on the same vertical line.
private final class ClipboardHistoryCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()
    /// True for the "nothing copied yet" row, which stays secondary
    /// coloured because it is never selected.
    private var isMessage = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor

        label.font = .systemFont(ofSize: Metrics.rowFontSize)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        label.cell?.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        thumbnailView.imageScaling = .scaleProportionallyDown
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.setContentHuggingPriority(.required, for: .horizontal)

        // NSTableCellView's own outlets: VoiceOver reads a row through
        // them, so a row without them announces as an unlabelled group.
        textField = label
        imageView = icon

        let stack = NSStackView(views: [icon, label, thumbnailView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Metrics.iconGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.cellInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.cellInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSlot),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSlot),
            thumbnailView.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.thumbnailBox.width),
            thumbnailView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.thumbnailBox.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Colours follow the row's background: on the accent highlight the
    /// icon and label switch to the matching foreground colour.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    func configure(symbolName: String?, text: String, thumbnail: NSImage?, isMessage: Bool) {
        self.isMessage = isMessage
        icon.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        label.stringValue = text
        label.toolTip = text
        thumbnailView.image = thumbnail
        thumbnailView.isHidden = thumbnail == nil
        applyColors()
    }

    private func applyColors() {
        let isHighlighted = backgroundStyle == .emphasized
        let foreground: NSColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
        label.textColor = isMessage ? .secondaryLabelColor : foreground
        icon.contentTintColor = isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
