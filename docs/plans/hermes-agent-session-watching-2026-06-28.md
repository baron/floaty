# Hermes Agent Session Watching: Plan

## Goal
Add Hermes agent sessions to Floaty's current local session watching so Hermes activity appears beside Codex and Claude Code in the floating dashboard without committing private state, writing to Hermes data, or blocking UI refreshes.

## Background
- Floaty's original plan includes Hermes, but deferred it until the storage/export format was known (`docs/plans/floating-window-agent-dashboard-2026-06-26.md:6`, `docs/plans/floating-window-agent-dashboard-2026-06-26.md:14`, `docs/plans/floating-window-agent-dashboard-2026-06-26.md:85`).
- The intended long-term architecture puts local indexing and read-only adapters in Rust, but the current app still uses `LocalSessionSnapshotProvider` in Swift (`README.md:5-10`, `README.md:24-26`; `FloatyApp/FloatyApp/DashboardViewController.swift:78-130`).
- Rust already has normalized session types and `AgentKind::Hermes`, but no Hermes discovery input and no app-facing non-mock FFI path yet (`crates/floaty-core/src/lib.rs:17-110`, `crates/floaty-core/src/lib.rs:182-210`).
- The dashboard refresh path is polling-based today: a 5-second timer runs provider refresh work off-main, then `WidgetModel` renders rows using `AgentKind.displayName` and existing source summaries (`FloatyApp/FloatyApp/DashboardViewController.swift:847-916`, `FloatyApp/FloatyApp/DashboardViewController.swift:919-1000`).
- Hermes public docs identify `~/.hermes/state.db` as the current SQLite/WAL session store and document `hermes sessions export` JSONL output. Do not watch legacy `~/.hermes/sessions/*.jsonl` as current storage.
- Local agent state is private project data; `.hermes/` is already ignored with the other agent/session stores (`.gitignore:64-69`).

## Approach
Choose the **current-app visible path** for v1: add Hermes to the Swift provider that already powers the dashboard. Do not wire Rust FFI as part of this change; that is a separate architecture migration.

Use `~/.hermes/state.db` as the only runtime source. Treat JSONL export output as a redacted fixture/schema-discovery aid, not a runtime fallback and not a watched source. This keeps v1 local, read-only, and dependency-light: no CLI invocation, no generated exports, and no ambiguity with legacy `~/.hermes/sessions` files.

Keep refresh behavior polling-only. Hermes sessions should enter the same snapshot model as Codex/Claude; the existing grouping, sorting, source summary, warnings, and drawing paths should work once `.hermes` maps to `"Hermes"`.

## Work Items
1. **Capture the minimum Hermes schema contract.** From a local or redacted Hermes install, record the schema/version and the exact fields needed for session id, title/summary, updated timestamp, project root/cwd evidence, and status hints. Commit only synthetic fixtures or redacted schema notes.
2. **Add a Swift Hermes source seam.** Extend `AgentKind` with `.hermes`, add `hermesStateDBURL = ~/.hermes/state.db`, and include the Hermes state path in watched roots once present (`FloatyApp/FloatyApp/DashboardViewController.swift:59-69`, `FloatyApp/FloatyApp/DashboardViewController.swift:83-130`).
3. **Read SQLite safely and briefly.** Add an isolated read-only Hermes loader around SQLite/WAL access. It should use short-lived reads, a bounded row limit matching the existing recent-session behavior, and warnings for missing DB, lock/busy, schema mismatch, or unreadable rows.
4. **Map Hermes rows into existing sessions.** Produce `AgentSessionSummary(kind: .hermes, ...)` with title, instance id, project path/name, last-updated time, status, and root evidence. Reuse existing status thresholds and project grouping unless Hermes exposes stronger status data (`FloatyApp/FloatyApp/DashboardViewController.swift:255-362`, `FloatyApp/FloatyApp/DashboardViewController.swift:698-713`).
5. **Leave rendering generic.** Do not add Hermes-specific drawing. `WidgetModel(snapshot:)` and `sourceSummary(for:)` should surface Hermes automatically through the display name (`FloatyApp/FloatyApp/DashboardViewController.swift:919-1000`).
6. **Add fixture-backed coverage.** Add the smallest practical tests or test harness for: present DB with one recent Hermes session, missing DB, schema mismatch, unknown project root, and no regression to Codex/Claude scans. Keep real `.hermes` data out of the repo.
7. **Document the Rust follow-up.** Add a short note or follow-up issue that Rust parity should add Hermes discovery config and parser once the FFI migration resumes, using the same schema contract (`crates/floaty-core/src/lib.rs:102-110`, `crates/floaty-core/src/lib.rs:729-858`). Do not implement duplicate Rust support in this v1 unless the FFI migration is explicitly pulled into scope.

## Acceptance Checks
- Hermes sessions appear in the dashboard with source label `Hermes` when `~/.hermes/state.db` is present and readable.
- Missing, locked, or schema-mismatched Hermes state emits warnings but does not affect Codex/Claude rows.
- Refresh work stays off the main thread and does not hold long SQLite reads.
- No real Hermes database, export, transcript, or private path is committed.
- `./script/build_and_run.sh --verify` and any added fixture tests pass.

## Open Questions
- The exact Hermes schema/version is the only blocking unknown; validate it before parser implementation.
- If architectural cleanup becomes more important than fastest visible support, swap this plan for a Rust-FFI-first plan before implementation starts. Do not build both paths in parallel.

## References
- Initial Floaty plan: `docs/plans/floating-window-agent-dashboard-2026-06-26.md`
- Catalyst feasibility spike: `docs/spikes/catalyst-window-feasibility-2026-06-26.md`
- Hermes session storage docs: https://hermes-agent.nousresearch.com/docs/developer-guide/session-storage
- Hermes sessions user guide: https://hermes-agent.nousresearch.com/docs/user-guide/sessions
