import AppKit
import OSLog

private let windowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.floaty.widget",
    category: "WindowPlacement"
)

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
        windowLogger.debug("applicationDidFinishLaunching")
        FloatyWindowController.logScreens(reason: "launch")
        FloatyWindowController.logSavedPlacement(reason: "launch")
        NSApp.setActivationPolicy(.regular)

        let controller = FloatyWindowController()
        windowController = controller
        controller.logCurrentFrame(reason: "after init")
        controller.restoreSavedFrameIfAvailable(suppressSave: true)
        controller.logCurrentFrame(reason: "after restore before show")
        controller.showWindowSuppressingPlacementSave()
        controller.logCurrentFrame(reason: "after showWindow")
        controller.restoreSavedFrameIfAvailable(suppressSave: true)
        controller.logCurrentFrame(reason: "after restore after show")
        controller.window?.makeKeyAndOrderFront(nil)
        controller.logCurrentFrame(reason: "after makeKeyAndOrderFront")
        controller.restoreSavedFrameIfAvailable(suppressSave: true)
        controller.logCurrentFrame(reason: "after final restore")
        controller.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        controller.logCurrentFrame(reason: "after activate")
        controller.saveCurrentFrame(flush: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowLogger.debug("applicationShouldHandleReopen hasVisibleWindows=\(flag, privacy: .public)")
        windowController?.toggleVisibility()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowLogger.debug("applicationWillTerminate")
        windowController?.saveCurrentFrame(flush: true)
    }
}

final class FloatyWindowController: NSWindowController, NSWindowDelegate {
    private static let minimumVisibleWidth: CGFloat = 96
    private static let minimumVisibleHeight: CGFloat = 96
    private static let savedFrameKey = "FloatyFloatingWidgetFrame"
    private static let savedScreenIDKey = "FloatyFloatingWidgetScreenID"
    private static let savedOffsetXKey = "FloatyFloatingWidgetOffsetX"
    private static let savedOffsetFromTopKey = "FloatyFloatingWidgetOffsetFromTop"
    private static let savedWidthKey = "FloatyFloatingWidgetWidth"
    private static let savedHeightKey = "FloatyFloatingWidgetHeight"
    private var suppressPlacementSave = false

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
        logCurrentFrame(reason: "toggleVisibility start visible=\(window.isVisible)")
        if window.isVisible {
            window.orderOut(nil)
            logCurrentFrame(reason: "toggleVisibility after orderOut")
            return
        }

        withPlacementSaveSuppressed {
            showWindow(nil)
        }
        logCurrentFrame(reason: "toggleVisibility after showWindow")
        window.makeKeyAndOrderFront(nil)
        logCurrentFrame(reason: "toggleVisibility after makeKeyAndOrderFront")
        restoreSavedFrameIfAvailable(suppressSave: true)
        logCurrentFrame(reason: "toggleVisibility after restore")
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        logCurrentFrame(reason: "toggleVisibility after activate")
        saveCurrentFrame(flush: true)
    }

    func restoreSavedFrameIfAvailable(suppressSave: Bool = false) {
        guard let frame = Self.savedFrame else {
            windowLogger.debug("restore skipped: no valid saved frame")
            return
        }
        windowLogger.debug("restore applying frame=\(Self.describe(frame), privacy: .public)")
        if suppressSave {
            withPlacementSaveSuppressed {
                window?.setFrame(frame, display: false)
            }
        } else {
            window?.setFrame(frame, display: false)
        }
    }

    func showWindowSuppressingPlacementSave() {
        withPlacementSaveSuppressed {
            showWindow(nil)
        }
    }

    func saveCurrentFrame(flush: Bool = false) {
        guard let frame = window?.frame else { return }
        Self.save(frame: frame, flush: flush)
    }

    func windowDidMove(_ notification: Notification) {
        logCurrentFrame(reason: "windowDidMove")
        guard !suppressPlacementSave else {
            windowLogger.debug("windowDidMove save skipped because placement save is suppressed")
            return
        }
        saveCurrentFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        logCurrentFrame(reason: "windowDidEndLiveResize")
        saveCurrentFrame()
    }

    func windowWillClose(_ notification: Notification) {
        logCurrentFrame(reason: "windowWillClose")
        saveCurrentFrame(flush: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard initialization is not used in Floaty.")
    }

    private static func defaultFrame() -> NSRect {
        if let savedFrame {
            windowLogger.debug("defaultFrame using saved frame=\(describe(savedFrame), privacy: .public)")
            return savedFrame
        }

        let size = NSSize(width: 336, height: 522)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visibleFrame.maxX - size.width - 84,
            y: visibleFrame.maxY - size.height - 64,
            width: size.width,
            height: size.height
        )
        windowLogger.debug("defaultFrame using fallback frame=\(describe(frame), privacy: .public) mainVisible=\(describe(visibleFrame), privacy: .public)")
        return frame
    }

    private static var savedFrame: NSRect? {
        if let placementFrame = savedScreenRelativeFrame {
            windowLogger.debug("savedFrame resolved from screen-relative placement frame=\(describe(placementFrame), privacy: .public)")
            return placementFrame
        }

        guard let string = UserDefaults.standard.string(forKey: savedFrameKey) else {
            windowLogger.debug("savedFrame missing legacy raw frame")
            return nil
        }

        let frame = NSRectFromString(string)
        guard frame.width >= 220, frame.height >= 300 else {
            windowLogger.debug("savedFrame rejected legacy raw frame too small frame=\(describe(frame), privacy: .public)")
            return nil
        }

        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard visibleFrames.contains(where: { $0.intersects(frame) }) else {
            windowLogger.debug("savedFrame rejected legacy raw frame offscreen frame=\(describe(frame), privacy: .public)")
            return nil
        }
        windowLogger.debug("savedFrame resolved from legacy raw frame=\(describe(frame), privacy: .public)")
        return frame
    }

    private static func save(frame: NSRect, flush: Bool) {
        let defaults = UserDefaults.standard
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: savedFrameKey)
        if let screen = bestScreen(for: frame) {
            let visibleFrame = screen.visibleFrame
            let screenID = screenID(for: screen)
            let offsetX = frame.minX - visibleFrame.minX
            let offsetFromTop = visibleFrame.maxY - frame.maxY
            defaults.set(screenID, forKey: savedScreenIDKey)
            defaults.set(offsetX, forKey: savedOffsetXKey)
            defaults.set(offsetFromTop, forKey: savedOffsetFromTopKey)
            defaults.set(frame.width, forKey: savedWidthKey)
            defaults.set(frame.height, forKey: savedHeightKey)
            windowLogger.debug("save frame=\(describe(frame), privacy: .public) screenID=\(screenID, privacy: .public) screenVisible=\(describe(visibleFrame), privacy: .public) offsetX=\(offsetX, privacy: .public) offsetTop=\(offsetFromTop, privacy: .public) flush=\(flush, privacy: .public)")
        } else {
            windowLogger.debug("save frame=\(describe(frame), privacy: .public) had no matching screen flush=\(flush, privacy: .public)")
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
            windowLogger.debug("screen-relative restore unavailable screenID=\(screenID, privacy: .public)")
            return nil
        }

        let width = defaults.double(forKey: savedWidthKey)
        let height = defaults.double(forKey: savedHeightKey)
        guard width >= 220, height >= 300 else {
            windowLogger.debug("screen-relative restore rejected size width=\(width, privacy: .public) height=\(height, privacy: .public)")
            return nil
        }

        let visibleFrame = screen.visibleFrame
        let minimumVisibleWidth = min(Self.minimumVisibleWidth, width)
        let minimumVisibleHeight = min(Self.minimumVisibleHeight, height)
        let minX = visibleFrame.minX - width + minimumVisibleWidth
        let maxX = visibleFrame.maxX - minimumVisibleWidth
        let minY = visibleFrame.minY - height + minimumVisibleHeight
        let maxY = visibleFrame.maxY - minimumVisibleHeight
        let offsetX = defaults.double(forKey: savedOffsetXKey)
        let offsetFromTop = defaults.double(forKey: savedOffsetFromTopKey)
        let unclampedX = visibleFrame.minX + offsetX
        let unclampedY = visibleFrame.maxY - offsetFromTop - height
        let x = min(max(unclampedX, minX), maxX)
        let y = min(max(unclampedY, minY), maxY)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        windowLogger.debug("screen-relative restore screenID=\(screenID, privacy: .public) visible=\(describe(visibleFrame), privacy: .public) offsetX=\(offsetX, privacy: .public) offsetTop=\(offsetFromTop, privacy: .public) unclamped=\(describe(NSRect(x: unclampedX, y: unclampedY, width: width, height: height)), privacy: .public) frame=\(describe(frame), privacy: .public)")
        return frame
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

    func logCurrentFrame(reason: String) {
        guard let window else {
            windowLogger.debug("\(reason, privacy: .public): no window")
            return
        }
        windowLogger.debug("\(reason, privacy: .public): frame=\(Self.describe(window.frame), privacy: .public) visible=\(window.isVisible, privacy: .public) miniaturized=\(window.isMiniaturized, privacy: .public)")
    }

    static func logScreens(reason: String) {
        for (index, screen) in NSScreen.screens.enumerated() {
            windowLogger.debug("\(reason, privacy: .public): screen index=\(index, privacy: .public) id=\(screenID(for: screen), privacy: .public) frame=\(describe(screen.frame), privacy: .public) visible=\(describe(screen.visibleFrame), privacy: .public)")
        }
    }

    static func logSavedPlacement(reason: String) {
        let defaults = UserDefaults.standard
        let rawFrame = defaults.string(forKey: savedFrameKey) ?? "nil"
        let screenID = defaults.integer(forKey: savedScreenIDKey)
        let offsetX = defaults.object(forKey: savedOffsetXKey) as? Double
        let offsetFromTop = defaults.object(forKey: savedOffsetFromTopKey) as? Double
        let width = defaults.object(forKey: savedWidthKey) as? Double
        let height = defaults.object(forKey: savedHeightKey) as? Double
        windowLogger.debug("\(reason, privacy: .public): defaults rawFrame=\(rawFrame, privacy: .public) screenID=\(screenID, privacy: .public) offsetX=\(String(describing: offsetX), privacy: .public) offsetTop=\(String(describing: offsetFromTop), privacy: .public) width=\(String(describing: width), privacy: .public) height=\(String(describing: height), privacy: .public)")
    }

    private static func describe(_ rect: NSRect) -> String {
        "x=\(Int(rect.origin.x.rounded())) y=\(Int(rect.origin.y.rounded())) w=\(Int(rect.size.width.rounded())) h=\(Int(rect.size.height.rounded()))"
    }

    private func withPlacementSaveSuppressed(_ body: () -> Void) {
        let wasSuppressing = suppressPlacementSave
        suppressPlacementSave = true
        defer { suppressPlacementSave = wasSuppressing }
        body()
    }
}
