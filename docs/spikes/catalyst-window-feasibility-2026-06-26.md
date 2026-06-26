# Catalyst Window Feasibility Spike

Checklist item: MVP Orchestration Checklist Item A from `docs/plans/floating-window-agent-dashboard-2026-06-26.md`.

## Scope

Implemented a minimal UIKit-only Mac Catalyst app in `FloatyApp/`.

Out of scope and intentionally untouched:

- Rust core and FFI
- agent adapters or transcript scanning
- Git/project discovery
- pets/assets scanning
- production dashboard UI

## Implemented seam

`FloatyApp/FloatyApp/CatalystWindowBridge.swift` defines a small command bridge:

- `setFloating(true, for:)` — represents the required floating command and gracefully reports that `NSWindow.Level.floating` is unavailable through supportable Mac Catalyst APIs
- `setFloating(false, for:)` — represents normal-level restore and reports the same supportability limit
- `minimizeToDock(for:)` — represents Dock minimization and gracefully reports that `NSWindow.miniaturize(_:)` is unavailable
- `activateAndRestore(for:)` — requests UIKit scene activation and makes the `UIWindow` key/visible, while documenting that AppKit deminiaturization remains unproven
- `describeResolvedWindow(for:)` — reports the UIKit window/scene is present but that no public backing `NSWindow` handle is exposed

The bridge intentionally does not compile against unavailable AppKit window symbols. It returns `.unsupportedPlatform` when not run as Mac Catalyst.

## Graceful failure behavior

Every command returns a `WindowBridgeResult` instead of force-unwrapping platform state. If no `UIWindow` is supplied, the result status is `.windowUnavailable`. If a `UIWindow` exists but the needed AppKit backing-window command is not supportably reachable, the result status is `.supportableAPIUnavailable` with a diagnostic message.

The app UI includes a **Probe Graceful Failure** button that intentionally calls the bridge with `nil` for the UIKit window to exercise this path.

## Supportability notes

This spike avoids private API: no private selectors, no KVC against hidden UIKit properties, no dynamic AppKit calls, and no method swizzling.

A direct public AppKit bridge was attempted first. The Mac Catalyst build rejected `NSWindow`, `NSApplication`, `NSWindow.Level.floating`, `NSWindow.miniaturize(_:)`, and related accessors as explicitly unavailable. That means the required floating and Dock-minimize behavior is not supportably reachable through direct public Mac Catalyst APIs in the tested SDK.

Recommendation: pause before investing in the full dashboard shell and revisit the host strategy, or keep any future private/unsupported experiment isolated from product code.

## Build/run

See `FloatyApp/README.md` for exact `xcodebuild` and Xcode run steps.
