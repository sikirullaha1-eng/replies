import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Reads the iMessage database. READ-ONLY, always — the app never writes to,
/// migrates or copies the user's messages.
struct ChatDB {
    let url: URL

    init(url: URL) { self.url = url }

    static var live: ChatDB {
        ChatDB(url: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db"))
    }

    /// Whether the database can be opened at all. `false` almost always means
    /// Full Disk Access has not been granted to this app.
    static func isReadable(_ url: URL) -> Bool {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard sqlite3_open_v2(uri(for: url), &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { return false }
        // Opening can succeed lazily; force a page read.
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master", -1, &stmt, nil)
                == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// `immutable=1` tells SQLite the file cannot change, so a WAL lock held by
    /// Messages.app cannot block or fail the read, and no -wal/-shm files are
    /// created beside the user's database.
    private static func uri(for url: URL) -> String {
        let escaped = url.path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "file://\(escaped)?immutable=1&mode=ro"
    }

    // MARK: reading

    /// Reads the whole history. Call it off the main actor — it is synchronous
    /// and a large database is tens of thousands of rows.
    /// `progress` is called with 0…1 and may be called from any thread.
    func load(progress: (@Sendable (Double) -> Void)? = nil) throws -> MessageStore {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(Self.uri(for: url), &db,
                                 SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if db != nil { sqlite3_close(db) }
            if rc == SQLITE_CANTOPEN || rc == SQLITE_PERM || rc == SQLITE_AUTH {
                throw ChatDBError.notAuthorized
            }
            throw ChatDBError.cannotOpen(why)
        }
        defer { sqlite3_close(db) }

        let messageCols = Set(columns(of: "message", db: db))
        guard !messageCols.isEmpty else {
            throw ChatDBError.queryFailed("no `message` table — is this an iMessage database?")
        }

        var missing: [String] = []
        /// Select the column when the schema has it, or a literal NULL when it
        /// does not, so an older or newer schema degrades instead of throwing.
        func col(_ name: String, _ fallback: String = "NULL") -> String {
            if messageCols.contains(name) { return "m.\(name)" }
            missing.append(name)
            return fallback
        }

        let sql = """
        SELECT m.ROWID,
               \(messageCols.contains("guid") ? "m.guid" : "''"),
               m.date,
               \(col("date_read", "0")),
               m.is_from_me,
               \(messageCols.contains("text") ? "m.text" : "NULL"),
               \(messageCols.contains("attributedBody") ? "m.attributedBody" : "NULL"),
               h.id,
               cmj.chat_id,
               \(col("service", "'iMessage'")),
               \(col("associated_message_type", "0")),
               \(col("cache_has_attachments", "0"))
        FROM message AS m
        LEFT JOIN handle AS h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
        ORDER BY m.date ASC
        """

        let total = count("SELECT COUNT(*) FROM message", db: db)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var messages: [Message] = []
        messages.reserveCapacity(max(total, 64))
        var seen = 0
        // A message that belongs to more than one chat comes back once per
        // chat_message_join row. Keep the first and drop the duplicates, or
        // every statistic counts it twice.
        var seenIDs = Set<Int64>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            seen += 1
            let rowID = sqlite3_column_int64(stmt, 0)
            guard seenIDs.insert(rowID).inserted else { continue }
            if let progress, total > 0, seen % 2000 == 0 {
                progress(Double(seen) / Double(total))
            }

            let body: String
            if let t = string(stmt, 5), !t.isEmpty {
                body = t
            } else if let blob = data(stmt, 6), let t = AttributedBody.text(from: blob) {
                body = t
            } else {
                body = ""
            }

            let readRaw = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 3)

            messages.append(Message(
                id: rowID,
                guid: string(stmt, 1) ?? "",
                date: Self.appleDate(sqlite3_column_int64(stmt, 2)),
                dateRead: readRaw > 0 ? Self.appleDate(readRaw) : nil,
                isFromMe: sqlite3_column_int(stmt, 4) == 1,
                text: body,
                handle: string(stmt, 7),
                chatID: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8),
                service: string(stmt, 9) ?? "iMessage",
                associatedType: Int(sqlite3_column_int(stmt, 10)),
                hasAttachments: sqlite3_column_int(stmt, 11) == 1))
        }
        progress?(1.0)

        return MessageStore(messages: messages,
                            conversations: try conversations(db: db),
                            missingColumns: missing)
    }

    // MARK: conversations

    private func conversations(db: OpaquePointer) throws -> [Conversation] {
        let chatCols = Set(columns(of: "chat", db: db))
        guard !chatCols.isEmpty else { return [] }

        let sql = """
        SELECT c.ROWID,
               \(chatCols.contains("guid") ? "c.guid" : "''"),
               \(chatCols.contains("display_name") ? "c.display_name" : "NULL"),
               \(chatCols.contains("service_name") ? "c.service_name" : "'iMessage'"),
               h.id
        FROM chat AS c
        LEFT JOIN chat_handle_join AS chj ON chj.chat_id = c.ROWID
        LEFT JOIN handle AS h ON h.ROWID = chj.handle_id
        ORDER BY c.ROWID
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // One row per (chat, participant); fold them into one Conversation each.
        var order: [Int64] = []
        var byID: [Int64: (guid: String, name: String?, service: String, people: [String])] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            if byID[id] == nil {
                order.append(id)
                byID[id] = (string(stmt, 1) ?? "", string(stmt, 2),
                            string(stmt, 3) ?? "iMessage", [])
            }
            if let person = string(stmt, 4), !byID[id]!.people.contains(person) {
                byID[id]!.people.append(person)
            }
        }

        return order.compactMap { id in
            guard let c = byID[id] else { return nil }
            return Conversation(id: id, guid: c.guid, displayName: c.name,
                                participants: c.people, service: c.service)
        }
    }

    // MARK: helpers

    /// Apple writes nanoseconds since 2001-01-01. Databases from before macOS
    /// 10.13 wrote plain seconds, so the magnitude decides which it is.
    static func appleDate(_ raw: Int64) -> Date {
        guard raw != 0 else { return Date(timeIntervalSince1970: 0) }
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: seconds + appleEpochOffset)
    }

    private func columns(of table: String, db: OpaquePointer) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let n = string(stmt, 1) { names.append(n) }
        }
        return names
    }

    private func count(_ sql: String, db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func string(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private func data(_ stmt: OpaquePointer, _ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(stmt, i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0 else { return nil }
        return Data(bytes: bytes, count: n)
    }
}
