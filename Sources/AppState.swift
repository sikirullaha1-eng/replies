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

    var url: URL {
        switch self {
        case .live: return Permission.liveURL
        case .sample(let u): return u
        }
    }
}

/// What the app is doing right now.
enum LoadPhase: Equatable {
    case idle
    case needsAccess(Permission.Status)
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
    var store: MessageStore = .empty

    var messageCount: Int { store.messages.count }
    var lastLoaded: Date?

    /// The standard location of the iMessage database.
    static var liveDatabaseURL: URL { Permission.liveURL }

    /// Checks access and reads whichever database is available. Called on
    /// launch and whenever the window comes back to the front, so granting
    /// Full Disk Access takes effect without a relaunch.
    func refresh() async {
        if case .sample = source {
            await load()
            return
        }
        switch Permission.check() {
        case .granted:
            source = .live
            await load()
        case .denied:
            phase = .needsAccess(.denied)
        case .noDatabase:
            phase = .needsAccess(.noDatabase)
        }
    }

    /// Falls back to the fixture so the app can be looked at before the
    /// permission is granted.
    func useSample() async {
        guard let url = Permission.sampleURL else { return }
        source = .sample(url)
        await load()
    }

    func load() async {
        phase = .loading(0)
        do {
            let store = try await Loader.load(url: source.url) { [weak self] p in
                Task { @MainActor in
                    guard let self, case .loading = self.phase else { return }
                    self.phase = .loading(p)
                }
            }
            self.store = store
            self.lastLoaded = Date()
            self.phase = .ready
        } catch ChatDBError.notAuthorized {
            phase = .needsAccess(.denied)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
