import AppKit

@main
enum FloatyMain {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: FloatyWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let controller = FloatyWindowController()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.toggleVisibility()
        return false
    }
}

final class FloatyWindowController: NSWindowController {
    init() {
        let panel = NSPanel(
            contentRect: FloatyWindowController.defaultFrame(),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "Floaty"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = DashboardViewController(windowBridge: AppKitWindowBridge())
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: panel)
    }

    func toggleVisibility() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
            return
        }

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard initialization is not used in Floaty.")
    }

    private static func defaultFrame() -> NSRect {
        let size = NSSize(width: 336, height: 522)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visibleFrame.maxX - size.width - 84,
            y: visibleFrame.maxY - size.height - 64,
            width: size.width,
            height: size.height
        )
    }
}
