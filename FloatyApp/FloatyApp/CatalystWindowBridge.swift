import UIKit

protocol WindowBridge {
    func setFloating(_ floating: Bool, for uiWindow: UIWindow?) -> WindowBridgeResult
    func minimizeToDock(for uiWindow: UIWindow?) -> WindowBridgeResult
    func activateAndRestore(for uiWindow: UIWindow?) -> WindowBridgeResult
    func describeResolvedWindow(for uiWindow: UIWindow?) -> WindowBridgeResult
}

enum WindowBridgeCommand: String {
    case setFloating = "Set Floating"
    case setNormal = "Set Normal"
    case minimizeToDock = "Minimize to Dock"
    case activateAndRestore = "Activate / Restore"
    case inspect = "Inspect Window"
}

enum WindowBridgeStatus: String {
    case succeeded = "Succeeded"
    case windowUnavailable = "Window Unavailable"
    case supportableAPIUnavailable = "Supportable API Unavailable"
    case unsupportedPlatform = "Unsupported Platform"
}

struct WindowBridgeResult {
    let command: WindowBridgeCommand
    let status: WindowBridgeStatus
    let message: String

    var displayText: String {
        "\(command.rawValue): \(status.rawValue)\n\(message)"
    }
}

/// MVP Catalyst/AppKit seam spike.
///
/// This intentionally does not use private selectors, KVC, method swizzling, or
/// dynamic AppKit calls. A direct reference to `NSWindow`/`NSApplication` was
/// attempted during the spike and failed to compile for Mac Catalyst because
/// those APIs are explicitly marked unavailable by the SDK. The bridge therefore
/// represents the required commands and fails gracefully when the supportable
/// backing-window handle cannot be reached.
final class CatalystWindowBridge: WindowBridge {
    func setFloating(_ floating: Bool, for uiWindow: UIWindow?) -> WindowBridgeResult {
        guard uiWindow != nil else {
            return unavailableResult(
                command: floating ? .setFloating : .setNormal,
                attemptedAction: "change floating window level",
                reason: "No UIKit window was supplied."
            )
        }

        #if targetEnvironment(macCatalyst)
        return supportableAPIUnavailableResult(
            command: floating ? .setFloating : .setNormal,
            attemptedAction: "set NSWindow.Level.\(floating ? "floating" : "normal")"
        )
        #else
        return unsupportedPlatformResult(command: floating ? .setFloating : .setNormal)
        #endif
    }

    func minimizeToDock(for uiWindow: UIWindow?) -> WindowBridgeResult {
        guard uiWindow != nil else {
            return unavailableResult(
                command: .minimizeToDock,
                attemptedAction: "minimize to the Dock",
                reason: "No UIKit window was supplied."
            )
        }

        #if targetEnvironment(macCatalyst)
        return supportableAPIUnavailableResult(
            command: .minimizeToDock,
            attemptedAction: "call NSWindow.miniaturize(_:)"
        )
        #else
        return unsupportedPlatformResult(command: .minimizeToDock)
        #endif
    }

    func activateAndRestore(for uiWindow: UIWindow?) -> WindowBridgeResult {
        guard let uiWindow else {
            return unavailableResult(
                command: .activateAndRestore,
                attemptedAction: "activate and restore the window",
                reason: "No UIKit window was supplied."
            )
        }

        #if targetEnvironment(macCatalyst)
        uiWindow.makeKeyAndVisible()

        if let session = uiWindow.windowScene?.session {
            UIApplication.shared.requestSceneSessionActivation(
                session,
                userActivity: nil,
                options: nil,
                errorHandler: nil
            )
        }

        return WindowBridgeResult(
            command: .activateAndRestore,
            status: .succeeded,
            message: "Requested UIKit scene activation and made the UIWindow key/visible. Supportable AppKit deminiaturize/makeKeyAndOrderFront access is unavailable in Mac Catalyst, so Dock restore remains unproven."
        )
        #else
        return unsupportedPlatformResult(command: .activateAndRestore)
        #endif
    }

    func describeResolvedWindow(for uiWindow: UIWindow?) -> WindowBridgeResult {
        guard let uiWindow else {
            return unavailableResult(
                command: .inspect,
                attemptedAction: "inspect the backing AppKit window",
                reason: "No UIKit window was supplied."
            )
        }

        let sceneTitle = uiWindow.windowScene?.title ?? "<untitled>"

        #if targetEnvironment(macCatalyst)
        return WindowBridgeResult(
            command: .inspect,
            status: .supportableAPIUnavailable,
            message: "UIKit window is present for scene ‘\(sceneTitle)’, but no public/supportable Catalyst API exposes the backing NSWindow. Direct AppKit symbols such as NSWindow, NSApplication, NSWindow.Level.floating, and NSWindow.miniaturize(_:) are compile-time unavailable for Mac Catalyst in the tested SDK."
        )
        #else
        return unsupportedPlatformResult(command: .inspect)
        #endif
    }

    private func supportableAPIUnavailableResult(
        command: WindowBridgeCommand,
        attemptedAction: String
    ) -> WindowBridgeResult {
        WindowBridgeResult(
            command: command,
            status: .supportableAPIUnavailable,
            message: "Cannot supportably \(attemptedAction): the backing NSWindow is not reachable through public Mac Catalyst APIs in this SDK. This is a graceful failure; Floaty should not build production floating/minimize behavior on private API without revisiting the host strategy."
        )
    }

    private func unavailableResult(
        command: WindowBridgeCommand,
        attemptedAction: String,
        reason: String
    ) -> WindowBridgeResult {
        WindowBridgeResult(
            command: command,
            status: .windowUnavailable,
            message: "Could not \(attemptedAction). \(reason) The caller should keep the dashboard usable and expose this diagnostic instead of crashing."
        )
    }

    private func unsupportedPlatformResult(command: WindowBridgeCommand) -> WindowBridgeResult {
        WindowBridgeResult(
            command: command,
            status: .unsupportedPlatform,
            message: "This spike is intended for Mac Catalyst. Build and run the FloatyApp scheme with destination ‘My Mac (Mac Catalyst)’ to inspect the seam."
        )
    }
}
