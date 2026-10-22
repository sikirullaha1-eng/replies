import Foundation

// Assertions for the analysis engine. Built and run by ./run-tests.sh analysis.
// Two halves: small hand-built threads whose answers can be worked out on
// paper (bursts, latencies, empty and single-message threads), and the
// generated fixtures/sample-chat.db, whose people were given known reply
// speeds, ghost rates and openers in Tools/make-fixture.swift. The fixture is
// random around those numbers, so it is checked with tolerances, never exact
// counts.

@main
struct AnalysisTests {
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

    /// `value` lies within [lo, hi]. A nil value fails.
    static func within(_ value: Double?, _ lo: Double, _ hi: Double, _ what: String) {
        checks += 1
        if let v = value, v >= lo, v <= hi { print("  ok    \(what) (\(fmt(v)))") }
        else { failures += 1; print("  FAIL  \(what) — got \(value.map(fmt) ?? "nil"), wanted \(fmt(lo))…\(fmt(hi))") }
    }

    static func fmt(_ v: Double) -> String { String(format: v < 10 ? "%.3f" : "%.0f", v) }

    static func main() {
        print("Analysis tests")

        testPercentile()
        testEmpty()
        testSingleMessage()
        testBurstsAndLatency()
        testConversationsAndRates()
        testTapbacksAreNotReplies()
        testGroupsStayOutOfContacts()
        testLeftOnRead()

        testFixture()

        print("\n\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: building threads by hand

    static let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    nonisolated(unsafe) static var nextID: Int64 = 1

    static func msg(_ chat: Int64, _ handle: String, me: Bool, _ at: TimeInterval,
                    _ text: String = "hey there", tapback: Int = 0,
                    read: Bool = false) -> Message {
        nextID += 1
        return Message(id: nextID, guid: "g\(nextID)", date: t0.addingTimeInterval(at),
                       dateRead: read ? t0.addingTimeInterval(at + 5) : nil,
                       isFromMe: me, text: text, handle: handle, chatID: chat,
                       service: "iMessage", associatedType: tapback, hasAttachments: false)
    }

    static func oneToOne(_ id: Int64, _ handle: String) -> Conversation {
        Conversation(id: id, guid: "c\(id)", displayName: nil, participants: [handle], service: "iMessage")
    }

    static func store(_ messages: [Message], _ convos: [Conversation]) -> MessageStore {
        MessageStore(messages: messages.sorted { $0.date < $1.date },
                     conversations: convos, missingColumns: [])
    }

    // MARK: percentile

    static func testPercentile() {
        print("\npercentiles")
        equal(Stats.percentile([], 0.5), nil, "median of nothing is nil, not a crash")
        equal(Stats.percentile([42], 0.9), 42, "p90 of one value is that value")
        equal(Stats.percentile([1, 2, 3, 4, 5], 0.5), 3, "odd-length median")
        equal(Stats.percentile([1, 2, 3, 4], 0.5), 2.5, "even-length median interpolates")
        within(Stats.percentile(Array(1...10).map(Double.init), 0.9), 9.0, 9.2, "p90 of 1…10")
        equal(Stats.ratio(3, 0), nil, "ratio over zero is nil")
        let l = LatencyStats([10, 30, 20])
        equal(l.count, 3, "latency count")
        equal(l.median, 20, "latency median sorts first")
        equal(l.mean, 20, "latency mean")
    }

    // MARK: empty and single

    static func testEmpty() {
        print("\nan empty database")
        let s = Engine.analyze(.empty, now: t0)
        expect(s.isEmpty, "empty snapshot says so")
        equal(s.myReplies, .empty, "no replies, no median")
        equal(s.myReplyRate, nil, "no reply rate rather than 0/0")
        equal(s.iStartShare, nil, "no opener share rather than 0/0")
        equal(s.myWordsPerMessage, nil, "no words per message rather than 0/0")
        equal(s.sentByHour.count, 24, "hour histogram always has 24 slots")
        equal(s.sentByWeekday.count, 7, "weekday histogram always has 7 slots")
        expect(s.leftOnRead.isEmpty && s.contacts.isEmpty && s.groups.isEmpty, "no lists")
        expect(s.longestSilence == nil, "no silence")

        // A chat row with no messages at all.
        let s2 = Engine.analyze(store([], [oneToOne(1, "+1555")]), now: t0)
        equal(s2.contacts.first?.myReplies.median, nil, "a thread with no messages has no median")
        equal(s2.contacts.first?.theyStartShare, nil, "…and no opener share")
    }

    static func testSingleMessage() {
        print("\na single-message thread")
        let s = Engine.analyze(store([msg(1, "+1555", me: false, 0, "you up?")],
                                     [oneToOne(1, "+1555")]),
                               now: t0.addingTimeInterval(3600))
        let c = s.contact("+1555")
        equal(c?.received, 1, "one message received")
        equal(c?.myReplies.count, 0, "no replies")
        equal(c?.myReplies.median, nil, "no median")
        equal(c?.myReplyRate, nil, "an hour-old message is pending, not unanswered")
        equal(c?.conversationsTheyStarted, 1, "they opened it")
        equal(c?.longestSilence, nil, "no gap in a single message")
        equal(s.leftOnRead.first?.handle, "+1555", "it is waiting on him")
        within(s.leftOnRead.first?.age, 3599, 3601, "waiting an hour")

        let later = Engine.analyze(store([msg(1, "+1555", me: false, 0)], [oneToOne(1, "+1555")]),
                                   now: t0.addingTimeInterval(3 * 86400))
        equal(later.contact("+1555")?.myReplyRate, 0, "three days on, it counts as unanswered")
    }

    // MARK: bursts

    static func testBurstsAndLatency() {
        print("\nbursts and latency")
        let h = "+1999"
        let msgs = [
            msg(1, h, me: false, 0, "you up?"),
            msg(1, h, me: false, 10, "need a ride"),      // same burst, 10s later
            msg(1, h, me: false, 35, "to the airport"),   // 25s after that: still the burst
            msg(1, h, me: true, 335, "yeah"),             // 300s after the LAST of theirs
            msg(1, h, me: true, 340, "what time"),
            msg(1, h, me: false, 460, "6am"),             // they answer in 120s
            msg(1, h, me: true, 1060, "bet"),             // he answers in 600s
            msg(1, h, me: true, 1200, "actually 6:30?"),  // 140s later: a second burst — double text
        ]
        let bursts = Engine.makeBursts(msgs, chatID: 1, gap: 30)
        equal(bursts.count, 5, "eight messages fold into five bursts")
        equal(bursts.first?.messageCount, 3, "messages under 30s apart are one burst")
        equal(bursts.first?.lastText, "to the airport", "a burst ends on its last message")

        let s = Engine.analyze(store(msgs, [oneToOne(1, h)]), now: t0.addingTimeInterval(1300))
        let c = s.contact(h)
        equal(c?.myReplies.count, 2, "two replies from him")
        equal(c?.myReplies.median, 450, "latency runs from the end of their burst (300 and 600)")
        equal(c?.theirReplies.median, 120, "their reply latency")
        equal(c?.myDoubleTexts, 1, "his follow-up before an answer is a double text")
        equal(c?.theirDoubleTexts, 0, "they did not double text")
        equal(c?.sent, 4, "messages sent")
        equal(c?.received, 4, "messages received")
        equal(c?.myReplyRate, 1, "both their bursts were answered")
        equal(c?.theirReplyRate, 0.5, "his first burst answered; the last is pending, the double-texted one is not")
        within(c?.myWordsPerMessage, 1.49, 1.51, "words per message (6 words / 4)")
        equal(c?.longestSilence, 600, "longest silence inside the thread")
    }

    // MARK: conversations

    static func testConversationsAndRates() {
        print("\nconversations and reply rate")
        let h = "+1777"
        let day: TimeInterval = 86400
        let msgs = [
            msg(1, h, me: false, 0),              // they open #1
            msg(1, h, me: true, 60),              // he answers
            msg(1, h, me: false, 2 * day),        // they open #2 (two days on — not a reply)
            msg(1, h, me: true, 4 * day),         // he opens #3: ignored #2 for two days
            msg(1, h, me: false, 4 * day + 30),   // they answer
        ]
        let s = Engine.analyze(store(msgs, [oneToOne(1, h)]), now: t0.addingTimeInterval(5 * day))
        let c = s.contact(h)
        equal(c?.conversations, 3, "a 24h silence starts a new conversation")
        equal(c?.conversationsTheyStarted, 2, "they opened two")
        equal(c?.conversationsIStarted, 1, "he opened one")
        equal(c?.myReplies.count, 1, "a message two days later is not a reply")
        within(c?.myReplyRate, 0.49, 0.51, "one of their two finished bursts answered")
        equal(s.conversations, 3, "overall conversations")
        within(s.iStartShare, 0.33, 0.34, "he opens a third")
        equal(s.longestSilence?.duration, 2 * day, "longest silence")
        equal(s.longestSilence?.handle, h, "…and whose")
    }

    // MARK: tapbacks

    static func testTapbacksAreNotReplies() {
        print("\ntapbacks")
        let h = "+1888"
        let msgs = [
            msg(1, h, me: false, 0, "look at this"),
            msg(1, h, me: true, 5, "", tapback: 2003),   // a laugh 5s later — not a reply
            msg(1, h, me: true, 900, "lmao"),            // the real reply
            msg(1, h, me: false, 905, "", tapback: 2000),
            msg(1, h, me: false, 910, "", tapback: 3000), // a removal
        ]
        let s = Engine.analyze(store(msgs, [oneToOne(1, h)]), now: t0.addingTimeInterval(1000))
        equal(s.contact(h)?.myReplies.median, 900, "a tapback does not count as answering")
        equal(s.sent, 1, "tapbacks are not sent messages")
        equal(s.received, 1, "…or received ones")
        equal(s.tapbacks.sent, 1, "tapbacks he sent")
        equal(s.tapbacks.received, 2, "tapbacks he got")
        equal(s.tapbacks.byKind[.laugh], 1, "kind decoded: laugh")
        equal(s.tapbacks.byKind[.removed], 1, "a 3000-series row is a removal")
        equal(s.contact(h)?.tapbacks.total, 3, "per-contact tapbacks")
        equal(s.sentByHour.reduce(0, +), 1, "tapbacks stay out of the hour histogram")
    }

    // MARK: groups

    static func testGroupsStayOutOfContacts() {
        print("\ngroup chats")
        let a = "+1111", b = "+1222"
        let group = Conversation(id: 9, guid: "grp", displayName: "Crew",
                                 participants: [a, b], service: "iMessage")
        let msgs = [
            msg(1, a, me: false, 0), msg(1, a, me: true, 100),
            msg(9, a, me: false, 200), msg(9, b, me: false, 260), msg(9, a, me: true, 5000),
        ]
        let s = Engine.analyze(store(msgs, [oneToOne(1, a), group]), now: t0.addingTimeInterval(6000))
        equal(s.contacts.map(\.id), [a], "a group is not a contact")
        equal(s.contact(a)?.received, 1, "group messages are not counted against a contact")
        equal(s.contact(a)?.myReplies.median, 100, "group replies stay out of contact latency")
        equal(s.myReplies.count, 1, "…and out of the overall latency")
        equal(s.groups.count, 1, "the group is reported on its own")
        equal(s.groups.first?.title, "Crew", "with its name")
        equal(s.groups.first?.myReplies.median, 4740, "his reply in the group, from the last other burst")
        within(s.groups.first?.myShare, 0.33, 0.34, "his share of the group")
        equal(s.received, 3, "totals still include group messages")
        expect(s.leftOnRead.allSatisfy { $0.handle != b }, "a group is never left on read")
    }

    // MARK: left on read

    static func testLeftOnRead() {
        print("\nleft on read")
        let msgs = [
            msg(1, "+1a", me: true, 0), msg(1, "+1a", me: false, 100, "old one", read: true),
            msg(2, "+1b", me: false, 0), msg(2, "+1b", me: true, 50),
            msg(3, "+1c", me: true, 0), msg(3, "+1c", me: false, 5000, "first"),
            msg(3, "+1c", me: false, 9000, "newer"),
        ]
        let s = Engine.analyze(store(msgs, [oneToOne(1, "+1a"), oneToOne(2, "+1b"), oneToOne(3, "+1c")]),
                               now: t0.addingTimeInterval(10_000))
        equal(s.leftOnRead.map(\.handle), ["+1a", "+1c"], "threads ending on them, oldest first")
        equal(s.leftOnRead.first?.wasRead, true, "read receipt carried through")
        equal(s.leftOnRead.last?.pendingMessages, 2, "both unanswered messages counted")
        equal(s.leftOnRead.last?.lastText, "newer", "newest text shown")
        equal(s.leftOnRead.last?.waitingSince, t0.addingTimeInterval(5000), "waiting since their first")
        equal(s.leftOnRead.last?.age, 1000, "age from their newest message")
    }

    // MARK: the fixture

    /// The known answers baked into Tools/make-fixture.swift.
    struct Known {
        let handle: String
        let myReply: Double, theirReply: Double, theyStart: Double, heGhosts: Double
    }
    static let gbemini = Known(handle: "+14435637111", myReply: 90, theirReply: 240, theyStart: 0.55, heGhosts: 0.02)
    static let mum = Known(handle: "+12403319087", myReply: 5400, theirReply: 900, theyStart: 0.8, heGhosts: 0.18)
    static let tobi = Known(handle: "+14105552981", myReply: 600, theirReply: 480, theyStart: 0.5, heGhosts: 0.05)
    static let ray = Known(handle: "+14432200144", myReply: 2700, theirReply: 10800, theyStart: 0.9, heGhosts: 0.25)
    static let deji = Known(handle: "deji.a@icloud.com", myReply: 1200, theirReply: 3600, theyStart: 0.35, heGhosts: 0.08)
    static let amara = Known(handle: "+12026619912", myReply: 240, theirReply: 180, theyStart: 0.45, heGhosts: 0.03)
    static let marcus = Known(handle: "+14437780031", myReply: 480, theirReply: 5400, theyStart: 0.95, heGhosts: 0.1)
    static let kemi = Known(handle: "+13015540277", myReply: 14400, theirReply: 600, theyStart: 0.85, heGhosts: 0.45)
    static let everyone = [gbemini, mum, tobi, ray, deji, amara, marcus, kemi]

    /// fixtures/sample-chat.db, generated if it is not there yet. The file's
    /// modification time is when the generator ran, which is the "now" the
    /// history is anchored to.
    static func fixture() -> (URL, Date)? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures/sample-chat.db")
        if !FileManager.default.fileExists(atPath: url.path) {
            print("  (generating fixtures/sample-chat.db)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            p.arguments = ["Tools/make-fixture.swift"]
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let made = attrs[.modificationDate] as? Date else { return nil }
        return (url, made)
    }

    static func testFixture() {
        print("\nfixtures/sample-chat.db")
        guard let (url, now) = fixture(), let store = try? ChatDB(url: url).load() else {
            failures += 1; checks += 1
            print("  FAIL  could not read fixtures/sample-chat.db"); return
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!   // the generator's waking hours
        let s = Engine.analyze(store, now: now, calendar: cal)

        expect(store.messages.count > 3000, "the fixture has a real history (\(store.messages.count) messages)")
        equal(s.sent + s.received + s.tapbacks.total, store.messages.count,
              "every message is either counted or a tapback")
        within(Double(s.tapbacks.total), 150, 250, "about 200 tapbacks")
        within(Stats.ratio(s.tapbacks.sent, s.tapbacks.total), 0.35, 0.65, "tapbacks split both ways")
        equal(s.contacts.count, 8, "eight one-to-one contacts")
        equal(s.groups.count, 2, "two group chats, kept apart")
        expect(Set(s.groups.map(\.title)) == ["Morgan CS 201", "Sunday ball"], "groups by name")

        print("\n  reply speed per contact, his and theirs (median within 0.6×–2× of the generator's)")
        for k in everyone {
            guard let c = s.contact(k.handle) else {
                failures += 1; checks += 1; print("  FAIL  \(k.handle) missing"); continue
            }
            within(c.myReplies.median, k.myReply * 0.6, k.myReply * 2, "\(k.handle) his median")
            within(c.theirReplies.median, k.theirReply * 0.6, k.theirReply * 2, "\(k.handle) their median")
            expect((c.myReplies.p90 ?? 0) > (c.myReplies.median ?? .infinity),
                   "\(k.handle) his p90 sits above his median")
            expect(c.myReplies.count >= 10, "\(k.handle) has enough replies to measure (\(c.myReplies.count))")
            within(c.theyStartShare, k.theyStart - 0.15, k.theyStart + 0.15, "\(k.handle) they open")
        }

        print("\n  rankings")
        equal(s.myFastest.first?.handle, gbemini.handle, "he answers Gbemini fastest")
        equal(s.mySlowest.first?.handle, kemi.handle, "he answers Kemi slowest")
        expect([amara.handle, gbemini.handle].contains(s.theirFastest.first?.handle ?? ""),
               "Amara or Gbemini answer him fastest")
        equal(s.theirSlowest.first?.handle, ray.handle, "Coach Ray answers him slowest")
        within((s.contact(kemi.handle)?.myReplies.median ?? 0) / (s.contact(gbemini.handle)?.myReplies.median ?? 1),
               50, 300, "Kemi waits roughly a hundred times longer than Gbemini for an answer")

        print("\n  reply rate (who he ghosts)")
        let rates = everyone.compactMap { k in s.contact(k.handle)?.myReplyRate.map { (k.handle, $0) } }
        equal(rates.count, 8, "every contact has a reply rate")
        equal(rates.min { $0.1 < $1.1 }?.0, kemi.handle, "Kemi (45% ghosted) has his lowest reply rate")
        within(s.contact(kemi.handle)?.myReplyRate, 0.3, 0.65, "Kemi reply rate")
        within(s.contact(gbemini.handle)?.myReplyRate, 0.72, 0.95, "Gbemini reply rate")
        expect((s.contact(gbemini.handle)?.myReplyRate ?? 0) - (s.contact(kemi.handle)?.myReplyRate ?? 1) > 0.2,
               "Gbemini gets answered far more often than Kemi")
        within(s.myReplyRate, 0.6, 0.9, "overall reply rate")

        print("\n  who starts conversations")
        within(s.iStartShare, 0.3, 0.5, "he opens fewer than half overall")
        expect((s.contact(marcus.handle)?.theyStartShare ?? 0) > (s.contact(deji.handle)?.theyStartShare ?? 1),
               "Marcus opens more of his conversations than Deji does")

        print("\n  left on read")
        let kemiWaiting = s.leftOnRead.first { $0.handle == kemi.handle }
        expect(kemiWaiting != nil, "Kemi's thread is left on read")
        within(kemiWaiting.map { $0.age / 86400 }, 9.5, 11.5, "for about eleven days")
        equal(kemiWaiting?.wasRead, true, "and he read it")
        expect((kemiWaiting?.pendingMessages ?? 0) >= 3, "three or more of her messages waiting")
        equal(kemiWaiting?.lastText, "ok bet", "her last word")
        expect(zip(s.leftOnRead, s.leftOnRead.dropFirst()).allSatisfy { $0.age >= $1.age },
               "ranked oldest first")
        equal(s.leftOnRead.first?.handle, kemi.handle, "Kemi has waited longest")
        expect(s.leftOnRead.allSatisfy { h in s.contacts.contains { $0.id == h.handle } },
               "only one-to-one threads are left on read")

        print("\n  overall and activity")
        expect((s.myReplies.p90 ?? 0) > (s.myReplies.median ?? .infinity), "overall p90 above median")
        within(s.myReplies.median, 120, 2400, "overall median his reply")
        within(s.theirReplies.median, 120, 2400, "overall median their reply")
        let sentAwake = s.sentByHour[8...23].reduce(0, +), recvAwake = s.receivedByHour[8...23].reduce(0, +)
        within(Stats.ratio(sentAwake + recvAwake, s.sent + s.received), 0.9, 1.0,
               "90%+ of messages fall 8am–midnight, the generator's waking hours")
        equal(s.sentByHour.reduce(0, +), s.sent, "hour histogram sums to sent")
        equal(s.receivedByWeekday.reduce(0, +), s.received, "weekday histogram sums to received")
        expect(s.sentByWeekday.allSatisfy { $0 > 0 }, "he texts every day of the week")
        within(s.myWordsPerMessage, 1.5, 5, "his words per message (short lines)")
        within(s.theirWordsPerMessage, 1.5, 5, "their words per message")
        within(Stats.ratio(s.received, s.sent), 1.1, 1.5, "he receives more than he sends")
        within(s.longestSilence.map { $0.duration / 86400 }, 5, 60, "longest silence is days, not months")
        expect(s.myDoubleTexts > 0 && s.theirDoubleTexts > 0, "double texts happen both ways")
        expect((s.contact(kemi.handle)?.theirDoubleTexts ?? 0) >= 2,
               "Kemi's unanswered hello?? and ok bet are double texts")

        let g = s.groups.first { $0.title == "Morgan CS 201" }
        within(g?.myShare, 0.18, 0.38, "he writes ~28% of the class group")
        expect((g?.myReplies.count ?? 0) > 0, "his group replies are measured")
    }
}
