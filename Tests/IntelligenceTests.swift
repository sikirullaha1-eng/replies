import Foundation
import FoundationModels

// Assertions for the on-device style read-out. Built and run by
// ./run-tests.sh intelligence.
//
// Everything deterministic — sampling his messages, cleaning and cutting
// them, building the prompt, mapping availability and errors, parsing the
// answer, caching — is tested against a stand-in model, so these pass on a
// Mac without Apple Intelligence. When the real on-device model IS available
// one last check asks it for a read-out of fixtures/sample-chat.db.

@main
struct IntelligenceTests {
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

    static func main() async {
        print("Intelligence tests")

        testAvailability()
        testFailures()
        testClean()
        testSpread()
        testSampling()
        testFormatting()
        testPrompt()
        testParse()
        await testGenerate()
        await testCache()
        await testFixtureAndLiveModel()

        print("\n\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: hand-built data

    static let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    nonisolated(unsafe) static var nextID: Int64 = 1

    static func msg(_ chat: Int64, _ handle: String, me: Bool, _ at: TimeInterval,
                    _ text: String, tapback: Int = 0) -> Message {
        nextID += 1
        return Message(id: nextID, guid: "g\(nextID)", date: t0.addingTimeInterval(at),
                       dateRead: nil, isFromMe: me, text: text, handle: handle, chatID: chat,
                       service: "iMessage", associatedType: tapback, hasAttachments: false)
    }

    static func store(_ messages: [Message]) -> MessageStore {
        var handles = Set<String>()
        for m in messages {
            if let chat = m.chatID, let handle = m.handle { handles.insert("\(chat)|\(handle)") }
        }
        let convos = handles.map { key -> Conversation in
            let parts = key.split(separator: "|")
            let id = Int64(parts[0])!
            return Conversation(id: id, guid: "c\(id)", displayName: nil, participants: [String(parts[1])], service: "iMessage")
        }
        return MessageStore(messages: messages.sorted { $0.date < $1.date }, conversations: convos, missingColumns: [])
    }

    /// A back-and-forth with one contact: they write "q<i>", he answers "a<i>"
    /// two minutes later, `rounds` times, an hour apart.
    static func chatty(rounds: Int, mine: (Int) -> String = { "a\($0) sounds good" }) -> MessageStore {
        var msgs: [Message] = []
        for i in 0..<rounds {
            let at = TimeInterval(i) * 3600
            msgs.append(msg(1, "+1555", me: false, at, "q\(i) THEIRS"))
            msgs.append(msg(1, "+1555", me: true, at + 120, mine(i)))
        }
        return store(msgs)
    }

    /// Counts calls and records prompts; answers with `reply` or throws.
    final class FakeModel: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        let respond: @Sendable (String) throws -> String
        init(_ respond: @escaping @Sendable (String) throws -> String) { self.respond = respond }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
        var calls: Int { prompts.count }
        var model: StyleModel {
            { [self] _, prompt in
                lock.lock(); _prompts.append(prompt); lock.unlock()
                try await Task.sleep(nanoseconds: 20_000_000)   // long enough for callers to overlap
                return try respond(prompt)
            }
        }
    }

    static let goodAnswer = "You reply fast. You keep it short. You text late. You start about half your chats."

    // MARK: availability

    static func testAvailability() {
        print("\nmodel availability")
        equal(StyleModelStatus(.available), .available, "available maps to available")
        equal(StyleModelStatus(.unavailable(.appleIntelligenceNotEnabled)), .appleIntelligenceOff,
              "Apple Intelligence off is its own status")
        equal(StyleModelStatus(.unavailable(.deviceNotEligible)), .deviceNotEligible, "unsupported Mac")
        equal(StyleModelStatus(.unavailable(.modelNotReady)), .modelNotReady, "model still downloading")
        let all: [StyleModelStatus] = [.available, .appleIntelligenceOff, .deviceNotEligible, .modelNotReady]
        equal(all.filter(\.isAvailable), [.available], "only .available lets the model run")
        equal(Set(all.map(\.explanation)).count, 4, "each status explains itself differently")
        expect(StyleModelStatus.appleIntelligenceOff.explanation.contains("System Settings"),
               "the off status says where to turn it on")
        print("  (this Mac: \(StyleModelStatus.current))")
    }

    static func testFailures() {
        print("\nerrors from the model")
        typealias G = LanguageModelSession.GenerationError
        let ctx = G.Context(debugDescription: "test")
        equal(StyleFailure(G.exceededContextWindowSize(ctx)), .tooLong, "context overflow")
        equal(StyleFailure(G.guardrailViolation(ctx)), .declined, "guardrail")
        equal(StyleFailure(G.unsupportedLanguageOrLocale(ctx)), .unsupportedLanguage, "language")
        equal(StyleFailure(G.concurrentRequests(ctx)), .busy, "concurrent requests")
        equal(StyleFailure(G.rateLimited(ctx)), .busy, "rate limited")
        equal(StyleFailure(G.assetsUnavailable(ctx)), .assetsUnavailable, "assets missing")
        if case .other = StyleFailure(CocoaError(.fileNoSuchFile)) { expect(true, "any other error is .other") }
        else { expect(false, "any other error is .other") }
        expect(StyleFailure.tooLong.retryWithoutSamples && StyleFailure.declined.retryWithoutSamples,
               "too long and declined are retried without his messages")
        expect(!StyleFailure.busy.retryWithoutSamples && !StyleFailure.unsupportedLanguage.retryWithoutSamples,
               "busy and language are not")
    }

    // MARK: cleaning one message

    static func testClean() {
        print("\ncleaning a message for the prompt")
        equal(StyleSample.clean("  on   my\nway  "), "on my way", "whitespace collapsed")
        equal(StyleSample.clean("\u{FFFC}"), nil, "attachment-only message dropped")
        equal(StyleSample.clean("look \u{FFFC} lol"), "look lol", "attachment placeholder removed")
        equal(StyleSample.clean("https://example.com/x?y=1"), nil, "a bare link says nothing about style")
        equal(StyleSample.clean("peep this https://x.co/abc lmao"), "peep this [link] lmao", "links masked")
        equal(StyleSample.clean("   "), nil, "blank dropped")
        equal(StyleSample.clean("k"), "k", "a one-letter reply is kept — it IS his style")

        let long = String(repeating: "word ", count: 60)
        let cut = StyleSample.clean(long, maxChars: 40)!
        expect(cut.count <= 40, "cut to the limit (\(cut.count) chars)")
        expect(cut.hasSuffix("…"), "cut text ends in an ellipsis")
        expect(!cut.contains("wor…"), "cut on a word boundary")
        let blob = StyleSample.truncate(String(repeating: "a", count: 300), to: 50)
        equal(blob.count, 50, "one huge word is hard-cut to exactly the limit")
        equal(StyleSample.truncate("short", to: 50), "short", "short text untouched")
    }

    static func testSpread() {
        print("\nspreading the sample across the history")
        equal(StyleSample.evenlySpaced(10, 3), [0, 5, 9], "first, middle, last")
        equal(StyleSample.evenlySpaced(4, 10), [0, 1, 2, 3], "asking for more than there is takes all")
        equal(StyleSample.evenlySpaced(10, 1), [9], "one pick is the newest")
        equal(StyleSample.evenlySpaced(0, 5), [], "nothing to pick")
        let big = StyleSample.evenlySpaced(5000, 30)
        equal(big.count, 30, "thirty picks")
        equal(Set(big).count, 30, "no index picked twice")
        expect(big == big.sorted() && big.first == 0 && big.last == 4999, "ordered, spanning the history")
    }

    // MARK: sampling his messages

    static func testSampling() {
        print("\npicking his messages")
        var msgs: [Message] = []
        for i in 0..<100 {
            msgs.append(msg(1, "+1555", me: false, Double(i) * 100, "THEIRS \(i)"))
            msgs.append(msg(1, "+1555", me: true, Double(i) * 100 + 10, "mine \(i)"))
        }
        msgs.append(msg(1, "+1555", me: true, 50_000, "", tapback: 2003))
        msgs.append(msg(1, "+1555", me: true, 50_100, "mine 5"))          // a repeat
        msgs.append(msg(1, "+1555", me: true, 50_200, "MINE 5"))          // a repeat, different case
        let s = store(msgs)

        let picked = StyleSample.pick(from: s)
        equal(picked.count, StyleSample.maxMessages, "capped at \(StyleSample.maxMessages) messages")
        expect(picked.allSatisfy { $0.hasPrefix("mine") }, "only his own messages, never theirs")
        equal(Set(picked.map { $0.lowercased() }).count, picked.count, "no repeats")
        equal(picked.first, "mine 0", "starts at his oldest")
        equal(picked.last, "mine 99", "ends at his newest")
        equal(StyleSample.pick(from: s), picked, "the same store gives the same sample")

        let tight = StyleSample.pick(from: s, limit: 30, perMessage: 100, totalBudget: 40)
        expect(tight.reduce(0) { $0 + $1.count } <= 40, "the total budget is respected")
        expect(tight.count >= 4, "a tight budget shrinks the sample rather than emptying it (\(tight.count))")
        expect(tight.first == "mine 0" && tight.last == "mine 99", "a smaller sample still spans the history")

        let longLines = store((0..<50).map { msg(1, "+1", me: true, Double($0), String(repeating: "yo ", count: 80) + "\($0)") })
        let capped = StyleSample.pick(from: longLines)
        expect(capped.allSatisfy { $0.count <= StyleSample.maxCharsPerMessage }, "each message cut to \(StyleSample.maxCharsPerMessage) chars")
        expect(capped.reduce(0) { $0 + $1.count } <= StyleSample.maxTotalChars, "all together under \(StyleSample.maxTotalChars) chars")

        equal(StyleSample.pick(from: .empty), [], "nothing from an empty store")
        equal(StyleSample.pick(from: store([msg(1, "+1", me: false, 0, "hi")])), [], "nothing when he never wrote")
    }

    // MARK: formatting numbers

    static func testFormatting() {
        print("\nnumbers in words")
        equal(StylePrompt.duration(45), "45 seconds", "seconds")
        equal(StylePrompt.duration(1), "1 second", "singular")
        equal(StylePrompt.duration(600), "10 minutes", "minutes")
        equal(StylePrompt.duration(5400), "1.5 hours", "hours with a decimal")
        equal(StylePrompt.duration(3 * 86400), "3 days", "days")
        equal(StylePrompt.duration(-5), "0 seconds", "never negative")
        equal(StylePrompt.hourLabel(0), "midnight", "midnight")
        equal(StylePrompt.hourLabel(12), "noon", "noon")
        equal(StylePrompt.hourLabel(9), "9 am", "morning")
        equal(StylePrompt.hourLabel(21), "9 pm", "evening")
        equal(StylePrompt.percent(0.666), "67%", "percent rounds")
        equal(StylePrompt.busiest([0, 3, 7, 7]), 2, "busiest bucket, first on a tie")
        equal(StylePrompt.busiest([0, 0]), nil, "no busiest when all zero")
    }

    // MARK: the prompt

    static func testPrompt() {
        print("\nbuilding the prompt")
        let snap = Engine.analyze(chatty(rounds: 30), now: t0.addingTimeInterval(40 * 3600))
        let facts = StylePrompt.facts(snap)
        expect(facts.contains { $0.contains("median") && $0.contains("2 minutes") },
               "his median reply (2 minutes) is in the facts")
        expect(facts.contains { $0.contains("He sent 30 messages and received 30") }, "message counts")
        expect(facts.contains { $0.contains("100%") && $0.contains("answers") }, "his reply rate")
        expect(facts.allSatisfy { !$0.contains("nil") && !$0.contains("Optional") }, "no nils leak into the facts")

        let empty = StylePrompt.facts(Engine.analyze(.empty, now: t0))
        equal(empty, ["He sent 0 messages and received 0."], "an empty snapshot states only what it knows")

        let samples = StyleSample.pick(from: chatty(rounds: 30))
        let prompt = StylePrompt.build(snapshot: snap, samples: samples)
        expect(prompt.contains("> a0 sounds good"), "his messages are in the prompt")
        expect(!prompt.contains("THEIRS"), "their messages are not")
        expect(prompt.contains("four or five sentences"), "it asks for four or five sentences")
        expect(prompt.count <= StylePrompt.maxPromptChars, "fits the budget (\(prompt.count) chars)")

        let bare = StylePrompt.build(snapshot: snap, samples: [])
        expect(!bare.contains("A sample of messages"), "without samples there is no sample section")

        let flood = (0..<500).map { "message number \($0) " + String(repeating: "x", count: 80) }
        let big = StylePrompt.build(snapshot: snap, samples: flood)
        expect(big.count <= StylePrompt.maxPromptChars, "a flood of samples is trimmed to fit (\(big.count) chars)")
        expect(big.contains("> message number 0 "), "trimming keeps the first samples")
        expect(!StylePrompt.instructions.isEmpty && StylePrompt.instructions.contains("Never invent a number"),
               "the instructions forbid invented numbers")
    }

    // MARK: parsing the answer

    static func testParse() {
        print("\nparsing what the model wrote")
        equal(StyleReadOut.parse(goodAnswer)?.sentences.count, 4, "four sentences")
        equal(StyleReadOut.parse("")?.sentences, nil, "nothing back is nil")
        equal(StyleReadOut.parse("  \n\n ")?.sentences, nil, "whitespace back is nil")
        equal(StyleReadOut.parse("- **")?.sentences, nil, "stray markdown is nil")

        let messy = """
        ## Your texting style
        Here's what I noticed:
        1. You **reply** in about 2.5 minutes.
        - You keep messages short
        * You text most after 9 pm!
        """
        let r = StyleReadOut.parse(messy)
        equal(r?.sentences, ["You reply in about 2.5 minutes.",
                             "You keep messages short.",
                             "You text most after 9 pm!"],
              "parsed: heading and lead-in dropped, each list item its own sentence")
        expect(r?.text.contains("#") == false && r?.text.contains("**") == false, "markdown stripped")
        expect(r?.text.contains("Here's what I noticed") == false, "preamble ending in a colon dropped")
        expect(r?.text.contains("2.5 minutes") == true, "a decimal does not split a sentence")
        expect(r?.sentences.allSatisfy { !$0.hasPrefix("1.") && !$0.hasPrefix("-") } == true, "numbering and bullets gone")

        let long = (1...8).map { "Sentence number \($0) is here." }.joined(separator: " ")
        equal(StyleReadOut.parse(long)?.sentences.count, StyleReadOut.maxSentences, "capped at five sentences")
        equal(StyleReadOut.parse("You said \"bet.\" Then you left.")?.sentences,
              ["You said \"bet.\"", "Then you left."], "a quote closing a sentence stays with it")
        equal(StyleReadOut.parse("No full stop at the end")?.sentences, ["No full stop at the end."],
              "a trailing fragment gets a full stop")
    }

    // MARK: running, with a stand-in model

    static func testGenerate() async {
        print("\ngenerating with a stand-in model")
        let snap = Engine.analyze(chatty(rounds: 30), now: t0.addingTimeInterval(40 * 3600))
        let samples = StyleSample.pick(from: chatty(rounds: 30))

        let ok = FakeModel { _ in goodAnswer }
        let out = await StyleRead.generate(snapshot: snap, samples: samples, status: .available, model: ok.model)
        equal(out.readOut?.sentences.count, 4, "a good answer becomes a read-out")
        equal(ok.calls, 1, "the model is asked once")
        expect(ok.prompts.first?.contains("> a0 sounds good") == true, "the model saw his messages")

        for status in [StyleModelStatus.appleIntelligenceOff, .deviceNotEligible, .modelNotReady] {
            let never = FakeModel { _ in goodAnswer }
            let o = await StyleRead.generate(snapshot: snap, samples: samples, status: status, model: never.model)
            equal(o, .unavailable(status), "\(status) gives a typed status")
            equal(never.calls, 0, "\(status) never calls the model")
            equal(o.readOut, nil, "\(status) has no read-out (nil, not a crash)")
        }

        let few = Engine.analyze(chatty(rounds: 5), now: t0.addingTimeInterval(10 * 3600))
        let idle = FakeModel { _ in goodAnswer }
        equal(await StyleRead.generate(snapshot: few, samples: [], status: .available, model: idle.model),
              .notEnoughData, "five messages are not enough to describe a style")
        equal(idle.calls, 0, "…and the model is not asked")

        let blank = FakeModel { _ in "  \n" }
        equal(await StyleRead.generate(snapshot: snap, samples: samples, status: .available, model: blank.model),
              .failed(.emptyAnswer), "an empty answer is a typed failure")

        let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        let picky = FakeModel { prompt in
            if prompt.contains("A sample of messages") { throw LanguageModelSession.GenerationError.guardrailViolation(ctx) }
            return goodAnswer
        }
        let retried = await StyleRead.generate(snapshot: snap, samples: samples, status: .available, model: picky.model)
        equal(retried.readOut?.sentences.count, 4, "a guardrail on his messages falls back to the numbers alone")
        equal(picky.calls, 2, "…in exactly one retry")
        expect(picky.prompts.last?.contains("> ") == false, "the retry carries none of his messages")

        let busy = FakeModel { _ in throw LanguageModelSession.GenerationError.concurrentRequests(ctx) }
        equal(await StyleRead.generate(snapshot: snap, samples: samples, status: .available, model: busy.model),
              .failed(.busy), "a busy model is reported, not retried")
        equal(busy.calls, 1, "…and asked only once")
    }

    // MARK: the cache

    final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: StyleModelStatus
        init(_ v: StyleModelStatus) { _value = v }
        var value: StyleModelStatus {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    static func testCache() async {
        print("\ncaching the read-out")
        let data = chatty(rounds: 30)
        let snap = Engine.analyze(data, now: t0.addingTimeInterval(40 * 3600))

        let fake = FakeModel { _ in goodAnswer }
        let reader = StyleReader(model: fake.model, status: { .available })
        let a = await reader.readOut(for: snap, store: data)
        let b = await reader.readOut(for: snap, store: data)
        equal(a, b, "the same answer twice")
        equal(fake.calls, 1, "a redraw does not ask the model again")

        // Re-analysing the same data at a different moment is the same read-out.
        let again = Engine.analyze(data, now: t0.addingTimeInterval(41 * 3600))
        _ = await reader.readOut(for: again, store: data)
        equal(fake.calls, 1, "a reload with the same numbers reuses the cache")

        let other = chatty(rounds: 40)
        _ = await reader.readOut(for: Engine.analyze(other, now: t0.addingTimeInterval(50 * 3600)), store: other)
        equal(fake.calls, 2, "new data makes a new read-out")

        await reader.forget()
        _ = await reader.readOut(for: snap, store: data)
        equal(fake.calls, 3, "forget() lets Try Again ask afresh")

        let together = FakeModel { _ in goodAnswer }
        let shared = StyleReader(model: together.model, status: { .available })
        async let x = shared.outcome(for: snap, store: data)
        async let y = shared.outcome(for: snap, store: data)
        async let z = shared.outcome(for: snap, store: data)
        let all = await [x, y, z]
        expect(all.allSatisfy { $0.readOut != nil }, "three views asking at once all get it")
        equal(together.calls, 1, "…from a single request")

        let toggle = Switch(.appleIntelligenceOff)
        let late = FakeModel { _ in goodAnswer }
        let reader2 = StyleReader(model: late.model, status: { toggle.value })
        equal(await reader2.outcome(for: snap, store: data), .unavailable(.appleIntelligenceOff), "off: typed status")
        equal(late.calls, 0, "off: the model is never called")
        toggle.value = .available
        equal(await reader2.outcome(for: snap, store: data).readOut?.sentences.count, 4,
              "turning Apple Intelligence on works without a relaunch (unavailable is not cached)")

        let fewData = chatty(rounds: 3)
        equal(await reader2.outcome(for: Engine.analyze(fewData, now: t0.addingTimeInterval(4 * 3600)), store: fewData),
              .notEnoughData, "too little history says so")
    }

    // MARK: the fixture, and the real model when there is one

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

    static func testFixtureAndLiveModel() async {
        print("\nfixtures/sample-chat.db")
        guard let (url, now) = fixture(), let data = try? ChatDB(url: url).load() else {
            failures += 1; checks += 1
            print("  FAIL  could not read fixtures/sample-chat.db"); return
        }
        let snap = Engine.analyze(data, now: now)
        let samples = StyleSample.pick(from: data)
        let his = Set(data.messages.filter { $0.isFromMe && !$0.isTapback }
                        .compactMap { StyleSample.clean($0.text) })
        equal(samples.count, StyleSample.maxMessages, "a full sample from a real-sized history")
        expect(samples.allSatisfy { his.contains($0) }, "every sampled line is one of HIS messages")
        expect(samples.reduce(0) { $0 + $1.count } <= StyleSample.maxTotalChars, "sample under the character budget")
        let prompt = StylePrompt.build(snapshot: snap, samples: samples)
        expect(prompt.count <= StylePrompt.maxPromptChars, "fixture prompt fits (\(prompt.count) chars)")
        expect(StylePrompt.facts(snap).count >= 10, "a real history gives a full set of facts (\(StylePrompt.facts(snap).count))")

        print("\nthe on-device model")
        let status = StyleModelStatus.current
        guard status.isAvailable else {
            print("  skip  live read-out — \(status): \(status.explanation)")
            let o = await StyleReader().outcome(for: snap, store: data)
            equal(o, .unavailable(status), "the real reader reports \(status) instead of crashing")
            return
        }
        let reader = StyleReader()
        let started = Date()
        let outcome = await reader.outcome(for: snap, store: data)
        let seconds = Date().timeIntervalSince(started)
        guard let read = outcome.readOut else {
            failures += 1; checks += 1
            print("  FAIL  live read-out came back as \(outcome)"); return
        }
        expect(!read.text.isEmpty, "the on-device model wrote a read-out (\(String(format: "%.1f", seconds))s)")
        expect((1...StyleReadOut.maxSentences).contains(read.sentences.count),
               "between one and five sentences (\(read.sentences.count))")
        print("\n  ---- read-out ----")
        for s in read.sentences { print("  \(s)") }
        print("  ------------------\n")
        let t = Date()
        let cached = await reader.readOut(for: snap, store: data)
        equal(cached, read, "asked again, the same read-out")
        expect(Date().timeIntervalSince(t) < 0.5, "…straight from the cache")
    }
}
