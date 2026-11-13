import CoreServices
import Foundation

/// Watches agents' transcript folders with FSEvents and remembers when each session last
/// wrote to its transcript. macOS reports only the files that changed, so this costs nearly
/// nothing even with years of transcripts on disk.
final class TranscriptWatcher: @unchecked Sendable {
    private struct Root {
        let path: String
        let source: TranscriptSource
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.emplv.AlwaysOn.transcripts")
    private let home = FileManager.default.homeDirectoryForCurrentUser
    // Guarded by `lock`.
    private var writes: [SessionKey: Date] = [:]
    private var roots: [Root] = []
    // Only touched from the main actor (refresh/stop).
    private var stream: FSEventStreamRef?
    /// Folders FSEvents refused, so a failure isn't retried (and logged) every scan.
    private var failedPaths: [String]?

    deinit { stop() }

    /// Starts watching the transcript folders that exist, or restarts when that set changed
    /// (e.g. Codex was installed). Cheap enough to call on every scan.
    func refresh() {
        let existing = TranscriptSource.all.compactMap { source -> Root? in
            let url = home.appendingPathComponent(source.directory).resolvingSymlinksInPath()
            return FileManager.default.fileExists(atPath: url.path) ? Root(path: url.path, source: source) : nil
        }
        let paths = existing.map(\.path)
        guard paths != failedPaths else { return }
        guard stream == nil || paths != lock.withLock({ roots.map(\.path) }) else { return }
        stop()
        guard !existing.isEmpty else { return }
        lock.withLock { roots = existing }
        failedPaths = start(paths: paths) ? nil : paths
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // Wait out a callback already running, which uses `self` unretained.
        queue.sync {}
        FSEventStreamRelease(stream)
        self.stream = nil
        lock.withLock { writes = [:] }
    }

    /// Writes since the previous call.
    func drainWrites() -> [SessionKey: Date] {
        lock.withLock {
            defer { writes = [:] }
            return writes
        }
    }

    private func start(paths: [String]) -> Bool {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.record(paths: changed, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, FSEventStreamCreateFlags(flags)
        ) else {
            agentLog.error("Couldn't watch transcript folders \(paths, privacy: .public)")
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            agentLog.error("Couldn't start watching transcript folders \(paths, privacy: .public)")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    private func record(paths: [String], flags: [FSEventStreamEventFlags]) {
        let now = Date()
        let written = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated)
        let changes = zip(paths, flags).filter { _, flag in
            flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
                && flag & written != 0
                && flag & UInt32(kFSEventStreamEventFlagItemRemoved) == 0
        }
        lock.withLock {
            let keys = changes.compactMap { path, _ in sessionKey(for: path) }
            writes = writes.merging(keys.map { ($0, now) }, uniquingKeysWith: max)
        }
    }

    /// Call with `lock` held.
    private func sessionKey(for path: String) -> SessionKey? {
        for root in roots where path.hasPrefix(root.path + "/") {
            let relative = String(path.dropFirst(root.path.count + 1))
            return root.source.sessionID(relativePath: relative).map { SessionKey(kind: root.source.kind, id: $0) }
        }
        return nil
    }
}
