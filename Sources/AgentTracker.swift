import Foundation

enum AgentDetection {
    static let pollInterval: TimeInterval = 5
    /// How long an agent still counts as working after its last sign of activity. Bridges
    /// quiet stretches like a model thinking or a tool waiting on the network.
    static let gracePeriod: TimeInterval = 5 * 60
    /// Average CPU, in cores, of an agent and everything it started, that counts as working.
    /// An idle agent sits near 0.002; one streaming output or running a build is well above.
    static let busyCPU: Double = 0.03
}

/// An agent process that no other agent process started (an agent's own helpers belong to it).
struct AgentProcess: Hashable, Sendable {
    let pid: Int32
    let kind: AgentKind
}

/// One scan of the system.
struct AgentObservation: Sendable {
    /// Agent processes that are running.
    let processes: [AgentProcess]
    /// Agent processes that hold a sleep assertion or use CPU, themselves or through their children.
    let activePIDs: Set<Int32>
    /// Claude status files, by the pid of the Claude process they describe.
    let claudeStatuses: [Int32: ClaudeSessionStatus]

    static let empty = AgentObservation(processes: [], activePIDs: [], claudeStatuses: [:])
}

struct SessionKey: Hashable, Sendable {
    let kind: AgentKind
    let id: String
}

/// Something that counts as one working agent: a process, or a session found by its transcript.
enum WorkUnit: Hashable, Sendable {
    case process(AgentProcess)
    case session(SessionKey)

    var kind: AgentKind {
        switch self {
        case .process(let process): process.kind
        case .session(let key): key.kind
        }
    }
}

struct AgentActivity: Equatable, Sendable {
    struct Count: Equatable, Sendable {
        let name: String
        let count: Int
    }

    /// Most first, then by name.
    let counts: [Count]

    static let none = AgentActivity(counts: [])

    init(counts: [Count]) {
        self.counts = counts
    }

    init(units: some Sequence<WorkUnit>) {
        let byName = Dictionary(grouping: units, by: { $0.kind.name })
        let unsorted = byName.map { Count(name: $0.key, count: $0.value.count) }
        counts = unsorted.sorted { (lhs: Count, rhs: Count) -> Bool in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs.name < rhs.name
        }
    }

    var total: Int { counts.reduce(0) { $0 + $1.count } }
    var isWorking: Bool { total > 0 }

    var summary: String {
        guard isWorking else { return "No agents working right now." }
        let noun = total == 1 ? "agent" : "agents"
        if counts.count == 1 { return "\(total) \(counts[0].name) \(noun) working" }
        let detail = counts.map { "\($0.count) \($0.name)" }.joined(separator: ", ")
        return "\(total) \(noun) working: \(detail)"
    }
}

/// Combines scans over time into "which agents are working now".
///
/// - A Claude process with a status file is working exactly while the file says busy.
/// - Any other agent process is working while it holds a sleep assertion or uses CPU, plus
///   the grace period.
/// - A transcript that changed counts as a working session for the grace period. When it
///   can't be tied to a process, processes of that agent aren't counted on top of it, since
///   the session most likely runs in one of them.
struct AgentTracker: Sendable {
    /// Last sign of activity per unit, within the grace period.
    let lastSeen: [WorkUnit: Date]
    /// Claude session → the process that runs (or ran) it, from status files.
    let claudeLinks: [String: Int32]
    let observation: AgentObservation

    init(lastSeen: [WorkUnit: Date] = [:], claudeLinks: [String: Int32] = [:], observation: AgentObservation = .empty) {
        self.lastSeen = lastSeen
        self.claudeLinks = claudeLinks
        self.observation = observation
    }

    func updated(with observation: AgentObservation, writes: [SessionKey: Date], now: Date) -> AgentTracker {
        let statuses = observation.claudeStatuses
        let busySessions = statuses.values.filter(\.isBusy)
            .map { WorkUnit.session(SessionKey(kind: AgentCatalog.claude, id: $0.sessionId)) }
        let busyProcesses = observation.processes
            .filter { observation.activePIDs.contains($0.pid) && statuses[$0.pid] == nil }
            .map(WorkUnit.process)
        let fresh = (busySessions + busyProcesses).map { ($0, now) }
            + writes.map { (WorkUnit.session($0.key), $0.value) }

        let seen = lastSeen
            .merging(fresh, uniquingKeysWith: max)
            .filter { now.timeIntervalSince($0.value) <= AgentDetection.gracePeriod }
        let live = Set(observation.processes.map(\.pid))
        let links = claudeLinks
            .merging(statuses.values.map { ($0.sessionId, $0.pid) }, uniquingKeysWith: { _, new in new })
            .filter { live.contains($0.value) || seen[.session(SessionKey(kind: AgentCatalog.claude, id: $0.key))] != nil }
        return AgentTracker(lastSeen: seen, claudeLinks: links, observation: observation)
    }

    func activity(now: Date) -> AgentActivity {
        let live = Set(observation.processes.map(\.pid))
        let busyClaudeSessions = Set(observation.claudeStatuses.values.filter(\.isBusy).map(\.sessionId))
        // A transcript no status file accounts for can only be written by a running agent of
        // its kind without one; otherwise its agent already quit (e.g. a finished `claude -p`).
        let untrackedKinds = Set(observation.processes
            .filter { observation.claudeStatuses[$0.pid] == nil }
            .map(\.kind))

        let candidates = lastSeen
            .filter { now.timeIntervalSince($0.value) <= AgentDetection.gracePeriod }
            .keys
            .filter { unit in
                switch unit {
                case .process(let process):
                    return live.contains(process.pid)
                case .session(let key):
                    guard let pid = linkedPID(key) else { return untrackedKinds.contains(key.kind) }
                    return live.contains(pid) && busyClaudeSessions.contains(key.id)
                }
            }

        let kindsWithUnlinkedSessions = Set(candidates.compactMap { unit -> AgentKind? in
            guard case .session(let key) = unit, linkedPID(key) == nil else { return nil }
            return key.kind
        })
        let working = candidates.filter { unit in
            guard case .process(let process) = unit else { return true }
            return !kindsWithUnlinkedSessions.contains(process.kind)
        }
        return AgentActivity(units: working)
    }

    private func linkedPID(_ key: SessionKey) -> Int32? {
        key.kind == AgentCatalog.claude ? claudeLinks[key.id] : nil
    }
}

enum ProcessTree {
    /// The outermost agent among `pid` and its ancestors, so what an agent starts (shells,
    /// builds, `caffeinate`) counts toward that agent.
    static func agentRoot(of pid: Int32, parents: [Int32: Int32], agents: Set<Int32>) -> Int32? {
        var current = pid
        var root: Int32?
        for _ in 0..<64 where current > 1 {
            if agents.contains(current) { root = current }
            guard let parent = parents[current], parent != current else { break }
            current = parent
        }
        return root
    }
}

/// A process, told apart from a later one that reuses its pid.
struct ProcessKey: Hashable, Sendable {
    let pid: Int32
    /// Start time, seconds since 1970.
    let started: TimeInterval
}

/// Turns total CPU time per process into average cores used by each agent's process tree
/// since the previous sample.
///
/// A process's total includes children it already reaped, so when a child exits its whole
/// lifetime moves into its parent's total. Comparing tree totals, with exited processes'
/// last readings taken out, counts only the CPU used in between.
struct CPUMeter: Sendable {
    struct Reading: Hashable, Sendable {
        /// The agent process whose tree this process belongs to.
        let root: Int32
        /// CPU seconds, including reaped children.
        let total: TimeInterval
    }

    let readings: [ProcessKey: Reading]
    let time: Date?

    init(readings: [ProcessKey: Reading] = [:], time: Date? = nil) {
        self.readings = readings
        self.time = time
    }

    func updated(readings current: [ProcessKey: Reading], now: Date) -> (meter: CPUMeter, cores: [Int32: Double]) {
        let meter = CPUMeter(readings: current, time: now)
        guard let time, now > time else { return (meter, [:]) }
        let since = time.timeIntervalSince1970

        let grown = current.map { key, reading -> (Int32, TimeInterval) in
            // New since the last sample: all its CPU is new. Older but not seen before: baseline.
            let before = readings[key]?.total ?? (key.started >= since ? 0 : reading.total)
            return (reading.root, reading.total - before)
        }
        let exited = readings.filter { current[$0.key] == nil }.map { ($0.value.root, -$0.value.total) }
        let elapsed = now.timeIntervalSince(time)
        let cores = Dictionary(grown + exited, uniquingKeysWith: +).mapValues { max(0, $0) / elapsed }
        return (meter, cores)
    }
}
