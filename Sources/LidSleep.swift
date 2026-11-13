import Foundation
import IOKit

/// Keeping a MacBook awake with the lid closed needs `pmset -a disablesleep 1`, which only
/// root can run, and no app-level assertion can do it. The first time, the user approves
/// (with their admin password) a sudoers rule that allows exactly `pmset -a disablesleep 0|1`
/// without a password, so the app can also undo it unattended when a timed session ends.
enum LidSleep {
    enum Failure: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Cancelled."
            case .failed(let message): message
            }
        }
    }
}

#if LITE
/// The Lite build (`./build.sh --lite`) has no lid-closed mode, so it never asks for admin
/// rights: no sudoers rule and no `pmset` in the binary. With no lid, the switches stay hidden.
extension LidSleep {
    static let hasLid = false
    static let isSleepDisabled = false
    static func setSleepDisabled(_ disabled: Bool, interactive: Bool) throws {}
    static func authorize() throws {}
}
#else
extension LidSleep {
    private static let pmset = "/usr/bin/pmset"
    static let sudoersFile = "/etc/sudoers.d/always-on"

    static let hasLid = rootDomainProperty("AppleClamshellState") != nil

    static var isSleepDisabled: Bool {
        rootDomainProperty("SleepDisabled") as? Bool ?? false
    }

    /// With `interactive`, asks for the admin password if the sudoers rule isn't installed yet.
    static func setSleepDisabled(_ disabled: Bool, interactive: Bool) throws {
        let arguments = ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"]
        if run("/usr/bin/sudo", arguments) == 0 { return }
        guard interactive else {
            throw Failure.failed("Couldn't change the lid setting without your admin password.")
        }
        try installSudoersRule()
        guard run("/usr/bin/sudo", arguments) == 0 else {
            throw Failure.failed("macOS didn't allow changing the lid setting.")
        }
    }

    /// Makes sure the lid setting can later change without a password (e.g. when an agent
    /// starts working while you're away), asking for the admin password now if needed.
    static func authorize() throws {
        guard !isAuthorized else { return }
        try installSudoersRule()
        guard isAuthorized else { throw Failure.failed("macOS didn't allow changing the lid setting.") }
    }

    /// Re-applies the current value, which changes nothing. (`sudo -l` can't tell: it also
    /// says yes to commands an admin may run with a password.)
    private static var isAuthorized: Bool {
        run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", isSleepDisabled ? "1" : "0"]) == 0
    }

    /// Validates the rule with visudo before installing it: a broken sudoers file would break sudo.
    static func sudoersSetupCommand(destination: String = sudoersFile) -> String {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
        return """
            tmp=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '\(rule)' > "$tmp" && /bin/chmod 0440 "$tmp" \
            && /usr/sbin/visudo -cqf "$tmp" && /usr/bin/install -m 0440 -o root -g wheel "$tmp" \(destination); \
            status=$?; /bin/rm -f "$tmp"; exit $status
            """
    }

    private static func installSudoersRule() throws {
        let prompt = "Always On wants to keep this Mac awake with the lid closed."
        let source = "do shell script \(appleScriptString(sudoersSetupCommand())) with prompt \(appleScriptString(prompt)) with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        if error[NSAppleScript.errorNumber] as? Int == -128 { throw Failure.cancelled }
        throw Failure.failed(error[NSAppleScript.errorMessage] as? String ?? "Setup failed.")
    }

    static func appleScriptString(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func rootDomainProperty(_ key: String) -> Any? {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(rootDomain) }
        return IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
