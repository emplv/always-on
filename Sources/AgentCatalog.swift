import Foundation

/// A coding agent the app can spot by the command that started it.
struct AgentKind: Hashable, Sendable {
    let name: String
    /// Executable or script names (case-sensitive, without extension) that start this agent.
    let commands: Set<String>
    /// First arguments that start a helper or server rather than an agent session.
    var helperSubcommands: Set<String> = []
    /// Arguments that mark a long-lived helper, such as Claude's Chrome bridge.
    var helperArguments: Set<String> = []

    func isHelper(arguments: [String]) -> Bool {
        if let first = arguments.first, helperSubcommands.contains(first) { return true }
        return !helperArguments.isDisjoint(with: arguments)
    }
}

enum AgentCatalog {
    static let claude = AgentKind(
        name: "Claude",
        commands: ["claude"],
        helperSubcommands: ["mcp"],
        helperArguments: ["--chrome-native-host"]
    )
    static let codex = AgentKind(name: "Codex", commands: ["codex"])

    static let all: [AgentKind] = [
        claude,
        codex,
        AgentKind(name: "Gemini", commands: ["gemini"]),
        AgentKind(name: "Qwen Code", commands: ["qwen"]),
        AgentKind(name: "OpenCode", commands: ["opencode"]),
        AgentKind(name: "Aider", commands: ["aider"]),
        AgentKind(name: "Cursor", commands: ["cursor-agent"]),
        // Left out on purpose: names other tools share, like `goose` (DB migrations) or
        // `copilot` (AWS), since a busy one would keep the Mac awake.
    ]

    /// Runtimes that agents written in JavaScript or Python run under; the agent is then the script.
    private static let interpreters: Set<String> = ["node", "bun", "deno"]
    private static let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "ts", "py"]

    /// The agent a process runs, judged by its executable, `argv[0]`, or the script an
    /// interpreter runs. `argv` includes `argv[0]`.
    static func kind(executablePath: String, argv: [String]) -> AgentKind? {
        let invoked = Set([executablePath, argv.first ?? ""].map(commandName))
        let arguments = Array(argv.dropFirst())

        if let kind = all.first(where: { !$0.commands.isDisjoint(with: invoked) }) {
            return kind.isHelper(arguments: arguments) ? nil : kind
        }
        guard invoked.contains(where: isInterpreter),
              let scriptIndex = arguments.firstIndex(where: { !$0.hasPrefix("-") })
        else { return nil }

        let script = commandName(arguments[scriptIndex])
        guard let kind = all.first(where: { $0.commands.contains(script) }) else { return nil }
        return kind.isHelper(arguments: Array(arguments[(scriptIndex + 1)...])) ? nil : kind
    }

    private static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || name.hasPrefix("python")
    }

    /// "/opt/homebrew/bin/gemini.js" → "gemini"; "-zsh" (login shell) → "zsh". Case stays, so
    /// the desktop apps (`Claude.app/Contents/MacOS/Claude`) aren't taken for their CLIs.
    private static func commandName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let base = scriptExtensions.contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
        return String(base.drop(while: { $0 == "-" }))
    }
}

/// Parses a `KERN_PROCARGS2` buffer: argc (Int32), the executable path, NUL padding, then argc
/// NUL-terminated arguments (possibly empty), then the environment, which is left out.
enum ProcessArguments {
    static func parse(_ buffer: some Collection<UInt8>) -> (executable: String, argv: [String])? {
        let bytes = Array(buffer)
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0, let pathEnd = bytes[header...].firstIndex(of: 0) else { return nil }

        let executable = String(decoding: bytes[header..<pathEnd], as: UTF8.self)
        var start = bytes[pathEnd...].firstIndex(where: { $0 != 0 }) ?? bytes.endIndex
        var argv: [String] = []
        while argv.count < argc, start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 0) ?? bytes.endIndex
            argv.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = min(end + 1, bytes.endIndex)
        }
        return (executable, argv)
    }
}

/// Where an agent writes its session transcripts, and how a file there maps to a session.
struct TranscriptSource: Sendable {
    enum Layout: Sendable {
        /// `<project>/<session>.jsonl`, plus `<project>/<session>/subagents/<agent>.jsonl`.
        case claudeProjects
        /// `<yyyy>/<mm>/<dd>/rollout-<time>-<thread>.jsonl`, one file per thread.
        case codexRollouts
    }

    let kind: AgentKind
    /// Relative to the home folder.
    let directory: String
    let layout: Layout

    static let claude = TranscriptSource(kind: AgentCatalog.claude, directory: ".claude/projects", layout: .claudeProjects)
    static let codex = TranscriptSource(kind: AgentCatalog.codex, directory: ".codex/sessions", layout: .codexRollouts)
    static let all = [claude, codex]

    /// The session a changed file belongs to; `relativePath` is relative to `directory`.
    func sessionID(relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let file = parts.last, file.hasSuffix(".jsonl") else { return nil }
        let stem = String(file.dropLast(".jsonl".count))
        switch layout {
        case .claudeProjects:
            guard parts.count >= 2 else { return nil }
            return parts.count == 2 ? stem : parts[1]
        case .codexRollouts:
            return file.hasPrefix("rollout-") ? stem : nil
        }
    }
}

/// Claude Code's `~/.claude/sessions/<pid>.json`: which session a process runs, and whether
/// it's busy with a turn. Older Claude versions don't write it.
struct ClaudeSessionStatus: Decodable, Hashable, Sendable {
    static let directory = ".claude/sessions"

    let pid: Int32
    let sessionId: String
    let status: String?

    var isBusy: Bool { status == "busy" }

    /// `nil` for a file that isn't a status file, e.g. one written halfway.
    static func decode(_ data: Data) -> ClaudeSessionStatus? {
        try? JSONDecoder().decode(ClaudeSessionStatus.self, from: data)
    }
}
