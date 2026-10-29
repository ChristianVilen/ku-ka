import XCTest
@testable import KuKa

@MainActor
final class AppLaunchModeTests: XCTestCase {
    func testXCTestProcessHasPassiveHost() {
        XCTAssertFalse(NSApp.delegate is AppDelegate, "XCTest must not construct the production AppDelegate")
        XCTAssertNil(NSApp.delegate)
    }

    func testLaunchModeChoosesProductionTestsAndPreviewWithTestsTakingPriority() {
        XCTAssertEqual(AppLaunchMode(environment: [:], arguments: ["KuKa"]), .production)
        XCTAssertEqual(AppLaunchMode(environment: [:], arguments: ["KuKa", "--uitesting"]), .settingsPreview)
        XCTAssertEqual(AppLaunchMode(environment: ["XCTestConfigurationFilePath": "tests"], arguments: ["KuKa"]), .xctest)
        XCTAssertEqual(AppLaunchMode(environment: ["XCTestConfigurationFilePath": "tests"],
                                     arguments: ["KuKa", "--uitesting"]), .xctest)
    }

    func testPreviewCommandsReuseSettingsAndWriteOnlyIsolatedPreferencesWithInertLogin() throws {
        let suite = "AppLaunchModeTests.Preview"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var presented: [NSWindow] = []
        let host = SettingsPreviewAppDelegate(defaults: defaults, present: { presented.append($0) },
            activation: OrdinaryWindowActivation(setPolicy: { _ in }))
        defer { host.settingsWindow.close() }
        XCTAssertNil(defaults.persistentDomain(forName: suite))
        let menuItem = try XCTUnwrap(host.statusMenu.menu.item(withTitle: "Settings…"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(menuItem.action), to: menuItem.target, from: menuItem))
        let appMenu = host.statusMenu.applicationMenu()
        let command = try XCTUnwrap(appMenu.items.first?.submenu?.item(withTitle: "Settings…"))
        XCTAssertEqual(command.keyEquivalent, ",")
        XCTAssertEqual(command.keyEquivalentModifierMask, .command)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(command.action), to: command.target, from: command))
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented.allSatisfy { $0 === host.settingsWindow.window })
        XCTAssertNil(defaults.persistentDomain(forName: suite))
        host.settingsWindow.summaryTool.selectItem(withTitle: "Claude Code (claude)")
        let popup = host.settingsWindow.summaryTool
        _ = popup.sendAction(popup.action, to: popup.target)
        XCTAssertEqual(defaults.string(forKey: "summaryTool"), "claude")
        host.settingsWindow.launchAtLogin.performClick(nil)
        XCTAssertEqual(host.settingsWindow.launchAtLogin.state, .off)
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"))
    }
}
