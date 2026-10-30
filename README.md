# Always On

A small macOS menu bar app that keeps your Mac (and its display) awake.

- **Keep always on**: the main switch. While on, the Mac and display don't idle-sleep and the
  screen saver doesn't start, which is the same thing Firefox does while a video plays.
- **Duration**: until you turn it off, 30 min – 12 hours, 1 day – 1 week, or until a date & time.
  Changing it while on restarts the clock from now. A running session survives restarts.
- **Countdown**: timed sessions show a live countdown in the panel. Tick "Show in menu bar" to
  also show the largest unit left next to the icon: `3d`, `5h`, `42m`, then `59s`, `58s`, …
- **Keep awake with lid closed** (MacBooks only, hidden on other Macs): asks for your admin
  password once; see below.
- **Uptime**: with a warning (menu bar icon turns into ⚠︎, plus a daily notification) from
  45 days of uptime. After 49.7 days macOS stops opening new network connections until restarted
  (32-bit `tcp_now` overflow).
- **Start at login**: on by default.

## Build & install

```sh
./build.sh           # -> build/Always On.app (universal, ad-hoc signed)
./build.sh install   # also replaces /Applications/Always On.app and relaunches it
```

Needs the Xcode command line tools; runs on macOS 13+. Install to /Applications before relying on
start at login: the login item points at the app's location.

Or open `AlwaysOn.xcodeproj` in Xcode and press ⌘R. It builds the same app (signed to run
locally, no sandbox, which the lid-closed mode needs). `Sources/` is a synced folder, so new
`.swift` files there are picked up by both Xcode and `build.sh`. Universal Release build from the
command line:

```sh
xcodebuild -project AlwaysOn.xcodeproj -scheme AlwaysOn -configuration Release \
  -derivedDataPath build/DerivedData build
```

## How it works

- Keep always on: a `ProcessInfo` activity holding `PreventUserIdleSystemSleep` +
  `PreventUserIdleDisplaySleep` power assertions (like `caffeinate -di`). macOS releases them if
  the app quits or crashes.
- Lid closed: no app-level assertion can stop lid-close sleep, so this uses
  `pmset -a disablesleep 1`, which needs root. The first time, the app installs (after your admin
  password and a `visudo` check) `/etc/sudoers.d/always-on`, which lets your user run exactly
  `pmset -a disablesleep 0|1` without a password. That's what lets a timed session undo it
  while you're away. Unlike assertions, this setting outlives the app, so the app undoes it when
  the session ends or the app quits, and on next launch after a crash. To remove the rule:
  `sudo rm /etc/sudoers.d/always-on`.

Check it's working:

```sh
pmset -g assertions | grep "Always On"
pmset -g | grep SleepDisabled      # lid mode
```
