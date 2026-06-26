import AppKit

struct DashboardSnapshot: Decodable {
    let generatedAt: String
    let projects: [ProjectSummary]
    let unassignedSessions: [AgentSessionSummary]
    let pets: [PetAssetSummary]
    let warnings: [CoreWarning]
}

struct ProjectSummary: Decodable {
    let rootPath: String
    let displayName: String
    let rootConfidence: RootConfidence
    let agents: [AgentSessionSummary]
    let git: GitSummary?
}

struct AgentSessionSummary: Decodable {
    let agentKind: AgentKind
    let sourcePath: String
    let title: String?
    let lastUpdatedAt: String
    let statusHint: StatusHint
    let projectRootEvidence: String?
}

struct GitSummary: Decodable {
    let branch: String?
    let dirty: Bool?
    let aheadCount: UInt?
    let behindCount: UInt?
    let lastCheckedAt: String
    let error: String?
}

struct PetAssetSummary: Decodable {
    let petId: String
    let displayName: String
    let sourcePath: String
}

struct CoreWarning: Decodable {
    let code: String
    let message: String
    let sourcePath: String?
}

enum RootConfidence: String, Decodable {
    case verified
    case inferred
    case unknown
}

enum StatusHint: String, Decodable {
    case active
    case idle
    case needsInput = "needs_input"
    case unknown

    var displayName: String {
        switch self {
        case .active: return "Running"
        case .idle: return "Idle"
        case .needsInput: return "Needs input"
        case .unknown: return "Checking"
        }
    }
}

enum AgentKind: Decodable, Equatable {
    case codex
    case claudeCode
    case openCode
    case hermes
    case other(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "codex": self = .codex
        case "claude_code": self = .claudeCode
        case "open_code": self = .openCode
        case "hermes": self = .hermes
        default: self = .other(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        case .openCode: return "OpenCode"
        case .hermes: return "Hermes"
        case .other(let value): return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

protocol DashboardSnapshotProviding {
    var providerName: String { get }
    var snapshotVersion: UInt64 { get }
    func currentSnapshot() throws -> DashboardSnapshot
    @discardableResult func refresh() throws -> UInt64
}

enum DashboardProviderError: Error, LocalizedError {
    case invalidMockJSON

    var errorDescription: String? {
        switch self {
        case .invalidMockJSON:
            return "The local Swift mock provider emitted JSON that does not match the dashboard snapshot shape."
        }
    }
}

final class MockDashboardSnapshotProvider: DashboardSnapshotProviding {
    private(set) var snapshotVersion: UInt64 = 1
    let providerName = "Local agent activity mock"

    func currentSnapshot() throws -> DashboardSnapshot {
        guard let data = mockSnapshotJSON(version: snapshotVersion).data(using: .utf8) else {
            throw DashboardProviderError.invalidMockJSON
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DashboardSnapshot.self, from: data)
    }

    @discardableResult
    func refresh() throws -> UInt64 {
        snapshotVersion = snapshotVersion == UInt64.max ? snapshotVersion : snapshotVersion + 1
        _ = try currentSnapshot()
        return snapshotVersion
    }

    private func mockSnapshotJSON(version: UInt64) -> String {
        let dirty = version % 2 == 0
        let second = String(format: "%02d", version % 60)
        let generatedAt = "2026-06-26T06:42:\(second)Z"
        let codexStatus = dirty ? "active" : "idle"

        return """
        {
          "generated_at": "\(generatedAt)",
          "projects": [
            {
              "root_path": "/Users/baron/projects/oss/floaty",
              "display_name": "Floaty",
              "root_confidence": "verified",
              "agents": [
                {
                  "agent_kind": "codex",
                  "source_path": "/Users/baron/.codex/sessions/floaty.jsonl",
                  "title": "Polish floating widget",
                  "last_updated_at": "\(generatedAt)",
                  "status_hint": "\(codexStatus)",
                  "project_root_evidence": "repo root"
                },
                {
                  "agent_kind": "claude_code",
                  "source_path": "/Users/baron/.claude/projects/floaty/session.jsonl",
                  "title": "Review native panel host",
                  "last_updated_at": "\(generatedAt)",
                  "status_hint": "active",
                  "project_root_evidence": "git root"
                },
                {
                  "agent_kind": "open_code",
                  "source_path": "/tmp/opencode/floaty.log",
                  "title": "Trace transcript scanner",
                  "last_updated_at": "\(generatedAt)",
                  "status_hint": "active",
                  "project_root_evidence": "cwd"
                }
              ],
              "git": {
                "branch": "feature/floating-widget",
                "dirty": \(dirty),
                "ahead_count": \(version % 4),
                "behind_count": 0,
                "last_checked_at": "\(generatedAt)",
                "error": null
              }
            },
            {
              "root_path": "/Users/baron/projects/work/revenue-engine",
              "display_name": "Revenue Engine",
              "root_confidence": "inferred",
              "agents": [
                {
                  "agent_kind": "hermes",
                  "source_path": "/tmp/hermes/revenue.log",
                  "title": "Patch billing smoke test",
                  "last_updated_at": "\(generatedAt)",
                  "status_hint": "needs_input",
                  "project_root_evidence": "prompt path"
                }
              ],
              "git": {
                "branch": "main",
                "dirty": false,
                "ahead_count": 0,
                "behind_count": 1,
                "last_checked_at": "\(generatedAt)",
                "error": null
              }
            }
          ],
          "unassigned_sessions": [
            {
              "agent_kind": "other_agent",
              "source_path": "/tmp/agent-runner/loose-session.jsonl",
              "title": "Need project match",
              "last_updated_at": "\(generatedAt)",
              "status_hint": "unknown",
              "project_root_evidence": null
            }
          ],
          "pets": [],
          "warnings": [
            {
              "code": "root_inferred",
              "message": "One agent session was matched from prompt context instead of a verified working directory.",
              "source_path": "/tmp/hermes/revenue.log"
            }
          ]
        }
        """
    }
}

struct ActivityRow {
    let agent: String
    let project: String
    let task: String
    var status: StatusHint
    var samples: [CGFloat]
    let iconName: String
}

struct WidgetModel {
    var activeCount: Int
    var taskCount: Int
    var doneCount: Int
    var costText: String
    var tokenText: String
    var bars: [CGFloat]
    var rows: [ActivityRow]
    var warningCount: Int
    var lastEvent: String
}

final class DashboardViewController: NSViewController {
    private let windowBridge: WindowBridge
    private let snapshotProvider: DashboardSnapshotProviding
    private let widgetView = DashboardWidgetView()
    private var animationTimer: Timer?
    private var isPaused = false

    init(
        windowBridge: WindowBridge,
        snapshotProvider: DashboardSnapshotProviding = MockDashboardSnapshotProvider()
    ) {
        self.windowBridge = windowBridge
        self.snapshotProvider = snapshotProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard initialization is not used in Floaty.")
    }

    override func loadView() {
        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: FloatyAppMetadata.widgetSize))
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        widgetView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(widgetView)
        NSLayoutConstraint.activate([
            widgetView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            widgetView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            widgetView.topAnchor.constraint(equalTo: effectView.topAnchor),
            widgetView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        widgetView.onRefresh = { [weak self] in self?.refreshSnapshot() }
        widgetView.onPauseToggle = { [weak self] in self?.togglePause() }
        widgetView.onRestore = { [weak self] in self?.restorePanel() }
        widgetView.onFloatToggle = { [weak self] in self?.toggleFloatingLevel() }
        loadSnapshot(reason: "Live")
        startAnimation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        widgetView.windowDiagnostic = windowBridge.describeResolvedWindow(for: view.window).displayText
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.widgetView.advancePulse()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func loadSnapshot(reason: String) {
        do {
            let snapshot = try snapshotProvider.currentSnapshot()
            widgetView.model = WidgetModel(snapshot: snapshot, version: snapshotProvider.snapshotVersion, reason: reason)
        } catch {
            widgetView.errorMessage = error.localizedDescription
        }
    }

    private func refreshSnapshot() {
        do {
            let version = try snapshotProvider.refresh()
            loadSnapshot(reason: "Refresh \(version)")
        } catch {
            widgetView.errorMessage = error.localizedDescription
        }
    }

    private func togglePause() {
        isPaused.toggle()
        widgetView.isPaused = isPaused
    }

    private func restorePanel() {
        widgetView.windowDiagnostic = windowBridge.activateAndRestore(for: view.window).displayText
    }

    private func toggleFloatingLevel() {
        guard let window = view.window else { return }
        let shouldFloat = window.level != .floating
        widgetView.windowDiagnostic = windowBridge.setFloating(shouldFloat, for: window).displayText
    }

    deinit {
        animationTimer?.invalidate()
    }
}

private extension WidgetModel {
    init(snapshot: DashboardSnapshot, version: UInt64, reason: String) {
        var rows: [ActivityRow] = []
        for project in snapshot.projects {
            for session in project.agents {
                rows.append(ActivityRow(
                    agent: session.agentKind.displayName,
                    project: project.displayName,
                    task: session.title ?? "Untitled task",
                    status: session.statusHint,
                    samples: WidgetModel.samples(seed: rows.count + Int(version)),
                    iconName: WidgetModel.iconName(for: session.agentKind)
                ))
            }
        }

        for session in snapshot.unassignedSessions {
            rows.append(ActivityRow(
                agent: session.agentKind.displayName,
                project: "Unassigned",
                task: session.title ?? "Needs project match",
                status: session.statusHint,
                samples: WidgetModel.samples(seed: rows.count + Int(version)),
                iconName: "questionmark.circle"
            ))
        }

        let activeCount = rows.filter { $0.status == .active }.count
        let needsInputCount = rows.filter { $0.status == .needsInput }.count
        let taskCount = max(1, rows.count * 3 + activeCount + needsInputCount)
        let doneCount = 29 + Int(version % 7)
        let cost = 0.08 + Double(version % 9) * 0.013
        let tokens = 1.0 + Double(taskCount) * 0.08

        self.init(
            activeCount: activeCount,
            taskCount: taskCount,
            doneCount: doneCount,
            costText: String(format: "$%.2f", cost),
            tokenText: String(format: "%.1fM tokens", tokens),
            bars: WidgetModel.barSamples(seed: Int(version)),
            rows: Array(rows.prefix(5)),
            warningCount: snapshot.warnings.count,
            lastEvent: "\(reason) - \(activeCount) active across \(snapshot.projects.count) roots"
        )
    }

    static func iconName(for agent: AgentKind) -> String {
        switch agent {
        case .codex: return "terminal"
        case .claudeCode: return "sparkles"
        case .openCode: return "doc.text"
        case .hermes: return "shield"
        case .other: return "bubble.left.and.bubble.right"
        }
    }

    static func samples(seed: Int) -> [CGFloat] {
        (0..<34).map { index in
            let wave = sin(Double(index + seed) * 0.72) * 0.22
            let small = sin(Double(index * 3 + seed) * 0.31) * 0.12
            return CGFloat(min(0.96, max(0.08, 0.44 + wave + small)))
        }
    }

    static func barSamples(seed: Int) -> [CGFloat] {
        (0..<11).map { index in
            CGFloat(min(1.0, max(0.14, 0.35 + sin(Double(index + seed) * 0.85) * 0.34)))
        }
    }
}

final class DashboardWidgetView: NSView {
    var model: WidgetModel? {
        didSet { needsDisplay = true }
    }

    var isPaused = false {
        didSet { needsDisplay = true }
    }

    var errorMessage: String? {
        didSet { needsDisplay = true }
    }

    var windowDiagnostic: String? {
        didSet { needsDisplay = true }
    }

    var onRefresh: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onRestore: (() -> Void)?
    var onFloatToggle: (() -> Void)?

    private var refreshRect = NSRect.zero
    private var pauseRect = NSRect.zero
    private var restoreRect = NSRect.zero
    private var floatRect = NSRect.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard initialization is not used in Floaty.")
    }

    func advancePulse() {
        guard var model else { return }
        model.bars.removeFirst()
        model.bars.append(CGFloat.random(in: 0.18...0.94))
        for index in model.rows.indices {
            model.rows[index].samples.removeFirst()
            let base = model.rows[index].status == .active ? CGFloat.random(in: 0.36...0.92) : CGFloat.random(in: 0.08...0.48)
            model.rows[index].samples.append(base)
        }
        self.model = model
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch point {
        case _ where refreshRect.contains(point):
            onRefresh?()
        case _ where pauseRect.contains(point):
            onPauseToggle?()
        case _ where restoreRect.contains(point):
            onRestore?()
        case _ where floatRect.contains(point):
            onFloatToggle?()
        default:
            window?.performDrag(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        drawChrome(in: bounds, context: context)

        if let errorMessage {
            drawText("Floaty", rect: NSRect(x: 24, y: 28, width: 160, height: 24), font: .systemFont(ofSize: 18, weight: .semibold), color: Palette.primaryText)
            drawText(errorMessage, rect: NSRect(x: 24, y: 70, width: bounds.width - 48, height: 80), font: .systemFont(ofSize: 13), color: Palette.warning)
            return
        }

        guard let model else { return }
        drawHeader(model, context: context)
        drawWorkload(model, context: context)
        drawRows(model, context: context)
        drawComposer(context: context)
        drawControls(context: context)
        drawFooter(model, context: context)
    }

    private func drawChrome(in rect: NSRect, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.addPath(path)
        context.setFillColor(Palette.panelFill.cgColor)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(Palette.hairline.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private func drawHeader(_ model: WidgetModel, context: CGContext) {
        drawSymbol("waveform.path.ecg", rect: NSRect(x: 22, y: 20, width: 24, height: 24), color: Palette.secondaryText)
        drawText("Floaty", rect: NSRect(x: 55, y: 20, width: 110, height: 24), font: .systemFont(ofSize: 17, weight: .semibold), color: Palette.primaryText)

        let dotRect = NSRect(x: bounds.width - 141, y: 28, width: 8, height: 8)
        Palette.green.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        drawText("\(model.activeCount) active", rect: NSRect(x: bounds.width - 126, y: 21, width: 66, height: 20), font: .systemFont(ofSize: 13, weight: .medium), color: Palette.secondaryText)

        floatRect = NSRect(x: bounds.width - 41, y: 17, width: 24, height: 28)
        drawSymbol("arrow.up.left.and.arrow.down.right", rect: floatRect.insetBy(dx: 3, dy: 4), color: Palette.secondaryText)

        drawRule(y: 57)
    }

    private func drawWorkload(_ model: WidgetModel, context: CGContext) {
        let x: CGFloat = 24
        let baseY: CGFloat = 90
        let barWidth: CGFloat = 4
        let gap: CGFloat = 6
        for (index, value) in model.bars.enumerated() {
            let height = 10 + value * 27
            let rect = NSRect(x: x + CGFloat(index) * (barWidth + gap), y: baseY - height, width: barWidth, height: height)
            let color = index < model.activeCount + 3 ? Palette.green : Palette.mutedStroke
            drawRounded(rect, radius: 2, color: color.withAlphaComponent(index < 3 ? 0.95 : 0.48))
        }
        drawText("\(model.taskCount) tasks running", rect: NSRect(x: 142, y: 73, width: 154, height: 22), font: .systemFont(ofSize: 13, weight: .medium), color: Palette.secondaryText)
        drawRule(y: 111)
    }

    private func drawRows(_ model: WidgetModel, context: CGContext) {
        var y: CGFloat = 116
        for row in model.rows {
            drawActivityRow(row, y: y, context: context)
            y += 56
        }
    }

    private func drawActivityRow(_ row: ActivityRow, y: CGFloat, context: CGContext) {
        drawSymbol(row.iconName, rect: NSRect(x: 22, y: y + 12, width: 25, height: 25), color: Palette.icon)
        drawText(row.agent, rect: NSRect(x: 61, y: y + 8, width: 92, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: Palette.primaryText)
        drawText(row.status.displayName, rect: NSRect(x: 61, y: y + 28, width: 105, height: 16), font: .systemFont(ofSize: 12), color: Palette.secondaryText)
        drawText(row.project, rect: NSRect(x: 156, y: y + 9, width: 83, height: 15), font: .systemFont(ofSize: 10, weight: .medium), color: Palette.tertiaryText)

        let statusColor: NSColor = row.status == .needsInput ? Palette.orange : (row.status == .active ? Palette.green : Palette.mutedStroke)
        statusColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - 35, y: y + 15, width: 9, height: 9)).fill()

        drawSparkline(samples: row.samples, rect: NSRect(x: 198, y: y + 29, width: 112, height: 19), color: statusColor, context: context)
        drawRule(y: y + 55)
    }

    private func drawComposer(context: CGContext) {
        let rect = NSRect(x: 18, y: bounds.height - 113, width: bounds.width - 36, height: 42)
        drawRounded(rect, radius: 11, color: Palette.inputFill)
        strokeRounded(rect, radius: 11, color: Palette.hairline, width: 1)
        drawText("Ask your agents...", rect: NSRect(x: rect.minX + 13, y: rect.minY + 12, width: rect.width - 54, height: 18), font: .systemFont(ofSize: 13), color: Palette.tertiaryText)
        drawSymbol("paperplane", rect: NSRect(x: rect.maxX - 34, y: rect.minY + 11, width: 19, height: 19), color: Palette.secondaryText)
    }

    private func drawControls(context: CGContext) {
        pauseRect = NSRect(x: 18, y: bounds.height - 61, width: 42, height: 34)
        restoreRect = NSRect(x: 72, y: bounds.height - 61, width: 42, height: 34)
        refreshRect = NSRect(x: 126, y: bounds.height - 61, width: 42, height: 34)

        drawButton(rect: pauseRect, symbol: isPaused ? "play.fill" : "pause.fill")
        drawButton(rect: restoreRect, symbol: "arrow.up.forward.app")
        drawButton(rect: refreshRect, symbol: "arrow.clockwise")
        drawRule(y: bounds.height - 14)
    }

    private func drawFooter(_ model: WidgetModel, context: CGContext) {
        let y = bounds.height - 28
        drawText("\(model.doneCount) done", rect: NSRect(x: 22, y: y, width: 62, height: 17), font: .systemFont(ofSize: 12, weight: .medium), color: Palette.secondaryText)
        drawText(" - \(model.costText) - \(model.tokenText)", rect: NSRect(x: 88, y: y, width: 160, height: 17), font: .systemFont(ofSize: 12, weight: .medium), color: Palette.secondaryText)
        if model.warningCount > 0 {
            drawText("\(model.warningCount) note", rect: NSRect(x: bounds.width - 72, y: y, width: 50, height: 17), font: .systemFont(ofSize: 12, weight: .medium), color: Palette.orange)
        }
    }

    private func drawButton(rect: NSRect, symbol: String) {
        drawRounded(rect, radius: 9, color: Palette.buttonFill)
        strokeRounded(rect, radius: 9, color: Palette.hairline, width: 1)
        drawSymbol(symbol, rect: rect.insetBy(dx: 12, dy: 9), color: Palette.secondaryText)
    }

    private func drawSparkline(samples: [CGFloat], rect: NSRect, color: NSColor, context: CGContext) {
        guard samples.count > 1 else { return }
        context.saveGState()
        context.setStrokeColor(color.withAlphaComponent(0.78).cgColor)
        context.setLineWidth(1.35)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let step = rect.width / CGFloat(samples.count - 1)
        for (index, sample) in samples.enumerated() {
            let x = rect.minX + CGFloat(index) * step
            let y = rect.maxY - sample * rect.height
            if index == 0 {
                context.move(to: CGPoint(x: x, y: y))
            } else {
                context.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawRule(y: CGFloat) {
        Palette.hairline.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: 18, y: y))
        path.line(to: NSPoint(x: bounds.width - 18, y: y))
        path.stroke()
    }

    private func drawRounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func strokeRounded(_ rect: NSRect, radius: CGFloat, color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.stroke()
    }

    private func drawSymbol(_ name: String, rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            color.setStroke()
            NSBezierPath(ovalIn: rect).stroke()
            return
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: min(rect.width, rect.height), weight: .regular)
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.isTemplate = true
        color.set()
        configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

private enum Palette {
    static let panelFill = NSColor(calibratedWhite: 0.88, alpha: 0.76)
    static let inputFill = NSColor(calibratedWhite: 0.99, alpha: 0.58)
    static let buttonFill = NSColor(calibratedWhite: 0.98, alpha: 0.52)
    static let hairline = NSColor(calibratedWhite: 0.36, alpha: 0.20)
    static let primaryText = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.17, alpha: 1.0)
    static let secondaryText = NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.36, alpha: 0.92)
    static let tertiaryText = NSColor(calibratedRed: 0.32, green: 0.37, blue: 0.46, alpha: 0.74)
    static let mutedStroke = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.69, alpha: 0.62)
    static let green = NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.41, alpha: 1)
    static let orange = NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.12, alpha: 1)
    static let warning = NSColor(calibratedRed: 0.84, green: 0.36, blue: 0.18, alpha: 1)
    static let icon = NSColor(calibratedRed: 0.30, green: 0.33, blue: 0.41, alpha: 0.92)
}
