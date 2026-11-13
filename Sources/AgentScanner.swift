import Darwin
import Foundation
import IOKit.pwr_mgt
import os

let agentLog = Logger(subsystem: "com.emplv.AlwaysOn", category: "agents")

/// Scans running processes for coding agents and what they're doing. Keeps the state that
/// has to survive between scans: what each process runs, and its last CPU reading.
actor AgentScanner {
    /// A process keeps its command line unless it execs, which also changes its name.
    private struct Identity: Hashable {
        let key: ProcessKey
        let command: String
    }

    private var kinds: [Identity: AgentKind?] = [:]
    private var meter = CPUMeter()
    private var lastStatuses: [Int32: ClaudeSessionStatus] = [:]
    private let ownPID = getpid()
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func scan(now: Date = Date()) -> AgentObservation {
        let entries = ProcessTable.entries()
        let agentKinds = identify(entries)
        let parents = Dictionary(entries.map { ($0.key.pid, $0.parent) }, uniquingKeysWith: { first, _ in first })
        let agentPIDs = Set(agentKinds.keys)
        let rootOf = Dictionary(entries.compactMap { entry in
            ProcessTree.agentRoot(of: entry.key.pid, parents: parents, agents: agentPIDs).map { (entry.key, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let processes = Set(rootOf.values).compactMap { pid in agentKinds[pid].map { AgentProcess(pid: pid, kind: $0) } }

        let rootByPID = Dictionary(rootOf.map { ($0.key.pid, $0.value) }, uniquingKeysWith: { first, _ in first })
        let asserting = PowerAssertions.pidsPreventingSleep()
            .subtracting([ownPID])
            .compactMap { rootByPID[$0] }
        let active = Set(asserting).union(busyRoots(rootOf: rootOf, now: now))

        return AgentObservation(
            processes: processes,
            activePIDs: active,
            claudeStatuses: claudeStatuses(for: processes)
        )
    }

    /// What each process runs, looked up once per process.
    private func identify(_ entries: [ProcessTable.Entry]) -> [Int32: AgentKind] {
        var buffer: [UInt8] = [] // allocated on the first process not seen before
        let current = Dictionary(entries.map { entry -> (Identity, AgentKind?) in
            let identity = Identity(key: entry.key, command: entry.command)
            if let known = kinds[identity] { return (identity, known) }
            if buffer.isEmpty { buffer = [UInt8](repeating: 0, count: ProcessTable.argumentMax) }
            let kind = ProcessTable.commandLine(of: entry.key.pid, buffer: &buffer)
                .flatMap { AgentCatalog.kind(executablePath: $0.executable, argv: $0.argv) }
            return (identity, kind)
        }, uniquingKeysWith: { first, _ in first })
        kinds = current
        return Dictionary(current.compactMap { identity, kind in kind.map { (identity.key.pid, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Agents whose process tree (the agent and everything it started) averaged at least
    /// `AgentDetection.busyCPU` since the previous scan.
    private func busyRoots(rootOf: [ProcessKey: Int32], now: Date) -> Set<Int32> {
        let readings = Dictionary(uniqueKeysWithValues: rootOf.compactMap { key, root -> (ProcessKey, CPUMeter.Reading)? in
            // A process that's listed but can't be read (e.g. exiting) keeps its last reading
            // until it's gone, so its CPU isn't counted twice once its parent reaps it.
            guard let total = ProcessTable.cpuTime(of: key.pid) ?? meter.readings[key]?.total else { return nil }
            return (key, CPUMeter.Reading(root: root, total: total))
        })
        let (nextMeter, cores) = meter.updated(readings: readings, now: now)
        meter = nextMeter
        return Set(cores.filter { $0.value >= AgentDetection.busyCPU }.keys)
    }

    private func claudeStatuses(for processes: [AgentProcess]) -> [Int32: ClaudeSessionStatus] {
        let directory = home.appendingPathComponent(ClaudeSessionStatus.directory)
        let statuses = processes.filter { $0.kind == AgentCatalog.claude }.compactMap { process -> (Int32, ClaudeSessionStatus)? in
            let file = directory.appendingPathComponent("\(process.pid).json")
            if let data = try? Data(contentsOf: file),
               let status = ClaudeSessionStatus.decode(data), status.pid == process.pid {
                return (process.pid, status)
            }
            // Caught mid-write: keep the last status rather than dropping a busy session.
            // No file at all and none before: an older Claude version, which other signals cover.
            return lastStatuses[process.pid].map { (process.pid, $0) }
        }
        let current = Dictionary(statuses, uniquingKeysWith: { first, _ in first })
        lastStatuses = current
        return current
    }
}

/// The current user's processes, read with `sysctl` and `libproc` (no `ps` subprocess).
enum ProcessTable {
    struct Entry: Sendable {
        let key: ProcessKey
        let parent: Int32
        /// The kernel's short name (`p_comm`), which changes when the process execs.
        let command: String
    }

    static func entries() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            agentLog.error("Listing processes failed: errno \(errno)")
            return []
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Processes can start between the two calls; leave room for some.
        let capacity = size / stride + 64
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else {
            agentLog.error("Listing processes failed: errno \(errno)")
            return []
        }
        return procs.prefix(size / stride).map { proc in
            let start = proc.kp_proc.p_starttime
            let command = withUnsafeBytes(of: proc.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return Entry(
                key: ProcessKey(pid: proc.kp_proc.p_pid, started: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000),
                parent: proc.kp_eproc.e_ppid,
                command: command
            )
        }
    }

    /// Executable path and `argv`, or `nil` for a process that's gone or not ours. `buffer`
    /// must hold `argumentMax` bytes; it's reused across calls.
    static func commandLine(of pid: Int32, buffer: inout [UInt8]) -> (executable: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessArguments.parse(buffer.prefix(size))
    }

    /// CPU seconds used by the process and by its children that already exited.
    static func cpuTime(of pid: Int32) -> TimeInterval? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time + info.ri_child_user_time + info.ri_child_system_time
        return Double(ticks) * nanosecondsPerTick / 1_000_000_000
    }

    static let argumentMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    /// `rusage` times are in Mach time units, which aren't nanoseconds on Apple silicon.
    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()
}

enum PowerAssertions {
    private static let sleepPreventing: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
    ]

    /// Processes holding an assertion that keeps the Mac or its display awake, such as the
    /// `caffeinate` Claude Code runs while it works.
    static func pidsPreventingSleep() -> Set<Int32> {
        var unmanaged: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&unmanaged)
        guard result == kIOReturnSuccess, let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            agentLog.error("Reading power assertions failed: \(result)")
            return []
        }
        return Set(byProcess.compactMap { pid, assertions in
            assertions.contains { sleepPreventing.contains($0[kIOPMAssertionTypeKey] as? String ?? "") }
                ? pid.int32Value : nil
        })
    }
}
