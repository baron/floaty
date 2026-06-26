import AppKit

struct DashboardSnapshot {
    let generatedAt: Date
    let sessions: [AgentSessionSummary]
    let watchedRoots: [String]
    let scannedFileCount: Int
    let recentFileCount: Int
    let warnings: [CoreWarning]
}

struct AgentSessionSummary {
    let agentKind: AgentKind
    let sourcePath: String
    let title: String
    let instanceID: String?
    let projectPath: String?
    let projectName: String
    let lastUpdatedAt: Date
    let statusHint: StatusHint
    let projectRootEvidence: String?
}

struct CoreWarning {
    let code: String
    let message: String
    let sourcePath: String?
}

enum StatusHint: String {
    case active
    case idle
    case stale
    case unknown

    var displayName: String {
        switch self {
        case .active: return "active"
        case .idle: return "idle"
        case .stale: return "stale"
        case .unknown: return "unknown"
        }
    }
}

enum AgentKind: Equatable {
    case codex
    case claudeCode

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        }
    }
}

protocol DashboardSnapshotProviding {
    var providerName: String { get }
    var snapshotVersion: UInt64 { get }
    func currentSnapshot() throws -> DashboardSnapshot
    @discardableResult func refresh() throws -> UInt64
}

final class LocalSessionSnapshotProvider: DashboardSnapshotProviding {
    private(set) var snapshotVersion: UInt64 = 0
    let providerName = "Local session files"

    private let fileManager: FileManager
    private let codexRoot: URL
    private let claudeRoot: URL
    private let codexProcessStateURL: URL
    private var cachedSnapshot: DashboardSnapshot?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.codexRoot = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.claudeRoot = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexProcessStateURL = homeDirectory.appendingPathComponent(".codex/process_manager/chat_processes.json")
    }

    func currentSnapshot() throws -> DashboardSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }
        _ = try refresh()
        return cachedSnapshot ?? DashboardSnapshot(
            generatedAt: Date(),
            sessions: [],
            watchedRoots: watchedRoots,
            scannedFileCount: 0,
            recentFileCount: 0,
            warnings: []
        )
    }

    @discardableResult
    func refresh() throws -> UInt64 {
        snapshotVersion = snapshotVersion == UInt64.max ? snapshotVersion : snapshotVersion + 1
        cachedSnapshot = scan()
        return snapshotVersion
    }

    private var watchedRoots: [String] {
        [codexRoot.path, claudeRoot.path]
    }

    private func scan() -> DashboardSnapshot {
        var warnings: [CoreWarning] = []
        var files: [(kind: AgentKind, url: URL, modified: Date)] = []

        files.append(contentsOf: sessionFiles(in: codexRoot, kind: .codex, warnings: &warnings))
        files.append(contentsOf: sessionFiles(in: claudeRoot, kind: .claudeCode, warnings: &warnings))

        files.sort { lhs, rhs in
            lhs.modified > rhs.modified
        }

        let recentFiles = Array(files.prefix(80))
        let activeCodexConversations = loadActiveCodexConversations(warnings: &warnings)
        let sessions = recentFiles.compactMap { file in
            parseSession(
                kind: file.kind,
                url: file.url,
                modified: file.modified,
                activeCodexConversations: activeCodexConversations,
                warnings: &warnings
            )
        }
        .sorted { lhs, rhs in
            lhs.lastUpdatedAt > rhs.lastUpdatedAt
        }

        return DashboardSnapshot(
            generatedAt: Date(),
            sessions: Array(sessions.prefix(12)),
            watchedRoots: watchedRoots,
            scannedFileCount: files.count,
            recentFileCount: recentFiles.count,
            warnings: warnings
        )
    }

    private func sessionFiles(
        in root: URL,
        kind: AgentKind,
        warnings: inout [CoreWarning]
    ) -> [(kind: AgentKind, url: URL, modified: Date)] {
        guard fileManager.fileExists(atPath: root.path) else {
            warnings.append(CoreWarning(
                code: "missing_source",
                message: "Source directory does not exist.",
                sourcePath: root.path
            ))
            return []
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            warnings.append(CoreWarning(
                code: "unreadable_source",
                message: "Source directory could not be enumerated.",
                sourcePath: root.path
            ))
            return []
        }

        var results: [(kind: AgentKind, url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" || url.pathExtension == "json" else {
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                results.append((kind, url, values.contentModificationDate ?? .distantPast))
            } catch {
                warnings.append(CoreWarning(
                    code: "unreadable_file_metadata",
                    message: "Session file metadata could not be read.",
                    sourcePath: url.path
                ))
            }
        }
        return results
    }

    private func parseSession(
        kind: AgentKind,
        url: URL,
        modified: Date,
        activeCodexConversations: Set<String>,
        warnings: inout [CoreWarning]
    ) -> AgentSessionSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            warnings.append(CoreWarning(
                code: "unreadable_session",
                message: "Session file could not be opened.",
                sourcePath: url.path
            ))
            return nil
        }
        defer { try? handle.close() }

        let headData = handle.readData(ofLength: 128 * 1024)
        let fileLength = (try? handle.seekToEnd()) ?? 0
        let tailOffset = fileLength > 128 * 1024 ? fileLength - UInt64(128 * 1024) : 0
        try? handle.seek(toOffset: tailOffset)
        let tailData = handle.readDataToEndOfFile()
        let data = headData + tailData
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            warnings.append(CoreWarning(
                code: "empty_session",
                message: "Session file has no readable UTF-8 metadata.",
                sourcePath: url.path
            ))
            return nil
        }

        var cwd: String?
        var title: String?
        var sessionID: String?
        var parsedLine = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).prefix(220) {
            guard let object = decodeObject(String(line)) else {
                continue
            }
            parsedLine = true
            cwd = cwd ?? stringValue(in: object, keys: ["cwd", "project_root", "projectRoot", "workspace", "root_path"])
            title = usefulTitle(title) ?? promptSnippet(in: object) ?? stringValue(in: object, keys: ["title", "summary", "name", "lastPrompt", "command"])
            sessionID = sessionID ?? stringValue(in: object, keys: ["session_id", "sessionId", "id", "conversationId"])

            if let payload = object["payload"] as? [String: Any] {
                cwd = cwd ?? stringValue(in: payload, keys: ["cwd", "project_root", "projectRoot", "workspace", "root_path"])
                title = usefulTitle(title) ?? promptSnippet(in: payload) ?? stringValue(in: payload, keys: ["title", "summary", "name", "lastPrompt", "command"])
                sessionID = sessionID ?? stringValue(in: payload, keys: ["session_id", "sessionId", "id", "conversationId"])
            }
        }

        guard parsedLine else {
            warnings.append(CoreWarning(
                code: "unknown_schema",
                message: "No JSONL metadata could be parsed from the session file.",
                sourcePath: url.path
            ))
            return nil
        }

        let projectPath = normalizedProjectPath(for: kind, cwd: cwd, fileURL: url)
        let projectName = projectPath.map(Self.displayName(forPath:)) ?? "Unassigned"
        let fallbackTitle = sessionID.map { shortID($0) } ?? url.deletingPathExtension().lastPathComponent
        let status = kind == .codex && sessionID.map(activeCodexConversations.contains) == true
            ? StatusHint.active
            : status(for: modified)

        return AgentSessionSummary(
            agentKind: kind,
            sourcePath: url.path,
            title: usefulTitle(title) ?? fallbackTitle,
            instanceID: sessionID.map(shortID),
            projectPath: projectPath,
            projectName: projectName,
            lastUpdatedAt: modified,
            statusHint: status,
            projectRootEvidence: projectPath == cwd ? "cwd metadata" : "source path"
        )
    }

    private func loadActiveCodexConversations(warnings: inout [CoreWarning]) -> Set<String> {
        guard fileManager.fileExists(atPath: codexProcessStateURL.path) else {
            return []
        }

        guard
            let data = try? Data(contentsOf: codexProcessStateURL),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            warnings.append(CoreWarning(
                code: "process_state_unreadable",
                message: "Codex process manager state could not be read.",
                sourcePath: codexProcessStateURL.path
            ))
            return []
        }

        return Set(array.compactMap { entry in
            guard entry["processId"] != nil || entry["osPid"] != nil else {
                return nil
            }
            return entry["conversationId"] as? String
        })
    }

    private func decodeObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private func promptSnippet(in object: [String: Any]) -> String? {
        if let role = object["role"] as? String, role != "user" {
            return nil
        }

        if let content = object["content"] as? String {
            return cleanPrompt(content)
        }

        if let content = object["lastPrompt"] as? String {
            return cleanPrompt(content)
        }

        if let content = object["message"] as? String {
            return cleanPrompt(content)
        }

        if let content = object["content"] as? [[String: Any]] {
            for item in content {
                if let text = item["text"] as? String ?? item["input_text"] as? String {
                    return cleanPrompt(text)
                }
            }
        }

        return nil
    }

    private func normalizedProjectPath(for kind: AgentKind, cwd: String?, fileURL: URL) -> String? {
        if let cwd, fileManager.fileExists(atPath: cwd) {
            return cwd
        }

        guard kind == .claudeCode else {
            return cwd
        }

        let encodedProject = fileURL.deletingLastPathComponent().lastPathComponent
        let decoded = decodeClaudeProjectPath(encodedProject)
        return decoded.isEmpty ? cwd : decoded
    }

    private func decodeClaudeProjectPath(_ encoded: String) -> String {
        if encoded.hasPrefix("-") {
            return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
        }
        return encoded.replacingOccurrences(of: "-", with: "/")
    }

    private func status(for modified: Date) -> StatusHint {
        let age = Date().timeIntervalSince(modified)
        if age < 5 * 60 { return .active }
        if age < 2 * 60 * 60 { return .idle }
        if age < 24 * 60 * 60 { return .stale }
        return .unknown
    }

    private func usefulTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()
        guard !["auto", "user", "external", "sdk-cli", "vscode"].contains(lowercased) else {
            return nil
        }
        return trimmed.count > 72 ? String(trimmed.prefix(69)) + "..." : trimmed
    }

    private func cleanPrompt(_ prompt: String) -> String? {
        let cleaned = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasPrefix("<environment_context>") || cleaned.hasPrefix("<system") {
            return nil
        }
        return cleaned.count > 72 ? String(cleaned.prefix(69)) + "..." : cleaned
    }

    private func shortID(_ id: String) -> String {
        id.count > 10 ? String(id.prefix(8)) : id
    }

    private static func displayName(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        return last.isEmpty ? path : last
    }
}

struct ActivityRow {
    let source: String
    let project: String
    let title: String
    let instance: String
    let status: String
    let age: String
    let isActive: Bool
    let lastUpdatedAt: Date
}

struct ProjectGroup {
    let project: String
    let activeCount: Int
    let rows: [ActivityRow]
    let lastUpdatedAt: Date
}

struct WidgetModel {
    let activeCount: Int
    let sessionCount: Int
    let scannedFileCount: Int
    let recentFileCount: Int
    let groups: [ProjectGroup]
    let watchedRoots: [String]
    let warningCount: Int
    let generatedAt: Date
}

final class DashboardViewController: NSViewController {
    private let snapshotProvider: DashboardSnapshotProviding
    private let widgetView = DashboardWidgetView()
    private let scanQueue = DispatchQueue(label: "dev.floaty.session-scan", qos: .utility)
    private var refreshTimer: Timer?

    init(
        windowBridge: WindowBridge,
        snapshotProvider: DashboardSnapshotProviding = LocalSessionSnapshotProvider()
    ) {
        _ = windowBridge
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
        effectView.layer?.cornerRadius = 16
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
        refreshSnapshot()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshSnapshot()
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func refreshSnapshot() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.snapshotProvider.refresh()
                let snapshot = try self.snapshotProvider.currentSnapshot()
                let model = WidgetModel(snapshot: snapshot)
                DispatchQueue.main.async {
                    self.widgetView.model = model
                    self.widgetView.errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.widgetView.errorMessage = error.localizedDescription
                }
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}

private extension WidgetModel {
    init(snapshot: DashboardSnapshot) {
        let rows = snapshot.sessions
            .filter { $0.statusHint == .active || $0.statusHint == .idle }
            .map { session in
            ActivityRow(
                source: session.agentKind.displayName,
                project: session.projectName,
                title: session.title,
                instance: session.instanceID ?? "",
                status: session.statusHint.displayName,
                age: Self.relativeAge(since: session.lastUpdatedAt),
                isActive: session.statusHint == .active,
                lastUpdatedAt: session.lastUpdatedAt
            )
        }

        let groups = Dictionary(grouping: rows, by: \.project)
            .map { project, rows in
                let sortedRows = rows.sorted { lhs, rhs in
                    if lhs.isActive != rhs.isActive {
                        return lhs.isActive
                    }
                    return lhs.lastUpdatedAt > rhs.lastUpdatedAt
                }
                return ProjectGroup(
                    project: project,
                    activeCount: sortedRows.filter(\.isActive).count,
                    rows: Array(sortedRows.prefix(4)),
                    lastUpdatedAt: sortedRows.map(\.lastUpdatedAt).max() ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                if lhs.activeCount != rhs.activeCount {
                    return lhs.activeCount > rhs.activeCount
                }
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }

        self.init(
            activeCount: rows.filter(\.isActive).count,
            sessionCount: rows.count,
            scannedFileCount: snapshot.scannedFileCount,
            recentFileCount: snapshot.recentFileCount,
            groups: groups,
            watchedRoots: snapshot.watchedRoots,
            warningCount: snapshot.warnings.count,
            generatedAt: snapshot.generatedAt
        )
    }

    static func relativeAge(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

final class DashboardWidgetView: NSView {
    var model: WidgetModel? {
        didSet { needsDisplay = true }
    }

    var errorMessage: String? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard initialization is not used in Floaty.")
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        drawChrome(context: context)
        if let errorMessage {
            drawText("Floaty", rect: NSRect(x: 20, y: 18, width: 120, height: 24), font: .systemFont(ofSize: 17, weight: .semibold), color: Palette.primaryText)
            drawText(errorMessage, rect: NSRect(x: 20, y: 56, width: bounds.width - 40, height: 80), font: .systemFont(ofSize: 12), color: Palette.warning)
            return
        }

        guard let model else {
            drawText("Floaty", rect: NSRect(x: 20, y: 18, width: 95, height: 24), font: .systemFont(ofSize: 17, weight: .semibold), color: Palette.primaryText)
            drawText("scanning local sessions", rect: NSRect(x: 20, y: 46, width: 150, height: 18), font: .systemFont(ofSize: 12, weight: .medium), color: Palette.secondaryText)
            drawRule(y: 76)
            drawText("Codex and Claude activity will appear here after the first metadata pass.", rect: NSRect(x: 20, y: 92, width: bounds.width - 40, height: 38), font: .systemFont(ofSize: 11), color: Palette.tertiaryText)
            return
        }
        drawHeader(model)
        drawSourceSummary(model)
        drawGroups(model)
        drawFooter(model)
    }

    private func drawChrome(context: CGContext) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        context.addPath(path)
        context.setFillColor(Palette.panelFill.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(Palette.hairline.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private func drawHeader(_ model: WidgetModel) {
        drawText("Floaty", rect: NSRect(x: 20, y: 18, width: 95, height: 24), font: .systemFont(ofSize: 17, weight: .semibold), color: Palette.primaryText)
        drawText("local sessions", rect: NSRect(x: 20, y: 40, width: 120, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: Palette.secondaryText)

        let statusColor = model.activeCount > 0 ? Palette.green : Palette.mutedText
        statusColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - 106, y: 25, width: 8, height: 8)).fill()
        drawText("\(model.activeCount) active", rect: NSRect(x: bounds.width - 92, y: 18, width: 74, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: Palette.primaryText)
        drawText("\(model.sessionCount) instances", rect: NSRect(x: bounds.width - 102, y: 38, width: 84, height: 16), font: .systemFont(ofSize: 11), color: Palette.secondaryText)
        drawRule(y: 68)
    }

    private func drawSourceSummary(_ model: WidgetModel) {
        drawText("watching", rect: NSRect(x: 20, y: 78, width: 58, height: 14), font: .systemFont(ofSize: 10, weight: .semibold), color: Palette.tertiaryText)
        let roots = model.watchedRoots.map(WidgetModel.shortPath).joined(separator: "  ")
        drawText(roots, rect: NSRect(x: 82, y: 76, width: bounds.width - 102, height: 18), font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: Palette.secondaryText)
        drawRule(y: 102)
    }

    private func drawGroups(_ model: WidgetModel) {
        var y: CGFloat = 112
        var drawnRows = 0
        for group in model.groups.prefix(4) {
            drawGroupHeader(group, y: y)
            y += 22

            for row in group.rows {
                guard drawnRows < 7 else { return }
                drawRow(row, y: y)
                y += 36
                drawnRows += 1
            }
        }
    }

    private func drawGroupHeader(_ group: ProjectGroup, y: CGFloat) {
        drawText(group.project, rect: NSRect(x: 20, y: y + 2, width: 148, height: 15), font: .systemFont(ofSize: 11, weight: .bold), color: Palette.primaryText)
        let label = group.activeCount > 0 ? "\(group.activeCount) active" : "\(group.rows.count) recent"
        drawText(label, rect: NSRect(x: bounds.width - 86, y: y + 2, width: 68, height: 15), font: .systemFont(ofSize: 10, weight: .medium), color: group.activeCount > 0 ? Palette.green : Palette.secondaryText)
    }

    private func drawRow(_ row: ActivityRow, y: CGFloat) {
        let dotColor = row.isActive ? Palette.green : Palette.mutedText
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 24, y: y + 8, width: 6, height: 6)).fill()

        drawText(row.source, rect: NSRect(x: 38, y: y + 1, width: 52, height: 15), font: .systemFont(ofSize: 10, weight: .bold), color: Palette.primaryText)
        drawText(row.instance, rect: NSRect(x: 94, y: y + 1, width: 42, height: 15), font: .monospacedSystemFont(ofSize: 9, weight: .regular), color: Palette.tertiaryText)
        drawText(row.status, rect: NSRect(x: 142, y: y + 1, width: 48, height: 15), font: .systemFont(ofSize: 10, weight: .medium), color: row.isActive ? Palette.green : Palette.secondaryText)
        drawText(row.age, rect: NSRect(x: bounds.width - 48, y: y + 1, width: 30, height: 15), font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: Palette.secondaryText)

        drawText(row.title, rect: NSRect(x: 38, y: y + 17, width: bounds.width - 56, height: 15), font: .systemFont(ofSize: 10), color: Palette.secondaryText)
        drawRule(y: y + 35)
    }

    private func drawFooter(_ model: WidgetModel) {
        let y = bounds.height - 30
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        drawText("updated \(formatter.string(from: model.generatedAt))", rect: NSRect(x: 20, y: y, width: 100, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: Palette.secondaryText)
        if model.warningCount > 0 {
            drawText("\(model.warningCount) warnings", rect: NSRect(x: bounds.width - 92, y: y, width: 74, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: Palette.warning)
        }
    }

    private func drawRule(y: CGFloat) {
        Palette.hairline.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: 18, y: y))
        path.line(to: NSPoint(x: bounds.width - 18, y: y))
        path.stroke()
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
    static let panelFill = NSColor(calibratedWhite: 0.90, alpha: 0.82)
    static let hairline = NSColor(calibratedWhite: 0.34, alpha: 0.18)
    static let primaryText = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
    static let secondaryText = NSColor(calibratedRed: 0.27, green: 0.31, blue: 0.38, alpha: 0.92)
    static let tertiaryText = NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.48, alpha: 0.74)
    static let mutedText = NSColor(calibratedRed: 0.55, green: 0.59, blue: 0.66, alpha: 0.9)
    static let green = NSColor(calibratedRed: 0.12, green: 0.70, blue: 0.38, alpha: 1)
    static let warning = NSColor(calibratedRed: 0.82, green: 0.36, blue: 0.16, alpha: 1)
}
