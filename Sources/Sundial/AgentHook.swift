import Foundation
import SQLite3

/// `Sundial agent <tool>`: run from a coding agent's hooks with the hook's JSON on stdin. It records how long
/// each turn runs, from your prompt until the agent stops, and writes `{}` to stdout as the hooks expect.
///
/// - Claude Code and Codex send `session_id`, `cwd` and `hook_event_name`
/// - Antigravity CLI sends `conversationId`, `cwd` and `hookEventName`
///
/// How events shape a turn:
/// - `UserPromptSubmit` starts one. Antigravity CLI doesn't send it, so there any event can start one.
/// - `PreToolUse` moves its end forward and marks a tool as running, so a long tool run stays in the turn.
/// - Other events (`PostToolUse`, Antigravity's `PreInvocation`) move its end forward. Unless a tool was
///   running, a gap of 10 minutes or more since the last event means the agent sat idle (a turn interrupted
///   without `Stop`, then work resumed), so a new turn starts instead.
/// - With no turn open, an event starts one, which keeps work going after `Stop` (another Stop hook may make
///   the agent continue) or after a lost `UserPromptSubmit`. A `PostToolUse` within seconds of `Stop` is the
///   finished turn's last hook arriving late, since hooks can run side by side, and is ignored.
/// - `Stop` ends the turn. `SessionEnd` only closes it, since it may come hours after the last activity.
///
/// Each call reads and writes in one write transaction, so hooks running side by side don't race.
func runAgentHook(tool: String) {
    defer { print("{}") }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let session = (json["session_id"] ?? json["conversationId"]) as? String,
          let event = (json["hook_event_name"] ?? json["hookEventName"]) as? String,
          let db = openDatabase() else { return }
    defer { sqlite3_close(db) }
    // Skipping one event beats racing another hook into a duplicate turn.
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
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

    // The session's latest turn: whether it is still open, when it last saw activity, and whether a tool is running
    var latest: (id: Int64, end: Double, closed: Bool, busy: Bool)?
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT id, end, closed, busy FROM agent_spans WHERE tool = ? AND session = ? ORDER BY id DESC LIMIT 1",
                          -1, &stmt, nil) == SQLITE_OK {
        bind(stmt, [tool, session])
        if sqlite3_step(stmt) == SQLITE_ROW {
            latest = (sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1),
                      sqlite3_column_int(stmt, 2) != 0, sqlite3_column_int(stmt, 3) != 0)
        }
    }
    sqlite3_finalize(stmt)
    let open = latest.flatMap { $0.closed ? nil : $0 }
    let busy: Int64 = event == "PreToolUse" ? 1 : 0

    func startTurn() {
        if let open { run("UPDATE agent_spans SET closed = 1 WHERE id = ?", [open.id]) }
        run("INSERT INTO agent_spans (tool, session, project, cwd, start, end, busy) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [tool, session, cwd.flatMap(gitProject(forPath:)), cwd.map(abbreviated), now, now, busy])
    }

    switch event {
    case "UserPromptSubmit":
        startTurn()
    case "Stop":
        if let open { run("UPDATE agent_spans SET end = ?, closed = 1, busy = 0 WHERE id = ?", [now, open.id]) }
    case "SessionEnd":
        if let open { run("UPDATE agent_spans SET closed = 1, busy = 0 WHERE id = ?", [open.id]) }
    default:
        if let open {
            if open.busy || now - open.end < 10 * 60 {
                run("UPDATE agent_spans SET end = ?, busy = ? WHERE id = ?", [now, busy, open.id])
            } else {
                startTurn()
            }
        } else if event == "PostToolUse", let latest, now - latest.end < 10 {
            // The finished turn's last tool hook, arriving after its Stop
        } else {
            startTurn()
        }
    }
}
