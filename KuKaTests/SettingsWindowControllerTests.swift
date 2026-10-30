import XCTest
@testable import KuKa

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: Settings!
    private var login: FakeLoginItem!
    private var sut: SettingsWindowController!
    private var picked: URL?

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "SettingsWindowControllerTests")!
        defaults.removePersistentDomain(forName: "SettingsWindowControllerTests")
        login = FakeLoginItem()
        settings = Settings(defaults: defaults, loginItem: login)
        settings.meetingsFolder = URL(fileURLWithPath: "/Users/example/Meetings")
        sut = SettingsWindowController(settings: settings,
            chooseFolder: { [unowned self] _, _, completion in completion(picked) },
            chooseContext: { [unowned self] _, _, completion in completion(picked) },
            present: { _ in }, activation: OrdinaryWindowActivation(setPolicy: { _ in }))
    }

    override func tearDown() async throws {
        sut.close()
        sut = nil
        defaults.removePersistentDomain(forName: "SettingsWindowControllerTests")
    }

    func testSwitchesSavePreferencesAndApplyTypedEffects() {
        var effects: [Bool] = []
        var calendar: [Bool] = []
        sut.onTilingChanged = { effects.append($0) }
        sut.onClipboardChanged = { effects.append($0) }
        sut.onDisplayAwakeChanged = { effects.append($0) }
        sut.onCalendarRemindersChanged = { calendar.append($0) }
        sut.show()
        for control in [sut.launchAtLogin, sut.windowTiling, sut.clipboardHistory, sut.displayAwake,
                        sut.calendarReminders, sut.teamsSpeakerNames] {
            control.performClick(nil)
        }
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertFalse(settings.windowTilingEnabled)
        XCTAssertFalse(settings.clipboardHistoryEnabled)
        XCTAssertFalse(settings.keepDisplayAwake)
        XCTAssertTrue(settings.teamsSpeakerNamesEnabled)
        XCTAssertEqual(effects, [false, false, false])
        XCTAssertEqual(calendar, [true])
        XCTAssertNil(defaults.object(forKey: "calendarRecordingRemindersEnabled"),
                     "only CalendarReminderController.setEnabled saves the calendar choice")
    }

    func testCalendarStatusSaysWhatTheUserMustDoAndShowsTheSavedChoice() {
        sut.show()
        let texts: [(CalendarReminderController.Status, String)] = [
            (.off, ""),
            (.ready, ""),
            (.requestingAccess, "Asking for Calendar access…"),
            (.calendarAccessRequired, "Allow Calendar access for Ku-Ka in System Settings > Privacy & Security > Calendars."),
            (.notificationsRequired, "Allow notifications for Ku-Ka in System Settings > Notifications."),
            (.readFailed, "Ku-Ka could not read your calendars. It tries again every minute.")
        ]
        for (status, text) in texts {
            sut.showCalendarStatus(status)
            XCTAssertEqual(sut.calendarStatus.stringValue, text, "\(status)")
            XCTAssertEqual(sut.calendarStatus.isHidden, text.isEmpty, "\(status)")
        }
        XCTAssertEqual(sut.calendarReminders.state, .off)
        settings.calendarRecordingRemindersEnabled = true
        sut.showCalendarStatus(.ready)
        XCTAssertEqual(sut.calendarReminders.state, .on)
    }

    func testChooseCancelClearAndFolderCallback() {
        var folders: [URL] = []
        sut.onMeetingsFolderChanged = { folders.append($0) }
        sut.show()
        picked = URL(fileURLWithPath: "/Users/example/Notes")
        sut.chooseMeetingsFolder.performClick(nil)
        XCTAssertEqual(settings.meetingsFolder.path, "/Users/example/Notes")
        XCTAssertEqual(folders.map(\.path), ["/Users/example/Notes"])
        picked = URL(fileURLWithPath: "/Users/example/background.md")
        sut.chooseBackground.performClick(nil)
        XCTAssertEqual(settings.meetingContextFile?.path, "/Users/example/background.md")
        picked = nil
        sut.chooseBackground.performClick(nil)
        sut.chooseMeetingsFolder.performClick(nil)
        XCTAssertEqual(settings.meetingContextFile?.path, "/Users/example/background.md")
        XCTAssertEqual(folders.count, 1)
        sut.clearBackground.performClick(nil)
        XCTAssertNil(defaults.object(forKey: "meetingContextFile"))
    }

    func testClearingBackgroundKeepsTheChosenFileOnDisk() throws {
        let file = try makeTemporaryDirectory().appendingPathComponent("background.md")
        try "Synthetic background".write(to: file, atomically: true, encoding: .utf8)
        sut.show()
        picked = file
        sut.chooseBackground.performClick(nil)
        XCTAssertEqual(settings.meetingContextFile, file)
        sut.clearBackground.performClick(nil)
        XCTAssertNil(settings.meetingContextFile)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Synthetic background")
    }

    func testReopeningRefreshesWithoutWritingAndKeepsCustomDuration() {
        defaults.set(7.5, forKey: "thumbnailDuration")
        let before = defaults.persistentDomain(forName: "SettingsWindowControllerTests")! as NSDictionary
        let window = sut.window
        sut.show()
        sut.close()
        settings.windowTilingEnabled = false
        settings.teamsSpeakerNamesEnabled = true
        sut.show()
        XCTAssertTrue(sut.window === window)
        XCTAssertEqual(sut.windowTiling.state, .off)
        XCTAssertEqual(sut.teamsSpeakerNames.state, .on)
        XCTAssertEqual(settings.thumbnailDuration, 7.5)
        XCTAssertEqual(sut.thumbnailDuration.itemTitles, ["3 seconds", "5 seconds", "15 seconds", "Forever", "Custom (7.5 seconds)"])
        XCTAssertEqual(sut.thumbnailDuration.titleOfSelectedItem, "Custom (7.5 seconds)")
        fire(sut.thumbnailDuration)
        XCTAssertEqual(settings.thumbnailDuration, 7.5)
        defaults.removeObject(forKey: "windowTilingEnabled")
        defaults.removeObject(forKey: "teamsSpeakerNamesEnabled")
        XCTAssertEqual(defaults.persistentDomain(forName: "SettingsWindowControllerTests")! as NSDictionary, before)
        XCTAssertEqual(login.setCalls, [])
    }

    func testLoginFailureShowsActualStateAndUsefulError() {
        login.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration refused"])
        sut.show()
        sut.launchAtLogin.performClick(nil)
        XCTAssertEqual(sut.launchAtLogin.state, .off)
        XCTAssertTrue(sut.loginError.stringValue.contains("Registration refused"))
    }

    func testReopeningAfterExternalLoginApprovalClearsPreviousError() {
        login.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration refused"])
        sut.show()
        sut.launchAtLogin.performClick(nil)
        XCTAssertEqual(sut.launchAtLogin.state, .off)
        XCTAssertFalse(sut.loginError.isHidden)
        XCTAssertTrue(sut.loginError.stringValue.contains("Registration refused"))
        sut.close()
        login.isEnabled = true
        sut.show()
        XCTAssertEqual(sut.launchAtLogin.state, .on)
        XCTAssertTrue(sut.loginError.isHidden)
        XCTAssertEqual(sut.loginError.stringValue, "")
    }

    func testLoginRequestThatNeedsSystemApprovalShowsActualStateAndGuidance() {
        struct PendingLoginItem: LoginItemManaging {
            var isEnabled: Bool { false }
            func setEnabled(_ enabled: Bool) throws {}
        }
        let controller = SettingsWindowController(settings: Settings(defaults: defaults, loginItem: PendingLoginItem()),
            present: { _ in }, activation: OrdinaryWindowActivation(setPolicy: { _ in }))
        defer { controller.close() }
        controller.show()
        controller.launchAtLogin.performClick(nil)
        XCTAssertEqual(controller.launchAtLogin.state, .off)
        XCTAssertTrue(controller.loginError.stringValue.contains("Login Items & Extensions"))
    }

    func testEveryPermanentThumbnailAndSummaryChoiceSavesThroughNativeActions() {
        sut.show()
        XCTAssertEqual(sut.thumbnailDuration.itemTitles, ["3 seconds", "5 seconds", "15 seconds", "Forever"])
        for (title, duration) in [("3 seconds", 3.0), ("5 seconds", 5), ("15 seconds", 15), ("Forever", 0)] {
            sut.thumbnailDuration.selectItem(withTitle: title)
            fire(sut.thumbnailDuration)
            XCTAssertEqual(settings.thumbnailDuration, Double(duration))
        }
        for (index, tool) in SummaryTool.allCases.enumerated() {
            sut.summaryTool.selectItem(at: index)
            fire(sut.summaryTool)
            XCTAssertEqual(settings.summaryTool, tool)
        }
    }

    func testLongPathsStayWithinTheFormAndExposeFullAccessibleValues() throws {
        let path = "/Users/example/" + String(repeating: "a long folder name/", count: 12) + "background.md"
        settings.meetingsFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        settings.meetingContextFile = URL(fileURLWithPath: path)
        sut.show()
        let scroll = try XCTUnwrap(descendants(try XCTUnwrap(sut.window?.contentView)).compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(sut.window?.contentView?.bounds.width, 760)
        XCTAssertTrue(try XCTUnwrap(scroll.documentView).isFlipped)
        let labels = descendants(try XCTUnwrap(scroll.documentView)).compactMap { $0 as? NSTextField }
        let background = try XCTUnwrap(labels.first { $0.accessibilityLabel() == "Background file" })
        XCTAssertEqual(background.accessibilityValue(), path)
        XCTAssertEqual(background.toolTip, path)
        XCTAssertLessThan(background.frame.width, scroll.contentView.bounds.width)
        sut.window?.setContentSize(NSSize(width: 640, height: 420))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testOrdinaryWindowsShareActivationUntilLastClose() {
        var policies: [NSApplication.ActivationPolicy] = []
        let activation = OrdinaryWindowActivation(setPolicy: { policies.append($0) })
        let first = NSWindow()
        let second = NSWindow()
        activation.open(first)
        activation.open(second)
        activation.close(first)
        XCTAssertEqual(policies, [.regular])
        activation.close(second)
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func testSettingsAndOnboardingKeepActivationUntilBothCloseInEitherOrder() {
        for settingsClosesFirst in [true, false] {
            var policies: [NSApplication.ActivationPolicy] = []
            let activation = OrdinaryWindowActivation(setPolicy: { policies.append($0) })
            let controller = SettingsWindowController(settings: settings, present: { _ in }, activation: activation)
            let onboarding = OnboardingWindowController(permissions: PermissionsManager(
                isAccessibilityTrusted: { true }, hasScreenCaptureAccess: { true }, microphoneAccess: { .granted }),
                settings: settings, activate: {}, activation: activation)
            defer { controller.close(); onboarding.close() }
            controller.show()
            onboarding.show()
            if settingsClosesFirst { controller.close() } else { onboarding.close() }
            XCTAssertEqual(policies, [.regular])
            if settingsClosesFirst { onboarding.close() } else { controller.close() }
            XCTAssertEqual(policies, [.regular, .accessory])
        }
    }

    func testSettingsAndWordReviewKeepActivationUntilBothCloseInEitherOrder() throws {
        let root = try makeTemporaryDirectory()
        let meeting = try MeetingFolder.create(in: root, startingAt: localDate(2026, 10, 29, 10, 0))
        try meeting.write("**[00:00:01] Them:** Ask Convio.\n", to: .transcript)
        try meeting.write("# Summary\n", to: .summary)
        try meeting.write(#"{"questions": [{"heard": "Convio", "kind": "company", "quote": "Ask Convio."}]}"#, to: .questions)
        for settingsClosesFirst in [true, false] {
            var policies: [NSApplication.ActivationPolicy] = []
            let activation = OrdinaryWindowActivation(setPolicy: { policies.append($0) })
            let controller = SettingsWindowController(settings: settings, present: { _ in }, activation: activation)
            let review = WordReviewController(root: { root },
                knownWords: KnownWordsFile(url: { root.appendingPathComponent("known-words.md") }),
                isOrdinary: { _ in false }, requestUpdate: { _ in })
            let window = WordReviewWindowController(controller: review, activate: {}, activation: activation)
            window.bindController()
            defer { controller.close(); window.close() }
            controller.show()
            window.show(meeting)
            if settingsClosesFirst { controller.close() } else { window.close() }
            XCTAssertEqual(policies, [.regular])
            if settingsClosesFirst { window.close() } else { controller.close() }
            XCTAssertEqual(policies, [.regular, .accessory])
        }
    }

    func testNativeAccessibilityNamesKeyOrderAndOffscreenRendering() throws {
        sut.window?.appearance = NSAppearance(named: .aqua)
        sut.show()
        XCTAssertEqual(sut.chooseMeetingsFolder.accessibilityLabel(), "Choose meetings folder")
        XCTAssertEqual(sut.chooseBackground.accessibilityLabel(), "Choose background file")
        XCTAssertEqual(sut.clearBackground.accessibilityLabel(), "Clear background file")
        let controls: [NSView] = sut.pageButtons + [sut.launchAtLogin, sut.windowTiling, sut.clipboardHistory, sut.displayAwake,
            sut.thumbnailDuration, sut.chooseMeetingsFolder, sut.summaryTool, sut.chooseBackground, sut.clearBackground,
            sut.calendarReminders, sut.teamsSpeakerNames]
        for (control, next) in zip(controls, controls.dropFirst() + [sut.pageButtons[0]]) {
            XCTAssertTrue(control.nextKeyView === next)
        }
        let content = try XCTUnwrap(sut.window?.contentView)
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "settings-offscreen-760x700"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(content.bounds.size, NSSize(width: 760, height: 700))
        XCTAssertEqual(bitmap.pixelsWide * 700, bitmap.pixelsHigh * 760)
    }

    private func fire(_ control: NSControl) {
        _ = control.sendAction(control.action, to: control.target)
    }
}
