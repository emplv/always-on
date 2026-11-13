# Always On

A small macOS menu bar app that keeps your Mac and its display awake: for as long as you
choose, or only while your coding agents are working.

## Download

|          | |
|----------|---|
| **[Always On](https://alwayson.emplv.com/downloads/AlwaysOn.dmg)** | Everything, including keep-awake with the lid closed (asks for your admin password once). |
| **[Always On Lite](https://alwayson.emplv.com/downloads/AlwaysOn-Lite.dmg)** | Everything except the lid-closed mode, so it never asks for admin rights. |

Free, signed and notarized by Apple, for macOS 13 or later on Apple silicon and Intel. Open the
DMG and drag the app to Applications. More at [alwayson.emplv.com](https://alwayson.emplv.com).

## Features

- **Keep always on**: the main switch. While on, the Mac and display don't idle-sleep and the
  screen saver doesn't start, which is the same thing a browser does while a video plays.
  - **Duration**: until you turn it off, 30 min – 12 hours, 1 day – 1 week, or until a date and
    time. Changing it while on restarts the clock from now. A running session survives restarts.
  - **Countdown**: timed sessions show a live countdown in the panel. Tick "Show in menu bar" to
    also show the largest unit left next to the icon: `3d`, `5h`, `42m`, then `59s`, `58s`, …
- **Keep awake while agents work**: keeps the Mac and display awake only while coding agents
  are busy, and shows how many: `3 agents working: 2 Claude, 1 Codex`. Works with Claude Code,
  Codex (CLI and app), Gemini CLI, Qwen Code, OpenCode, Aider and Cursor's `cursor-agent`, in
  any terminal, tmux, an IDE's terminal or the Codex app, with no setup. Idle sessions don't
  count, so a forgotten `claude` tab doesn't keep the Mac up for days.
- **Keep awake with lid closed** (Full build, MacBooks only): a sub-switch under each of the two
  switches above, shown while that switch is on. Close the lid, walk away, and the session or
  the agents carry on. It asks for your admin password once; see [How it works](#how-it-works).
- **Uptime warning**: from 45 days of uptime the menu bar icon turns into ⚠︎, plus a daily
  notification. After 49.7 days macOS stops opening new network connections until it restarts
  (its 32-bit `tcp_now` clock overflows).
- **Start at login**: on by default.

## Privacy

Always On makes no network connections and collects nothing. To spot agents it reads, locally,
your own process list, Claude Code's small status files in `~/.claude/sessions`, and which
transcript files in `~/.claude/projects` and `~/.codex/sessions` changed (names and times,
never their contents).

## How it works

- **Keep always on**: a `ProcessInfo` activity holding `PreventUserIdleSystemSleep` and
  `PreventUserIdleDisplaySleep` power assertions (like `caffeinate -di`). macOS releases them if
  the app quits or crashes.
- **Agents**: every 5 seconds the app lists your processes (`sysctl`, no subprocesses) and picks
  out agents by executable or script name. Processes an agent starts (shells, builds,
  `caffeinate`) count toward that agent. An agent is working when any of these holds:
  - Claude Code's own status file `~/.claude/sessions/<pid>.json` says `busy`. Where it
    exists, it alone decides for that Claude session.
  - The agent or one of its children holds a sleep assertion, like the `caffeinate -i` Claude
    Code runs during a turn (or Codex with its `prevent_idle_sleep` feature).
  - The agent and its children used at least 3% of a core since the last scan (idle is about
    0.5%).
  - A session transcript changed (`~/.claude/projects`, `~/.codex/sessions`, watched with
    FSEvents). This counts the Codex app's threads, which all run in one process.

  Apart from the Claude status file, activity counts for 5 more minutes, to bridge a model
  thinking or a tool waiting on the network. An agent that quits stops counting right away.
  While agents work, the app holds a second activity ("Always On: agents are working") with the
  same assertions as the main switch. Not covered yet: Claude's Cowork, which runs in a virtual
  machine inside the Claude app.
- **Lid closed**: no app-level assertion can stop lid-close sleep, so this uses
  `pmset -a disablesleep 1`, which needs root. The first time, the app installs (after your admin
  password and a `visudo` check) `/etc/sudoers.d/always-on`, which lets your user run exactly
  `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password, and nothing else.
  That's what lets a timed session, or agents finishing, undo it while you're away. Unlike
  assertions, this setting outlives the app, so the app undoes it when it's no longer wanted,
  when the app quits, and on the next launch after a crash. The Lite build has none of this
  code.

Check it's working:

```sh
pmset -g assertions | grep "Always On"
pmset -g | grep SleepDisabled      # lid mode
```

## Uninstall

Quit Always On and move it to the Trash. If you used the lid-closed mode, also remove its rule:

```sh
sudo rm /etc/sudoers.d/always-on
```

## Build from source

```sh
./build.sh           # -> build/Always On.app (universal, ad-hoc signed)
./build.sh --lite    # -> build/lite/Always On.app, without lid-closed mode (Swift flag LITE)
./build.sh install   # also replaces /Applications/Always On.app and relaunches it
./test.sh            # unit tests for the agent detection
```

Needs the Xcode command line tools. Install to /Applications before relying on start at login:
the login item points at the app's location.

Or open `AlwaysOn.xcodeproj` in Xcode and press ⌘R. It builds the Full app (signed to run
locally, no sandbox, which the lid-closed mode and agent detection need). `Sources/` is a synced
folder, so new `.swift` files there are picked up by both Xcode and `build.sh`.

## Release

```sh
./release.sh                 # -> build/AlwaysOn-<version>.dmg, Developer ID signed + notarized
./release.sh --lite          # -> build/AlwaysOn-Lite-<version>.dmg
./release.sh --no-notarize   # signed only; Gatekeeper blocks it on other Macs
PUBLISH_HOST=user@host ./publish.sh   # upload both to alwayson.emplv.com/downloads
```

Needs a "Developer ID Application" certificate in the keychain (override with `SIGN_ID`) and,
once, a notarytool profile (override the name with `NOTARY_PROFILE`), which prompts for an
app-specific password from account.apple.com:

```sh
xcrun notarytool store-credentials AlwaysOn --apple-id <apple-id> --team-id <team-id>
```

## License

MIT, see [LICENSE](LICENSE).
