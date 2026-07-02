import AppKit
import Darwin
import SQLite3

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
    case inProgress
    case justFinished
    case done
    case stale
    case unknown

    var displayName: String {
        switch self {
        case .inProgress: return "in progress"
        case .justFinished: return "just finished"
        case .done: return "done"
        case .stale: return "stale"
        case .unknown: return "unknown"
        }
    }

    var sortRank: Int {
        switch self {
        case .inProgress: return 0
        case .justFinished: return 1
        case .done: return 2
        case .stale: return 3
        case .unknown: return 4
        }
    }
}

enum AgentKind: Equatable {
    case codex
    case claudeCode
    case hermes

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        case .hermes: return "Hermes"
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
    private struct HermesSessionRow {
        let id: String
        let title: String?
        let cwd: String?
        let gitRepoRoot: String?
        let startedAt: Double?
        let endedAt: Double?
        let endReason: String?
        let lastUpdatedAt: Double
    }

    private struct HermesMessageCandidate {
        let role: String?
        let content: String?
        let toolName: String?
        let timestamp: Double
    }

    private(set) var snapshotVersion: UInt64 = 0
    let providerName = "Local session files"

    private let fileManager: FileManager
    private let codexRoot: URL
    private let claudeRoot: URL
    private let hermesStateDBURL: URL
    private let codexProcessStateURL: URL
    private var cachedSnapshot: DashboardSnapshot?
    private var previousSessionModifiedDates: [String: Date] = [:]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.codexRoot = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.claudeRoot = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        self.hermesStateDBURL = homeDirectory.appendingPathComponent(".hermes/state.db")
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
        var roots = [codexRoot.path, claudeRoot.path]
        if fileManager.fileExists(atPath: hermesStateDBURL.path) {
            roots.append(hermesStateDBURL.path)
        }
        return roots
    }

    private func scan() -> DashboardSnapshot {
        var warnings: [CoreWarning] = []
        var files: [(kind: AgentKind, url: URL, modified: Date)] = []

        files.append(contentsOf: sessionFiles(in: codexRoot, kind: .codex, warnings: &warnings))
        files.append(contentsOf: sessionFiles(in: claudeRoot, kind: .claudeCode, warnings: &warnings))

        files.sort { lhs, rhs in
            lhs.modified > rhs.modified
        }

        let previousModifiedDates = previousSessionModifiedDates
        previousSessionModifiedDates = Dictionary(uniqueKeysWithValues: files.map { ($0.url.path, $0.modified) })

        let activeCodexProjects = loadActiveCodexProjects(warnings: &warnings)
        let candidateFiles = sessionCandidates(
            from: files,
            activeCodexConversations: Set(activeCodexProjects.keys),
            limit: 12
        )
        let fileBackedSessions: [AgentSessionSummary] = candidateFiles.compactMap { file in
            let wasModifiedSinceLastScan = previousModifiedDates[file.url.path].map { file.modified > $0 } ?? false
            return parseSession(
                kind: file.kind,
                url: file.url,
                modified: file.modified,
                wasModifiedSinceLastScan: wasModifiedSinceLastScan,
                activeCodexProjects: activeCodexProjects,
                warnings: &warnings
            )
        }
        let hermesSessions = loadHermesSessions(limit: 12, warnings: &warnings)
        let sessions = (fileBackedSessions + hermesSessions)
            .sorted(by: Self.sessionPrioritySort)

        return DashboardSnapshot(
            generatedAt: Date(),
            sessions: Array(sessions.prefix(16)),
            watchedRoots: watchedRoots,
            scannedFileCount: files.count + (fileManager.fileExists(atPath: hermesStateDBURL.path) ? 1 : 0),
            recentFileCount: candidateFiles.count + hermesSessions.count,
            warnings: warnings
        )
    }

    private func sessionCandidates(
        from files: [(kind: AgentKind, url: URL, modified: Date)],
        activeCodexConversations: Set<String>,
        limit: Int
    ) -> [(kind: AgentKind, url: URL, modified: Date)] {
        var seen = Set<String>()
        var candidates: [(kind: AgentKind, url: URL, modified: Date)] = []

        func append(_ file: (kind: AgentKind, url: URL, modified: Date)) {
            guard seen.insert(file.url.path).inserted else { return }
            candidates.append(file)
        }

        for file in files.prefix(limit) {
            append(file)
        }

        guard !activeCodexConversations.isEmpty else {
            return candidates
        }

        for file in files where file.kind == .codex {
            let filename = file.url.lastPathComponent
            if activeCodexConversations.contains(where: { filename.contains($0) }) {
                append(file)
            }
        }

        return candidates
    }


    private func loadHermesSessions(
        limit: Int,
        warnings: inout [CoreWarning]
    ) -> [AgentSessionSummary] {
        guard fileManager.fileExists(atPath: hermesStateDBURL.path) else {
            warnings.append(CoreWarning(
                code: "hermes_state_missing",
                message: "Hermes state database does not exist.",
                sourcePath: hermesStateDBURL.path
            ))
            return []
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            hermesStateDBURL.path,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let db else {
            let message = sqliteMessage(db, fallback: "Hermes state database could not be opened read-only.")
            warnings.append(CoreWarning(
                code: sqliteWarningCode(openResult, db: db, fallback: "hermes_state_unreadable"),
                message: message,
                sourcePath: hermesStateDBURL.path
            ))
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 50)
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)

        guard validateHermesSchema(db: db, warnings: &warnings) else {
            return []
        }

        let messageLimitPerSession = 12
        let recentMessageWindow = max(limit * messageLimitPerSession, 200)
        let sql = """
        WITH recent_messages AS (
            SELECT session_id, timestamp
            FROM messages
            WHERE timestamp IS NOT NULL
            ORDER BY timestamp DESC
            LIMIT ?
        ),
        recent_message_sessions AS (
            SELECT session_id, MAX(timestamp) AS last_message_at
            FROM recent_messages
            GROUP BY session_id
        ),
        session_rows AS (
            SELECT
                s.id AS id,
                s.title AS title,
                s.cwd AS cwd,
                s.git_repo_root AS git_repo_root,
                s.started_at AS started_at,
                s.ended_at AS ended_at,
                s.end_reason AS end_reason,
                COALESCE(r.last_message_at, s.ended_at, s.started_at) AS last_updated_at
            FROM sessions s
            LEFT JOIN recent_message_sessions r ON r.session_id = s.id
        )
        SELECT id, title, cwd, git_repo_root, started_at, ended_at, end_reason, last_updated_at
        FROM session_rows
        ORDER BY last_updated_at DESC
        LIMIT ?
        """

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            warnings.append(CoreWarning(
                code: sqliteWarningCode(prepareResult, db: db, fallback: "hermes_schema_mismatch"),
                message: "Hermes state schema did not match the expected sessions/messages contract.",
                sourcePath: hermesStateDBURL.path
            ))
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(recentMessageWindow))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var sessions: [AgentSessionSummary] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                guard let row = hermesSessionRow(from: statement) else {
                    warnings.append(CoreWarning(
                        code: "hermes_row_unreadable",
                        message: "A Hermes session row could not be mapped into dashboard metadata.",
                        sourcePath: hermesStateDBURL.path
                    ))
                    continue
                }

                let messages = loadHermesMessageCandidates(
                    db: db,
                    sessionID: row.id,
                    limit: messageLimitPerSession,
                    warnings: &warnings
                )
                guard let session = hermesSession(from: row, messages: messages) else {
                    warnings.append(CoreWarning(
                        code: "hermes_row_unreadable",
                        message: "A Hermes session row could not be mapped into dashboard metadata.",
                        sourcePath: hermesStateDBURL.path
                    ))
                    continue
                }
                sessions.append(session)
                continue
            }

            if stepResult == SQLITE_DONE {
                break
            }

            warnings.append(CoreWarning(
                code: sqliteWarningCode(stepResult, db: db, fallback: "hermes_state_unreadable"),
                message: sqliteMessage(db, fallback: "Hermes session rows could not be read."),
                sourcePath: hermesStateDBURL.path
            ))
            break
        }

        return sessions
    }

    private func validateHermesSchema(db: OpaquePointer, warnings: inout [CoreWarning]) -> Bool {
        guard let schemaVersion = sqliteSingleInt(db: db, sql: "SELECT version FROM schema_version LIMIT 1") else {
            warnings.append(CoreWarning(
                code: "hermes_schema_mismatch",
                message: "Hermes state schema_version table is missing or unreadable.",
                sourcePath: hermesStateDBURL.path
            ))
            return false
        }

        let sessionColumns = sqliteColumns(db: db, table: "sessions")
        let messageColumns = sqliteColumns(db: db, table: "messages")
        let requiredSessionColumns: Set<String> = ["id", "started_at", "ended_at", "end_reason", "title", "cwd", "git_repo_root"]
        let requiredMessageColumns: Set<String> = ["session_id", "timestamp", "role", "content", "tool_name"]
        guard
            schemaVersion >= 16,
            requiredSessionColumns.isSubset(of: sessionColumns),
            requiredMessageColumns.isSubset(of: messageColumns)
        else {
            warnings.append(CoreWarning(
                code: "hermes_schema_mismatch",
                message: "Hermes state schema does not match the v1 sessions/messages contract.",
                sourcePath: hermesStateDBURL.path
            ))
            return false
        }
        return true
    }

    private func hermesSessionRow(from statement: OpaquePointer) -> HermesSessionRow? {
        guard let sessionID = sqliteText(statement, 0) else { return nil }
        let title = sqliteText(statement, 1)
        let cwd = sqliteText(statement, 2)
        let gitRepoRoot = sqliteText(statement, 3)
        let startedAt = sqliteOptionalDouble(statement, 4)
        let endedAt = sqliteOptionalDouble(statement, 5)
        let endReason = sqliteText(statement, 6)
        guard let updatedAt = sqliteOptionalDouble(statement, 7) ?? endedAt ?? startedAt else { return nil }
        return HermesSessionRow(
            id: sessionID,
            title: title,
            cwd: cwd,
            gitRepoRoot: gitRepoRoot,
            startedAt: startedAt,
            endedAt: endedAt,
            endReason: endReason,
            lastUpdatedAt: updatedAt
        )
    }

    private func loadHermesMessageCandidates(
        db: OpaquePointer,
        sessionID: String,
        limit: Int,
        warnings: inout [CoreWarning]
    ) -> [HermesMessageCandidate] {
        let sql = """
        SELECT role, SUBSTR(content, 1, 4096) AS content, tool_name, timestamp
        FROM messages
        WHERE session_id = ?
          AND (
            (content IS NOT NULL AND TRIM(content) != '')
            OR (tool_name IS NOT NULL AND TRIM(tool_name) != '')
          )
        ORDER BY timestamp DESC
        LIMIT ?
        """

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            warnings.append(CoreWarning(
                code: sqliteWarningCode(prepareResult, db: db, fallback: "hermes_messages_unreadable"),
                message: sqliteMessage(db, fallback: "Hermes message rows could not be prepared."),
                sourcePath: hermesStateDBURL.path
            ))
            return []
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionID, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var candidates: [HermesMessageCandidate] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                let timestamp = sqliteOptionalDouble(statement, 3) ?? 0
                candidates.append(HermesMessageCandidate(
                    role: sqliteText(statement, 0),
                    content: sqliteText(statement, 1),
                    toolName: sqliteText(statement, 2),
                    timestamp: timestamp
                ))
                continue
            }
            if stepResult == SQLITE_DONE {
                break
            }
            warnings.append(CoreWarning(
                code: sqliteWarningCode(stepResult, db: db, fallback: "hermes_messages_unreadable"),
                message: sqliteMessage(db, fallback: "Hermes message rows could not be read."),
                sourcePath: hermesStateDBURL.path
            ))
            break
        }
        return candidates
    }

    private func hermesSession(from row: HermesSessionRow, messages: [HermesMessageCandidate]) -> AgentSessionSummary? {
        let project = hermesProjectPath(cwd: row.cwd, gitRepoRoot: row.gitRepoRoot)
        let projectPath = project.path
        let projectName = projectPath.map(Self.displayName(forPath:)) ?? "Unassigned"
        let updatedAt = dateFromHermesTimestamp(row.lastUpdatedAt)

        return AgentSessionSummary(
            agentKind: .hermes,
            sourcePath: hermesStateDBURL.path,
            title: hermesDisplayTitle(row: row, messages: messages),
            instanceID: shortID(row.id),
            projectPath: projectPath,
            projectName: projectName,
            lastUpdatedAt: updatedAt,
            statusHint: status(for: updatedAt, wasModifiedSinceLastScan: false, isKnownRunning: false),
            projectRootEvidence: project.evidence
        )
    }

    private func hermesDisplayTitle(row: HermesSessionRow, messages: [HermesMessageCandidate]) -> String {
        for candidate in messages.sorted(by: { $0.timestamp > $1.timestamp }) {
            if let snippet = hermesActivitySnippet(from: candidate) {
                return snippet
            }
        }
        return usefulHermesTitle(row.title) ?? "Hermes session \(shortID(row.id))"
    }

    private func hermesActivitySnippet(from candidate: HermesMessageCandidate) -> String? {
        if candidate.role?.lowercased() == "system" {
            return nil
        }

        if let toolName = candidate.toolName?.lowercased(), isGenericHermesToolName(toolName) {
            if let content = candidate.content?.nonEmptyTrimmed {
                return hermesCommandActivitySnippet(content)
            }
            return nil
        }

        if let content = candidate.content,
           let snippet = cleanActivity(content)
        {
            return snippet
        }

        if let toolName = candidate.toolName,
           !isGenericHermesToolName(toolName)
        {
            return toolCallSnippet(name: toolName, arguments: candidate.content)
        }

        return nil
    }

    private func hermesCommandActivitySnippet(_ content: String) -> String? {
        if let object = argumentsObject(from: content),
           let command = object["cmd"] as? String ?? object["command"] as? String
        {
            return cleanActivity(commandActivitySnippet(command))
        }

        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksCommandLike(trimmed) else { return nil }
        return cleanActivity(commandActivitySnippet(trimmed))
    }

    private func usefulHermesTitle(_ title: String?) -> String? {
        guard let candidate = usefulTitle(title) else { return nil }
        let lowercased = candidate.lowercased()
        guard !["untitled", "new session", "hermes"].contains(lowercased) else { return nil }
        guard !looksDateLikeSessionTitle(candidate) else { return nil }
        return candidate
    }

    private func isGenericHermesToolName(_ toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["terminal", "shell", "bash", "sh", "command", "exec", "execute"].contains(normalized)
    }

    private func looksDateLikeSessionTitle(_ title: String) -> Bool {
        let compact = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let patterns = [
            #"^\d{8}(\s+in\s+progress)?$"#,
            #"^\d{4}-\d{2}-\d{2}(\s+in\s+progress)?$"#,
            #"^\d{4}/\d{2}/\d{2}(\s+in\s+progress)?$"#
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(compact.startIndex..., in: compact)
            return regex.firstMatch(in: compact, range: range) != nil
        }
    }

    private func looksCommandLike(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let prefixes = [
            "./", "bash ", "cargo ", "find ", "git ", "jq ", "make ", "node ",
            "npm ", "npx ", "open ", "osascript ", "pkill ", "pnpm ", "python ",
            "rg ", "ruby ", "screencapture ", "sh ", "swift ", "swiftc ", "tail ",
            "xcodebuild", "yarn "
        ]
        return prefixes.contains { text.hasPrefix($0) } || text.contains(" xcodebuild ")
    }

    private func hermesProjectPath(cwd: String?, gitRepoRoot: String?) -> (path: String?, evidence: String?) {
        let candidates = [
            (gitRepoRoot, "git_repo_root metadata"),
            (cwd, "cwd metadata")
        ]

        for (candidate, evidence) in candidates {
            guard
                let path = candidate?.nonEmptyTrimmed,
                path != "/",
                fileManager.fileExists(atPath: path)
            else {
                continue
            }
            return (path, evidence)
        }
        return (nil, nil)
    }

    private func dateFromHermesTimestamp(_ timestamp: Double) -> Date {
        if timestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1_000)
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func sqliteColumns(db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqliteText(statement, 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func sqliteSingleInt(db: OpaquePointer, sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func sqliteOptionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func sqliteWarningCode(_ result: Int32, db: OpaquePointer?, fallback: String) -> String {
        let code = db.map { sqlite3_extended_errcode($0) } ?? result
        if code == SQLITE_BUSY || code == SQLITE_LOCKED || (code & 0xFF) == SQLITE_BUSY || (code & 0xFF) == SQLITE_LOCKED {
            return "hermes_state_busy"
        }
        return fallback
    }

    private func sqliteMessage(_ db: OpaquePointer?, fallback: String) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return fallback }
        let text = String(cString: message)
        return text.isEmpty ? fallback : text
    }

    private static func sessionPrioritySort(_ lhs: AgentSessionSummary, _ rhs: AgentSessionSummary) -> Bool {
        if lhs.statusHint.sortRank != rhs.statusHint.sortRank {
            return lhs.statusHint.sortRank < rhs.statusHint.sortRank
        }
        return lhs.lastUpdatedAt > rhs.lastUpdatedAt
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
        wasModifiedSinceLastScan: Bool,
        activeCodexProjects: [String: String],
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

        let headWindow = UInt64(64 * 1024)
        let tailWindow = UInt64(16 * 1024)
        let headData = handle.readData(ofLength: Int(headWindow))
        let fileLength = (try? handle.seekToEnd()) ?? 0
        let tailOffset = fileLength > tailWindow ? fileLength - tailWindow : 0
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
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines.prefix(50) {
            guard let object = decodeObject(line) else {
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

        if shouldReplaceSessionID(sessionID), let fileConversationID = conversationID(in: url) {
            sessionID = fileConversationID
        }

        if kind == .codex,
           let sessionID,
           let activeProject = activeCodexProjects[sessionID],
           !activeProject.isEmpty
        {
            cwd = cwd == "/" ? activeProject : cwd ?? activeProject
        }

        let recentActivities = lines.reversed().prefix(40).compactMap { line -> String? in
            guard let object = decodeObject(line) else { return nil }
            return activitySnippet(in: object)
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
        let isKnownRunning = kind == .codex && sessionID.map { activeCodexProjects[$0] != nil } == true
        let status = status(
            for: modified,
            wasModifiedSinceLastScan: wasModifiedSinceLastScan,
            isKnownRunning: isKnownRunning
        )
        let latestActivity = status == .inProgress
            ? recentActivities.first { !$0.hasPrefix("Finished:") } ?? recentActivities.first
            : recentActivities.first

        return AgentSessionSummary(
            agentKind: kind,
            sourcePath: url.path,
            title: latestActivity ?? usefulTitle(title) ?? fallbackTitle,
            instanceID: sessionID.map(shortID),
            projectPath: projectPath,
            projectName: projectName,
            lastUpdatedAt: modified,
            statusHint: status,
            projectRootEvidence: projectPath == cwd ? "cwd metadata" : "source path"
        )
    }

    private func loadActiveCodexProjects(warnings: inout [CoreWarning]) -> [String: String] {
        guard fileManager.fileExists(atPath: codexProcessStateURL.path) else {
            return [:]
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
            return [:]
        }

        var projects: [String: String] = [:]
        for entry in array {
            guard
                let pid = intValue(entry["osPid"]),
                isProcessAlive(pid),
                let conversationID = entry["conversationId"] as? String
            else {
                continue
            }
            let cwd = (entry["cwd"] as? String).flatMap { $0 == "/" ? nil : $0 } ?? ""
            if projects[conversationID, default: ""].isEmpty || !cwd.isEmpty {
                projects[conversationID] = cwd
            }
        }
        return projects
    }

    private func decodeObject(_ line: String) -> [String: Any]? {
        if line.utf8.count > 24 * 1024,
           !line.contains(#""type":"session_meta""#),
           !line.contains(#""type":"turn_context""#)
        {
            return nil
        }
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

    private func activitySnippet(in object: [String: Any]) -> String? {
        if let payload = object["payload"] as? [String: Any],
           let snippet = codexActivitySnippet(in: payload)
        {
            return snippet
        }

        if let message = object["message"] as? [String: Any],
           let snippet = messageActivitySnippet(message)
        {
            return snippet
        }

        if let snippet = promptSnippet(in: object) {
            return snippet
        }

        if let lastPrompt = object["lastPrompt"] as? String {
            return cleanActivity(lastPrompt)
        }

        if let aiTitle = object["aiTitle"] as? String {
            return cleanActivity(aiTitle)
        }

        if let type = object["type"] as? String,
           type == "queue-operation",
           let content = object["content"] as? String
        {
            return cleanActivity(content)
        }

        return nil
    }

    private func codexActivitySnippet(in payload: [String: Any]) -> String? {
        guard let type = payload["type"] as? String else {
            return messageActivitySnippet(payload)
        }

        switch type {
        case "message":
            return messageActivitySnippet(payload)
        case "function_call", "custom_tool_call":
            return toolCallSnippet(name: payload["name"] as? String, arguments: payload["arguments"] ?? payload["input"])
        case "task_complete":
            if let message = payload["last_agent_message"] as? String {
                if isAdministrativeResult(message) {
                    return nil
                }
                return cleanActivity("Finished: \(message)")
            }
            return "Finished task"
        case "patch_apply_end":
            if let success = payload["success"] as? Bool, success {
                return "Applied code edits"
            }
            return "Patch failed"
        default:
            return nil
        }
    }

    private func messageActivitySnippet(_ message: [String: Any]) -> String? {
        if let role = message["role"] as? String, role == "system" {
            return nil
        }

        if let content = message["content"] as? String {
            return cleanActivity(content)
        }

        if let content = message["content"] as? [[String: Any]] {
            for item in content.reversed() {
                if let snippet = contentItemSnippet(item) {
                    return snippet
                }
            }
        }

        return nil
    }

    private func contentItemSnippet(_ item: [String: Any]) -> String? {
        let type = item["type"] as? String
        if type == "input_image" || type == "image" || type == "tool_result" {
            return nil
        }

        if let text = item["text"] as? String ?? item["input_text"] as? String {
            return cleanActivity(text)
        }

        if type == "tool_use" {
            return toolCallSnippet(name: item["name"] as? String, arguments: item["input"])
        }

        return nil
    }

    private func toolCallSnippet(name: String?, arguments: Any?) -> String? {
        let toolName = name ?? "tool"
        if toolName == "write_stdin" {
            return nil
        }

        if toolName == "view_image" {
            return "Reviewing screenshot"
        }

        if toolName == "ask_oracle" || toolName.contains("oracle") {
            return "Consulting context oracle"
        }

        if toolName.hasPrefix("agent_") {
            if let object = argumentsObject(from: arguments),
               let operation = object["op"] as? String
            {
                if operation == "start" {
                    return "Starting delegated agent"
                }
                if operation == "wait" {
                    return "Waiting for delegated agent"
                }
            }
            return "Coordinating delegated agent"
        }

        if let object = argumentsObject(from: arguments) {
            if let command = object["cmd"] as? String ?? object["command"] as? String {
                return cleanActivity(commandActivitySnippet(command))
            }

            if let path = object["path"] as? String ?? object["file_path"] as? String {
                return cleanActivity("\(toolName) \(URL(fileURLWithPath: path).lastPathComponent)")
            }

            if let description = object["description"] as? String {
                return cleanActivity("\(toolName): \(description)")
            }

            if toolName == "apply_patch" {
                return "Apply code edits"
            }
        }

        if let string = arguments as? String {
            if toolName == "apply_patch" {
                return "Apply code edits"
            }
            return cleanActivity("\(toolName): \(string)")
        }

        return cleanActivity("Use \(toolName)")
    }

    private func argumentsObject(from arguments: Any?) -> [String: Any]? {
        if let object = arguments as? [String: Any] {
            return object
        }

        guard
            let string = arguments as? String,
            let data = string.data(using: .utf8)
        else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func commandActivitySnippet(_ command: String) -> String {
        let firstLine = command
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? command
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("xcodebuild") || trimmed.contains(" xcodebuild ") {
            return "Building app"
        }
        if trimmed.hasPrefix("sleep ") {
            return "Waiting"
        }
        if trimmed.hasPrefix("git ") {
            return gitActivitySnippet(trimmed)
        }
        if trimmed.hasPrefix("screencapture ") {
            return "Capturing screenshot"
        }
        if trimmed.hasPrefix("open ") || trimmed.hasPrefix("osascript ") || trimmed.hasPrefix("pkill ") {
            return "Managing app launch"
        }
        if trimmed.hasPrefix("find ") || trimmed.hasPrefix("tail ") || trimmed.hasPrefix("jq ") || trimmed.hasPrefix("rg ") {
            return "Inspecting session files"
        }
        return "Running \(trimmed)"
    }

    private func gitActivitySnippet(_ command: String) -> String {
        if command.hasPrefix("git log ") {
            return "Inspecting git history"
        }
        if command.hasPrefix("git diff") {
            return "Reviewing code changes"
        }
        if command.hasPrefix("git status") {
            return "Checking git status"
        }
        if command.hasPrefix("git push") {
            return "Pushing branch"
        }
        if command.hasPrefix("git commit") {
            return "Committing changes"
        }
        if command.hasPrefix("git add") {
            return "Staging changes"
        }
        return command
    }

    private func isAdministrativeResult(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return compact == #"{"outcome":"allow"}"# || compact == #"{"outcome":"deny"}"#
    }

    private func normalizedProjectPath(for kind: AgentKind, cwd: String?, fileURL: URL) -> String? {
        let usableCwd = cwd == "/" ? nil : cwd

        if let usableCwd, fileManager.fileExists(atPath: usableCwd) {
            return usableCwd
        }

        guard kind == .claudeCode else {
            return usableCwd
        }

        let encodedProject = fileURL.deletingLastPathComponent().lastPathComponent
        let decoded = decodeClaudeProjectPath(encodedProject)
        return decoded.isEmpty ? usableCwd : decoded
    }

    private func decodeClaudeProjectPath(_ encoded: String) -> String {
        if encoded.hasPrefix("-") {
            return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
        }
        return encoded.replacingOccurrences(of: "-", with: "/")
    }

    private func status(
        for modified: Date,
        wasModifiedSinceLastScan: Bool,
        isKnownRunning: Bool
    ) -> StatusHint {
        if isKnownRunning || wasModifiedSinceLastScan {
            return .inProgress
        }

        let age = Date().timeIntervalSince(modified)
        if age < 20 { return .inProgress }
        if age < 5 * 60 { return .justFinished }
        if age < 2 * 60 * 60 { return .done }
        if age < 24 * 60 * 60 { return .stale }
        return .unknown
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let result = Darwin.kill(pid_t(pid), 0)
        return result == 0 || errno == EPERM
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
        cleanActivity(prompt)
    }

    private func cleanActivity(_ prompt: String) -> String? {
        let cleaned = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasPrefix("<environment_context>") || cleaned.hasPrefix("<system") {
            return nil
        }
        if cleaned.hasPrefix("<image ") || cleaned.contains("data:image") {
            return nil
        }
        return cleaned.count > 92 ? String(cleaned.prefix(89)) + "..." : cleaned
    }

    private func shortID(_ id: String) -> String {
        id.count > 10 ? String(id.prefix(8)) : id
    }

    private func shouldReplaceSessionID(_ id: String?) -> Bool {
        guard let id else { return true }
        return conversationID(in: id) == nil
    }

    private func conversationID(in url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        return conversationID(in: filename)
    }

    private func conversationID(in text: String) -> String? {
        let pattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else {
            return nil
        }
        return String(text[range])
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
    let projectPath: String?
    let title: String
    let instance: String
    let status: String
    let age: String
    let statusHint: StatusHint
    let lastUpdatedAt: Date
}

struct ProjectGroup {
    let project: String
    let inProgressCount: Int
    let justFinishedCount: Int
    let sourceSummary: String
    let environment: ProjectEnvironment
    let rows: [ActivityRow]
    let lastUpdatedAt: Date
    let priorityUpdatedAt: Date
    let topStatusRank: Int
}

struct ProjectEnvironment {
    let location: String
    let branch: String?
    let changedFiles: Int
    let insertions: Int
    let deletions: Int

    var isDirty: Bool {
        changedFiles > 0 || insertions > 0 || deletions > 0
    }
}

struct WidgetModel {
    let inProgressCount: Int
    let justFinishedCount: Int
    let doneCount: Int
    let sessionCount: Int
    let scannedFileCount: Int
    let recentFileCount: Int
    let groups: [ProjectGroup]
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
            .filter { $0.statusHint == .inProgress || $0.statusHint == .justFinished || $0.statusHint == .done }
            .map { session in
            ActivityRow(
                source: session.agentKind.displayName,
                project: session.projectName,
                projectPath: session.projectPath,
                title: session.title,
                instance: session.instanceID ?? "",
                status: session.statusHint.displayName,
                age: Self.relativeAge(since: session.lastUpdatedAt),
                statusHint: session.statusHint,
                lastUpdatedAt: session.lastUpdatedAt
            )
        }

        let groups = Dictionary(grouping: rows, by: \.project)
            .map { project, rows in
                let sortedRows = rows.sorted { lhs, rhs in
                    if lhs.statusHint.sortRank != rhs.statusHint.sortRank {
                        return lhs.statusHint.sortRank < rhs.statusHint.sortRank
                    }
                    return lhs.lastUpdatedAt > rhs.lastUpdatedAt
                }
                return ProjectGroup(
                    project: project,
                    inProgressCount: sortedRows.filter { $0.statusHint == .inProgress }.count,
                    justFinishedCount: sortedRows.filter { $0.statusHint == .justFinished }.count,
                    sourceSummary: Self.sourceSummary(for: sortedRows),
                    environment: GitEnvironmentReader.snapshot(for: sortedRows.compactMap(\.projectPath).first),
                    rows: sortedRows,
                    lastUpdatedAt: sortedRows.map(\.lastUpdatedAt).max() ?? .distantPast,
                    priorityUpdatedAt: sortedRows.first?.lastUpdatedAt ?? .distantPast,
                    topStatusRank: sortedRows.first?.statusHint.sortRank ?? StatusHint.unknown.sortRank
                )
            }
            .sorted { lhs, rhs in
                if lhs.topStatusRank != rhs.topStatusRank {
                    return lhs.topStatusRank < rhs.topStatusRank
                }
                if lhs.priorityUpdatedAt != rhs.priorityUpdatedAt {
                    return lhs.priorityUpdatedAt > rhs.priorityUpdatedAt
                }
                if lhs.justFinishedCount != rhs.justFinishedCount {
                    return lhs.justFinishedCount > rhs.justFinishedCount
                }
                if lhs.inProgressCount != rhs.inProgressCount {
                    return lhs.inProgressCount > rhs.inProgressCount
                }
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }

        self.init(
            inProgressCount: rows.filter { $0.statusHint == .inProgress }.count,
            justFinishedCount: rows.filter { $0.statusHint == .justFinished }.count,
            doneCount: rows.filter { $0.statusHint == .done }.count,
            sessionCount: rows.count,
            scannedFileCount: snapshot.scannedFileCount,
            recentFileCount: snapshot.recentFileCount,
            groups: groups,
            warningCount: snapshot.warnings.count,
            generatedAt: snapshot.generatedAt
        )
    }

    static func sourceSummary(for rows: [ActivityRow]) -> String {
        let counts = Dictionary(grouping: rows, by: \.source).mapValues(\.count)
        return counts
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { count in
                let label = count.value == 1 ? count.key : "\(count.key) x\(count.value)"
                return label
            }
            .joined(separator: ", ")
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

}

private enum GitEnvironmentReader {
    private static let cacheInterval: TimeInterval = 20
    private static var cache: [String: (snapshot: ProjectEnvironment, capturedAt: Date)] = [:]

    static func snapshot(for projectPath: String?) -> ProjectEnvironment {
        guard
            let projectPath,
            !projectPath.isEmpty,
            FileManager.default.fileExists(atPath: projectPath)
        else {
            return ProjectEnvironment(location: "Local", branch: nil, changedFiles: 0, insertions: 0, deletions: 0)
        }

        if
            let cached = cache[projectPath],
            Date().timeIntervalSince(cached.capturedAt) < cacheInterval
        {
            return cached.snapshot
        }

        guard let root = runGit(["-C", projectPath, "rev-parse", "--show-toplevel"]).nonEmptyTrimmed else {
            return ProjectEnvironment(location: "Local", branch: nil, changedFiles: 0, insertions: 0, deletions: 0)
        }

        if
            let cached = cache[root],
            Date().timeIntervalSince(cached.capturedAt) < cacheInterval
        {
            cache[projectPath] = cached
            return cached.snapshot
        }

        let branch = runGit(["-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"]).nonEmptyTrimmed
            ?? runGit(["-C", root, "rev-parse", "--short", "HEAD"]).nonEmptyTrimmed
        let status = runGit(["-C", root, "status", "--porcelain=v1", "--untracked-files=no"])
        let shortstat = runGit(["-C", root, "diff", "--shortstat", "HEAD"])

        let snapshot = ProjectEnvironment(
            location: "Local",
            branch: branch,
            changedFiles: status.split(separator: "\n", omittingEmptySubsequences: true).count,
            insertions: captureInt(in: shortstat, pattern: #"([0-9,]+) insertion"#),
            deletions: captureInt(in: shortstat, pattern: #"([0-9,]+) deletion"#)
        )
        let entry = (snapshot: snapshot, capturedAt: Date())
        cache[projectPath] = entry
        cache[root] = entry
        return snapshot
    }

    private static func runGit(_ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks"] + arguments
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        guard process.terminationStatus == 0 else {
            return ""
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func captureInt(in text: String, pattern: String) -> Int {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else {
            return 0
        }

        let digits = text[range].replacingOccurrences(of: ",", with: "")
        return Int(digits) ?? 0
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class DashboardWidgetView: NSView {
    private struct Layout {
        let bounds: NSRect
        let contentLeft: CGFloat = 20
        let contentRightInset: CGFloat = 18
        let rightColumnWidth: CGFloat = 112
        let ageColumnWidth: CGFloat = 34
        let columnGap: CGFloat = 8

        var contentRight: CGFloat { bounds.width - contentRightInset }
        var rightColumnX: CGFloat { contentRight - rightColumnWidth }
        var ageColumnX: CGFloat { contentRight - ageColumnWidth }

        func rightColumnRect(y: CGFloat, height: CGFloat) -> NSRect {
            NSRect(x: rightColumnX, y: y, width: rightColumnWidth, height: height)
        }

        func ageColumnRect(y: CGFloat, height: CGFloat) -> NSRect {
            NSRect(x: ageColumnX, y: y, width: ageColumnWidth, height: height)
        }

        func leadingRect(x: CGFloat, y: CGFloat, height: CGFloat, beforeRightRail: Bool = true) -> NSRect {
            let railX = beforeRightRail ? rightColumnX : ageColumnX
            return NSRect(x: x, y: y, width: max(40, railX - columnGap - x), height: height)
        }
    }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
        drawGroups(model)
        drawFooter(model)
    }

    private func drawChrome(context: CGContext) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        context.addPath(path)
        context.setFillColor(cgColor(for: Palette.panelFill))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(cgColor(for: Palette.hairline))
        context.setLineWidth(1)
        context.strokePath()
    }

    private func drawHeader(_ model: WidgetModel) {
        let layout = Layout(bounds: bounds)
        drawText("Floaty", rect: NSRect(x: layout.contentLeft, y: 18, width: 95, height: 24), font: .systemFont(ofSize: 17, weight: .semibold), color: Palette.primaryText)
        drawText("local sessions", rect: NSRect(x: layout.contentLeft, y: 40, width: 120, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: Palette.secondaryText)

        drawRightText(headerStatusLabel(model), rect: layout.rightColumnRect(y: 18, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: headerStatusColor(model))
        drawHeaderSecondaryStatus(model, layout: layout)
        drawRule(y: 66)
    }

    private func drawGroups(_ model: WidgetModel) {
        var y: CGFloat = 78
        var drawnRows = 0
        let footerTop = bounds.height - 42
        let activeGroupCount = model.groups.filter { $0.inProgressCount > 0 }.count
        for group in visibleGroups(model) {
            guard y + 42 < footerTop else { return }
            drawGroupHeader(group, y: y)
            y += 42

            for row in visibleRows(for: group, activeGroupCount: activeGroupCount) {
                guard drawnRows < 6, y + 44 < footerTop else { return }
                drawRow(row, y: y)
                y += 44
                drawnRows += 1
            }
        }
    }

    private func visibleGroups(_ model: WidgetModel) -> [ProjectGroup] {
        let runningGroups = model.groups.filter { $0.inProgressCount > 0 }
        let otherGroups = model.groups.filter { $0.inProgressCount == 0 }
        return Array((runningGroups + otherGroups).prefix(4))
    }

    private func visibleRows(for group: ProjectGroup, activeGroupCount: Int) -> [ActivityRow] {
        let runningRows = group.rows.filter { $0.statusHint == .inProgress }
        let justFinishedRows = group.rows.filter { $0.statusHint == .justFinished }
        let doneRows = group.rows.filter { $0.statusHint == .done }

        guard !runningRows.isEmpty else {
            return Array((justFinishedRows + doneRows).prefix(1))
        }

        let runningLimit = activeGroupCount >= 3 ? 1 : 2
        var rows = Array(runningRows.prefix(runningLimit))
        let finishedLimit = activeGroupCount <= 1 ? max(0, 3 - rows.count) : max(0, 2 - rows.count)
        if finishedLimit > 0 {
            rows.append(contentsOf: justFinishedRows.prefix(finishedLimit))
        }
        return rows
    }

    private func drawGroupHeader(_ group: ProjectGroup, y: CGFloat) {
        let layout = Layout(bounds: bounds)
        drawText(group.project, rect: layout.leadingRect(x: layout.contentLeft, y: y, height: 18), font: .systemFont(ofSize: 13, weight: .bold), color: Palette.primaryText)
        drawRightText(groupStatusLabel(group), rect: layout.rightColumnRect(y: y + 3, height: 15), font: .systemFont(ofSize: 11, weight: .semibold), color: groupStatusColor(group))

        let branch = group.environment.branch ?? "no git"
        let context = "\(group.sourceSummary)  \(group.environment.location)  \(branch)"
        drawText(context, rect: layout.leadingRect(x: layout.contentLeft, y: y + 18, height: 15), font: .systemFont(ofSize: 10.5, weight: .medium), color: Palette.secondaryText)
        drawChangeSummary(group.environment, y: y + 18, layout: layout)
    }

    private func drawRow(_ row: ActivityRow, y: CGFloat) {
        let layout = Layout(bounds: bounds)
        let dotColor = statusColor(row.statusHint)
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 24, y: y + 12, width: 7, height: 7)).fill()

        drawText(row.title, rect: layout.leadingRect(x: 42, y: y + 3, height: 17, beforeRightRail: false), font: .systemFont(ofSize: 12, weight: .medium), color: Palette.primaryText)
        drawRightText(row.age, rect: layout.ageColumnRect(y: y + 3, height: 17), font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: Palette.secondaryText)

        let detail = row.instance.isEmpty ? row.status : "\(row.instance)  \(row.status)"
        drawText(detail, rect: layout.leadingRect(x: 42, y: y + 23, height: 15), font: .monospacedSystemFont(ofSize: 10.5, weight: .medium), color: statusDetailColor(row.statusHint))
        drawRule(y: y + 43)
    }

    private func headerStatusLabel(_ model: WidgetModel) -> String {
        if model.inProgressCount > 0 {
            return "\(model.inProgressCount) running"
        }
        if model.justFinishedCount > 0 {
            return "\(model.justFinishedCount) finished"
        }
        return "\(model.doneCount) done"
    }

    private func headerStatusColor(_ model: WidgetModel) -> NSColor {
        if model.inProgressCount > 0 { return Palette.green }
        if model.justFinishedCount > 0 { return Palette.amber }
        return Palette.mutedText
    }

    private func drawHeaderSecondaryStatus(_ model: WidgetModel, layout: Layout) {
        drawRightText(
            headerSecondaryLabel(model),
            rect: layout.rightColumnRect(y: 38, height: 16),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: Palette.secondaryText
        )
    }

    private func headerSecondaryLabel(_ model: WidgetModel) -> String {
        if model.inProgressCount > 0 && model.justFinishedCount > 0 {
            return "\(model.justFinishedCount) finished / \(model.sessionCount) total"
        }
        return "\(model.sessionCount) total"
    }

    private func groupStatusLabel(_ group: ProjectGroup) -> String {
        if group.inProgressCount > 0 {
            return "\(group.inProgressCount) running"
        }
        if group.justFinishedCount > 0 {
            return "\(group.justFinishedCount) finished"
        }
        return "\(group.rows.count) done"
    }

    private func groupStatusColor(_ group: ProjectGroup) -> NSColor {
        if group.inProgressCount > 0 { return Palette.green }
        if group.justFinishedCount > 0 { return Palette.amber }
        return Palette.secondaryText
    }

    private func statusColor(_ status: StatusHint) -> NSColor {
        switch status {
        case .inProgress: return Palette.green
        case .justFinished: return Palette.amber
        case .done: return Palette.mutedText
        case .stale, .unknown: return Palette.tertiaryText
        }
    }

    private func statusDetailColor(_ status: StatusHint) -> NSColor {
        switch status {
        case .inProgress: return Palette.green
        case .justFinished: return Palette.amber
        case .done, .stale, .unknown: return Palette.secondaryText
        }
    }

    private func drawFooter(_ model: WidgetModel) {
        let layout = Layout(bounds: bounds)
        let y = bounds.height - 30
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        drawText("updated \(formatter.string(from: model.generatedAt))", rect: layout.leadingRect(x: layout.contentLeft, y: y, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: Palette.secondaryText)
        if model.warningCount > 0 {
            drawRightText("\(model.warningCount) warnings", rect: layout.rightColumnRect(y: y, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: Palette.warning)
        }
    }

    private func drawChangeSummary(_ environment: ProjectEnvironment, y: CGFloat, layout: Layout) {
        if environment.insertions > 0 || environment.deletions > 0 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
            let gap: CGFloat = 8
            let deletions = "-\(Self.formattedCount(environment.deletions))"
            let deletionWidth = textWidth(deletions, font: font)
            let insertions = "+\(Self.formattedCount(environment.insertions))"
            let insertionWidth = textWidth(insertions, font: font)
            let totalWidth = insertionWidth + gap + deletionWidth
            guard totalWidth <= layout.rightColumnWidth else {
                let text = environment.changedFiles > 0 ? "\(environment.changedFiles) files" : "changes"
                drawRightText(text, rect: layout.rightColumnRect(y: y, height: 15), font: .systemFont(ofSize: 10.5, weight: .semibold), color: Palette.warning)
                return
            }
            let startX = layout.contentRight - totalWidth

            drawText(insertions, rect: NSRect(x: startX, y: y, width: insertionWidth, height: 15), font: font, color: Palette.green)
            drawText(deletions, rect: NSRect(x: startX + insertionWidth + gap, y: y, width: deletionWidth, height: 15), font: font, color: Palette.red)
            return
        }

        let text = environment.changedFiles > 0 ? "\(environment.changedFiles) files" : "clean"
        drawRightText(text, rect: layout.rightColumnRect(y: y, height: 15), font: .systemFont(ofSize: 10.5, weight: .semibold), color: environment.isDirty ? Palette.warning : Palette.secondaryText)
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

    private func drawRightText(_ text: String, rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingHead
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func cgColor(for color: NSColor) -> CGColor {
        var output = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            output = color.cgColor
        }
        return output
    }

    private static func formattedCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

private enum Palette {
    static let panelFill = adaptive(
        light: NSColor(calibratedWhite: 0.94, alpha: 0.90),
        dark: NSColor(calibratedWhite: 0.11, alpha: 0.88)
    )
    static let hairline = adaptive(
        light: NSColor(calibratedWhite: 0.26, alpha: 0.20),
        dark: NSColor(calibratedWhite: 1.00, alpha: 0.18)
    )
    static let primaryText = NSColor.labelColor
    static let secondaryText = adaptive(
        light: NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.34, alpha: 0.96),
        dark: NSColor(calibratedWhite: 0.82, alpha: 0.94)
    )
    static let tertiaryText = adaptive(
        light: NSColor(calibratedRed: 0.33, green: 0.37, blue: 0.44, alpha: 0.88),
        dark: NSColor(calibratedWhite: 0.70, alpha: 0.90)
    )
    static let mutedText = adaptive(
        light: NSColor(calibratedRed: 0.46, green: 0.51, blue: 0.58, alpha: 0.95),
        dark: NSColor(calibratedWhite: 0.58, alpha: 0.92)
    )
    static let green = adaptive(
        light: NSColor(calibratedRed: 0.00, green: 0.62, blue: 0.32, alpha: 1),
        dark: NSColor(calibratedRed: 0.25, green: 0.86, blue: 0.50, alpha: 1)
    )
    static let amber = adaptive(
        light: NSColor(calibratedRed: 0.80, green: 0.45, blue: 0.00, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.25, alpha: 1)
    )
    static let red = adaptive(
        light: NSColor(calibratedRed: 0.80, green: 0.12, blue: 0.16, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.33, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor.systemOrange,
        dark: NSColor.systemYellow
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }
}
