# Floating Window Agent Dashboard: Plan

## Goal
Build **Floaty**, a high-performance macOS floating-window dashboard for juggling local agent sessions across projects. The host app should use UIKit through Mac Catalyst, not SwiftUI; bridge to AppKit only for required window behavior; and put performance-sensitive local work in Rust.

Floaty should show recent activity for tools such as Codex, Claude Code, OpenCode, Hermes, and future agents; display minimal Git state per project; let users jump directly to a project; and optionally use local pets from `~/.codex/pets` as visual identity in the floating window.

## MVP Decisions
1. **Platform gate first:** prove Mac Catalyst can support the needed floating-window and Dock-minimize behavior through public or supportable APIs before investing in app structure.
2. **Distribution:** start as a personal/local developer tool outside the Mac App Store. Direct access to dot-directories and project roots is central; sandbox-compatible distribution is a later design.
3. **Session state:** v1 shows read-only recent-session summaries. “Live” means watcher-driven freshness from local transcript/export files, not invasive process inspection.
4. **FFI delivery:** use a pull model first. Rust maintains the latest immutable snapshot; UIKit requests snapshots on launch, foreground, visible refresh intervals, and user refresh. Add push/callback delivery only after the ownership/threading model is proven.
5. **Project jump:** v1 exposes a configurable jump command with `open "{project_root}"` as the default.
6. **Adapters:** implement a generic adapter contract. Codex and Claude Code are first; OpenCode follows after validating local-vs-export behavior; Hermes is deferred until its storage/export format is discovered.
7. **Pets:** support `~/.codex/pets` as optional, lazy-loaded visual assets when present. Pet data is not session state.

## Background
- The repository was blank before this plan: no source, docs, `AGENTS.md`, `docs/plans`, or git history.
- UIKit-on-macOS means Mac Catalyst. Floating level and Dock minimize are AppKit concepts, so the risky seam is Catalyst-to-`NSWindow` access.
- Apple documents `NSWindow.Level.floating` for floating-style windows and `NSWindow.miniaturize(_:)` for minimizing a window into the Dock.
- Codex documents local transcripts usable by `codex resume`, including files under `~/.codex/sessions/`. Claude Code and OpenCode can be supported through read-only filesystem/export adapters, but their schemas should be treated as less stable.
- Rust should own indexing, parsing, Git status, file watching, caching, and throttling so the UIKit process stays light and responsive.

## Approach

### 1. Prove the Catalyst/AppKit Window Seam
Start with a disposable Mac Catalyst spike that answers one question: can Floaty obtain and command the backing `NSWindow` using public/supportable APIs?

The spike must prove:
- apply/remove floating behavior;
- minimize to the Dock immediately;
- restore/activate the window;
- fail gracefully if an `NSWindow` cannot be reached.

If this fails, stop and revisit the host strategy before building the rest of the app. Do not rely on private API for the core product thesis.

### 2. Keep UIKit Thin
The Catalyst/UIKit shell owns only visible product state and user actions:
- dashboard rendering;
- selected/expanded project rows;
- chosen pet/avatar;
- refresh and jump actions;
- snapshot display on the main thread.

UIKit must not parse transcripts, scan Git repositories, walk filesystems, or contain source-specific agent logic.

### 3. Put Local Work in Rust
Rust owns the authoritative local dashboard model:
- discover session sources and configured project roots;
- derive project roots from adapter metadata, with explicit confidence/fallbacks;
- parse recent session metadata into normalized summaries;
- compute cheap Git summaries per verified project root;
- watch local inputs with `notify`/FSEvents where possible, with low-frequency polling fallback;
- debounce refreshes, cache parsed metadata, and publish immutable snapshots.

Use `git2` first for conservative Git support. Revisit `gix` only if packaging, footprint, or performance measurements justify it.

### 4. Make Project Identity Explicit
Project grouping depends on reliable root extraction, so treat it as a first-class discovery seam.

Adapter output should include:
- claimed root path, if present;
- source evidence, such as transcript metadata, encoded path, or configured root match;
- confidence: `verified`, `inferred`, or `unknown`.

Only `verified` and acceptable `inferred` roots become project cards. Unknown roots stay in an “Unassigned sessions” group until the user maps them.

### 5. Use a Small FFI Surface
MVP FFI should be pull-only and ownership-simple:
- initialize/shutdown core;
- request current snapshot as serialized bytes/string;
- request current snapshot version/hash;
- trigger refresh;
- update preferences such as watched roots and jump command templates;
- free returned buffers using a Rust-owned release function if the ABI requires it.

Serialized JSON snapshots are acceptable for the first implementation because they keep the boundary stable while adapters evolve. Move to generated typed bindings only after the snapshot model stops changing.

### 6. Treat Agent Sources as Read-only Adapters
Each adapter is isolated and non-fatal.

- **Codex:** scan `~/.codex/sessions/` for recent transcripts and derive project/session summaries where metadata permits.
- **Claude Code:** scan `~/.claude/projects/` JSONL-style logs and infer roots from metadata or encoded paths.
- **OpenCode:** validate whether local files or `opencode export` are the lowest-cost reliable source before implementing.
- **Hermes/future agents:** use the adapter interface only until local storage/export behavior is known.

Parsing failures, missing directories, partial files, and unknown schemas become warnings in the snapshot.

### 7. Keep Pets Optional and Lazy
Scan `~/.codex/pets` separately from session adapters. Expose available pet folders/manifests/thumbnails as visual choices, lazy-load images or animation frames, and ignore invalid assets with warnings. Pets should enrich the dashboard without affecting project/session logic.

## Snapshot Shape
Define the model lightly at first; adapters will refine the exact fields.

```text
DashboardSnapshot
- generated_at
- projects: [ProjectSummary]
- unassigned_sessions: [AgentSessionSummary]
- pets: [PetAssetSummary]
- warnings: [CoreWarning]

ProjectSummary
- root_path
- display_name
- root_confidence
- agents: [AgentSessionSummary]
- git: GitSummary?

AgentSessionSummary
- agent_kind
- source_path
- title?
- last_updated_at
- status_hint
- project_root_evidence?

GitSummary
- branch?
- dirty?
- ahead_count?
- behind_count?
- last_checked_at
- error?
```

Defer detailed pet, jump, and resume fields until the first adapters prove what data is actually available.

## Refresh Flow
1. Rust watches known source directories and verified project roots.
2. Filesystem events mark affected inputs dirty and are debounced.
3. Adapter refreshes update the Rust cache off the main thread.
4. Rust publishes a new immutable snapshot and version.
5. UIKit pulls the latest version/snapshot while the dashboard is visible or foregrounded, then applies changes on the main thread.
6. A low-frequency recovery refresh handles dropped/coalesced watcher events.

Do not watch `.git` directories until project roots are verified and Git summaries are implemented. Git refreshes should be debounced separately from agent-session refreshes.

## Work Items
1. **Window feasibility spike.** Disposable Catalyst target proving supported access to floating level, Dock minimize, activation, and failure behavior.
2. **Repo skeleton.** Add the Catalyst app target, Rust workspace/crate, bridge target, and shared docs for snapshot schemas after the window spike passes.
3. **Rust core seam.** Implement lifecycle, cache, snapshot versioning, pull-only FFI, and a mocked snapshot.
4. **Root discovery seam.** Implement configured roots plus Codex/Claude root extraction with evidence/confidence; add an unassigned-session path.
5. **First adapters.** Parse enough Codex and Claude Code metadata to group recent sessions without reading large histories on the hot path.
6. **Minimal Git summaries.** Add cheap branch/dirty/ahead/behind checks only for verified project roots, with independent debounce/backoff.
7. **Dashboard UI.** Render projects, unassigned sessions, agent badges, Git chips, warnings, refresh state, lazy pet identity, and jump actions from snapshots only.
8. **Jump command preferences.** Ship `open "{project_root}"` by default; add safe substitution and non-fatal error reporting.
9. **OpenCode and Hermes discovery.** Validate OpenCode’s best source, then implement it. Keep Hermes deferred until storage/export behavior is known.
10. **Package and measure.** Add launch/idle/update measurements, watcher stress checks, memory targets, and a direct-download signing/notarization investigation.

## Error Handling and Privacy
- Default to local-only operation with no network dependency.
- Treat transcript inputs as private and read-only.
- Missing directories, unreadable files, corrupt JSONL, unknown schemas, and Git errors should become warnings, not crashes.
- Do not block UI rendering on parsing or Git scans.
- Do not retain more transcript text than needed for a short preview.
- Pause visible UI polling when the dashboard is hidden or minimized.

## Open Discovery Items
- Public/supportable Catalyst route to the backing `NSWindow`.
- Reliability of project-root extraction in Codex and Claude Code transcripts.
- OpenCode’s lowest-cost reliable source: local files versus `opencode export`.
- Hermes local storage/export format.
- Final distribution path: unsigned personal build, signed/notarized direct download, or a sandbox-compatible redesign.
- When to replace JSON snapshots with typed generated bindings.

## References
- Apple Mac Catalyst: https://developer.apple.com/documentation/uikit/mac-catalyst
- Apple `NSWindow.Level.floating`: https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/floating
- Apple `NSWindow.miniaturize(_:)`: https://developer.apple.com/documentation/appkit/nswindow/miniaturize%28_%3A%29
- OpenAI Codex CLI resume/local transcript docs: https://developers.openai.com/codex/cli/features
- OpenCode CLI docs: https://opencode.ai/docs/cli/
- Rust `notify` crate: https://docs.rs/notify/latest/notify/
- Rust `git2` bindings: https://docs.rs/git2/latest/git2/
- Rust `gix` crate: https://crates.io/crates/gix
- Rust `swift-bridge` crate: https://crates.io/crates/swift-bridge
