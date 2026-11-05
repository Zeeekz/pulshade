#if os(iOS)
import UIKit

extension Notification.Name {
    /// Apple gave this phone a push token (or a new one).
    static let pulshadePushToken = Notification.Name("pulshade.push.token")
}

/// Where Apple's answer to "register me for pushes" lands. The token goes to the relay, never anywhere else.
enum Push {
    /// This phone's token, as hex, once Apple has issued it.
    nonisolated(unsafe) static var token: String?
    /// Why Apple didn't give a token, if it didn't, for the status line in Settings.
    nonisolated(unsafe) static var failure: String?

    /// A debug build is signed for Apple's sandbox, whose tokens only the sandbox accepts. TestFlight and the
    /// App Store use the real one.
    static var sandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // A call push that wakes a closed app finds this ready, and the tones are where the system looks for them.
        MainActor.assumeIsolated { CallRinger.shared.start() }
        MessageTone.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Push.failure = nil
        NotificationCenter.default.post(name: .pulshadePushToken, object: nil)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Push.token = nil
        Push.failure = error.localizedDescription
    }
}
#endif
