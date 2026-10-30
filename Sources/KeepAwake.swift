import Foundation

enum SessionLength: String, CaseIterable, Identifiable {
    case indefinitely
    case minutes30, hour1, hours2, hours4, hours8, hours12
    case day1, days2, days3, week1
    case untilDate

    static let hours: [SessionLength] = [.minutes30, .hour1, .hours2, .hours4, .hours8, .hours12]
    static let days: [SessionLength] = [.day1, .days2, .days3, .week1]

    var id: Self { self }

    var title: String {
        switch self {
        case .indefinitely: "Until I turn it off"
        case .minutes30: "30 minutes"
        case .hour1: "1 hour"
        case .hours2: "2 hours"
        case .hours4: "4 hours"
        case .hours8: "8 hours"
        case .hours12: "12 hours"
        case .day1: "1 day"
        case .days2: "2 days"
        case .days3: "3 days"
        case .week1: "1 week"
        case .untilDate: "Until a date & time…"
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .indefinitely, .untilDate: nil
        case .minutes30: 30 * 60
        case .hour1: 3600
        case .hours2: 2 * 3600
        case .hours4: 4 * 3600
        case .hours8: 8 * 3600
        case .hours12: 12 * 3600
        case .day1: 86_400
        case .days2: 2 * 86_400
        case .days3: 3 * 86_400
        case .week1: 7 * 86_400
        }
    }
}

/// The "Keep always on" session. While it's on, the app holds a process activity that
/// creates the same power assertions as `caffeinate -di` (and as Firefox playing video).
/// macOS drops them automatically if the app quits or crashes.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    private enum Key {
        static let isOn = "keepAlwaysOn"
        static let length = "sessionLength"
        static let untilDate = "untilDate"
        static let endDate = "sessionEndDate"
        static let lidClosed = "keepAwakeWithLidClosed"
        static let lidSleepDisabledByApp = "lidSleepDisabledByApp"
        static let lastUptimeWarning = "lastUptimeWarning"
    }

    @Published private(set) var isOn: Bool
    @Published private(set) var length: SessionLength
    @Published private(set) var untilDate: Date
    /// When the current session ends; `nil` while off or running until turned off.
    @Published private(set) var endDate: Date?
    @Published private(set) var lidClosed: Bool
    @Published private(set) var lidError: String?
    @Published private(set) var now = Date()

    private let defaults = UserDefaults.standard
    private var activity: NSObjectProtocol?
    private var ticker: Task<Void, Never>?

    init() {
        let now = Date()
        let defaults = UserDefaults.standard
        isOn = defaults.bool(forKey: Key.isOn)
        length = defaults.string(forKey: Key.length).flatMap(SessionLength.init) ?? .indefinitely
        untilDate = defaults.object(forKey: Key.untilDate) as? Date ?? Self.defaultUntilDate()
        endDate = defaults.object(forKey: Key.endDate) as? Date
        lidClosed = defaults.bool(forKey: Key.lidClosed)

        // A timed session that ended while the app wasn't running (e.g. across a restart).
        if isOn, let endDate, endDate <= now {
            isOn = false
            self.endDate = nil
            save()
        }
        apply(interactive: false)
        restartTicker()
    }

    // MARK: - Actions

    func setOn(_ on: Bool) {
        let end = on ? plannedEndDate() : nil
        if let end, end <= Date() { return } // the chosen date has already passed
        isOn = on
        endDate = end
        now = Date()
        save()
        apply(interactive: true)
        restartTicker()
    }

    /// Changing the length of a running session restarts its clock from now.
    func setLength(_ newLength: SessionLength) {
        length = newLength
        if newLength == .untilDate, untilDate <= Date() {
            untilDate = Self.defaultUntilDate()
        }
        save()
        if isOn { setOn(true) }
    }

    func setUntilDate(_ date: Date) {
        untilDate = date
        save()
        if isOn, length == .untilDate { setOn(true) }
    }

    func setLidClosed(_ on: Bool) {
        lidClosed = on
        lidError = nil
        save()
        applyLidSleep(interactive: true)
    }

    /// Called when the app quits: undo the lid setting so it can't outlive the app.
    func prepareForQuit() {
        guard defaults.bool(forKey: Key.lidSleepDisabledByApp) else { return }
        if (try? LidSleep.setSleepDisabled(false, interactive: false)) != nil {
            defaults.set(false, forKey: Key.lidSleepDisabledByApp)
        }
    }

    func tick() {
        now = Date()
        if isOn, let endDate, endDate <= now {
            isOn = false
            self.endDate = nil
            save()
            apply(interactive: false)
        }
        warnAboutUptimeIfNeeded()
    }

    // MARK: - Display text

    var statusText: String {
        guard isOn else {
            if length == .untilDate, untilDate <= now { return "Pick a time in the future." }
            return "Your Mac follows its normal sleep settings."
        }
        guard let endDate else { return "Mac and display stay awake until you turn this off." }
        return "Mac and display stay awake until \(endDate.formatted(date: .abbreviated, time: .shortened))."
    }

    /// Whole seconds left in a timed session, rounded up so it reads 1s until it actually ends.
    var secondsLeft: Int? {
        guard isOn, let endDate else { return nil }
        return max(0, Int(endDate.timeIntervalSince(now).rounded(.up)))
    }

    /// Full countdown for the panel: "2d 4:05:09", "1:05:09", "5:09".
    var countdownText: String? {
        guard let seconds = secondsLeft else { return nil }
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60
        let clock = days > 0 || hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
            : String(format: "%d:%02d", minutes, seconds % 60)
        return days > 0 ? "\(days)d \(clock)" : clock
    }

    /// Only the largest unit, for the menu bar: "3d", "5h", "42m", then "59s", "58s", …
    var menuBarCountdown: String? {
        guard let seconds = secondsLeft else { return nil }
        switch seconds {
        case 86_400...: return "\(seconds / 86_400)d"
        case 3600...: return "\(seconds / 3600)h"
        case 60...: return "\(seconds / 60)m"
        default: return "\(seconds)s"
        }
    }

    var lidCaption: String {
        if let lidError { return lidError }
        if !lidClosed { return "Asks for your admin password the first time." }
        if !isOn { return "Applies while Keep always on is on." }
        return "Stays awake when closed. Keep it ventilated, not in a bag."
    }

    var uptime: TimeInterval { now.timeIntervalSince(Uptime.bootDate) }
    var uptimeStatus: Uptime.Status { Uptime.status(for: uptime) }
    var uptimeText: String { Format.duration(uptime) }
    var uptimeWarning: String? { Uptime.warning(for: uptime) }

    // MARK: - Private

    private func restartTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled, let delay = self?.nextTickDelay() {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    /// Every second, on the second, while a countdown is running; otherwise every 15 s.
    private func nextTickDelay() -> TimeInterval {
        guard isOn, let endDate else { return 15 }
        let remaining = endDate.timeIntervalSinceNow
        return remaining - remaining.rounded(.down) + 0.01
    }

    private func plannedEndDate() -> Date? {
        switch length {
        case .indefinitely: nil
        case .untilDate: untilDate
        default: Date().addingTimeInterval(length.duration ?? 0)
        }
    }

    private func apply(interactive: Bool) {
        if isOn, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "Always On: \"Keep always on\" is enabled"
            )
        } else if !isOn, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        applyLidSleep(interactive: interactive)
    }

    /// Lid-closed sleep is a system-wide setting (unlike assertions), so we track whether
    /// we changed it and only ever undo our own change.
    private func applyLidSleep(interactive: Bool) {
        let wanted = isOn && lidClosed && LidSleep.hasLid
        let disabledByUs = defaults.bool(forKey: Key.lidSleepDisabledByApp)
        do {
            if wanted, !LidSleep.isSleepDisabled {
                try LidSleep.setSleepDisabled(true, interactive: interactive)
                defaults.set(true, forKey: Key.lidSleepDisabledByApp)
            } else if !wanted, disabledByUs {
                if LidSleep.isSleepDisabled {
                    try LidSleep.setSleepDisabled(false, interactive: interactive)
                }
                defaults.set(false, forKey: Key.lidSleepDisabledByApp)
            }
        } catch {
            if wanted {
                lidClosed = false
                save()
            }
            if case LidSleep.Failure.cancelled = error { return }
            lidError = error.localizedDescription
        }
    }

    private func warnAboutUptimeIfNeeded() {
        guard let warning = uptimeWarning else { return }
        if let last = defaults.object(forKey: Key.lastUptimeWarning) as? Date,
           last > Uptime.bootDate, now.timeIntervalSince(last) < 86_400 { return }
        defaults.set(now, forKey: Key.lastUptimeWarning)
        Uptime.notify(status: uptimeStatus, message: warning)
    }

    private func save() {
        defaults.set(isOn, forKey: Key.isOn)
        defaults.set(length.rawValue, forKey: Key.length)
        defaults.set(untilDate, forKey: Key.untilDate)
        defaults.set(endDate, forKey: Key.endDate)
        defaults.set(lidClosed, forKey: Key.lidClosed)
    }

    /// Tomorrow at the next full hour.
    private static func defaultUntilDate() -> Date {
        Calendar.current.nextDate(
            after: Date().addingTimeInterval(86_400),
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(86_400)
    }
}

enum Format {
    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func duration(_ interval: TimeInterval) -> String {
        formatter.string(from: max(60, interval)) ?? ""
    }
}
