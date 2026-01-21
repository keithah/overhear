import Foundation
import OSLog
#if canImport(SQLite3)
import SQLite3

/// Lightweight FTS index for transcripts to speed content searches across large libraries.
/// Stored alongside transcript files in Application Support.
final class TranscriptSearchIndex {
    private let db: OpaquePointer?
    private static let logger = Logger(subsystem: "com.overhear.app", category: "TranscriptSearchIndex")
    // Equivalent to SQLITE_TRANSIENT for Swift bindings.
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(baseDirectory: URL) throws {
        let dbURL = baseDirectory.appendingPathComponent("search.sqlite")
        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            throw NSError(domain: "TranscriptSearchIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open index database"])
        }
        db = handle
        let createSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
            id UNINDEXED,
            title,
            content,
            path UNINDEXED,
            date UNINDEXED
        );
        """
        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            throw Self.makeError(for: db)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func index(transcript: StoredTranscript, fileURL: URL) throws {
        let deleteSQL = "DELETE FROM transcripts_fts WHERE id = ?1;"
        try execute(deleteSQL) { [sqliteTransient] stmt in
            guard let idCString = transcript.id.cString(using: .utf8) else { return }
            sqlite3_bind_text(stmt, 1, idCString, -1, sqliteTransient)
        }
        let insertSQL = "INSERT INTO transcripts_fts (id, title, content, path, date) VALUES (?1, ?2, ?3, ?4, ?5);"
        try execute(insertSQL) { [sqliteTransient] stmt in
            guard
                let idCString = transcript.id.cString(using: .utf8),
                let titleCString = transcript.title.cString(using: .utf8),
                let contentCString = transcript.transcript.cString(using: .utf8),
                let pathCString = fileURL.path.cString(using: .utf8)
            else { return }
            sqlite3_bind_text(stmt, 1, idCString, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, titleCString, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, contentCString, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 4, pathCString, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 5, transcript.date.timeIntervalSince1970)
        }
    }

    func delete(id: String) throws {
        let sql = "DELETE FROM transcripts_fts WHERE id = ?1;"
        try execute(sql) { [sqliteTransient] stmt in
            guard let idCString = id.cString(using: .utf8) else { return }
            sqlite3_bind_text(stmt, 1, idCString, -1, sqliteTransient)
        }
    }

    func search(query: String, limit: Int, offset: Int) throws -> [URL] {
        let normalized = (query as NSString).precomposedStringWithCanonicalMapping
        let trimmed = normalized.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Allow only alphanumerics, spaces, underscores, and hyphens to avoid FTS operator injection.
        let allowed = CharacterSet.alphanumerics
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "_-"))
        let sanitizedScalars = trimmed.unicodeScalars.map { scalar -> UnicodeScalar in
            allowed.contains(scalar) ? scalar : " " as UnicodeScalar
        }
        var sanitized = String(String.UnicodeScalarView(sanitizedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }
        sanitized = sanitized.replacingOccurrences(of: "\"", with: "\"\"")
        guard !sanitized.isEmpty else { return [] }
        let words = sanitized.split(separator: " ").map(String.init)
        // Apply wildcard only for single-word, reasonably short queries.
        let token: String
        if words.count == 1, let first = words.first, first.count <= 50 {
            token = "\"\(first)\"*"
        } else {
            token = "\"\(sanitized)\""
        }
        let sql = """
        SELECT path FROM transcripts_fts
        WHERE transcripts_fts MATCH ?1
        ORDER BY date DESC
        LIMIT ?2 OFFSET ?3;
        """
        var results: [URL] = []
        try self.query(sql, bind: { [sqliteTransient] stmt in
            guard let tokenCString = token.cString(using: .utf8) else { return }
            sqlite3_bind_text(stmt, 1, tokenCString, -1, sqliteTransient)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            sqlite3_bind_int(stmt, 3, Int32(offset))
        }, rowHandler: { stmt in
            if let cString = sqlite3_column_text(stmt, 0) {
                let path = String(cString: cString)
                results.append(URL(fileURLWithPath: path))
            }
        })
        return results
    }

    // MARK: - SQLite helpers

    private func execute(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Self.makeError(for: db)
        }
        if let bind { bind(stmt) }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw Self.makeError(for: db)
        }
    }

    private func query(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil, rowHandler: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Self.makeError(for: db)
        }
        if let bind { bind(stmt) }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowHandler(stmt)
        }
    }

    nonisolated private static func makeError(for db: OpaquePointer?) -> NSError {
        let message = String(cString: sqlite3_errmsg(db))
        Self.logger.error("SQLite error: \(message, privacy: .public)")
        return NSError(domain: "TranscriptSearchIndex", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
