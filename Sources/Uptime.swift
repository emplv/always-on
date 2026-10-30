import Foundation
import UserNotifications

/// macOS's TCP clock (`tcp_now`, 32-bit milliseconds) wraps after 2^32 ms ≈ 49 days 17 hours.
/// From then on the Mac can't open new network connections until it restarts.
/// Uptime here is wall-clock time since boot, which includes any sleep, so the warning
/// errs on the early side.
enum Uptime {
    static let networkFailureAt: TimeInterval = 4_294_967.296
    static let warnFrom: TimeInterval = networkFailureAt - 5 * 86_400

    enum Status { case ok, restartSoon, restartNow }

    static let bootDate: Date = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }()

    static func status(for uptime: TimeInterval) -> Status {
        if uptime >= networkFailureAt { return .restartNow }
        if uptime >= warnFrom { return .restartSoon }
        return .ok
    }

    static func warning(for uptime: TimeInterval) -> String? {
        let reason = "After 49.7 days without a restart, macOS stops opening new network connections."
        switch status(for: uptime) {
        case .ok: return nil
        case .restartSoon: return "Restart within \(Format.duration(networkFailureAt - uptime)). \(reason)"
        case .restartNow: return "Restart now. \(reason)"
        }
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(status: Status, message: String) {
        let content = UNMutableNotificationContent()
        content.title = status == .restartNow ? "Restart your Mac now" : "Restart your Mac soon"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: "uptime-warning", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
