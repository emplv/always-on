import Foundation

/// Unit tests for the pure agent-detection logic. Run with `./test.sh`.
@main
enum AgentDetectionTests {
    static func main() {
        let check = Checker()
        catalogTests(check)
        transcriptTests(check)
        claudeStatusTests(check)
        argumentTests(check)
        processTreeTests(check)
        cpuMeterTests(check)
        trackerTests(check)
        summaryTests(check)
        print(check.failures == 0
              ? "All \(check.count) checks passed."
              : "\(check.failures) of \(check.count) checks failed.")
        exit(check.failures == 0 ? 0 : 1)
    }

    // MARK: - Catalog

    static func catalogTests(_ check: Checker) {
        let claude = AgentCatalog.kind(
            executablePath: "/Users/me/.local/share/claude/versions/2.1.323",
            argv: ["claude", "--dangerously-skip-permissions"]
        )
        check.equal(claude, AgentCatalog.claude, "native claude binary started as `claude`")
        check.equal(
            AgentCatalog.kind(executablePath: "/Users/me/.local/bin/claude", argv: ["/Users/me/.local/bin/claude", "--chrome-native-host"]),
            nil, "Claude's Chrome bridge is a helper, not a session"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/usr/local/bin/claude", argv: ["claude", "mcp", "serve"]),
            nil, "`claude mcp serve` is a helper"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/Users/me/.codex/bin/codex", argv: ["/Users/me/.codex/bin/codex", "app-server", "daemon"]),
            AgentCatalog.codex, "Codex app-server daemon"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/Users/me/.codex/bin/codex-code-mode-host", argv: ["codex-code-mode-host"]),
            nil, "Codex helper binary with a different name"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/gemini", "-p", "hi"])?.name,
            "Gemini", "node script agent"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/opt/homebrew/bin/node", argv: ["node", "--no-warnings", "/usr/local/bin/qwen"])?.name,
            "Qwen Code", "node flags before the script"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/usr/bin/python3.12", argv: ["python3.12", "/Users/me/.local/bin/aider"])?.name,
            "Aider", "python script agent"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/opt/homebrew/bin/node", argv: ["node", "/x/cursor-agent.js"])?.name,
            "Cursor", "script extension is ignored"
        )
        check.equal(AgentCatalog.kind(executablePath: "/opt/homebrew/bin/node", argv: ["node", "server.js"]), nil, "plain node app")
        check.equal(AgentCatalog.kind(executablePath: "/bin/zsh", argv: ["-zsh"]), nil, "shell")
        check.equal(
            AgentCatalog.kind(executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor", argv: ["Cursor"]),
            nil, "IDE itself isn't an agent"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/Applications/Claude.app/Contents/MacOS/Claude", argv: ["/Applications/Claude.app/Contents/MacOS/Claude"]),
            nil, "Claude desktop app isn't the claude CLI"
        )
        check.equal(
            AgentCatalog.kind(executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", argv: ["Codex"]),
            nil, "Codex desktop app shell isn't the codex CLI"
        )
        check.equal(AgentCatalog.kind(executablePath: "/opt/homebrew/bin/goose", argv: ["goose", "up"]), nil, "ambiguous names aren't matched")
    }

    // MARK: - Arguments

    static func argumentTests(_ check: Checker) {
        func procargs(argc: Int32, _ strings: [String], padding: Int = 3) -> [UInt8] {
            let header = withUnsafeBytes(of: argc) { Array($0) }
            let path = Array(strings[0].utf8) + [UInt8](repeating: 0, count: padding)
            let rest: [UInt8] = strings.dropFirst().flatMap { Array($0.utf8) + [UInt8(0)] }
            return header + path + rest
        }
        let parsed = ProcessArguments.parse(procargs(argc: 3, ["/bin/claude", "claude", "", "-p", "HOME=/x"]))
        check.equal(parsed?.executable, "/bin/claude", "executable path")
        check.equal(parsed?.argv, ["claude", "", "-p"], "empty argument kept, environment left out")
        check.equal(ProcessArguments.parse([1, 0]) == nil, true, "truncated buffer")
    }

    // MARK: - Transcripts

    static func transcriptTests(_ check: Checker) {
        let claude = TranscriptSource.claude
        check.equal(claude.sessionID(relativePath: "-Users-me-app/1ec2285f.jsonl"), "1ec2285f", "Claude transcript")
        check.equal(claude.sessionID(relativePath: "-Users-me-app/1ec2285f/subagents/agent-a1.jsonl"), "1ec2285f", "Claude subagent transcript")
        check.equal(claude.sessionID(relativePath: "-Users-me-app/memory/MEMORY.md"), nil, "Claude memory file")
        check.equal(claude.sessionID(relativePath: "-Users-me-app/1ec2285f/tool-results/x.txt"), nil, "Claude tool output")
        check.equal(claude.sessionID(relativePath: "stray.jsonl"), nil, "file outside a project folder")

        let codex = TranscriptSource.codex
        check.equal(
            codex.sessionID(relativePath: "2026/11/13/rollout-2026-11-13T12-24-19-01a1d46f.jsonl"),
            "rollout-2026-11-13T12-24-19-01a1d46f", "Codex rollout"
        )
        check.equal(codex.sessionID(relativePath: "2026/11/13/notes.jsonl"), nil, "not a rollout")
    }

    // MARK: - Claude status files

    static func claudeStatusTests(_ check: Checker) {
        let busy = ClaudeSessionStatus.decode(Data("""
            {"pid":3520,"sessionId":"6e9f","cwd":"/x","kind":"interactive","status":"busy","updatedAt":1794571858363}
            """.utf8))
        check.equal(busy?.pid, 3520, "pid")
        check.equal(busy?.sessionId, "6e9f", "session")
        check.equal(busy?.isBusy, true, "busy")
        let idle = ClaudeSessionStatus.decode(Data(#"{"pid":1,"sessionId":"a","status":"idle"}"#.utf8))
        check.equal(idle?.isBusy, false, "idle")
        let noStatus = ClaudeSessionStatus.decode(Data(#"{"pid":1,"sessionId":"a"}"#.utf8))
        check.equal(noStatus?.isBusy, false, "missing status counts as not busy")
        check.equal(ClaudeSessionStatus.decode(Data("not json".utf8)), nil, "malformed file")
    }

    // MARK: - Process tree

    static func processTreeTests(_ check: Checker) {
        // caffeinate 10 → claude 9 → zsh 8 → tmux 7 → launchd 1
        let parents: [Int32: Int32] = [10: 9, 9: 8, 8: 7, 7: 1]
        check.equal(ProcessTree.agentRoot(of: 10, parents: parents, agents: [9]), 9, "caffeinate counts toward claude")
        check.equal(ProcessTree.agentRoot(of: 9, parents: parents, agents: [9]), 9, "agent is its own root")
        check.equal(ProcessTree.agentRoot(of: 8, parents: parents, agents: [9]), nil, "shell above the agent")

        // codex daemon 20 → app-server 21 → zsh 22 → cargo 23
        let nested: [Int32: Int32] = [23: 22, 22: 21, 21: 20, 20: 1]
        check.equal(ProcessTree.agentRoot(of: 23, parents: nested, agents: [20, 21]), 20, "outermost agent wins")

        check.equal(ProcessTree.agentRoot(of: 5, parents: [5: 6, 6: 5], agents: []), nil, "parent cycle terminates")
    }

    // MARK: - CPU

    static func cpuMeterTests(_ check: Checker) {
        typealias Reading = CPUMeter.Reading
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(5)
        let agent = ProcessKey(pid: 1, started: 500)
        let (first, firstCores) = CPUMeter().updated(readings: [agent: Reading(root: 1, total: 10)], now: t0)
        check.equal(firstCores, [:], "first sample is a baseline")

        let fresh = ProcessKey(pid: 2, started: 1_002)
        let joined = ProcessKey(pid: 3, started: 900)
        let (_, cores) = first.updated(readings: [
            agent: Reading(root: 1, total: 10.5),
            fresh: Reading(root: 1, total: 0.2),
            joined: Reading(root: 1, total: 50),
        ], now: t1)
        check.near(cores[1], 0.14, "0.5 s + a new process's 0.2 s over 5 s; an older process first seen is a baseline")

        // An MCP server (pid 4) that used 20 s over an hour exits; its agent reaps it and its
        // 20 s move into the agent's child time.
        let server = ProcessKey(pid: 4, started: 100)
        let (before, _) = CPUMeter().updated(readings: [agent: Reading(root: 1, total: 1), server: Reading(root: 1, total: 20)], now: t0)
        let (_, afterExit) = before.updated(readings: [agent: Reading(root: 1, total: 21)], now: t1)
        check.near(afterExit[1], 0, "an exiting child's earlier CPU isn't counted again")

        let (_, busyExit) = before.updated(readings: [agent: Reading(root: 1, total: 22)], now: t1)
        check.near(busyExit[1], 0.2, "only CPU used since the last sample counts")
    }

    // MARK: - Tracker

    static func trackerTests(_ check: Checker) {
        let t0 = Date(timeIntervalSince1970: 10_000)
        let claude = AgentCatalog.claude
        let codex = AgentCatalog.codex
        let claudeProc = AgentProcess(pid: 100, kind: claude)
        let codexProc = AgentProcess(pid: 200, kind: codex)

        func status(_ pid: Int32, _ session: String, _ state: String) -> ClaudeSessionStatus {
            ClaudeSessionStatus(pid: pid, sessionId: session, status: state)
        }
        func activity(_ observation: AgentObservation, writes: [SessionKey: Date] = [:], from tracker: AgentTracker = AgentTracker(), at now: Date) -> (AgentTracker, AgentActivity) {
            let next = tracker.updated(with: observation, writes: writes, now: now)
            return (next, next.activity(now: now))
        }

        let busyObs = AgentObservation(processes: [claudeProc], activePIDs: [], claudeStatuses: [100: status(100, "s1", "busy")])
        check.equal(activity(busyObs, at: t0).1.total, 1, "busy Claude status")

        let idleObs = AgentObservation(processes: [claudeProc], activePIDs: [100], claudeStatuses: [100: status(100, "s1", "idle")])
        let linkedWrite = [SessionKey(kind: claude, id: "s1"): t0]
        check.equal(activity(idleObs, writes: linkedWrite, at: t0).1.total, 0, "idle status wins over CPU and writes")

        let (busyTracker, _) = activity(busyObs, at: t0)
        let (_, afterIdle) = activity(idleObs, writes: linkedWrite, from: busyTracker, at: t0.addingTimeInterval(5))
        check.equal(afterIdle.total, 0, "busy → idle stops counting right away")

        let oldClaude = AgentObservation(processes: [claudeProc], activePIDs: [100], claudeStatuses: [:])
        check.equal(activity(oldClaude, at: t0).1.total, 1, "Claude without status file, busy CPU")
        let unlinked = [SessionKey(kind: claude, id: "s9"): t0]
        check.equal(activity(oldClaude, writes: unlinked, at: t0).1.total, 1, "its transcript isn't counted twice")

        let codexObs = AgentObservation(processes: [codexProc], activePIDs: [200], claudeStatuses: [:])
        let twoRollouts = [SessionKey(kind: codex, id: "r1"): t0, SessionKey(kind: codex, id: "r2"): t0]
        let (_, codexActivity) = activity(codexObs, writes: twoRollouts, at: t0)
        check.equal(codexActivity.counts, [AgentActivity.Count(name: "Codex", count: 2)], "Codex daemon with two threads")

        let quiet = AgentObservation(processes: [codexProc], activePIDs: [], claudeStatuses: [:])
        let (wrote, _) = activity(quiet, writes: [SessionKey(kind: codex, id: "r1"): t0], at: t0)
        let (stillGrace, inGrace) = activity(quiet, from: wrote, at: t0.addingTimeInterval(AgentDetection.gracePeriod - 1))
        check.equal(inGrace.total, 1, "quiet session counts during the grace period")
        let (_, pastGrace) = activity(quiet, from: stillGrace, at: t0.addingTimeInterval(AgentDetection.gracePeriod + 1))
        check.equal(pastGrace.total, 0, "and stops after it")

        let (cpuTracker, _) = activity(oldClaude, at: t0)
        let (_, exited) = activity(.empty, from: cpuTracker, at: t0.addingTimeInterval(5))
        check.equal(exited.total, 0, "agent that quit stops counting right away")

        let (linkedTracker, _) = activity(busyObs, at: t0)
        let (_, linkedExit) = activity(.empty, writes: linkedWrite, from: linkedTracker, at: t0.addingTimeInterval(5))
        check.equal(linkedExit.total, 0, "transcript write of a Claude session whose process quit")

        let (codexWrote, _) = activity(quiet, writes: [SessionKey(kind: codex, id: "r1"): t0], at: t0)
        let (_, codexQuit) = activity(.empty, from: codexWrote, at: t0.addingTimeInterval(5))
        check.equal(codexQuit.total, 0, "Codex that quit stops counting even within the grace period")

        let statusOnly = AgentObservation(processes: [claudeProc], activePIDs: [], claudeStatuses: [100: status(100, "s1", "idle")])
        check.equal(
            activity(statusOnly, writes: [SessionKey(kind: claude, id: "oneshot"): t0], at: t0).1.total, 0,
            "transcript of a `claude -p` run that already finished: every live Claude has a status file"
        )

        let mixed = AgentObservation(
            processes: [claudeProc, AgentProcess(pid: 101, kind: claude), codexProc],
            activePIDs: [200],
            claudeStatuses: [100: status(100, "s1", "busy"), 101: status(101, "s2", "busy")]
        )
        check.equal(
            activity(mixed, at: t0).1.counts,
            [AgentActivity.Count(name: "Claude", count: 2), AgentActivity.Count(name: "Codex", count: 1)],
            "counts per agent, most first"
        )
    }

    // MARK: - Summary

    static func summaryTests(_ check: Checker) {
        check.equal(AgentActivity.none.summary, "No agents working right now.", "none")
        check.equal(AgentActivity(counts: [.init(name: "Claude", count: 1)]).summary, "1 Claude agent working", "one")
        check.equal(AgentActivity(counts: [.init(name: "Codex", count: 2)]).summary, "2 Codex agents working", "one kind")
        check.equal(
            AgentActivity(counts: [.init(name: "Claude", count: 2), .init(name: "Codex", count: 1)]).summary,
            "3 agents working: 2 Claude, 1 Codex", "several kinds"
        )
    }
}

final class Checker {
    private(set) var failures = 0
    private(set) var count = 0

    func expect(_ condition: Bool, _ message: String, line: UInt) {
        count += 1
        guard !condition else { return }
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: UInt = #line) {
        expect(actual == expected, "\(message): expected \(expected), got \(actual)", line: line)
    }

    func near(_ actual: Double?, _ expected: Double, _ message: String, line: UInt = #line) {
        let ok = actual.map { abs($0 - expected) < 1e-9 } ?? false
        expect(ok, "\(message): expected \(expected), got \(String(describing: actual))", line: line)
    }
}
