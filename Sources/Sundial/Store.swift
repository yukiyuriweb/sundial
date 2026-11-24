import Foundation
import SQLite3

/// What was in front during one sample: the app, the project it belonged to, and the file, directory or page
struct Activity: Equatable {
    let bundle: String
    let app: String
    let project: String?
    let detail: String?
}

/// A stretch of time spent on one activity
struct Span {
    let start: Date
    let end: Date
    let bundle: String
    let app: String
    let project: String?
    let detail: String?

    func seconds(in range: Range<Date>) -> TimeInterval {
        max(0, min(end, range.upperBound).timeIntervalSince(max(start, range.lowerBound)))
    }
}

/// A stretch of one coding agent's turn: from your prompt until it stops
struct AgentSpan {
    let start: Date
    let end: Date
    let tool: String
    let project: String?

    func seconds(in range: Range<Date>) -> TimeInterval {
        max(0, min(end, range.upperBound).timeIntervalSince(max(start, range.lowerBound)))
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Opens ~/Library/Application Support/Sundial/sundial.sqlite, which the app and the agent hook command
/// (see AgentHook.swift) both write to
func openDatabase() -> OpaquePointer? {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sundial")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(dir.appendingPathComponent("sundial.sqlite").path, &db) == SQLITE_OK else {
        NSLog("Sundial couldn't open its database: %@", String(cString: sqlite3_errmsg(db)))
        return nil
    }
    sqlite3_busy_timeout(db, 2000)
    sqlite3_exec(db, """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS spans (
            id INTEGER PRIMARY KEY,
            start REAL NOT NULL,
            end REAL NOT NULL,
            bundle TEXT NOT NULL,
            app TEXT NOT NULL,
            project TEXT,
            detail TEXT
        );
        CREATE INDEX IF NOT EXISTS spans_end ON spans (end);
        CREATE TABLE IF NOT EXISTS agent_spans (
            id INTEGER PRIMARY KEY,
            tool TEXT NOT NULL,
            session TEXT NOT NULL,
            project TEXT,
            cwd TEXT,
            start REAL NOT NULL,
            end REAL NOT NULL,
            closed INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS agent_spans_end ON agent_spans (end);
        CREATE INDEX IF NOT EXISTS agent_spans_session ON agent_spans (tool, session);
        """, nil, nil, nil)
    return db
}

/// Binds Double, Int64, String and nil values to a statement's parameters in order
func bind(_ stmt: OpaquePointer?, _ values: [Any?]) {
    for (i, value) in values.enumerated() {
        let index = Int32(i + 1)
        switch value {
        case let v as Double: sqlite3_bind_double(stmt, index, v)
        case let v as Int64: sqlite3_bind_int64(stmt, index, v)
        case let v as String: sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
        default: sqlite3_bind_null(stmt, index)
        }
    }
}

/// Keeps spans in ~/Library/Application Support/Sundial/sundial.sqlite. Consecutive samples of the same
/// activity extend one row rather than adding a row each.
@MainActor
final class Store: ObservableObject {
    /// Bumped on every write so views know to reload
    @Published private(set) var revision = 0
    private var db: OpaquePointer?
    private var last: (id: Int64, activity: Activity, end: TimeInterval)?

    init() {
        db = openDatabase()
    }

    /// Credits the `interval` seconds up to `now` to the activity. It extends the latest span when that span
    /// is the same activity and ended at the previous sample; otherwise it starts a new one.
    func record(_ activity: Activity, at now: Date, interval: TimeInterval) {
        let t = now.timeIntervalSince1970
        if let last, last.activity == activity, t - last.end <= interval * 1.5 {
            run("UPDATE spans SET end = ? WHERE id = ?", [t, last.id])
            self.last?.end = t
        } else {
            run("INSERT INTO spans (start, end, bundle, app, project, detail) VALUES (?, ?, ?, ?, ?, ?)",
                [t - interval, t, activity.bundle, activity.app, activity.project, activity.detail])
            last = (sqlite3_last_insert_rowid(db), activity, t)
        }
    }

    func noteChanges() { revision += 1 }

    /// Spans that overlap the range
    func spans(in range: Range<Date>) -> [Span] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT start, end, bundle, app, project, detail FROM spans WHERE end > ? AND start < ? ORDER BY start",
                                 -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970])
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        var result: [Span] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(Span(start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                               end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                               bundle: text(2) ?? "", app: text(3) ?? "", project: text(4), detail: text(5)))
        }
        return result
    }

    /// Agent turns that overlap the range
    func agentSpans(in range: Range<Date>) -> [AgentSpan] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT start, end, tool, project FROM agent_spans WHERE end > ? AND start < ? ORDER BY start",
                                 -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970])
        var result: [AgentSpan] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(AgentSpan(start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                                    end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                    tool: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                                    project: sqlite3_column_text(stmt, 3).map { String(cString: $0) }))
        }
        return result
    }

    func totalSeconds(in range: Range<Date>) -> TimeInterval {
        spans(in: range).reduce(0) { $0 + $1.seconds(in: range) }
    }

    private func run(_ sql: String, _ values: [Any?]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("Sundial couldn't write: %@", String(cString: sqlite3_errmsg(db)))
        }
    }
}
