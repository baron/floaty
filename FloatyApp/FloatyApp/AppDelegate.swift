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
        controller.restoreSavedFrameIfAvailable()
        controller.showWindow(nil)
        controller.restoreSavedFrameIfAvailable()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.restoreSavedFrameIfAvailable()
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

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveCurrentFrame(flush: true)
    }
}

final class FloatyWindowController: NSWindowController, NSWindowDelegate {
    private static let savedFrameKey = "FloatyFloatingWidgetFrame"

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
        panel.isRestorable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = DashboardViewController(windowBridge: AppKitWindowBridge())
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self
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

    func restoreSavedFrameIfAvailable() {
        guard let frame = Self.savedFrame else { return }
        window?.setFrame(frame, display: false)
    }

    func saveCurrentFrame(flush: Bool = false) {
        guard let frame = window?.frame else { return }
        Self.save(frame: frame, flush: flush)
    }

    func windowDidMove(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveCurrentFrame(flush: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard initialization is not used in Floaty.")
    }

    private static func defaultFrame() -> NSRect {
        if let savedFrame {
            return savedFrame
        }

        let size = NSSize(width: 336, height: 522)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visibleFrame.maxX - size.width - 84,
            y: visibleFrame.maxY - size.height - 64,
            width: size.width,
            height: size.height
        )
    }

    private static var savedFrame: NSRect? {
        guard let string = UserDefaults.standard.string(forKey: savedFrameKey) else {
            return nil
        }

        let frame = NSRectFromString(string)
        guard frame.width >= 220, frame.height >= 300 else {
            return nil
        }

        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard visibleFrames.contains(where: { $0.intersects(frame) }) else {
            return nil
        }
        return frame
    }

    private static func save(frame: NSRect, flush: Bool) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: savedFrameKey)
        if flush {
            UserDefaults.standard.synchronize()
        }
    }
}
