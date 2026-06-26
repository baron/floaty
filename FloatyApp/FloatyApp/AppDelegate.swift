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
    private static let savedScreenIDKey = "FloatyFloatingWidgetScreenID"
    private static let savedOffsetXKey = "FloatyFloatingWidgetOffsetX"
    private static let savedOffsetFromTopKey = "FloatyFloatingWidgetOffsetFromTop"
    private static let savedWidthKey = "FloatyFloatingWidgetWidth"
    private static let savedHeightKey = "FloatyFloatingWidgetHeight"

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
        if let placementFrame = savedScreenRelativeFrame {
            return placementFrame
        }

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
        let defaults = UserDefaults.standard
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: savedFrameKey)
        if let screen = bestScreen(for: frame) {
            let visibleFrame = screen.visibleFrame
            defaults.set(screenID(for: screen), forKey: savedScreenIDKey)
            defaults.set(frame.minX - visibleFrame.minX, forKey: savedOffsetXKey)
            defaults.set(visibleFrame.maxY - frame.maxY, forKey: savedOffsetFromTopKey)
            defaults.set(frame.width, forKey: savedWidthKey)
            defaults.set(frame.height, forKey: savedHeightKey)
        }
        if flush {
            UserDefaults.standard.synchronize()
        }
    }

    private static var savedScreenRelativeFrame: NSRect? {
        let defaults = UserDefaults.standard
        let screenID = defaults.integer(forKey: savedScreenIDKey)
        guard
            screenID != 0,
            let screen = NSScreen.screens.first(where: { self.screenID(for: $0) == screenID })
        else {
            return nil
        }

        let width = defaults.double(forKey: savedWidthKey)
        let height = defaults.double(forKey: savedHeightKey)
        guard width >= 220, height >= 300 else {
            return nil
        }

        let visibleFrame = screen.visibleFrame
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - height)
        let offsetX = defaults.double(forKey: savedOffsetXKey)
        let offsetFromTop = defaults.double(forKey: savedOffsetFromTopKey)
        let x = min(max(visibleFrame.minX + offsetX, visibleFrame.minX), maxX)
        let y = min(max(visibleFrame.maxY - offsetFromTop - height, visibleFrame.minY), maxY)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func bestScreen(for frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containingScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return containingScreen
        }

        return NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.visibleFrame, frame) < intersectionArea(rhs.visibleFrame, frame)
        }
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func screenID(for screen: NSScreen) -> Int {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int ?? 0
    }
}
