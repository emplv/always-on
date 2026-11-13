import Foundation

/// While started, scans for working agents every few seconds and publishes how many there are.
@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var activity = AgentActivity.none

    private let scanner = AgentScanner()
    private let watcher = TranscriptWatcher()
    private var tracker = AgentTracker()
    private var poller: Task<Void, Never>?
    /// Keeps App Nap from stretching the scan interval while no assertion is held.
    private var appNapGuard: NSObjectProtocol?

    func start() {
        guard poller == nil else { return }
        appNapGuard = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Always On: watching for working agents"
        )
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(AgentDetection.pollInterval))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        watcher.stop()
        tracker = AgentTracker()
        activity = .none
        if let appNapGuard {
            ProcessInfo.processInfo.endActivity(appNapGuard)
            self.appNapGuard = nil
        }
    }

    private func poll() async {
        watcher.refresh()
        let observation = await scanner.scan()
        guard poller != nil, !Task.isCancelled else { return }
        let now = Date()
        tracker = tracker.updated(with: observation, writes: watcher.drainWrites(), now: now)
        let next = tracker.activity(now: now)
        if next != activity { activity = next }
    }
}
