# Floaty

Floaty is an early-stage macOS floating-window dashboard concept for juggling local coding-agent sessions across projects.

The planned architecture uses:

- UIKit through Mac Catalyst for the host UI, not SwiftUI
- a narrow AppKit bridge for floating-window and Dock-minimize behavior
- a Rust core for local indexing, agent-session summaries, Git status, file watching, caching, and throttling
- read-only adapters for local tools such as Codex, Claude Code, OpenCode, Hermes, and future agents
- optional local pet assets from `~/.codex/pets`

See [`docs/plans/floating-window-agent-dashboard-2026-06-26.md`](docs/plans/floating-window-agent-dashboard-2026-06-26.md) for the initial execution plan.

## Status

Planning stage. No application code has been implemented yet.

## License

MIT. See [`LICENSE`](LICENSE).
