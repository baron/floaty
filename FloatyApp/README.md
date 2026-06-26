# Floaty

Floaty is a native macOS floating activity widget for keeping track of local agent work across Codex, Claude Code, OpenCode, and other runners.

The current app is intentionally small and glanceable: it opens as a floating `NSPanel`, scans local agent session metadata, and renders the dashboard in one custom AppKit view so engineers can see where work is happening without opening every terminal or agent UI.

## What it shows

- running, just-finished, and done local agent instance counts
- projects in motion, sorted by activity
- per-project Codex and Claude Code instances
- prompt/session labels from session metadata
- motion-aware status from live process state and file modification changes
- watched local source roots

## Current Provider

`DashboardViewController` uses `LocalSessionSnapshotProvider`, a read-only provider that scans:

- `~/.codex/sessions`
- `~/.claude/projects`
- `~/.codex/process_manager/chat_processes.json`

The provider reads bounded metadata from recent JSONL files, groups sessions by project, filters stale/unknown sessions out of the floating UI, and uses live Codex process-manager pids plus file modification movement to separate in-progress, just-finished, and done work.

## App icon

The app icon lives in `FloatyApp/FloatyApp/Assets.xcassets/AppIcon.appiconset`.

Regenerate the PNG set with:

```sh
swift script/generate_app_icon.swift FloatyApp/FloatyApp/Assets.xcassets/AppIcon.appiconset
```

## Build and Run

From the repository root:

```sh
./script/build_and_run.sh
```

Useful modes:

```sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --debug
```

The Codex Run action is wired to the same script through `.codex/environments/environment.toml`.
