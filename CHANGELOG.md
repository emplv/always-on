# Changelog

Downloads for every version: [alwayson.emplv.com/changelog](https://alwayson.emplv.com/changelog).

## Unreleased

- Battery and heat stops for "Keep awake with lid closed": on battery below 10%, or when the
  Mac gets seriously hot, a closed Mac goes to sleep, and the panel says why. Needs no new
  admin rights.

## 1.2 (13 November 2026)

- "Keep always on" and "Keep awake while agents work" are now modes: turning one on turns the
  other off.
- "Keep awake with lid closed" is one switch below both modes and applies to whichever is on.
  It's grayed out while both are off. A lid setting you made for agents carries over.

## 1.0 (13 November 2026)

First public release.

- Keep always on: until you turn it off, 30 minutes to 1 week, or until a date and time, with a
  live countdown (optionally in the menu bar).
- Keep awake while agents work: the Mac and display stay awake only while Claude Code, Codex,
  Gemini CLI, Qwen Code, OpenCode, Aider or cursor-agent are busy, in any terminal, tmux, IDE or
  the Codex app.
- Keep awake with lid closed (Full build, MacBooks).
- Uptime warning from 45 days, before macOS stops opening network connections at 49.7 days.
- Start at login.
- Two builds: Full, and Lite without lid-closed mode, so it never asks for admin rights. Signed
  and notarized by Apple.
