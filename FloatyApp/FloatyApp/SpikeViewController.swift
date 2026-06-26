import UIKit

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
    case unknown
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
        case .claudeCode: return "Claude Code"
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
            return "The local Swift mock provider emitted JSON that does not match the Rust snapshot shape."
        }
    }
}

/// Local UIKit-side provider that mirrors the Rust `DashboardSnapshot` JSON shape.
///
/// This keeps Item D buildable without introducing Rust/Catalyst link steps yet.
/// The FFI seam can replace this type with a provider backed by
/// `floaty_core_snapshot_json` and `floaty_core_refresh`.
final class MockDashboardSnapshotProvider: DashboardSnapshotProviding {
    private(set) var snapshotVersion: UInt64 = 1
    let providerName = "Swift mock snapshot provider"

    func currentSnapshot() throws -> DashboardSnapshot {
        let data = mockSnapshotJSON(version: snapshotVersion).data(using: .utf8)
        guard let data else { throw DashboardProviderError.invalidMockJSON }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DashboardSnapshot.self, from: data)
    }

    @discardableResult
    func refresh() throws -> UInt64 {
        snapshotVersion = snapshotVersion.saturatingIncremented()
        _ = try currentSnapshot()
        return snapshotVersion
    }

    private func mockSnapshotJSON(version: UInt64) -> String {
        let second = String(format: "%02d", version % 60)
        let generatedAt = "mock-2026-06-26T00:00:\(second)Z"
        let dirty = version % 2 == 0
        let status = dirty ? "active" : "idle"
        let warningMessage = version == 1
            ? "Dashboard is using a Swift mock provider with the same JSON shape as floaty-core."
            : "Refresh updated the visible snapshot from the local Swift mock provider."

        return """
        {
          "generated_at": "\(generatedAt)",
          "projects": [
            {
              "root_path": "/tmp",
              "display_name": "Local Temp Workspace",
              "root_confidence": "verified",
              "agents": [
                {
                  "agent_kind": "codex",
                  "source_path": "/tmp/floaty-demo/codex-session.jsonl",
                  "title": "MVP dashboard pass",
                  "last_updated_at": "\(generatedAt)",
                  "status_hint": "\(status)",
                  "project_root_evidence": "mock configured root"
                },
                {
                  "agent_kind": "claude_code",
                  "source_path": "/tmp/floaty-demo/claude-session.jsonl",
                  "title": "Review UIKit shell",
                  "last_updated_at": "\(generatedAt)",
                  "status_hint": "idle",
                  "project_root_evidence": "mock metadata matched configured root"
                }
              ],
              "git": {
                "branch": "main",
                "dirty": \(dirty),
                "ahead_count": \(version % 3),
                "behind_count": 0,
                "last_checked_at": "\(generatedAt)",
                "error": null
              }
            }
          ],
          "unassigned_sessions": [
            {
              "agent_kind": "open_code",
              "source_path": "/tmp/floaty-unassigned/opencode-session.jsonl",
              "title": "Unmapped agent session",
              "last_updated_at": "\(generatedAt)",
              "status_hint": "unknown",
              "project_root_evidence": "mock session did not expose a verified root"
            }
          ],
          "pets": [
            {
              "pet_id": "mock-cat",
              "display_name": "Mock Cat",
              "source_path": "/tmp/floaty-pets/mock-cat/pet.json"
            },
            {
              "pet_id": "mock-otter",
              "display_name": "Mock Otter",
              "source_path": "/tmp/floaty-pets/mock-otter/pet.json"
            }
          ],
          "warnings": [
            {
              "code": "mock_provider",
              "message": "\(warningMessage)",
              "source_path": null
            }
          ]
        }
        """
    }
}

private extension UInt64 {
    func saturatingIncremented() -> UInt64 {
        self == UInt64.max ? UInt64.max : self + 1
    }
}

final class DashboardViewController: UIViewController {
    private let windowBridge: WindowBridge
    private let snapshotProvider: DashboardSnapshotProviding

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let snapshotSummaryLabel = UILabel()
    private let jumpStatusLabel = UILabel()
    private let diagnosticsStatusLabel = UILabel()
    private let diagnosticsTextView = UITextView()

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
        fatalError("Storyboard initialization is not used in the UIKit-only dashboard.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildInterface()
        loadSnapshot(reason: "Initial load")
        renderWindowDiagnostic(
            WindowBridgeResult(
                command: .inspect,
                status: .windowUnavailable,
                message: "The dashboard has loaded. Wait for the scene window to appear, then use Inspect Window or another command."
            )
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        renderWindowDiagnostic(windowBridge.describeResolvedWindow(for: view.window))
    }

    private func buildInterface() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 16
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    private func loadSnapshot(reason: String) {
        do {
            let snapshot = try snapshotProvider.currentSnapshot()
            render(snapshot: snapshot, reason: reason)
        } catch {
            renderLoadFailure(error)
        }
    }

    private func render(snapshot: DashboardSnapshot, reason: String) {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let titleLabel = makeLabel(
            "Floaty MVP Dashboard",
            style: .largeTitle,
            color: .label,
            weight: .bold
        )
        let subtitle = makeLabel(
            "Snapshot-shaped UIKit shell backed by \(snapshotProvider.providerName). Rust FFI is the next provider seam.",
            style: .body,
            color: .secondaryLabel
        )
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitle)

        snapshotSummaryLabel.text = "Version \(snapshotProvider.snapshotVersion) • generated \(snapshot.generatedAt) • \(reason)"
        snapshotSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        snapshotSummaryLabel.adjustsFontForContentSizeCategory = true
        snapshotSummaryLabel.textColor = .secondaryLabel
        snapshotSummaryLabel.numberOfLines = 0
        contentStack.addArrangedSubview(snapshotSummaryLabel)

        let refreshButton = makeButton(title: "Refresh Snapshot", action: #selector(refreshSnapshot))
        contentStack.addArrangedSubview(refreshButton)

        jumpStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        jumpStatusLabel.adjustsFontForContentSizeCategory = true
        jumpStatusLabel.textColor = .secondaryLabel
        jumpStatusLabel.numberOfLines = 0
        jumpStatusLabel.text = "Jump actions open verified local directories with UIApplication.open(fileURL)."
        contentStack.addArrangedSubview(jumpStatusLabel)

        contentStack.addArrangedSubview(makeSectionHeader("Projects"))
        if snapshot.projects.isEmpty {
            contentStack.addArrangedSubview(makeEmptyCard("No projects in the current snapshot."))
        } else {
            snapshot.projects.forEach { project in
                contentStack.addArrangedSubview(makeProjectCard(project))
            }
        }

        contentStack.addArrangedSubview(makeSectionHeader("Unassigned Sessions"))
        if snapshot.unassignedSessions.isEmpty {
            contentStack.addArrangedSubview(makeEmptyCard("No unassigned sessions."))
        } else {
            snapshot.unassignedSessions.forEach { session in
                contentStack.addArrangedSubview(makeSessionRow(session, indented: false))
            }
        }

        contentStack.addArrangedSubview(makeSectionHeader("Pets"))
        if snapshot.pets.isEmpty {
            contentStack.addArrangedSubview(makeEmptyCard("No pet assets discovered."))
        } else {
            let petStack = makeCardStack()
            snapshot.pets.forEach { pet in
                petStack.addArrangedSubview(makeLabel("🐾 \(pet.displayName) (\(pet.petId))", style: .body, color: .label))
                petStack.addArrangedSubview(makeLabel(pet.sourcePath, style: .caption1, color: .secondaryLabel))
            }
            contentStack.addArrangedSubview(petStack)
        }

        contentStack.addArrangedSubview(makeSectionHeader("Warnings"))
        if snapshot.warnings.isEmpty {
            contentStack.addArrangedSubview(makeEmptyCard("No warnings."))
        } else {
            let warningStack = makeCardStack(backgroundColor: .systemYellow.withAlphaComponent(0.18))
            snapshot.warnings.forEach { warning in
                warningStack.addArrangedSubview(makeLabel("⚠️ \(warning.code)", style: .headline, color: .label))
                warningStack.addArrangedSubview(makeLabel(warning.message, style: .body, color: .label))
                if let sourcePath = warning.sourcePath {
                    warningStack.addArrangedSubview(makeLabel(sourcePath, style: .caption1, color: .secondaryLabel))
                }
            }
            contentStack.addArrangedSubview(warningStack)
        }

        contentStack.addArrangedSubview(makeWindowDiagnosticsSection())
    }

    private func renderLoadFailure(_ error: Error) {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        contentStack.addArrangedSubview(makeLabel("Floaty MVP Dashboard", style: .largeTitle, color: .label, weight: .bold))
        contentStack.addArrangedSubview(makeEmptyCard("Could not load dashboard snapshot: \(error.localizedDescription)"))
        contentStack.addArrangedSubview(makeWindowDiagnosticsSection())
    }

    private func makeProjectCard(_ project: ProjectSummary) -> UIView {
        let card = makeCardStack()
        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .firstBaseline

        let nameLabel = makeLabel(project.displayName, style: .title2, color: .label, weight: .semibold)
        let confidence = makePill(project.rootConfidence.rawValue.uppercased())
        titleRow.addArrangedSubview(nameLabel)
        titleRow.addArrangedSubview(confidence)
        titleRow.addArrangedSubview(UIView())
        card.addArrangedSubview(titleRow)

        card.addArrangedSubview(makeLabel(project.rootPath, style: .caption1, color: .secondaryLabel))

        if let git = project.git {
            card.addArrangedSubview(makeLabel(gitSummaryText(git), style: .subheadline, color: .label))
        }

        let jumpButton = makeButton(title: "Jump to Project", action: #selector(jumpButtonTapped(_:)))
        jumpButton.accessibilityIdentifier = project.rootPath
        card.addArrangedSubview(jumpButton)

        if project.agents.isEmpty {
            card.addArrangedSubview(makeLabel("No agent sessions for this project.", style: .body, color: .secondaryLabel))
        } else {
            project.agents.forEach { session in
                card.addArrangedSubview(makeSessionRow(session, indented: true))
            }
        }

        return card
    }

    private func makeSessionRow(_ session: AgentSessionSummary, indented: Bool) -> UIView {
        let stack = makeCardStack(backgroundColor: indented ? .tertiarySystemBackground : .secondarySystemBackground)
        stack.layoutMargins.left = indented ? 18 : 12
        let title = session.title ?? "Untitled session"
        stack.addArrangedSubview(makeLabel("\(agentBadge(session.agentKind)) \(title)", style: .headline, color: .label))
        stack.addArrangedSubview(makeLabel("\(session.agentKind.displayName) • \(session.statusHint.rawValue) • \(session.lastUpdatedAt)", style: .subheadline, color: .secondaryLabel))
        stack.addArrangedSubview(makeLabel(session.sourcePath, style: .caption1, color: .secondaryLabel))
        if let evidence = session.projectRootEvidence {
            stack.addArrangedSubview(makeLabel("Evidence: \(evidence)", style: .caption1, color: .secondaryLabel))
        }
        return stack
    }

    private func makeWindowDiagnosticsSection() -> UIView {
        let stack = makeCardStack()
        stack.addArrangedSubview(makeLabel("Window Command Diagnostics", style: .title3, color: .label, weight: .semibold))
        stack.addArrangedSubview(makeLabel("Public Catalyst APIs still do not expose supportable NSWindow floating/minimize controls, so diagnostics stay visible in the MVP dashboard.", style: .body, color: .secondaryLabel))

        let buttons = UIStackView(arrangedSubviews: [
            makeButton(title: "Inspect Window", action: #selector(inspectWindow)),
            makeButton(title: "Float Window", action: #selector(floatWindow)),
            makeButton(title: "Normal Window", action: #selector(normalWindow)),
            makeButton(title: "Minimize to Dock", action: #selector(minimizeToDock)),
            makeButton(title: "Activate / Restore", action: #selector(activateAndRestore)),
            makeButton(title: "Probe Graceful Failure", action: #selector(probeGracefulFailure))
        ])
        buttons.axis = .vertical
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        diagnosticsStatusLabel.font = .preferredFont(forTextStyle: .headline)
        diagnosticsStatusLabel.adjustsFontForContentSizeCategory = true
        diagnosticsStatusLabel.numberOfLines = 0
        stack.addArrangedSubview(diagnosticsStatusLabel)

        diagnosticsTextView.isEditable = false
        diagnosticsTextView.isSelectable = true
        diagnosticsTextView.font = .preferredFont(forTextStyle: .body)
        diagnosticsTextView.adjustsFontForContentSizeCategory = true
        diagnosticsTextView.backgroundColor = .systemBackground
        diagnosticsTextView.layer.cornerRadius = 10
        diagnosticsTextView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        diagnosticsTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        stack.addArrangedSubview(diagnosticsTextView)

        return stack
    }

    private func makeCardStack(backgroundColor: UIColor = .secondarySystemBackground) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.backgroundColor = backgroundColor
        stack.layer.cornerRadius = 12
        return stack
    }

    private func makeSectionHeader(_ text: String) -> UILabel {
        makeLabel(text, style: .title3, color: .label, weight: .semibold)
    }

    private func makeEmptyCard(_ text: String) -> UIView {
        let stack = makeCardStack()
        stack.addArrangedSubview(makeLabel(text, style: .body, color: .secondaryLabel))
        return stack
    }

    private func makeLabel(
        _ text: String,
        style: UIFont.TextStyle,
        color: UIColor,
        weight: UIFont.Weight? = nil
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color
        if let weight {
            let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
            label.font = UIFont.systemFont(ofSize: descriptor.pointSize, weight: weight)
        } else {
            label.font = .preferredFont(forTextStyle: style)
        }
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func makePill(_ text: String) -> UILabel {
        let label = makeLabel(text, style: .caption2, color: .white, weight: .bold)
        label.backgroundColor = .systemBlue
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.textAlignment = .center
        label.layoutMargins = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        return label
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .medium

        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .primaryActionTriggered)
        return button
    }

    private func gitSummaryText(_ git: GitSummary) -> String {
        let branch = git.branch ?? "unknown branch"
        let dirty = git.dirty.map { $0 ? "dirty" : "clean" } ?? "dirty unknown"
        let ahead = git.aheadCount.map(String.init) ?? "?"
        let behind = git.behindCount.map(String.init) ?? "?"
        var text = "Git: \(branch) • \(dirty) • ↑\(ahead) ↓\(behind) • checked \(git.lastCheckedAt)"
        if let error = git.error {
            text += " • error: \(error)"
        }
        return text
    }

    private func agentBadge(_ kind: AgentKind) -> String {
        switch kind {
        case .codex: return "▣"
        case .claudeCode: return "◇"
        case .openCode: return "○"
        case .hermes: return "✦"
        case .other: return "•"
        }
    }

    private func renderWindowDiagnostic(_ result: WindowBridgeResult) {
        diagnosticsStatusLabel.text = result.status.rawValue
        diagnosticsStatusLabel.textColor = color(for: result.status)
        diagnosticsTextView.text = result.displayText
    }

    private func color(for status: WindowBridgeStatus) -> UIColor {
        switch status {
        case .succeeded:
            return .systemGreen
        case .windowUnavailable, .supportableAPIUnavailable:
            return .systemOrange
        case .unsupportedPlatform:
            return .systemRed
        }
    }

    @objc private func refreshSnapshot() {
        do {
            let version = try snapshotProvider.refresh()
            loadSnapshot(reason: "Manual refresh to version \(version)")
        } catch {
            renderLoadFailure(error)
        }
    }

    @objc private func jumpButtonTapped(_ sender: UIButton) {
        guard let rootPath = sender.accessibilityIdentifier, !rootPath.isEmpty else {
            jumpStatusLabel.text = "Jump failed: missing project root."
            jumpStatusLabel.textColor = .systemRed
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            jumpStatusLabel.text = "Jump skipped safely: project root is not an existing directory: \(rootPath)"
            jumpStatusLabel.textColor = .systemOrange
            return
        }

        let url = URL(fileURLWithPath: rootPath, isDirectory: true)
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            DispatchQueue.main.async {
                self?.jumpStatusLabel.text = success
                    ? "Jump requested: \(rootPath)"
                    : "Jump attempt was rejected by the system: \(rootPath)"
                self?.jumpStatusLabel.textColor = success ? .systemGreen : .systemOrange
            }
        }
    }

    @objc private func inspectWindow() {
        renderWindowDiagnostic(windowBridge.describeResolvedWindow(for: view.window))
    }

    @objc private func floatWindow() {
        renderWindowDiagnostic(windowBridge.setFloating(true, for: view.window))
    }

    @objc private func normalWindow() {
        renderWindowDiagnostic(windowBridge.setFloating(false, for: view.window))
    }

    @objc private func minimizeToDock() {
        renderWindowDiagnostic(windowBridge.minimizeToDock(for: view.window))
    }

    @objc private func activateAndRestore() {
        renderWindowDiagnostic(windowBridge.activateAndRestore(for: view.window))
    }

    @objc private func probeGracefulFailure() {
        renderWindowDiagnostic(windowBridge.setFloating(true, for: nil))
    }
}
