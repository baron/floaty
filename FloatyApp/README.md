# Floaty

Floaty is a native macOS floating activity widget for keeping track of local agent work across Codex, Claude Code, OpenCode, and other runners.

The current app is intentionally small and glanceable: it opens as a floating `NSPanel`, scans local agent session metadata, and renders the dashboard in one custom AppKit view so engineers can see where work is happening without opening every terminal or agent UI.

## What it shows

- running, just-finished, and done local agent instance counts
- a priority view that keeps running projects represented before extra finished rows
- projects in motion, sorted by activity
- per-project Codex, Claude Code, and Hermes instances
- prompt/session labels from session metadata
- motion-aware status from live process state and file modification changes
- watched local source roots

## Current Provider

`DashboardViewController` uses `LocalSessionSnapshotProvider`, a read-only provider that scans:

- `~/.codex/sessions`
- `~/.claude/projects`
- `~/.codex/process_manager/chat_processes.json`
- `~/.hermes/state.db` (SQLite/WAL, read-only)

The provider reads bounded metadata from recent Codex/Claude JSONL files plus recent Hermes rows from the current `sessions`/`messages` schema contract (`schema_version >= 16`, session id/title/cwd/git repo root/timestamps and latest message timestamp/content). Missing, busy, or schema-mismatched Hermes state is reported as a non-fatal warning so Codex/Claude rows keep rendering.

Rust parity follow-up: when the Rust FFI-backed provider replaces this Swift-local path, add Hermes discovery config and a parser for the same `~/.hermes/state.db` schema instead of duplicating a second runtime source.

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
