import AppKit

protocol WindowBridge {
    func setFloating(_ floating: Bool, for window: NSWindow?) -> WindowBridgeResult
    func minimizeToDock(for window: NSWindow?) -> WindowBridgeResult
    func activateAndRestore(for window: NSWindow?) -> WindowBridgeResult
    func describeResolvedWindow(for window: NSWindow?) -> WindowBridgeResult
}

enum WindowBridgeCommand: String {
    case setFloating = "Set Floating"
    case setNormal = "Set Normal"
    case minimizeToDock = "Minimize"
    case activateAndRestore = "Restore"
    case inspect = "Inspect"
}

enum WindowBridgeStatus: String {
    case succeeded = "Ready"
    case windowUnavailable = "Window Missing"
    case unsupportedPlatform = "Unsupported"
}

struct WindowBridgeResult {
    let command: WindowBridgeCommand
    let status: WindowBridgeStatus
    let message: String

    var displayText: String {
        "\(command.rawValue): \(status.rawValue). \(message)"
    }
}

final class AppKitWindowBridge: WindowBridge {
    func setFloating(_ floating: Bool, for window: NSWindow?) -> WindowBridgeResult {
        guard let window else {
            return missingWindow(command: floating ? .setFloating : .setNormal)
        }

        window.level = floating ? .floating : .normal
        return WindowBridgeResult(
            command: floating ? .setFloating : .setNormal,
            status: .succeeded,
            message: floating ? "Panel is pinned above normal windows." : "Panel returned to normal window level."
        )
    }

    func minimizeToDock(for window: NSWindow?) -> WindowBridgeResult {
        guard let window else { return missingWindow(command: .minimizeToDock) }
        window.miniaturize(nil)
        return WindowBridgeResult(
            command: .minimizeToDock,
            status: .succeeded,
            message: "Panel miniaturized."
        )
    }

    func activateAndRestore(for window: NSWindow?) -> WindowBridgeResult {
        guard let window else { return missingWindow(command: .activateAndRestore) }
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        return WindowBridgeResult(
            command: .activateAndRestore,
            status: .succeeded,
            message: "Panel restored and ordered front."
        )
    }

    func describeResolvedWindow(for window: NSWindow?) -> WindowBridgeResult {
        guard let window else { return missingWindow(command: .inspect) }

        let levelName = window.level == .floating ? "floating" : "level \(window.level.rawValue)"
        let frame = window.frame.integral
        return WindowBridgeResult(
            command: .inspect,
            status: .succeeded,
            message: "\(Int(frame.width))x\(Int(frame.height)) \(levelName) panel at x \(Int(frame.minX)), y \(Int(frame.minY))."
        )
    }

    private func missingWindow(command: WindowBridgeCommand) -> WindowBridgeResult {
        WindowBridgeResult(
            command: command,
            status: .windowUnavailable,
            message: "No AppKit window is attached yet."
        )
    }
}
