import AppKit
import Foundation

@main
enum HermesFixtureTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floaty-hermes-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try testHermesSessionAppears(root: root.appendingPathComponent("present", isDirectory: true))
        try testHermesMissingWarning(root: root.appendingPathComponent("missing", isDirectory: true))
        try testHermesSchemaMismatch(root: root.appendingPathComponent("mismatch", isDirectory: true))
        try testUnknownHermesProjectRoot(root: root.appendingPathComponent("unknown-root", isDirectory: true))
        try testHermesGenericTerminalIsDemoted(root: root.appendingPathComponent("terminal-demotion", isDirectory: true))
        try testHermesTerminalOutputIsDemoted(root: root.appendingPathComponent("terminal-output-demotion", isDirectory: true))
        try testHermesDateLikeTitleFallsBack(root: root.appendingPathComponent("date-title", isDirectory: true))
        try testHermesRecentMessageBeatsTitle(root: root.appendingPathComponent("message-priority", isDirectory: true))
        try testHermesTerminalCommandTranslates(root: root.appendingPathComponent("terminal-command", isDirectory: true))
        try testCodexClaudeStillScan(root: root.appendingPathComponent("file-backed", isDirectory: true))

        print("Hermes fixture tests passed")
    }

    private static func testHermesSessionAppears(root: URL) throws {
        let project = root.appendingPathComponent("workspace/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try createHermesDB(
            home: root,
            rows: [HermesFixtureRow(
                id: "hermes-present-1",
                title: "Implement Hermes dashboard",
                cwd: project.path,
                gitRepoRoot: project.path,
                lastUpdated: Date().timeIntervalSince1970 - 60,
                userMessage: "Wire Hermes sessions into Floaty"
            )]
        )

        let snapshot = try snapshot(for: root)
        guard let session = snapshot.sessions.first(where: { $0.agentKind == .hermes }) else {
            throw TestFailure("expected Hermes session")
        }
        assertEqual(session.agentKind.displayName, "Hermes", "Hermes display name")
        assertEqual(session.projectName, "demo", "Hermes project name")
        assertEqual(session.instanceID, "hermes-p", "Hermes short id")
        if !snapshot.watchedRoots.contains(root.appendingPathComponent(".hermes/state.db").path) {
            throw TestFailure("expected Hermes state.db in watched roots")
        }
    }

    private static func testHermesMissingWarning(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = try snapshot(for: root)
        if !snapshot.warnings.contains(where: { $0.code == "hermes_state_missing" }) {
            throw TestFailure("expected missing Hermes warning")
        }
    }

    private static func testHermesSchemaMismatch(root: URL) throws {
        let hermes = root.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
        let db = hermes.appendingPathComponent("state.db")
        try runSQLite(db: db, sql: "CREATE TABLE schema_version(version INTEGER NOT NULL); INSERT INTO schema_version VALUES (1); CREATE TABLE sessions(id TEXT PRIMARY KEY);")

        let snapshot = try snapshot(for: root)
        if !snapshot.warnings.contains(where: { $0.code == "hermes_schema_mismatch" }) {
            throw TestFailure("expected schema mismatch warning")
        }
        if snapshot.sessions.contains(where: { $0.agentKind == .hermes }) {
            throw TestFailure("schema mismatch should not produce Hermes sessions")
        }
    }

    private static func testUnknownHermesProjectRoot(root: URL) throws {
        try createHermesDB(
            home: root,
            rows: [HermesFixtureRow(
                id: "hermes-unknown-root",
                title: "Unknown root",
                cwd: root.appendingPathComponent("does-not-exist").path,
                gitRepoRoot: nil,
                lastUpdated: Date().timeIntervalSince1970 - 120,
                userMessage: nil
            )]
        )

        let snapshot = try snapshot(for: root)
        guard let session = snapshot.sessions.first(where: { $0.agentKind == .hermes }) else {
            throw TestFailure("expected Hermes unknown-root session")
        }
        assertEqual(session.projectName, "Unassigned", "unknown Hermes project name")
        if session.projectPath != nil {
            throw TestFailure("unknown Hermes project should not expose nonexistent projectPath")
        }
    }

    private static func testHermesGenericTerminalIsDemoted(root: URL) throws {
        let now = Date().timeIntervalSince1970 - 30
        try createHermesDB(
            home: root,
            rows: [HermesFixtureRow(
                id: "hermes-terminal-demotion",
                title: "20260628 in progress",
                cwd: root.path,
                gitRepoRoot: nil,
                lastUpdated: now,
                messages: [
                    HermesFixtureMessage(role: "user", content: "Wire Hermes sessions into Floaty", toolName: nil, timestamp: now - 10),
                    HermesFixtureMessage(role: "assistant", content: nil, toolName: "terminal", timestamp: now)
                ]
            )]
        )

        let session = try onlyHermesSession(for: root)
        assertEqual(session.title, "Wire Hermes sessions into Floaty", "generic terminal should not beat useful message")
        if session.title == "Using terminal" {
            throw TestFailure("Hermes should not surface generic terminal tool labels")
        }
    }

    private static func testHermesTerminalOutputIsDemoted(root: URL) throws {
        let now = Date().timeIntervalSince1970 - 35
        try createHermesDB(
            home: root,
            rows: [HermesFixtureRow(
                id: "hermes-terminal-output-demotion",
                title: "20260628 in progress",
                cwd: root.path,
                gitRepoRoot: nil,
                lastUpdated: now,
                messages: [
                    HermesFixtureMessage(role: "user", content: "Keep the useful Hermes prompt", toolName: nil, timestamp: now - 10),
                    HermesFixtureMessage(role: "assistant", content: "Process exited with code 0", toolName: "terminal", timestamp: now)
                ]
            )]
        )

        let session = try onlyHermesSession(for: root)
        assertEqual(session.title, "Keep the useful Hermes prompt", "terminal output should not beat useful message")
    }

    private static func testHermesDateLikeTitleFallsBack(root: URL) throws {
        let now = Date().timeIntervalSince1970 - 40
        try createHermesDB(
            home: root,
            rows: [HermesFixtureRow(
                id: "hermes-date-title",
                title: "20260628 in progress",
                cwd: root.path,
                gitRepoRoot: nil,
                lastUpdated: now
            )]
        )

        let session = try onlyHermesSession(for: root)
        assertEqual(session.title, "Hermes session hermes-d", "date-like Hermes title fallback")
    }

    private static func testHermesRecentMessageBeatsTitle(root: URL) throws {
        let now = Date().timeIntervalSince1970 - 50
        try createHermesDB(
            home: root,
            rows: [HermesFixtureRow(
                id: "hermes-message-priority",
                title: "Human readable session title",
                cwd: root.path,
                gitRepoRoot: nil,
                lastUpdated: now,
                messages: [
                    HermesFixtureMessage(role: "assistant", content: "Summarizing dashboard alignment fixes", toolName: nil, timestamp: now)
                ]
            )]
        )

        let session = try onlyHermesSession(for: root)
        assertEqual(session.title, "Summarizing dashboard alignment fixes", "recent Hermes message should beat session title")
    }

    private static func testHermesTerminalCommandTranslates(root: URL) throws {
        let now = Date().timeIntervalSince1970 - 60
        try createHermesDB(
            home: root,
            rows: [HermesFixtureRow(
                id: "hermes-terminal-command",
                title: "20260628 in progress",
                cwd: root.path,
                gitRepoRoot: nil,
                lastUpdated: now,
                messages: [
                    HermesFixtureMessage(role: "assistant", content: "git diff -- FloatyApp/FloatyApp/DashboardViewController.swift", toolName: "terminal", timestamp: now)
                ]
            )]
        )

        let session = try onlyHermesSession(for: root)
        assertEqual(session.title, "Reviewing code changes", "terminal command should translate to useful activity")
    }

    private static func testCodexClaudeStillScan(root: URL) throws {
        let codex = root.appendingPathComponent(".codex/sessions/2026/06/28", isDirectory: true)
        let claude = root.appendingPathComponent(".claude/projects/-tmp-floaty-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("floaty-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try writeJSONLine(
            ["cwd": project.path, "title": "Codex fixture", "session_id": "11111111-1111-4111-8111-111111111111"],
            to: codex.appendingPathComponent("rollout-11111111-1111-4111-8111-111111111111.jsonl")
        )
        try writeJSONLine(
            ["cwd": project.path, "title": "Claude fixture", "sessionId": "claude-fixture"],
            to: claude.appendingPathComponent("session.jsonl")
        )

        let snapshot = try snapshot(for: root)
        let kinds = Set(snapshot.sessions.map(\.agentKind.displayName))
        if !kinds.contains("Codex") || !kinds.contains("Claude") {
            throw TestFailure("expected Codex and Claude sessions, got \(kinds)")
        }
        if snapshot.sessions.contains(where: { $0.agentKind == .hermes }) {
            throw TestFailure("missing Hermes DB should not create Hermes session")
        }
    }

    private static func snapshot(for home: URL) throws -> DashboardSnapshot {
        let provider = LocalSessionSnapshotProvider(homeDirectory: home)
        _ = try provider.refresh()
        return try provider.currentSnapshot()
    }

    private static func onlyHermesSession(for home: URL) throws -> AgentSessionSummary {
        let snapshot = try snapshot(for: home)
        guard let session = snapshot.sessions.first(where: { $0.agentKind == .hermes }) else {
            throw TestFailure("expected Hermes session")
        }
        return session
    }

    private static func writeJSONLine(_ object: [String: String], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        try line.write(to: url, atomically: true, encoding: .utf8)
    }

    private struct HermesFixtureRow {
        let id: String
        let title: String
        let cwd: String
        let gitRepoRoot: String?
        let lastUpdated: TimeInterval
        let userMessage: String?
        let messages: [HermesFixtureMessage]

        init(
            id: String,
            title: String,
            cwd: String,
            gitRepoRoot: String?,
            lastUpdated: TimeInterval,
            userMessage: String? = nil,
            messages: [HermesFixtureMessage] = []
        ) {
            self.id = id
            self.title = title
            self.cwd = cwd
            self.gitRepoRoot = gitRepoRoot
            self.lastUpdated = lastUpdated
            self.userMessage = userMessage
            self.messages = messages
        }
    }

    private struct HermesFixtureMessage {
        let role: String
        let content: String?
        let toolName: String?
        let timestamp: TimeInterval
    }

    private static func createHermesDB(home: URL, rows: [HermesFixtureRow]) throws {
        let hermes = home.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
        let db = hermes.appendingPathComponent("state.db")
        var sql = """
        CREATE TABLE schema_version(version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (16);
        CREATE TABLE sessions(
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            end_reason TEXT,
            title TEXT,
            cwd TEXT,
            git_repo_root TEXT
        );
        CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT,
            tool_name TEXT,
            timestamp REAL NOT NULL
        );
        """
        for row in rows {
            sql += "INSERT INTO sessions(id, source, started_at, ended_at, end_reason, title, cwd, git_repo_root) VALUES (\(quoted(row.id)), 'hermes', \(row.lastUpdated - 30), NULL, NULL, \(quoted(row.title)), \(quoted(row.cwd)), \(quoted(row.gitRepoRoot)));\n"
            if row.messages.isEmpty, let message = row.userMessage {
                sql += "INSERT INTO messages(session_id, role, content, tool_name, timestamp) VALUES (\(quoted(row.id)), 'user', \(quoted(message)), NULL, \(row.lastUpdated));\n"
            }
            for message in row.messages {
                sql += "INSERT INTO messages(session_id, role, content, tool_name, timestamp) VALUES (\(quoted(row.id)), \(quoted(message.role)), \(quoted(message.content)), \(quoted(message.toolName)), \(message.timestamp));\n"
            }
        }
        try runSQLite(db: db, sql: sql)
    }

    private static func runSQLite(db: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path]
        let input = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = error.fileHandleForReading.readDataToEndOfFile()
            throw TestFailure(String(data: data, encoding: .utf8) ?? "sqlite3 fixture setup failed")
        }
    }

    private static func quoted(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fatalError("\(label): expected \(expected), got \(actual)")
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
