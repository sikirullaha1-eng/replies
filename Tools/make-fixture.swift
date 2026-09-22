// Writes fixtures/sample-chat.db — a database with the REAL chat.db schema,
// filled with believable traffic. Everything in this project is tested against
// it, because macOS will not let the agent read the real one.
//
//   swift Tools/make-fixture.swift
//
// Seeded, so the personalities and reply speeds are the same every run. The
// history is anchored to the current date, so the row count drifts by a
// handful between runs — assert on ratios and medians, never on exact counts.

import Foundation

// MARK: - a seeded generator, so the fixture never changes underfoot

struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
    mutating func double() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(double() * Double(range.count))
    }
    mutating func pick<T>(_ xs: [T]) -> T { xs[min(xs.count - 1, int(0...xs.count - 1))] }
    mutating func chance(_ p: Double) -> Bool { double() < p }
    /// Latency clustered around a median, with a long tail — the shape real
    /// reply times actually have.
    mutating func latency(median: Double) -> Double {
        let u = max(0.0001, double())
        return median * pow(u, -0.45) * (0.55 + double() * 0.5)
    }
}

var rng = LCG(seed: 20260922)

// MARK: - who is in the fixture

struct Person {
    let name: String
    let handle: String
    let service: String
    /// How fast *he* answers them, in seconds (median).
    let myReply: Double
    /// How fast *they* answer him.
    let theirReply: Double
    /// How often they are the one to start a conversation.
    let theyStart: Double
    /// How often he simply never answers.
    let heGhosts: Double
    let perDay: Double
}

let people: [Person] = [
    Person(name: "Gbemini",   handle: "+14435637111", service: "iMessage",
           myReply: 90,    theirReply: 240,   theyStart: 0.55, heGhosts: 0.02, perDay: 9),
    Person(name: "Mum",       handle: "+12403319087", service: "iMessage",
           myReply: 5400,  theirReply: 900,   theyStart: 0.8,  heGhosts: 0.18, perDay: 2.2),
    Person(name: "Tobi",      handle: "+14105552981", service: "iMessage",
           myReply: 600,   theirReply: 480,   theyStart: 0.5,  heGhosts: 0.05, perDay: 4),
    Person(name: "Coach Ray", handle: "+14432200144", service: "SMS",
           myReply: 2700,  theirReply: 10800, theyStart: 0.9,  heGhosts: 0.25, perDay: 0.8),
    Person(name: "Deji",      handle: "deji.a@icloud.com", service: "iMessage",
           myReply: 1200,  theirReply: 3600,  theyStart: 0.35, heGhosts: 0.08, perDay: 2),
    Person(name: "Amara",     handle: "+12026619912", service: "iMessage",
           myReply: 240,   theirReply: 180,   theyStart: 0.45, heGhosts: 0.03, perDay: 5),
    Person(name: "Home Depot — Marcus", handle: "+14437780031", service: "SMS",
           myReply: 480,   theirReply: 5400,  theyStart: 0.95, heGhosts: 0.1,  perDay: 1.1),
    Person(name: "Kemi",      handle: "+13015540277", service: "iMessage",
           myReply: 14400, theirReply: 600,   theyStart: 0.85, heGhosts: 0.45, perDay: 1.4),
]

struct Group {
    let name: String
    let members: [Int]   // indices into `people`
    let perDay: Double
}

let groups: [Group] = [
    Group(name: "Morgan CS 201", members: [2, 4, 5], perDay: 3.5),
    Group(name: "Sunday ball",   members: [0, 2, 3], perDay: 1.6),
]

// MARK: - what they say

let outbound = [
    "otw", "yeah im up", "gimme 10", "bet", "ok cool", "sorry just saw this",
    "im at work rn", "ill call you after", "that's crazy lol", "send it",
    "i got you", "can you pull up", "no fr", "what time", "nah i'm good",
    "did you finish the lab", "my shift ends at 9", "say less", "appreciate you",
    "lemme check and get back to you", "im outside", "you free later?",
    "that test was rough", "😭😭", "aight", "i'll be there",
]
let inbound = [
    "you up?", "where you at", "call me when you can", "did you see this",
    "wyd", "lmk", "can you cover tomorrow", "i sent it", "how'd it go",
    "don't forget the thing", "you good?", "we still on for later",
    "im pulling up in 5", "this is wild", "send me the notes", "happy birthday!!",
    "did you eat", "answer your phone", "hellooo", "what happened with the aid office",
    "you coming sunday", "😂", "ok", "text me back",
]
let groupLines = [
    "who's got the notes from friday", "im down", "what time we starting",
    "bring a ball", "cant make it today", "same", "lol", "📍 field is open",
    "quiz got moved to thursday", "anyone at the library", "im 5 min out",
]

// MARK: - build the rows

/// Apple stores dates as nanoseconds since 2001-01-01.
func appleTime(_ d: Date) -> Int64 {
    Int64((d.timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
}

/// The typedstream shape Messages writes into `attributedBody` when `text` is
/// NULL. Some rows in the fixture use it so the reader is exercised on it.
func typedStream(_ text: String) -> [UInt8] {
    var b: [UInt8] = [0x04, 0x0b]
    b += Array("streamtyped".utf8)
    b += [0x81, 0xe8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
    b += [0x12] + Array("NSAttributedString".utf8) + [0x00]
    b += [0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
    b += [0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b]
    let body = Array(text.utf8)
    if body.count < 0x80 { b += [UInt8(body.count)] }
    else { b += [0x81, UInt8(body.count & 0xff), UInt8((body.count >> 8) & 0xff)] }
    b += body
    b += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
    return b
}

struct Row {
    var id: Int
    var chat: Int
    var handleIndex: Int
    var fromMe: Bool
    var text: String
    var date: Date
    var dateRead: Date?
    var service: String
    var associated: Int
    var attachment: Bool
    /// Carry the body in attributedBody instead of text, as modern macOS does.
    var asBlob: Bool
}

var rows: [Row] = []
var nextID = 1

let now = Date()
let start = now.addingTimeInterval(-240 * 86400)

/// Nudge a timestamp into waking hours — nobody texts uniformly round the clock.
func waking(_ d: Date) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    let h = cal.component(.hour, from: d)
    if h >= 8 && h <= 23 { return d }
    return d.addingTimeInterval(Double((9 - h + 24) % 24) * 3600)
}

func addBurst(chat: Int, person: Int, fromMe: Bool, at time: Date,
              service: String, lines: [String]) -> Date {
    var t = time
    let n = rng.chance(0.28) ? rng.int(2...3) : 1
    for _ in 0..<n {
        let body = rng.pick(lines)
        rows.append(Row(id: nextID, chat: chat, handleIndex: person, fromMe: fromMe,
                        text: body, date: t, dateRead: nil, service: service,
                        associated: 0, attachment: rng.chance(0.06),
                        asBlob: rng.chance(0.35)))
        nextID += 1
        t = t.addingTimeInterval(Double(rng.int(4...25)))
    }
    return t
}

// One-to-one threads
for (i, p) in people.enumerated() {
    let chat = i + 1
    var t = waking(start.addingTimeInterval(rng.double() * 86400))

    while t < now.addingTimeInterval(-86400) {
        let theyOpen = rng.chance(p.theyStart)
        var end = addBurst(chat: chat, person: i, fromMe: !theyOpen, at: t,
                           service: p.service, lines: theyOpen ? inbound : outbound)

        // A few back-and-forth turns.
        var turns = rng.int(1...5)
        var lastWasThem = theyOpen
        while turns > 0 {
            let ghosted = lastWasThem && rng.chance(p.heGhosts)
            if ghosted { break }
            let wait = lastWasThem ? rng.latency(median: p.myReply)
                                   : rng.latency(median: p.theirReply)
            let at = end.addingTimeInterval(wait)
            if at >= now { break }
            end = addBurst(chat: chat, person: i, fromMe: lastWasThem, at: at,
                           service: p.service, lines: lastWasThem ? outbound : inbound)
            // The odd tapback on the message just answered.
            if rng.chance(0.09) {
                rows.append(Row(id: nextID, chat: chat, handleIndex: i,
                                fromMe: rng.chance(0.5), text: "", date: end.addingTimeInterval(3),
                                dateRead: nil, service: p.service,
                                associated: 2000 + rng.int(0...5), attachment: false,
                                asBlob: false))
                nextID += 1
            }
            lastWasThem.toggle()
            turns -= 1
        }

        // Gap until the next conversation.
        let gapDays = max(0.2, (1.0 / p.perDay) * Double(rng.int(2...14)))
        t = waking(end.addingTimeInterval(gapDays * 86400 * (0.5 + rng.double())))
    }
}

// Group chats
for (gi, g) in groups.enumerated() {
    let chat = people.count + gi + 1
    var t = waking(start.addingTimeInterval(rng.double() * 86400))
    while t < now.addingTimeInterval(-86400) {
        let speaker = rng.pick(g.members)
        let fromMe = rng.chance(0.28)
        rows.append(Row(id: nextID, chat: chat, handleIndex: speaker, fromMe: fromMe,
                        text: rng.pick(groupLines), date: t, dateRead: nil,
                        service: "iMessage", associated: 0,
                        attachment: rng.chance(0.05), asBlob: rng.chance(0.3)))
        nextID += 1
        t = waking(t.addingTimeInterval((1.0 / g.perDay) * 86400 * (0.3 + rng.double() * 1.4)))
    }
}

// One thread deliberately left on read: Kemi's last word, eleven days ago,
// and he never answered.
if let kemi = people.firstIndex(where: { $0.name == "Kemi" }) {
    let chat = kemi + 1
    rows.removeAll { $0.chat == chat && $0.date > now.addingTimeInterval(-11 * 86400) }
    var t = waking(now.addingTimeInterval(-11 * 86400))
    for line in ["you coming to the thing", "hello??", "ok bet"] {
        rows.append(Row(id: nextID, chat: chat, handleIndex: kemi, fromMe: false,
                        text: line, date: t, dateRead: t.addingTimeInterval(400),
                        service: "iMessage", associated: 0, attachment: false, asBlob: false))
        nextID += 1
        t = t.addingTimeInterval(Double(rng.int(600...7200)))
    }
}

rows.sort { $0.date < $1.date }

// MARK: - write it

func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

var sql = """
PRAGMA journal_mode=DELETE;
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL,
    country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
    style INTEGER, state INTEGER, account_id TEXT, properties BLOB, chat_identifier TEXT,
    service_name TEXT, room_name TEXT, account_login TEXT, is_archived INTEGER DEFAULT 0,
    last_addressed_handle TEXT, display_name TEXT, group_id TEXT);
CREATE TABLE chat_handle_join (chat_id INTEGER REFERENCES chat(ROWID),
    handle_id INTEGER REFERENCES handle(ROWID), UNIQUE(chat_id, handle_id));
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
    text TEXT, replace INTEGER DEFAULT 0, service_center TEXT, handle_id INTEGER DEFAULT 0,
    subject TEXT, country TEXT, attributedBody BLOB, version INTEGER DEFAULT 0,
    type INTEGER DEFAULT 0, service TEXT, account TEXT, account_guid TEXT,
    error INTEGER DEFAULT 0, date INTEGER, date_read INTEGER, date_delivered INTEGER,
    is_delivered INTEGER DEFAULT 0, is_finished INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0,
    is_read INTEGER DEFAULT 0, is_sent INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0,
    cache_roomnames TEXT, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
    expressive_send_style_id TEXT, thread_originator_guid TEXT);
CREATE TABLE chat_message_join (chat_id INTEGER REFERENCES chat(ROWID),
    message_id INTEGER REFERENCES message(ROWID), message_date INTEGER DEFAULT 0,
    PRIMARY KEY (chat_id, message_id));
BEGIN;

"""

for (i, p) in people.enumerated() {
    sql += "INSERT INTO handle (ROWID,id,country,service,uncanonicalized_id) VALUES (\(i + 1),\(sqlQuote(p.handle)),'us',\(sqlQuote(p.service)),NULL);\n"
}
for (i, p) in people.enumerated() {
    sql += "INSERT INTO chat (ROWID,guid,style,chat_identifier,service_name,display_name) VALUES (\(i + 1),\(sqlQuote("\(p.service);-;\(p.handle)")),45,\(sqlQuote(p.handle)),\(sqlQuote(p.service)),NULL);\n"
    sql += "INSERT INTO chat_handle_join VALUES (\(i + 1),\(i + 1));\n"
}
for (gi, g) in groups.enumerated() {
    let id = people.count + gi + 1
    sql += "INSERT INTO chat (ROWID,guid,style,chat_identifier,service_name,display_name) VALUES (\(id),\(sqlQuote("iMessage;+;chat\(100 + gi)")),43,\(sqlQuote("chat\(100 + gi)")),'iMessage',\(sqlQuote(g.name)));\n"
    for m in g.members { sql += "INSERT INTO chat_handle_join VALUES (\(id),\(m + 1));\n" }
}

for r in rows {
    let d = appleTime(r.date)
    let read = r.dateRead.map { String(appleTime($0)) } ?? "0"
    let textCol: String
    let blobCol: String
    if r.asBlob && !r.text.isEmpty {
        textCol = "NULL"
        blobCol = "X'" + typedStream(r.text).map { String(format: "%02X", $0) }.joined() + "'"
    } else {
        textCol = r.text.isEmpty ? "NULL" : sqlQuote(r.text)
        blobCol = "NULL"
    }
    sql += """
    INSERT INTO message (ROWID,guid,text,handle_id,attributedBody,service,date,date_read,\
    date_delivered,is_delivered,is_finished,is_from_me,is_read,is_sent,cache_has_attachments,\
    associated_message_type) VALUES (\(r.id),\(sqlQuote(UUID().uuidString)),\(textCol),\
    \(r.handleIndex + 1),\(blobCol),\(sqlQuote(r.service)),\(d),\(read),\(d),1,1,\
    \(r.fromMe ? 1 : 0),1,\(r.fromMe ? 1 : 0),\(r.attachment ? 1 : 0),\(r.associated));

    """
    sql += "INSERT INTO chat_message_join VALUES (\(r.chat),\(r.id),\(d));\n"
}
sql += "COMMIT;\n"

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dir = root.appendingPathComponent("fixtures")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let db = dir.appendingPathComponent("sample-chat.db")
for suffix in ["", "-wal", "-shm"] {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + suffix))
}

let script = dir.appendingPathComponent("build.sql")
try sql.write(to: script, atomically: true, encoding: .utf8)

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
p.arguments = [db.path, ".read \(script.path)"]
let err = Pipe()
p.standardError = err
p.standardOutput = FileHandle.nullDevice
try p.run()
p.waitUntilExit()
let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
try? FileManager.default.removeItem(at: script)

guard p.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("sqlite3 failed:\n\(errText)\n".utf8))
    exit(1)
}

let people1to1 = people.count
print("Wrote \(db.path)")
print("  \(rows.count) messages across \(people1to1) contacts and \(groups.count) group chats")
print("  \(rows.filter { $0.fromMe }.count) sent, \(rows.filter { !$0.fromMe }.count) received")
print("  \(rows.filter { $0.asBlob && !$0.text.isEmpty }.count) carry their body in attributedBody only")
print("  \(rows.filter { $0.associated != 0 }.count) tapbacks")
