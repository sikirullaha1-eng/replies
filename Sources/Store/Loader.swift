import Foundation

/// Reads a database off the main thread and reports progress back on it.
/// The whole read is synchronous inside SQLite, so it must never run on the
/// main actor — a large history is tens of thousands of rows.
enum Loader {
    static func load(
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MessageStore {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let store = try ChatDB(url: url).load(progress: progress)
                    continuation.resume(returning: store)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
