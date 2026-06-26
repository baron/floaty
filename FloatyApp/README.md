# Floaty

Floaty is a native macOS floating activity widget for keeping track of local agent work across Codex, Claude Code, OpenCode, and other runners.

The current app is intentionally small and glanceable: it opens as a floating `NSPanel`, renders the dashboard in one custom AppKit view, and animates lightweight sparklines so engineers can see where work is happening without opening every terminal or agent UI.

## What it shows

- active agent count
- task pressure bars
- per-agent status rows
- project/root labels
- live-ish activity sparklines
- quick pause, restore, and refresh controls
- footer totals for completed work, spend, and tokens

## Current provider

`DashboardViewController` still uses a local mock provider with the same broad shape as the Rust dashboard snapshot. That keeps the UI buildable while the scanner/FFI integration evolves.

The mock data is deliberately realistic enough to exercise the widget: multiple tools, mixed project roots, active/idle/needs-input states, warnings, and token/cost totals.

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
