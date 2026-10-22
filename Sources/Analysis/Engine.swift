import Foundation

// The statistics. Pure functions over a MessageStore: no I/O, no globals, so
// the same input always gives the same Snapshot and the tests can pin `now`.
//
// The turn model:
//   message  → one row, tapbacks excluded (they are reactions, not replies)
//   burst    → consecutive messages from the same sender less than
//              `burstGap` apart ("on my way" "5 min" "ok" is one thought)
//   reply    → the first message of a burst that follows the OTHER side's
//              burst within `conversationGap`. Its latency runs from the LAST
//              message of the burst it answers.
//   conversation → bursts separated by less than `conversationGap`. The
//              sender of the first burst after a longer silence opened it.
//
// Reply latency is measured in one-to-one threads only. In a group nobody
// owes anybody an answer and a reply cannot be pinned on one contact, so
// groups get their own, smaller set of numbers (GroupStats).

// MARK: - options

struct AnalysisOptions: Sendable {
    /// Messages from the same sender closer than this are one burst.
    var burstGap: TimeInterval = 30
    /// A silence this long ends a conversation: the next burst opens a new
    /// one rather than replying to the last.
    var conversationGap: TimeInterval = 24 * 3600
    /// A contact needs this many replies before it is ranked fastest/slowest,
    /// so one lucky answer does not top the chart.
    var minimumRepliesToRank: Int = 5

    static let standard = AnalysisOptions()
}

// MARK: - building blocks

/// Median, 90th percentile and mean of a set of durations (seconds).
/// Every field is nil when there is nothing to measure.
struct LatencyStats: Sendable, Equatable {
    let count: Int
    let median: TimeInterval?
    let p90: TimeInterval?
    let mean: TimeInterval?

    static let empty = LatencyStats(count: 0, median: nil, p90: nil, mean: nil)

    init(count: Int, median: TimeInterval?, p90: TimeInterval?, mean: TimeInterval?) {
        self.count = count; self.median = median; self.p90 = p90; self.mean = mean
    }

    init(_ values: [TimeInterval]) {
        let sorted = values.sorted()
        count = sorted.count
        median = Stats.percentile(sorted, 0.5)
        p90 = Stats.percentile(sorted, 0.9)
        mean = sorted.isEmpty ? nil : sorted.reduce(0, +) / Double(sorted.count)
    }
}

enum Stats {
    /// Linear-interpolated percentile of an ALREADY SORTED array.
    /// nil for an empty array; the only value for a single-element array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    /// a / b, or nil when b is zero.
    static func ratio(_ a: Int, _ b: Int) -> Double? {
        b == 0 ? nil : Double(a) / Double(b)
    }
}

/// The reaction a tapback carries. 2000–2005 add one; 3000–3005 take it back.
enum TapbackKind: String, Sendable, CaseIterable {
    case love, like, dislike, laugh, emphasize, question, other, removed

    init(associatedType t: Int) {
        switch t {
        case 2000: self = .love
        case 2001: self = .like
        case 2002: self = .dislike
        case 2003: self = .laugh
        case 2004: self = .emphasize
        case 2005: self = .question
        case 3000...3999: self = .removed
        default: self = .other
        }
    }
}

struct TapbackCounts: Sendable, Equatable {
    var sent = 0
    var received = 0
    var byKind: [TapbackKind: Int] = [:]
    var total: Int { sent + received }
}

/// A run of messages from one sender, less than `burstGap` apart.
struct Burst: Sendable, Equatable {
    let chatID: Int64
    let isFromMe: Bool
    /// Who sent it — "me", or the other party's handle.
    let sender: String
    let first: Date
    let last: Date
    let messageCount: Int
    let lastText: String
}

// MARK: - the results

struct ContactStats: Sendable, Identifiable {
    /// The handle (phone number or email). Several one-to-one threads with the
    /// same handle (iMessage and SMS) are pooled under it.
    let id: String
    let title: String
    let chatIDs: [Int64]

    /// How fast HE answers them.
    let myReplies: LatencyStats
    /// How fast THEY answer him.
    let theirReplies: LatencyStats

    /// Their bursts he answered / their bursts that have had time to be answered.
    let myReplyRate: Double?
    let inboundBursts: Int
    let inboundAnswered: Int
    /// His bursts they answered / his bursts that have had time to be answered.
    let theirReplyRate: Double?

    let conversations: Int
    let conversationsIStarted: Int
    let conversationsTheyStarted: Int
    /// Share of conversations they opened; nil with no conversations.
    var theyStartShare: Double? { Stats.ratio(conversationsTheyStarted, conversations) }

    let sent: Int
    let received: Int
    let myWordsPerMessage: Double?
    let theirWordsPerMessage: Double?

    /// He sent another burst before they answered the first.
    let myDoubleTexts: Int
    let theirDoubleTexts: Int

    let longestSilence: TimeInterval?
    let lastMessage: Date?
    let tapbacks: TapbackCounts
}

struct GroupStats: Sendable, Identifiable {
    let id: Int64
    let title: String
    let participants: [String]
    let messages: Int
    let sent: Int
    /// His share of the group's messages.
    var myShare: Double? { Stats.ratio(sent, messages) }
    /// His burst after someone else's burst in the group, within the window.
    let myReplies: LatencyStats
    let conversations: Int
    let conversationsIStarted: Int
    let lastMessage: Date?
}

/// A one-to-one thread whose last word is theirs.
struct UnansweredThread: Sendable, Identifiable {
    var id: String { handle }
    let handle: String
    let title: String
    let chatID: Int64
    /// Their newest message.
    let lastMessage: Date
    /// The first of their messages since he last said anything.
    let waitingSince: Date
    /// now − lastMessage
    let age: TimeInterval
    /// How many messages of theirs are sitting there.
    let pendingMessages: Int
    let lastText: String
    /// Whether the database says he read it.
    let wasRead: Bool
}

struct RankedContact: Sendable, Equatable {
    let handle: String
    let title: String
    let median: TimeInterval
    let replies: Int
}

/// Everything the views read. Immutable: recompute it, never edit it.
struct Snapshot: Sendable {
    let generatedAt: Date
    let options: AnalysisOptions

    // overall, one-to-one threads
    let myReplies: LatencyStats
    let theirReplies: LatencyStats
    let myReplyRate: Double?
    let theirReplyRate: Double?
    let conversations: Int
    let conversationsIStarted: Int
    let conversationsTheyStarted: Int
    var iStartShare: Double? { Stats.ratio(conversationsIStarted, conversations) }
    let myDoubleTexts: Int
    let theirDoubleTexts: Int

    // everything, groups included
    let sent: Int
    let received: Int
    let myWordsPerMessage: Double?
    let theirWordsPerMessage: Double?
    /// Index 0 = midnight–1am, in the calendar's time zone.
    let sentByHour: [Int]
    let receivedByHour: [Int]
    /// Index 0 = Sunday … 6 = Saturday.
    let sentByWeekday: [Int]
    let receivedByWeekday: [Int]
    let tapbacks: TapbackCounts

    /// The longest gap inside any one-to-one thread, and whose it was.
    let longestSilence: (handle: String, title: String, duration: TimeInterval)?

    let contacts: [ContactStats]
    let groups: [GroupStats]
    /// Oldest first.
    let leftOnRead: [UnansweredThread]

    /// Contacts with enough replies to rank, quickest first.
    let myFastest: [RankedContact]
    let theirFastest: [RankedContact]
    var mySlowest: [RankedContact] { myFastest.reversed() }
    var theirSlowest: [RankedContact] { theirFastest.reversed() }

    func contact(_ handle: String) -> ContactStats? { contacts.first { $0.id == handle } }

    var isEmpty: Bool { sent + received == 0 }
}

// MARK: - the engine

enum Engine {

    static func analyze(_ store: MessageStore,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        options: AnalysisOptions = .standard) -> Snapshot {

        // Totals over every substantive message, groups included.
        var sentByHour = [Int](repeating: 0, count: 24)
        var receivedByHour = [Int](repeating: 0, count: 24)
        var sentByWeekday = [Int](repeating: 0, count: 7)
        var receivedByWeekday = [Int](repeating: 0, count: 7)
        var sent = 0, received = 0
        var myWords = 0, myWorded = 0, theirWords = 0, theirWorded = 0
        var tapbacks = TapbackCounts()
        var tapbacksByChat: [Int64: TapbackCounts] = [:]
        var byChat: [Int64: [Message]] = [:]

        for m in store.messages {
            if m.isTapback {
                record(tapback: m, into: &tapbacks)
                if let c = m.chatID { record(tapback: m, into: &tapbacksByChat[c, default: TapbackCounts()]) }
                continue
            }
            guard m.isSubstantive else { continue }
            let hour = calendar.component(.hour, from: m.date)
            let weekday = calendar.component(.weekday, from: m.date) - 1
            let words = m.wordCount
            if m.isFromMe {
                sent += 1
                sentByHour[hour] += 1; sentByWeekday[weekday] += 1
                if words > 0 { myWords += words; myWorded += 1 }
            } else {
                received += 1
                receivedByHour[hour] += 1; receivedByWeekday[weekday] += 1
                if words > 0 { theirWords += words; theirWorded += 1 }
            }
            if let c = m.chatID { byChat[c, default: []].append(m) }
        }

        // One-to-one threads, pooled per handle.
        var pooled: [String: ThreadResult] = [:]
        var titles: [String: String] = [:]
        var groups: [GroupStats] = []
        var unanswered: [UnansweredThread] = []

        let known = Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.id, $0) })
        // Threads with messages but no chat row still get analysed, keyed by
        // whatever handle their inbound messages carry.
        let chatIDs = Set(byChat.keys).union(known.keys).sorted()

        for chatID in chatIDs {
            let msgs = (byChat[chatID] ?? []).sorted { $0.date < $1.date }
            let convo = known[chatID]
            let isGroup = convo?.isGroup ?? (Set(msgs.compactMap { $0.isFromMe ? nil : $0.handle }).count > 1)
            let bursts = makeBursts(msgs, chatID: chatID, gap: options.burstGap)

            if isGroup {
                groups.append(groupStats(chatID: chatID, convo: convo, msgs: msgs,
                                         bursts: bursts, options: options))
                continue
            }

            guard let handle = convo?.participants.first
                    ?? msgs.first(where: { !$0.isFromMe })?.handle
                    ?? msgs.first?.handle
            else { continue }
            titles[handle] = titles[handle] ?? convo?.title ?? handle

            var result = thread(msgs: msgs, bursts: bursts, now: now, options: options)
            result.chatIDs = [chatID]
            result.tapbacks = tapbacksByChat[chatID] ?? TapbackCounts()
            pooled[handle] = pooled[handle].map { $0.merged(with: result) } ?? result

            if let last = bursts.last, !last.isFromMe {
                let pending = bursts.reversed().prefix { !$0.isFromMe }
                let pendingMessages = msgs.reversed().prefix { !$0.isFromMe }
                unanswered.append(UnansweredThread(
                    handle: handle, title: titles[handle] ?? handle, chatID: chatID,
                    lastMessage: last.last,
                    waitingSince: pending.last?.first ?? last.first,
                    age: max(0, now.timeIntervalSince(last.last)),
                    pendingMessages: pendingMessages.count,
                    lastText: last.lastText,
                    wasRead: pendingMessages.first?.dateRead != nil))
            }
        }

        // If the same handle is waiting in two threads, keep the newer one.
        var newest: [String: UnansweredThread] = [:]
        for u in unanswered where (newest[u.handle]?.lastMessage ?? .distantPast) < u.lastMessage {
            newest[u.handle] = u
        }
        let leftOnRead = newest.values.sorted {
            $0.age != $1.age ? $0.age > $1.age : $0.handle < $1.handle
        }

        let contacts: [ContactStats] = pooled.keys.sorted().map { handle in
            pooled[handle]!.stats(handle: handle, title: titles[handle] ?? handle)
        }.sorted { ($0.sent + $0.received, $1.id) > ($1.sent + $1.received, $0.id) }

        // Overall, one-to-one only.
        let all = pooled.values
        let myLat = all.flatMap { $0.myLatencies }
        let theirLat = all.flatMap { $0.theirLatencies }
        let inbound = all.reduce(0) { $0 + $1.inboundDue }
        let answered = all.reduce(0) { $0 + $1.inboundAnswered }
        let outbound = all.reduce(0) { $0 + $1.outboundDue }
        let outAnswered = all.reduce(0) { $0 + $1.outboundAnswered }

        var longest: (handle: String, title: String, duration: TimeInterval)?
        for c in contacts {
            if let s = c.longestSilence, s > (longest?.duration ?? -1) {
                longest = (c.id, c.title, s)
            }
        }

        func ranked(_ pick: (ContactStats) -> LatencyStats) -> [RankedContact] {
            contacts.compactMap { c in
                let l = pick(c)
                guard l.count >= options.minimumRepliesToRank, let med = l.median else { return nil }
                return RankedContact(handle: c.id, title: c.title, median: med, replies: l.count)
            }.sorted { ($0.median, $0.handle) < ($1.median, $1.handle) }
        }

        return Snapshot(
            generatedAt: now, options: options,
            myReplies: LatencyStats(myLat), theirReplies: LatencyStats(theirLat),
            myReplyRate: Stats.ratio(answered, inbound),
            theirReplyRate: Stats.ratio(outAnswered, outbound),
            conversations: all.reduce(0) { $0 + $1.conversations },
            conversationsIStarted: all.reduce(0) { $0 + $1.iStarted },
            conversationsTheyStarted: all.reduce(0) { $0 + $1.theyStarted },
            myDoubleTexts: all.reduce(0) { $0 + $1.myDoubleTexts },
            theirDoubleTexts: all.reduce(0) { $0 + $1.theirDoubleTexts },
            sent: sent, received: received,
            myWordsPerMessage: myWorded == 0 ? nil : Double(myWords) / Double(myWorded),
            theirWordsPerMessage: theirWorded == 0 ? nil : Double(theirWords) / Double(theirWorded),
            sentByHour: sentByHour, receivedByHour: receivedByHour,
            sentByWeekday: sentByWeekday, receivedByWeekday: receivedByWeekday,
            tapbacks: tapbacks,
            longestSilence: longest,
            contacts: contacts,
            groups: groups.sorted { ($0.messages, $1.id) > ($1.messages, $0.id) },
            leftOnRead: leftOnRead,
            myFastest: ranked { $0.myReplies },
            theirFastest: ranked { $0.theirReplies })
    }

    // MARK: bursts

    /// Groups time-sorted, tapback-free messages into bursts.
    static func makeBursts(_ msgs: [Message], chatID: Int64, gap: TimeInterval) -> [Burst] {
        var out: [Burst] = []
        var start = 0
        func sender(_ m: Message) -> String { m.isFromMe ? "me" : (m.handle ?? "them") }
        for i in msgs.indices {
            let isLast = i == msgs.count - 1
            let breaks = isLast
                || sender(msgs[i + 1]) != sender(msgs[i])
                || msgs[i + 1].date.timeIntervalSince(msgs[i].date) >= gap
            if breaks {
                out.append(Burst(chatID: chatID, isFromMe: msgs[start].isFromMe,
                                 sender: sender(msgs[start]),
                                 first: msgs[start].date, last: msgs[i].date,
                                 messageCount: i - start + 1, lastText: msgs[i].text))
                start = i + 1
            }
        }
        return out
    }

    // MARK: one-to-one threads

    /// The raw numbers from one thread, kept as lists so threads with the same
    /// person can be pooled before medians are taken.
    struct ThreadResult {
        var chatIDs: [Int64] = []
        var myLatencies: [TimeInterval] = []
        var theirLatencies: [TimeInterval] = []
        var inboundDue = 0, inboundAnswered = 0
        var outboundDue = 0, outboundAnswered = 0
        var conversations = 0, iStarted = 0, theyStarted = 0
        var sent = 0, received = 0
        var myWords = 0, myWorded = 0, theirWords = 0, theirWorded = 0
        var myDoubleTexts = 0, theirDoubleTexts = 0
        var longestSilence: TimeInterval?
        var lastMessage: Date?
        var tapbacks = TapbackCounts()

        func merged(with o: ThreadResult) -> ThreadResult {
            var r = self
            r.chatIDs += o.chatIDs
            r.myLatencies += o.myLatencies; r.theirLatencies += o.theirLatencies
            r.inboundDue += o.inboundDue; r.inboundAnswered += o.inboundAnswered
            r.outboundDue += o.outboundDue; r.outboundAnswered += o.outboundAnswered
            r.conversations += o.conversations
            r.iStarted += o.iStarted; r.theyStarted += o.theyStarted
            r.sent += o.sent; r.received += o.received
            r.myWords += o.myWords; r.myWorded += o.myWorded
            r.theirWords += o.theirWords; r.theirWorded += o.theirWorded
            r.myDoubleTexts += o.myDoubleTexts; r.theirDoubleTexts += o.theirDoubleTexts
            r.longestSilence = [longestSilence, o.longestSilence].compactMap { $0 }.max()
            r.lastMessage = [lastMessage, o.lastMessage].compactMap { $0 }.max()
            r.tapbacks.sent += o.tapbacks.sent
            r.tapbacks.received += o.tapbacks.received
            r.tapbacks.byKind.merge(o.tapbacks.byKind, uniquingKeysWith: +)
            return r
        }

        func stats(handle: String, title: String) -> ContactStats {
            ContactStats(
                id: handle, title: title, chatIDs: chatIDs,
                myReplies: LatencyStats(myLatencies),
                theirReplies: LatencyStats(theirLatencies),
                myReplyRate: Stats.ratio(inboundAnswered, inboundDue),
                inboundBursts: inboundDue, inboundAnswered: inboundAnswered,
                theirReplyRate: Stats.ratio(outboundAnswered, outboundDue),
                conversations: conversations,
                conversationsIStarted: iStarted, conversationsTheyStarted: theyStarted,
                sent: sent, received: received,
                myWordsPerMessage: myWorded == 0 ? nil : Double(myWords) / Double(myWorded),
                theirWordsPerMessage: theirWorded == 0 ? nil : Double(theirWords) / Double(theirWorded),
                myDoubleTexts: myDoubleTexts, theirDoubleTexts: theirDoubleTexts,
                longestSilence: longestSilence, lastMessage: lastMessage,
                tapbacks: tapbacks)
        }
    }

    static func thread(msgs: [Message], bursts: [Burst], now: Date,
                       options: AnalysisOptions) -> ThreadResult {
        var r = ThreadResult()
        for m in msgs {
            let w = m.wordCount
            if m.isFromMe { r.sent += 1; if w > 0 { r.myWords += w; r.myWorded += 1 } }
            else { r.received += 1; if w > 0 { r.theirWords += w; r.theirWorded += 1 } }
        }
        r.lastMessage = msgs.last?.date

        for (i, b) in bursts.enumerated() {
            // Who opened, who replied, who double-texted.
            if i == 0 {
                r.conversations += 1
                if b.isFromMe { r.iStarted += 1 } else { r.theyStarted += 1 }
            } else {
                let prev = bursts[i - 1]
                let gap = b.first.timeIntervalSince(prev.last)
                r.longestSilence = max(r.longestSilence ?? 0, gap)
                if gap >= options.conversationGap {
                    r.conversations += 1
                    if b.isFromMe { r.iStarted += 1 } else { r.theyStarted += 1 }
                } else if b.isFromMe != prev.isFromMe {
                    if b.isFromMe { r.myLatencies.append(gap) } else { r.theirLatencies.append(gap) }
                } else {
                    if b.isFromMe { r.myDoubleTexts += 1 } else { r.theirDoubleTexts += 1 }
                }
            }

            // Was this burst answered? A burst still inside the window with
            // nothing after it is pending, not ignored, so it counts for neither.
            let next = i + 1 < bursts.count ? bursts[i + 1] : nil
            let answered = next.map {
                $0.isFromMe != b.isFromMe && $0.first.timeIntervalSince(b.last) < options.conversationGap
            } ?? false
            let due = answered || next != nil || now.timeIntervalSince(b.last) >= options.conversationGap
            guard due else { continue }
            if b.isFromMe {
                r.outboundDue += 1; if answered { r.outboundAnswered += 1 }
            } else {
                r.inboundDue += 1; if answered { r.inboundAnswered += 1 }
            }
        }
        return r
    }

    // MARK: groups

    static func groupStats(chatID: Int64, convo: Conversation?, msgs: [Message],
                           bursts: [Burst], options: AnalysisOptions) -> GroupStats {
        var replies: [TimeInterval] = []
        var conversations = 0, iStarted = 0
        for (i, b) in bursts.enumerated() {
            let gap = i == 0 ? .infinity : b.first.timeIntervalSince(bursts[i - 1].last)
            if gap >= options.conversationGap {
                conversations += 1
                if b.isFromMe { iStarted += 1 }
            } else if b.isFromMe && !bursts[i - 1].isFromMe {
                replies.append(gap)
            }
        }
        return GroupStats(
            id: chatID, title: convo?.title ?? "Group \(chatID)",
            participants: convo?.participants ?? [],
            messages: msgs.count, sent: msgs.filter(\.isFromMe).count,
            myReplies: LatencyStats(replies),
            conversations: conversations, conversationsIStarted: iStarted,
            lastMessage: msgs.last?.date)
    }

    // MARK: tapbacks

    private static func record(tapback m: Message, into c: inout TapbackCounts) {
        if m.isFromMe { c.sent += 1 } else { c.received += 1 }
        c.byKind[TapbackKind(associatedType: m.associatedType), default: 0] += 1
    }
}
