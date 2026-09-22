import Foundation
import AppKit

/// macOS refuses ~/Library/Messages/chat.db to any process that has not been
/// granted Full Disk Access. The grant is per-app and only the user can give
/// it, so the app's job is to detect the refusal and explain it well.
enum Permission {

    /// Where the real database lives.
    static var liveURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db")
    }

    /// The fixture shipped beside the app, or found in the project during
    /// development. Nil when there is none.
    static var sampleURL: URL? {
        if let bundled = Bundle.main.url(forResource: "sample-chat", withExtension: "db") {
            return bundled
        }
        // Running from the project folder during development.
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures/sample-chat.db")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    enum Status: Equatable {
        case granted
        case denied
        /// Messages has never been used on this Mac, so there is nothing to read.
        case noDatabase
    }

    /// Cheap enough to call on every window activation.
    static func check() -> Status {
        guard FileManager.default.fileExists(atPath: liveURL.path) else {
            // The file may exist but be invisible to us without access, so a
            // failed existence check alone does not prove there is no database.
            return ChatDB.isReadable(liveURL) ? .granted : .denied
        }
        return ChatDB.isReadable(liveURL) ? .granted : .denied
    }

    /// Opens System Settings straight at the Full Disk Access list.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Shows Replies.app in Finder so it can be dragged into that list.
    static func revealApp() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([app])
    }
}
