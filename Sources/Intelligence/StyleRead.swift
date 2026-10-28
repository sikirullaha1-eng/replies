import Foundation
import FoundationModels

// The on-device style read-out: four or five plain sentences about how he
// texts, written by Apple's SystemLanguageModel from the Snapshot's numbers
// and a small sample of his own messages (StylePrompt.swift).
//
// Everything runs on this Mac. FoundationModels' system model is local: no
// network, no account, no key. When it cannot run (Apple Intelligence off,
// a Mac that does not support it, the model still downloading) the read-out
// is simply absent and the rest of the app is unaffected.

// MARK: - can the model run?

enum StyleModelStatus: Equatable, Sendable {
    case available
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available: self = .available
        case .unavailable(.appleIntelligenceNotEnabled): self = .appleIntelligenceOff
        case .unavailable(.deviceNotEligible): self = .deviceNotEligible
        case .unavailable(.modelNotReady): self = .modelNotReady
        case .unavailable: self = .modelNotReady   // a reason newer than this SDK
        }
    }

    /// Asks the system right now. Cheap; safe to call on every view update.
    static var current: StyleModelStatus { StyleModelStatus(SystemLanguageModel.default.availability) }

    var isAvailable: Bool { self == .available }

    /// What to tell him, in plain words.
    var explanation: String {
        switch self {
        case .available:
            return "Apple Intelligence is ready."
        case .appleIntelligenceOff:
            return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri to get a written read of your style."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence, so there is no written read of your style. Every number still works."
        case .modelNotReady:
            return "Apple Intelligence is still getting ready (it may be downloading). Try again in a little while."
        }
    }
}

// MARK: - what can go wrong once it runs

enum StyleFailure: Equatable, Sendable {
    /// The prompt did not fit the model's context window.
    case tooLong
    /// The model's safety guardrails or a refusal stopped it.
    case declined
    /// The messages are in a language the model does not support.
    case unsupportedLanguage
    /// Another request is running, or the system is rate limiting.
    case busy
    /// The model's files are missing.
    case assetsUnavailable
    /// It answered, but nothing usable was in the answer.
    case emptyAnswer
    case other(String)

    init(_ error: Error) {
        guard let g = error as? LanguageModelSession.GenerationError else {
            self = .other(error.localizedDescription); return
        }
        switch g {
        case .exceededContextWindowSize: self = .tooLong
        case .guardrailViolation, .refusal: self = .declined
        case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
        case .rateLimited, .concurrentRequests: self = .busy
        case .assetsUnavailable: self = .assetsUnavailable
        default: self = .other(g.localizedDescription)
        }
    }

    var explanation: String {
        switch self {
        case .tooLong: return "There was too much to read in one go."
        case .declined: return "Apple Intelligence declined to describe these messages."
        case .unsupportedLanguage: return "Apple Intelligence does not support the language of these messages yet."
        case .busy: return "Apple Intelligence is busy. Try again in a moment."
        case .assetsUnavailable: return "Apple Intelligence's model files are not available right now."
        case .emptyAnswer: return "Apple Intelligence did not write anything usable."
        case .other(let why): return "Could not write the read-out: \(why)"
        }
    }

    /// Worth retrying with the statistics alone, without his messages:
    /// the messages are the long part and the likely trigger for a guardrail.
    var retryWithoutSamples: Bool { self == .tooLong || self == .declined }
}

enum StyleOutcome: Equatable, Sendable {
    case ready(StyleReadOut)
    case unavailable(StyleModelStatus)
    /// Too little history to say anything.
    case notEnoughData
    case failed(StyleFailure)

    /// The read-out, or nil for every other outcome.
    var readOut: StyleReadOut? {
        if case .ready(let r) = self { return r }
        return nil
    }
}

// MARK: - running it

/// Instructions + prompt in, raw text out. The live one is the on-device
/// model; tests pass a stand-in.
typealias StyleModel = @Sendable (_ instructions: String, _ prompt: String) async throws -> String

enum StyleRead {
    /// Apple's on-device model. One fresh session per call: nothing from an
    /// earlier read-out leaks into the next one's context.
    static let onDevice: StyleModel = { instructions, prompt in
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: 400)
        return try await session.respond(to: prompt, options: options).content
    }

    /// Builds the prompt and asks the model once, retrying with the numbers
    /// alone if his messages made it too long or tripped a guardrail. Checks
    /// availability first, so an unavailable model is never called.
    static func generate(snapshot: Snapshot,
                         samples: [String],
                         status: StyleModelStatus,
                         model: StyleModel) async -> StyleOutcome {
        guard snapshot.sent >= StylePrompt.minimumSent else { return .notEnoughData }
        guard status.isAvailable else { return .unavailable(status) }

        let first = await ask(model, StylePrompt.build(snapshot: snapshot, samples: samples))
        if case .failed(let f) = first, f.retryWithoutSamples, !samples.isEmpty {
            return await ask(model, StylePrompt.build(snapshot: snapshot, samples: []))
        }
        return first
    }

    private static func ask(_ model: StyleModel, _ prompt: String) async -> StyleOutcome {
        do {
            let raw = try await model(StylePrompt.instructions, prompt)
            guard let out = StyleReadOut.parse(raw) else { return .failed(.emptyAnswer) }
            return .ready(out)
        } catch {
            return .failed(StyleFailure(error))
        }
    }
}

// MARK: - the cache

/// Hands out read-outs and remembers them, so a view that redraws does not
/// ask the model again. Keyed by the prompt itself: a reload that produces the
/// same numbers and the same sample reuses the answer; new data makes a new
/// prompt and so a new read-out. Two callers asking at once share one request.
///
/// "Unavailable" is never cached — turning Apple Intelligence on takes effect
/// on the next ask. Failures are cached until `forget()` so a redraw loop
/// cannot hammer the model; a Try Again button calls `forget()` first.
actor StyleReader {
    private let model: StyleModel
    private let status: @Sendable () -> StyleModelStatus
    private var cache: [String: StyleOutcome] = [:]
    private var running: [String: Task<StyleOutcome, Never>] = [:]

    init(model: @escaping StyleModel = StyleRead.onDevice,
         status: @escaping @Sendable () -> StyleModelStatus = { StyleModelStatus.current }) {
        self.model = model
        self.status = status
    }

    func outcome(for snapshot: Snapshot, store: MessageStore) async -> StyleOutcome {
        let samples = StyleSample.pick(from: store)
        let key = StylePrompt.build(snapshot: snapshot, samples: samples)
        if let done = cache[key] { return done }

        let status = self.status()
        guard status.isAvailable else {
            return snapshot.sent < StylePrompt.minimumSent ? .notEnoughData : .unavailable(status)
        }
        if let inFlight = running[key] { return await inFlight.value }

        let model = self.model
        let task = Task { await StyleRead.generate(snapshot: snapshot, samples: samples, status: status, model: model) }
        running[key] = task
        let result = await task.value
        running[key] = nil
        cache[key] = result
        return result
    }

    /// The read-out, or nil whenever there is none (model unavailable, too
    /// little history, or it failed). The app is complete without it.
    func readOut(for snapshot: Snapshot, store: MessageStore) async -> StyleReadOut? {
        await outcome(for: snapshot, store: store).readOut
    }

    func forget() { cache.removeAll() }
}
