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

MVP spike stage. The repo now contains:

- a buildable UIKit/Mac Catalyst dashboard shell in [`FloatyApp/`](FloatyApp/)
- a Rust local core crate in [`crates/floaty-core`](crates/floaty-core)
- the initial execution plan in [`docs/plans/floating-window-agent-dashboard-2026-06-26.md`](docs/plans/floating-window-agent-dashboard-2026-06-26.md)
- the Catalyst window feasibility result in [`docs/spikes/catalyst-window-feasibility-2026-06-26.md`](docs/spikes/catalyst-window-feasibility-2026-06-26.md)

The Catalyst spike documents that direct public `NSWindow`/`NSApplication` floating and Dock-minimize APIs are unavailable to Mac Catalyst in the tested SDK; those commands report `supportableAPIUnavailable`, while activation uses UIKit scene APIs. The dashboard currently uses a Swift mock provider shaped like the Rust `DashboardSnapshot`; the next step is linking the Rust FFI artifact into the Catalyst target.

## License

MIT. See [`LICENSE`](LICENSE).
