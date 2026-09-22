import Foundation
import Observation

/// Where the messages are being read from.
enum DataSource: Equatable {
    /// The real iMessage database at ~/Library/Messages/chat.db
    case live
    /// The generated fixture, used when Full Disk Access has not been granted
    /// and for every test in this project.
    case sample(URL)

    var label: String {
        switch self {
        case .live: return "Your messages"
        case .sample: return "Sample data"
        }
    }
}

/// What the app is doing right now.
enum LoadPhase: Equatable {
    case idle
    case needsAccess
    case loading(Double)      // 0…1
    case ready
    case failed(String)
}

/// The one piece of shared state. Views read it; the loader writes it.
@Observable
@MainActor
final class AppState {
    var phase: LoadPhase = .idle
    var source: DataSource = .live

    /// Set by the loader once a database has been read. Typed models arrive in RPL-2.
    var messageCount: Int = 0
    var lastLoaded: Date?

    /// The standard location of the iMessage database.
    static var liveDatabaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db")
    }

    func note(_ message: String) {
        phase = .failed(message)
    }
}
