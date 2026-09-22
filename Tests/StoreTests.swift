import Foundation

// Assertions for the chat.db reader. Built and run by ./run-tests.sh store.
// Everything here works on a database this file creates in a temp directory —
// never on the user's real messages, which the agent cannot read anyway.

@main
struct StoreTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expect(_ condition: Bool, _ what: String) {
        checks += 1
        if condition { print("  ok    \(what)") }
        else { failures += 1; print("  FAIL  \(what)") }
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        checks += 1
        if a == b { print("  ok    \(what)") }
        else { failures += 1; print("  FAIL  \(what) — got \(a), wanted \(b)") }
    }

    static func main() {
        print("Store tests")

        testAppleDate()
        testAttributedBody()
        testReadingADatabase()
        testDegradedSchema()
        testMissingFile()
        testMessageInTwoChats()

        print("\n\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: dates

    static func testAppleDate() {
        print("\nApple epoch")
        // 2001-01-01T00:00:00Z is 978307200 in Unix time.
        equal(ChatDB.appleDate(0).timeIntervalSince1970, 0, "zero stays at the Unix epoch")
        equal(ChatDB.appleDate(1).timeIntervalSince1970, 978_307_201, "legacy seconds format")
        equal(ChatDB.appleDate(700_000_000_000_000_000).timeIntervalSince1970,
              978_307_200 + 700_000_000, "nanosecond format")
        // A real message from 2023 must land in 2023, not 1970 or 2255.
        let y = Calendar(identifier: .gregorian)
            .component(.year, from: ChatDB.appleDate(700_000_000_000_000_000))
        equal(y, 2023, "a 2023 timestamp reads as 2023")
    }

    // MARK: attributedBody

    /// Builds the typedstream prefix Messages actually writes, ending in the
    /// NSString marker, the 0x2B type code, a length and the UTF-8 bytes.
    static func typedStream(_ text: String) -> Data {
        var bytes: [UInt8] = [0x04, 0x0b]
        bytes += Array("streamtyped".utf8)
        bytes += [0x81, 0xe8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
        bytes += [0x12] + Array("NSAttributedString".utf8) + [0x00]
        bytes += [0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
        bytes += [0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b]

        let body = Array(text.utf8)
        if body.count < 0x80 {
            bytes += [UInt8(body.count)]
        } else {
            bytes += [0x81, UInt8(body.count & 0xff), UInt8((body.count >> 8) & 0xff)]
        }
        bytes += body
        bytes += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
        return Data(bytes)
    }

    static func testAttributedBody() {
        print("\nattributedBody")
        equal(AttributedBody.text(from: typedStream("hey are you coming")),
              "hey are you coming", "short body")
        let long = String(repeating: "a really long message. ", count: 40)
        equal(AttributedBody.text(from: typedStream(long)), long,
              "body over 127 bytes uses the 0x81 length escape")
        equal(AttributedBody.text(from: typedStream("café 🙃 ok")), "café 🙃 ok",
              "utf-8 with emoji survives")
        expect(AttributedBody.text(from: Data([0x00, 0x01, 0x02])) == nil,
               "garbage returns nil instead of crashing")
        expect(AttributedBody.text(from: Data()) == nil, "empty blob returns nil")
    }

    // MARK: a real database

    static func sqlite(_ path: String, _ sql: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, sql]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func makeDB(_ name: String, schema: String, rows: [String]) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replies-test-\(name).db")
        try? FileManager.default.removeItem(at: url)
        sqlite(url.path, schema)
        for row in rows { sqlite(url.path, row) }
        return url
    }

    /// The columns of the real chat.db that this project uses.
    static let realSchema = """
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, service_name TEXT);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
        attributedBody BLOB, handle_id INTEGER, service TEXT, date INTEGER,
        date_read INTEGER, is_from_me INTEGER, associated_message_type INTEGER,
        cache_has_attachments INTEGER);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    """

    static func testReadingADatabase() {
        print("\nreading a database")
        let base: Int64 = 700_000_000_000_000_000
        let url = makeDB("basic", schema: realSchema, rows: [
            "INSERT INTO handle VALUES (1,'+14435637111','iMessage'),(2,'friend@icloud.com','iMessage');",
            "INSERT INTO chat VALUES (1,'iMessage;-;+14435637111',NULL,'iMessage'),(2,'iMessage;+;chat9','Study group','iMessage');",
            "INSERT INTO chat_handle_join VALUES (1,1),(2,1),(2,2);",
            // 1 inbound with text, 2 outbound with text, 3 inbound attributedBody only,
            // 4 a tapback, 5 an attachment with no words, 6 in the group chat
            "INSERT INTO message (ROWID,guid,text,handle_id,service,date,date_read,is_from_me,associated_message_type,cache_has_attachments) VALUES " +
            "(1,'g1','you up?',1,'iMessage',\(base),0,0,0,0)," +
            "(2,'g2','yeah',1,'iMessage',\(base + 120_000_000_000),0,1,0,0)," +
            "(4,'g4','',1,'iMessage',\(base + 400_000_000_000),0,1,2000,0)," +
            "(5,'g5',NULL,1,'SMS',\(base + 500_000_000_000),0,0,0,1)," +
            "(6,'g6','who is bringing notes',2,'iMessage',\(base + 600_000_000_000),0,0,0,0);",
            "INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(1,5),(2,6);",
        ])
        // Row 3 carries its body only in attributedBody.
        let blob = typedStream("sent from the new Messages").map { String(format: "%02X", $0) }.joined()
        sqlite(url.path, "INSERT INTO message (ROWID,guid,text,attributedBody,handle_id,service,date,date_read,is_from_me,associated_message_type,cache_has_attachments) VALUES (3,'g3',NULL,X'\(blob)',1,'iMessage',\(base + 300_000_000_000),\(base + 310_000_000_000),0,0,0);")

        guard let store = try? ChatDB(url: url).load() else {
            failures += 1; checks += 1
            print("  FAIL  could not read the test database"); return
        }

        equal(store.messages.count, 6, "every row is read")
        equal(store.missingColumns, [], "the real schema is missing nothing")

        let m = Dictionary(uniqueKeysWithValues: store.messages.map { ($0.id, $0) })

        equal(m[1]?.text, "you up?", "plain text body")
        equal(m[1]?.isFromMe, false, "inbound flagged")
        equal(m[2]?.isFromMe, true, "outbound flagged")
        equal(m[1]?.handle, "+14435637111", "handle joined")

        equal(m[3]?.text, "sent from the new Messages",
              "a NULL text row is recovered from attributedBody")
        expect(m[3]?.dateRead != nil, "date_read is read when set")
        expect(m[1]?.dateRead == nil, "date_read of 0 reads as nil, not 1970")

        expect(m[4]?.isTapback == true, "a tapback is marked as one")
        expect(m[4]?.isSubstantive == false, "a tapback does not count as a message")
        expect(m[5]?.isSubstantive == true, "an attachment with no words still counts")
        equal(m[5]?.service, "SMS", "service is read")

        equal(store.messages.first?.id, 1, "sorted oldest first")
        equal(m[2]?.wordCount, 1, "word count")

        equal(store.conversations.count, 2, "both chats")
        let group = store.conversations.first { $0.id == 2 }
        equal(group?.participants.count, 2, "group participants folded into one row")
        equal(group?.isGroup, true, "group detected")
        equal(group?.title, "Study group", "display name wins as the title")
        equal(store.conversations.first { $0.id == 1 }?.title, "+14435637111",
              "a one-to-one falls back to the handle")
        equal(m[6]?.chatID, 2, "chat_message_join maps the message to its thread")

        let year = Calendar(identifier: .gregorian).component(.year, from: m[1]!.date)
        equal(year, 2023, "dates land in the right year")
    }

    // MARK: a schema that is missing things

    static func testDegradedSchema() {
        print("\nolder or newer schema")
        let url = makeDB("degraded", schema: """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, handle_id INTEGER,
            date INTEGER, is_from_me INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        """, rows: [
            "INSERT INTO handle VALUES (1,'+15551234567');",
            "INSERT INTO chat VALUES (1,'iMessage;-;+15551234567');",
            "INSERT INTO chat_handle_join VALUES (1,1);",
            "INSERT INTO message VALUES (1,'hello',1,700000000000000000,0);",
            "INSERT INTO chat_message_join VALUES (1,1);",
        ])

        guard let store = try? ChatDB(url: url).load() else {
            failures += 1; checks += 1
            print("  FAIL  a schema missing columns should degrade, not throw"); return
        }
        equal(store.messages.count, 1, "still reads what is there")
        equal(store.messages.first?.text, "hello", "body still read")
        equal(store.messages.first?.service, "iMessage", "service defaults")
        expect(store.missingColumns.contains("date_read"), "missing columns are reported")
        expect(store.missingColumns.contains("associated_message_type"), "…all of them")
        equal(store.conversations.first?.displayName, nil, "no display_name column is fine")
    }

    // MARK: a message that belongs to two chats

    static func testMessageInTwoChats() {
        print("\na message in two chats")
        let base: Int64 = 700_000_000_000_000_000
        let url = makeDB("dupe", schema: realSchema, rows: [
            "INSERT INTO handle VALUES (1,'+15551112222','iMessage');",
            "INSERT INTO chat VALUES (1,'a',NULL,'iMessage'),(2,'b',NULL,'iMessage');",
            "INSERT INTO chat_handle_join VALUES (1,1),(2,1);",
            "INSERT INTO message (ROWID,guid,text,handle_id,service,date,date_read,is_from_me,associated_message_type,cache_has_attachments) VALUES (1,'g1','once',1,'iMessage',\(base),0,0,0,0);",
            "INSERT INTO chat_message_join VALUES (1,1),(2,1);",
        ])
        guard let store = try? ChatDB(url: url).load() else {
            failures += 1; checks += 1
            print("  FAIL  could not read the test database"); return
        }
        equal(store.messages.count, 1, "a message joined to two chats is counted once")
    }

    // MARK: no database at all

    static func testMissingFile() {
        print("\nno database")
        let missing = URL(fileURLWithPath: "/tmp/replies-does-not-exist-\(UUID().uuidString).db")
        expect(!ChatDB.isReadable(missing), "isReadable is false for a file that is not there")
        do {
            _ = try ChatDB(url: missing).load()
            failures += 1; checks += 1
            print("  FAIL  reading a missing database should throw")
        } catch {
            checks += 1
            print("  ok    reading a missing database throws instead of crashing")
        }
        // The user's real database: unreadable without Full Disk Access, and the
        // check must say so rather than hanging or crashing.
        _ = ChatDB.isReadable(ChatDB.live.url)
        checks += 1
        print("  ok    isReadable on the live database answers without crashing")
    }
}
