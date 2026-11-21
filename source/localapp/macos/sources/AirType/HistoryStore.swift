import Foundation
import SQLite3

struct VoiceHistoryRecord: Identifiable, Equatable {
    var id: Int64
    var createdAt: Date
    var asrText: String
    var llmText: String?
    var asrBackend: String
    var asrEngine: String
    var asrModel: String
    var asrEndpoint: String?
    var llmEnabled: Bool
    var llmModel: String?
    var llmEndpoint: String?
    var result: String
    var durationMs: Int?
    var audioPath: String?
}

/// How many history rows were added in each window. The windows overlap:
/// today is included in this week, this week in this month, and so on.
struct HistorySummary: Equatable {
    var today = 0
    var thisWeek = 0
    var thisMonth = 0
    var threeMonths = 0
    var sixMonths = 0
    var oneYear = 0
    var total = 0
}

struct ObsidianImportRecord: Identifiable, Equatable {
    var id: Int64
    var createdAt: Date
    var sourceURL: String
    var sourceKind: String
    var savedCount: Int
    var failedCount: Int
    var skippedCount: Int
    var items: [ObsidianImportItem]
}

struct ObsidianImportItem: Identifiable, Equatable {
    var id: Int64
    var sourceId: String
    var title: String
    var markdownPath: String
    var status: String
    var error: String?
}

struct HistoryQuery {
    var dateFrom: Date?
    var dateTo: Date?
    var content: String?
    var limit: Int = 50
    var offset: Int = 0
}

/// SQLite-backed Voice Input + Obsidian import history under `~/.airtype/history.sqlite`.
final class HistoryStore {
    static let shared = HistoryStore()
    static let pageSize = 50

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "airtype.history", qos: .utility)
    private let iso = ISO8601DateFormatter()

    private init() {
        open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open() {
        let path = AirTypeHome.historyDB
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(path.path, &db) != SQLITE_OK {
            Logger.shared.log("HistoryStore: could not open \(path.path)")
            db = nil
            return
        }
        exec("""
        CREATE TABLE IF NOT EXISTS voice_inputs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at TEXT NOT NULL,
          asr_text TEXT NOT NULL,
          llm_text TEXT,
          asr_backend TEXT NOT NULL,
          asr_engine TEXT NOT NULL,
          asr_model TEXT NOT NULL,
          asr_endpoint TEXT,
          llm_enabled INTEGER NOT NULL DEFAULT 0,
          llm_model TEXT,
          llm_endpoint TEXT,
          result TEXT NOT NULL,
          duration_ms INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_voice_created ON voice_inputs(created_at DESC);
        CREATE TABLE IF NOT EXISTS obsidian_imports (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at TEXT NOT NULL,
          source_url TEXT NOT NULL,
          source_kind TEXT NOT NULL,
          saved_count INTEGER NOT NULL,
          failed_count INTEGER NOT NULL,
          skipped_count INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_obs_created ON obsidian_imports(created_at DESC);
        """)
        addColumnIfMissing(table: "voice_inputs", column: "audio_path", definition: "TEXT")
        openSchemaTail()
    }

    /// `CREATE TABLE IF NOT EXISTS` does not add columns to a database created before this build.
    private func addColumnIfMissing(table: String, column: String, definition: String) {
        guard let db else { return }
        let pragma = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column {
                found = true
                break
            }
        }
        sqlite3_finalize(stmt)
        guard !found else { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func openSchemaTail() {
        exec("""
        CREATE TABLE IF NOT EXISTS obsidian_import_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          import_id INTEGER NOT NULL,
          source_id TEXT NOT NULL,
          title TEXT NOT NULL,
          markdown_path TEXT NOT NULL,
          status TEXT NOT NULL,
          error TEXT,
          FOREIGN KEY(import_id) REFERENCES obsidian_imports(id)
        );
        """)
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                Logger.shared.log("HistoryStore SQL error: \(String(cString: err))")
                sqlite3_free(err)
            }
        }
    }

    // MARK: - Voice

    func recordVoiceAsync(
        asrText: String,
        llmText: String?,
        asrBackend: String,
        asrEngine: String,
        asrModel: String,
        asrEndpoint: String?,
        llmEnabled: Bool,
        llmModel: String?,
        llmEndpoint: String?,
        result: String,
        durationMs: Int?,
        audioPCM: Data? = nil,
        audioDirectory: String = "",
        recordedAt: Date = Date()
    ) {
        queue.async { [weak self] in
            let audioPath = Self.archiveVoiceAudio(
                pcm: audioPCM,
                transcript: asrText,
                directory: audioDirectory,
                date: recordedAt
            )
            self?.recordVoice(
                asrText: asrText,
                llmText: llmText,
                asrBackend: asrBackend,
                asrEngine: asrEngine,
                asrModel: asrModel,
                asrEndpoint: asrEndpoint,
                llmEnabled: llmEnabled,
                llmModel: llmModel,
                llmEndpoint: llmEndpoint,
                result: result,
                durationMs: durationMs,
                audioPath: audioPath,
                createdAt: recordedAt
            )
        }
    }

    /// Writes the Opus file before the row is inserted so the stored path matches a file that exists.
    private static func archiveVoiceAudio(pcm: Data?, transcript: String, directory: String, date: Date) -> String? {
        guard let pcm, !pcm.isEmpty else { return nil }
        let folder = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return nil }
        do {
            let url = try VoiceAudioArchive.save(pcm: pcm, transcript: transcript, directory: folder, date: date)
            Logger.shared.log("Voice audio saved: \(url.path)")
            return url.path
        } catch {
            Logger.shared.log("Voice audio save failed: \(error)")
            return nil
        }
    }

    private func recordVoice(
        asrText: String,
        llmText: String?,
        asrBackend: String,
        asrEngine: String,
        asrModel: String,
        asrEndpoint: String?,
        llmEnabled: Bool,
        llmModel: String?,
        llmEndpoint: String?,
        result: String,
        durationMs: Int?,
        audioPath: String?,
        createdAt: Date
    ) {
        guard let db else { return }
        let sql = """
        INSERT INTO voice_inputs
        (created_at, asr_text, llm_text, asr_backend, asr_engine, asr_model, asr_endpoint,
         llm_enabled, llm_model, llm_endpoint, result, duration_ms, audio_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, iso.string(from: createdAt))
        bindText(stmt, 2, asrText)
        bindText(stmt, 3, llmText)
        bindText(stmt, 4, asrBackend)
        bindText(stmt, 5, asrEngine)
        bindText(stmt, 6, asrModel)
        bindText(stmt, 7, asrEndpoint)
        sqlite3_bind_int(stmt, 8, llmEnabled ? 1 : 0)
        bindText(stmt, 9, llmModel)
        bindText(stmt, 10, llmEndpoint)
        bindText(stmt, 11, result)
        if let durationMs {
            sqlite3_bind_int(stmt, 12, Int32(durationMs))
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        bindText(stmt, 13, audioPath)
        if sqlite3_step(stmt) != SQLITE_DONE {
            Logger.shared.log("HistoryStore: voice insert failed")
        }
    }

    func queryVoice(_ query: HistoryQuery) -> [VoiceHistoryRecord] {
        queue.sync {
            guard let db else { return [] }
            var sql = "SELECT id, created_at, asr_text, llm_text, asr_backend, asr_engine, asr_model, asr_endpoint, llm_enabled, llm_model, llm_endpoint, result, duration_ms, audio_path FROM voice_inputs WHERE 1=1"
            var args: [Any?] = []
            appendDateFilters(to: &sql, args: &args, query: query, column: "created_at")
            if let content = query.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                sql += " AND (asr_text LIKE ? OR IFNULL(llm_text,'') LIKE ?)"
                let pattern = "%\(content)%"
                args.append(pattern)
                args.append(pattern)
            }
            sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
            args.append(query.limit)
            args.append(query.offset)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindArgs(stmt, args)
            var rows: [VoiceHistoryRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(VoiceHistoryRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    createdAt: date(from: text(stmt, 1)) ?? Date(),
                    asrText: text(stmt, 2) ?? "",
                    llmText: text(stmt, 3),
                    asrBackend: text(stmt, 4) ?? "",
                    asrEngine: text(stmt, 5) ?? "",
                    asrModel: text(stmt, 6) ?? "",
                    asrEndpoint: text(stmt, 7),
                    llmEnabled: sqlite3_column_int(stmt, 8) != 0,
                    llmModel: text(stmt, 9),
                    llmEndpoint: text(stmt, 10),
                    result: text(stmt, 11) ?? "",
                    durationMs: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 12)),
                    audioPath: text(stmt, 13)
                ))
            }
            return rows
        }
    }

    func voiceSummary(now: Date = Date()) -> HistorySummary {
        summary(table: "voice_inputs", now: now)
    }

    func obsidianSummary(now: Date = Date()) -> HistorySummary {
        summary(table: "obsidian_imports", now: now)
    }

    private func summary(table: String, now: Date) -> HistorySummary {
        queue.sync {
            guard let db else { return HistorySummary() }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
            let threeMonths = calendar.date(byAdding: .month, value: -3, to: now) ?? today
            let sixMonths = calendar.date(byAdding: .month, value: -6, to: now) ?? today
            let oneYear = calendar.date(byAdding: .year, value: -1, to: now) ?? today
            let bounds = [today, week, month, threeMonths, sixMonths, oneYear].map { iso.string(from: $0) }
            let sql = """
            SELECT
              COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0),
              COUNT(*)
            FROM \(table)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return HistorySummary() }
            defer { sqlite3_finalize(stmt) }
            for (index, bound) in bounds.enumerated() {
                bindText(stmt, Int32(index + 1), bound)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return HistorySummary() }
            return HistorySummary(
                today: Int(sqlite3_column_int(stmt, 0)),
                thisWeek: Int(sqlite3_column_int(stmt, 1)),
                thisMonth: Int(sqlite3_column_int(stmt, 2)),
                threeMonths: Int(sqlite3_column_int(stmt, 3)),
                sixMonths: Int(sqlite3_column_int(stmt, 4)),
                oneYear: Int(sqlite3_column_int(stmt, 5)),
                total: Int(sqlite3_column_int(stmt, 6))
            )
        }
    }

    // MARK: - Obsidian

    func recordObsidianImportAsync(
        sourceURL: String,
        sourceKind: String,
        savedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        items: [(sourceId: String, title: String, markdownPath: String, status: String, error: String?)]
    ) {
        queue.async { [weak self] in
            self?.recordObsidianImport(
                sourceURL: sourceURL,
                sourceKind: sourceKind,
                savedCount: savedCount,
                failedCount: failedCount,
                skippedCount: skippedCount,
                items: items
            )
        }
    }

    private func recordObsidianImport(
        sourceURL: String,
        sourceKind: String,
        savedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        items: [(sourceId: String, title: String, markdownPath: String, status: String, error: String?)]
    ) {
        guard let db else { return }
        let insert = """
        INSERT INTO obsidian_imports (created_at, source_url, source_kind, saved_count, failed_count, skipped_count)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        bindText(stmt, 1, iso.string(from: Date()))
        bindText(stmt, 2, sourceURL)
        bindText(stmt, 3, sourceKind)
        sqlite3_bind_int(stmt, 4, Int32(savedCount))
        sqlite3_bind_int(stmt, 5, Int32(failedCount))
        sqlite3_bind_int(stmt, 6, Int32(skippedCount))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            return
        }
        sqlite3_finalize(stmt)
        let importID = sqlite3_last_insert_rowid(db)

        let itemSQL = """
        INSERT INTO obsidian_import_items (import_id, source_id, title, markdown_path, status, error)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        for item in items {
            var itemStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, itemSQL, -1, &itemStmt, nil) == SQLITE_OK, let itemStmt else { continue }
            sqlite3_bind_int64(itemStmt, 1, importID)
            bindText(itemStmt, 2, item.sourceId)
            bindText(itemStmt, 3, item.title)
            bindText(itemStmt, 4, item.markdownPath)
            bindText(itemStmt, 5, item.status)
            bindText(itemStmt, 6, item.error)
            _ = sqlite3_step(itemStmt)
            sqlite3_finalize(itemStmt)
        }
    }

    func queryObsidianImports(_ query: HistoryQuery) -> [ObsidianImportRecord] {
        queue.sync {
            guard let db else { return [] }
            var sql = "SELECT id, created_at, source_url, source_kind, saved_count, failed_count, skipped_count FROM obsidian_imports WHERE 1=1"
            var args: [Any?] = []
            appendDateFilters(to: &sql, args: &args, query: query, column: "created_at")
            if let content = query.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                sql += """
                 AND id IN (
                  SELECT import_id FROM obsidian_import_items
                  WHERE title LIKE ? OR markdown_path LIKE ? OR source_id LIKE ?
                )
                """
                let pattern = "%\(content)%"
                args.append(pattern)
                args.append(pattern)
                args.append(pattern)
            }
            sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
            args.append(query.limit)
            args.append(query.offset)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindArgs(stmt, args)
            var rows: [ObsidianImportRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                rows.append(ObsidianImportRecord(
                    id: id,
                    createdAt: date(from: text(stmt, 1)) ?? Date(),
                    sourceURL: text(stmt, 2) ?? "",
                    sourceKind: text(stmt, 3) ?? "",
                    savedCount: Int(sqlite3_column_int(stmt, 4)),
                    failedCount: Int(sqlite3_column_int(stmt, 5)),
                    skippedCount: Int(sqlite3_column_int(stmt, 6)),
                    items: loadItems(importID: id)
                ))
            }
            return rows
        }
    }

    private func loadItems(importID: Int64) -> [ObsidianImportItem] {
        guard let db else { return [] }
        let sql = "SELECT id, source_id, title, markdown_path, status, error FROM obsidian_import_items WHERE import_id = ? ORDER BY id ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, importID)
        var items: [ObsidianImportItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(ObsidianImportItem(
                id: sqlite3_column_int64(stmt, 0),
                sourceId: text(stmt, 1) ?? "",
                title: text(stmt, 2) ?? "",
                markdownPath: text(stmt, 3) ?? "",
                status: text(stmt, 4) ?? "",
                error: text(stmt, 5)
            ))
        }
        return items
    }

    // MARK: - Helpers

    private func appendDateFilters(to sql: inout String, args: inout [Any?], query: HistoryQuery, column: String) {
        if let from = query.dateFrom {
            let start = Calendar.current.startOfDay(for: from)
            sql += " AND \(column) >= ?"
            args.append(iso.string(from: start))
        }
        if let to = query.dateTo {
            let start = Calendar.current.startOfDay(for: to)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? to
            sql += " AND \(column) < ?"
            args.append(iso.string(from: end))
        }
    }

    private func bindArgs(_ stmt: OpaquePointer, _ args: [Any?]) {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String:
                bindText(stmt, idx, s)
            case let n as Int:
                sqlite3_bind_int(stmt, idx, Int32(n))
            case let n as Int32:
                sqlite3_bind_int(stmt, idx, n)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return iso.date(from: value)
    }
}
