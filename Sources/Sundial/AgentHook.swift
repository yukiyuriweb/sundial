import Foundation
import SQLite3

/// `Sundial agent <tool>`: run from a coding agent's hooks with the hook's JSON on stdin. It records how long
/// each turn runs, from your prompt until the agent stops, and writes `{}` to stdout as the hooks expect.
///
/// - Claude Code and Codex send `session_id`, `cwd` and `hook_event_name`
/// - Antigravity CLI sends `conversationId`, `cwd` and `hookEventName`
///
/// `UserPromptSubmit` starts a turn, `Stop` and `SessionEnd` end it, and any other event (tool use, a model
/// call) moves the turn's end forward, so a turn cut short without `Stop` ends at its last sign of activity.
/// Hooks can run side by side (Claude Code runs them asynchronously), so each one reads and writes in a single
/// write transaction.
func runAgentHook(tool: String) {
    defer { print("{}") }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let session = (json["session_id"] ?? json["conversationId"]) as? String,
          let event = (json["hook_event_name"] ?? json["hookEventName"]) as? String,
          let db = openDatabase() else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
    defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
    let cwd = json["cwd"] as? String
    let now = Date().timeIntervalSince1970

    func run(_ sql: String, _ values: [Any?]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        sqlite3_step(stmt)
    }

    // The session's turn still running, if any
    var open: (id: Int64, end: Double)?
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT id, end FROM agent_spans WHERE tool = ? AND session = ? AND closed = 0 ORDER BY id DESC LIMIT 1",
                          -1, &stmt, nil) == SQLITE_OK {
        bind(stmt, [tool, session])
        if sqlite3_step(stmt) == SQLITE_ROW {
            open = (sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1))
        }
    }
    sqlite3_finalize(stmt)

    func startTurn() {
        if let open { run("UPDATE agent_spans SET closed = 1 WHERE id = ?", [open.id]) }
        run("INSERT INTO agent_spans (tool, session, project, cwd, start, end) VALUES (?, ?, ?, ?, ?, ?)",
            [tool, session, cwd.flatMap(gitProject(forPath:)), cwd.map(abbreviated), now, now])
    }

    switch event {
    case "UserPromptSubmit":
        startTurn()
    case "Stop", "SessionEnd":
        if let open { run("UPDATE agent_spans SET end = ?, closed = 1 WHERE id = ?", [now, open.id]) }
    default:
        // Antigravity CLI has no UserPromptSubmit hook here, so a turn it left without a Stop is closed once it
        // has been quiet for 15 minutes. Elsewhere the next prompt closes it, and a long tool run stays one turn.
        if let open, tool != "antigravity" || now - open.end < 15 * 60 {
            run("UPDATE agent_spans SET end = ? WHERE id = ?", [now, open.id])
        } else {
            startTurn()
        }
    }
}
