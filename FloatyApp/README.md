# FloatyApp MVP Dashboard

This is a UIKit + Mac Catalyst shell for Floaty MVP Checklist Item D. It renders dashboard state from data shaped like the Rust `DashboardSnapshot` JSON model while keeping the Item A window-command diagnostics visible.

The app intentionally avoids SwiftUI, private AppKit/Catalyst APIs, and private local machine paths.

## What it shows

The dashboard renders snapshot-shaped data for:

- projects and root confidence
- agent session summaries and source paths
- minimal Git chips
- unassigned sessions
- optional pets
- core warnings
- window command diagnostics from `CatalystWindowBridge`

## Current provider

`DashboardViewController` uses `MockDashboardSnapshotProvider`, a local Swift provider that emits JSON with the same keys as `crates/floaty-core`:

- `generated_at`
- `projects`
- `unassigned_sessions`
- `pets`
- `warnings`

This keeps the Catalyst app buildable without adding Rust cross-compilation/linking steps in Item D. The mock data uses generic `/tmp` paths only.

## Refresh and jump actions

- **Refresh Snapshot** increments the provider version, decodes a fresh JSON snapshot, and updates visible generated time, status, Git dirty state, and warning copy.
- **Jump to Project** validates that the project root is an existing local directory and then asks UIKit to open the `file://` URL. Missing roots are reported non-fatally in the UI.
- Window command buttons remain available and continue to report `.supportableAPIUnavailable` for floating/minimize commands when public Catalyst APIs cannot reach `NSWindow`.

## Build

From the repository root:

```sh
xcodebuild \
  -project FloatyApp/FloatyApp.xcodeproj \
  -scheme FloatyApp \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/FloatyAppDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Run / inspect

Open `FloatyApp/FloatyApp.xcodeproj` in Xcode, choose **My Mac (Mac Catalyst)**, and run the `FloatyApp` scheme.

Suggested smoke check:

1. Confirm the dashboard shows Projects, Unassigned Sessions, Pets, Warnings, and Window Command Diagnostics.
2. Click **Refresh Snapshot** and confirm the version/generated timestamp and some visible state changes.
3. Click **Jump to Project** and confirm the UI reports the local open request.
4. Click the window diagnostic buttons and confirm unsupported window operations are visible instead of crashing.

## Rust FFI next step

The Rust crate already exposes a pull-style C ABI in `crates/floaty-core/include/floaty_core.h`:

- `floaty_core_new`
- `floaty_core_snapshot_version`
- `floaty_core_refresh`
- `floaty_core_snapshot_json`
- `floaty_core_buffer_free`
- `floaty_core_free`

The next integration step is to add a Catalyst-linkable build artifact for `floaty-core`, add the header/library to the Xcode target, and replace `MockDashboardSnapshotProvider` with an FFI-backed provider that decodes `floaty_core_snapshot_json` into the same Swift `DashboardSnapshot` models.

## MVP limits

- No Rust library is linked into the Catalyst app yet.
- The UIKit shell does not scan transcripts, Git repositories, pets, or project roots; those remain Rust responsibilities.
- Floating/minimize window behavior remains a documented Catalyst supportability limitation in this spike path.
