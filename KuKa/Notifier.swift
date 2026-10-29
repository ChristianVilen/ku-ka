import AppKit
import UserNotifications

/// What a click on a notification does.
enum NotificationClick: Equatable {
    /// Opens a file or folder.
    case open(URL)
    /// Opens the review window on this meeting.
    case checkWords(MeetingFolder)

    /// "url" is also the key of every notification before Check Words, so those still open.
    private static let openKey = "url"
    private static let checkWordsKey = "checkWords"

    /// The notification's userInfo, which macOS keeps until the click.
    var userInfo: [String: String] {
        switch self {
        case .open(let url): return [Self.openKey: url.absoluteString]
        case .checkWords(let meeting): return [Self.checkWordsKey: meeting.url.absoluteString]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        if let string = userInfo[Self.checkWordsKey] as? String, let url = URL(string: string) {
            self = .checkWords(MeetingFolder(url: url))
        } else if let string = userInfo[Self.openKey] as? String, let url = URL(string: string) {
            self = .open(url)
        } else {
            return nil
        }
    }
}

protocol Notifying {
    /// Call when the user starts something that will notify later, so the
    /// macOS prompt appears while its reason is clear.
    func requestPermission()
    /// `onClick` happens when the user clicks the notification.
    func post(title: String, body: String, onClick: NotificationClick?)
}

/// The one way Ku-Ka posts notifications. `AppDelegate` installs it as the
/// notification center's delegate, so a click opens the notification's file
/// or the review window.
final class SystemNotifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    private var didRequestPermission = false
    private let open: (URL) -> Void

    /// A click on a notification that has words to check. The app opens the review window.
    var onCheckWords: (@MainActor (MeetingFolder) -> Void)?

    init(open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    func requestPermission() {
        guard !didRequestPermission else { return }
        didRequestPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(title: String, body: String, onClick click: NotificationClick?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let click { content.userInfo = click.userInfo }
        // A unique identifier, so two meetings' notices do not replace each other.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    @MainActor
    func perform(_ click: NotificationClick) {
        switch click {
        case .open(let url): open(url)
        case .checkWords(let meeting): onCheckWords?(meeting)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let click = NotificationClick(userInfo: response.notification.request.content.userInfo) {
            Task { @MainActor in self.perform(click) }
        }
        completionHandler()
    }

    /// Without this, macOS hides a notification while Ku-Ka is the active app,
    /// for example while its menu is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
