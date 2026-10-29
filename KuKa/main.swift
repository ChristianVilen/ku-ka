import Cocoa

// Process entry always runs on the main thread; assumeIsolated makes that
// visible to the compiler so the @MainActor AppDelegate can be created here.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let mode = AppLaunchMode(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
    let delegate: (any NSApplicationDelegate)?
    switch mode {
    case .production: delegate = AppDelegate()
    case .xctest: delegate = nil
    case .settingsPreview: delegate = SettingsPreviewAppDelegate()
    }
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
