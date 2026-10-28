import Foundation

// The deterministic half of the style read-out: what goes INTO the on-device
// model and how what comes OUT is cleaned up. Nothing here touches
// FoundationModels, so all of it is tested without the model.
//
// The on-device model has a small context window (about 4,000 tokens for
// instructions, prompt and answer together), so every input is capped:
// at most `StyleSample.maxMessages` of his messages, each cut to
// `maxCharsPerMessage`, all of them together under `maxTotalChars`, and the
// finished prompt under `StylePrompt.maxPromptChars`.

// MARK: - sampling his own messages

enum StyleSample {
    static let maxMessages = 30
    static let maxCharsPerMessage = 100
    static let maxTotalChars = 1_800

    /// A small, even spread of messages HE sent, oldest first. Only his own
    /// words — never anyone else's. Tapbacks, attachment-only rows and exact
    /// repeats are skipped. Deterministic: the same store gives the same sample.
    static func pick(from store: MessageStore,
                     limit: Int = maxMessages,
                     perMessage: Int = maxCharsPerMessage,
                     totalBudget: Int = maxTotalChars) -> [String] {
        guard limit > 0, perMessage > 0, totalBudget > 0 else { return [] }

        var seen = Set<String>()
        var mine: [(date: Date, text: String)] = []
        for m in store.messages where m.isFromMe && !m.isTapback {
            guard let t = clean(m.text, maxChars: perMessage) else { continue }
            if seen.insert(t.lowercased()).inserted { mine.append((m.date, t)) }
        }
        mine.sort { $0.date < $1.date }
        guard !mine.isEmpty else { return [] }

        // Spread across the whole history, then shrink the count until the
        // total fits the budget, so the sample stays spread rather than
        // collapsing onto the oldest messages.
        var count = min(limit, mine.count)
        while count > 0 {
            let picked = evenlySpaced(mine.count, count).map { mine[$0].text }
            if picked.reduce(0, { $0 + $1.count }) <= totalBudget { return picked }
            count -= 1
        }
        return []
    }

    /// `count` indices spread evenly over 0..<total, first and last included.
    static func evenlySpaced(_ total: Int, _ count: Int) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        if count >= total { return Array(0..<total) }
        if count == 1 { return [total - 1] }
        let step = Double(total - 1) / Double(count - 1)
        return (0..<count).map { Int((Double($0) * step).rounded()) }
    }

    /// One message made safe to put in the prompt: attachment placeholders
    /// removed, links replaced with [link], whitespace collapsed, and cut at a
    /// word boundary to `maxChars` (with an ellipsis). Nil when nothing is left.
    static func clean(_ raw: String, maxChars: Int = maxCharsPerMessage) -> String? {
        let words = raw
            .replacingOccurrences(of: "\u{FFFC}", with: " ")   // attachment placeholder
            .replacingOccurrences(of: "\u{FFFD}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { w -> String in
                let lower = w.lowercased()
                return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
                    ? "[link]" : String(w)
            }
        let text = words.joined(separator: " ")
        guard !text.isEmpty, text != "[link]" else { return nil }
        return truncate(text, to: maxChars)
    }

    /// Cuts at the last space that fits, so words are not chopped in half;
    /// falls back to a hard cut for one very long word. The result, ellipsis
    /// included, is never longer than `limit` characters.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(max(limit, 0))) }
        let head = String(text.prefix(limit - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= limit / 2 {
            return head[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return head + "…"
    }
}

// MARK: - the prompt

enum StylePrompt {
    /// Prompt ceiling in characters (~1,200 tokens), leaving room for the
    /// instructions and a five-sentence answer inside the context window.
    static let maxPromptChars = 4_800
    /// Below this many sent messages there is no style to describe.
    static let minimumSent = 20

    static let instructions = """
    You describe a person's texting habits back to them, kindly and honestly, \
    in plain everyday English. Speak to them directly as "you". Use ONLY the \
    facts and messages you are given. Never invent a number; if you mention \
    one, it must appear in the facts. Do not name or guess at the people they \
    text. No lists, no headings, no markdown, no preamble.
    """

    /// The statistics as short English lines. Facts the snapshot cannot back
    /// (nil medians, empty histograms) are left out rather than stated as zero.
    static func facts(_ s: Snapshot) -> [String] {
        var out: [String] = []
        out.append("He sent \(s.sent) messages and received \(s.received).")

        if let med = s.myReplies.median {
            var line = "When someone texts him, his typical (median) reply takes \(duration(med))"
            if let p90 = s.myReplies.p90 { line += "; one reply in ten takes longer than \(duration(p90))" }
            out.append(line + ".")
        }
        if let med = s.theirReplies.median {
            out.append("When he texts someone, their typical reply takes \(duration(med)).")
        }
        if let r = s.myReplyRate {
            out.append("He answers \(percent(r)) of the messages people send him.")
        }
        if let r = s.theirReplyRate {
            out.append("Other people answer \(percent(r)) of his messages.")
        }
        if let share = s.iStartShare {
            out.append("He starts \(percent(share)) of his one-to-one conversations; the other person starts the rest.")
        }
        if let mine = s.myWordsPerMessage {
            var line = "His messages average \(oneDecimal(mine)) words"
            if let theirs = s.theirWordsPerMessage { line += ", against \(oneDecimal(theirs)) for the people he texts" }
            out.append(line + ".")
        }
        if s.myDoubleTexts + s.theirDoubleTexts > 0 {
            out.append("He sent a second message before getting an answer \(s.myDoubleTexts) times; other people did that to him \(s.theirDoubleTexts) times.")
        }
        if let hour = busiest(s.sentByHour) {
            out.append("He texts most between \(hourLabel(hour)) and \(hourLabel((hour + 1) % 24)).")
        }
        if let late = Stats.ratio(s.sentByHour.prefix(5).reduce(0, +), s.sentByHour.reduce(0, +)), late > 0 {
            out.append("\(percent(late)) of his messages are sent between midnight and 5 am.")
        }
        if let day = busiest(s.sentByWeekday), day < weekdays.count {
            out.append("His busiest day for texting is \(weekdays[day]).")
        }
        if s.tapbacks.total > 0 {
            out.append("He sent \(s.tapbacks.sent) tapback reactions and received \(s.tapbacks.received).")
        }
        if let fast = s.myFastest.first, let slow = s.mySlowest.first, slow.median > fast.median {
            out.append("His typical reply time differs a lot by person: \(duration(fast.median)) for the person he answers fastest, \(duration(slow.median)) for the slowest.")
        }
        if !s.leftOnRead.isEmpty, let oldest = s.leftOnRead.first {
            out.append("Right now \(s.leftOnRead.count) one-to-one threads end with a message he has not answered; the oldest has waited \(duration(oldest.age)).")
        }
        let groupMessages = s.groups.reduce(0) { $0 + $1.messages }
        if let share = Stats.ratio(s.groups.reduce(0) { $0 + $1.sent }, groupMessages) {
            out.append("He is in \(s.groups.count) group chats and writes \(percent(share)) of their messages.")
        }
        return out
    }

    /// The full prompt. Samples are dropped from the end until it fits
    /// `maxPromptChars`, so a long history can never overflow the model.
    static func build(snapshot: Snapshot, samples: [String]) -> String {
        let factBlock = facts(snapshot).map { "- \($0)" }.joined(separator: "\n")
        var kept = samples
        while true {
            let text = compose(facts: factBlock, samples: kept)
            if text.count <= maxPromptChars || kept.isEmpty { return text }
            kept.removeLast()
        }
    }

    private static func compose(facts: String, samples: [String]) -> String {
        var text = """
        Facts about how he texts, measured from his message history:
        \(facts)
        """
        if !samples.isEmpty {
            text += """


            A sample of messages HE sent (one per line, in his own words):
            \(samples.map { "> \($0)" }.joined(separator: "\n"))
            """
        }
        text += """


        Write four or five sentences describing his texting style: how fast he \
        replies, who usually starts, how long and in what tone he writes, and \
        when he is most active. \(samples.isEmpty ? "" : "Mention a habit you can see in his own messages (slang, punctuation, length, emoji) without quoting a whole message. ")Talk to him as "you".
        """
        return text
    }

    // MARK: formatting

    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Index of the largest bucket; nil when every bucket is zero. Ties go to
    /// the earliest index.
    static func busiest(_ buckets: [Int]) -> Int? {
        guard let top = buckets.max(), top > 0 else { return nil }
        return buckets.firstIndex(of: top)
    }

    static func hourLabel(_ h: Int) -> String {
        switch h {
        case 0: return "midnight"
        case 12: return "noon"
        case 1..<12: return "\(h) am"
        default: return "\(h - 12) pm"
        }
    }

    /// "45 seconds", "12 minutes", "1.5 hours", "3 days".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        func unit(_ v: Double, _ name: String) -> String {
            let text = v < 10 && v != v.rounded() ? oneDecimal(v) : String(Int(v.rounded()))
            return "\(text) \(name)\(text == "1" ? "" : "s")"
        }
        if s < 90 { return unit(s.rounded(), "second") }
        if s < 90 * 60 { return unit((s / 60).rounded(), "minute") }
        if s < 36 * 3600 { return unit(((s / 3600) * 10).rounded() / 10, "hour") }
        return unit(((s / 86400) * 10).rounded() / 10, "day")
    }

    static func percent(_ r: Double) -> String { "\(Int((r * 100).rounded()))%" }

    static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }
}

// MARK: - the answer

/// The read-out, cleaned up: between one and `maxSentences` plain sentences.
struct StyleReadOut: Equatable, Sendable {
    static let maxSentences = 5

    let sentences: [String]
    var text: String { sentences.joined(separator: " ") }

    /// Cleans what the model wrote: strips markdown, bullets and numbering,
    /// drops a "Here is…:" preamble, splits into sentences and keeps the
    /// first `maxSentences`. Nil when nothing usable came back.
    static func parse(_ raw: String) -> StyleReadOut? {
        var lines: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            // A markdown heading is a title, not part of the read-out.
            if l.hasPrefix("#") { continue }
            var isItem = false
            while let f = l.first, ">*-•".contains(f) {
                l.removeFirst(); l = l.trimmingCharacters(in: .whitespaces); isItem = true
            }
            if let r = l.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) {
                l.removeSubrange(r); isItem = true
            }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            guard !l.isEmpty else { continue }
            // A lead-in line such as "Here's your texting style:" carries nothing.
            if lines.isEmpty, l.hasSuffix(":") { continue }
            // A list item is its own sentence even when the model left off the stop.
            if isItem, let last = l.last, !terminators.contains(last) { l.append(".") }
            lines.append(l)
        }
        let sentences = split(lines.joined(separator: " "))
        guard !sentences.isEmpty else { return nil }
        return StyleReadOut(sentences: Array(sentences.prefix(maxSentences)))
    }

    /// Splits on . ! ? (and an ellipsis) followed by a space, so decimals like
    /// "2.5" stay whole. A fragment without a closing mark keeps a full stop.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            // A closing quote or bracket straight after the mark ends it too.
            let ends = terminators.contains(c)
                || (closers.contains(c) && i > 0 && terminators.contains(chars[i - 1]))
            let nextIsBreak = i + 1 >= chars.count || chars[i + 1].isWhitespace
            if ends && nextIsBreak {
                append(current, to: &out); current = ""
            }
        }
        append(current, to: &out)
        return out
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", ")", "”", "’"]

    private static func append(_ s: String, to out: inout [String]) {
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Ignore stray punctuation the model sometimes leaves on its own.
        guard t.contains(where: { $0.isLetter }) else { return }
        let last = t.last!
        out.append(terminators.contains(last) || closers.contains(last) ? t : t + ".")
    }
}
