import Foundation

/// Apple stores Core Data / Messages dates as an offset from 2001-01-01.
let appleEpochOffset: TimeInterval = 978_307_200

/// One message, normalised out of the `message` table.
struct Message: Identifiable, Sendable {
    let id: Int64
    let guid: String
    /// When it was sent.
    let date: Date
    /// When it was read, if the database recorded that.
    let dateRead: Date?
    /// True when Sikiru sent it.
    let isFromMe: Bool
    /// The body. Empty for a message that carried only an attachment.
    let text: String
    /// The other party's phone number or email (`handle.id`). Nil on some
    /// messages he sent into a group.
    let handle: String?
    /// The thread this belongs to — `chat.ROWID`.
    let chatID: Int64?
    /// "iMessage" or "SMS".
    let service: String
    /// Non-zero for a tapback (love, like, emphasis…) rather than a real message.
    let associatedType: Int
    let hasAttachments: Bool

    /// Tapbacks are reactions, not replies. 2000–2005 add one, 3000–3005 remove one.
    var isTapback: Bool { associatedType != 0 }

    /// A message that counts towards conversation analysis.
    var isSubstantive: Bool { !isTapback && (!text.isEmpty || hasAttachments) }

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}

/// A thread — one contact, or a group.
struct Conversation: Identifiable, Sendable {
    let id: Int64                 // chat.ROWID
    let guid: String
    /// What Messages shows at the top of the window, when the chat has a name.
    let displayName: String?
    /// Every handle in the thread.
    let participants: [String]
    let service: String
    var isGroup: Bool { participants.count > 1 }

    /// The best label we can give it without the Contacts database.
    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if participants.count == 1 { return participants[0] }
        if participants.isEmpty { return "Unknown" }
        return participants.prefix(3).joined(separator: ", ")
            + (participants.count > 3 ? " +\(participants.count - 3)" : "")
    }
}

/// Everything one read of the database produced.
struct MessageStore: Sendable {
    let messages: [Message]
    let conversations: [Conversation]
    /// Columns the schema did not have, so callers know what degraded.
    let missingColumns: [String]

    static let empty = MessageStore(messages: [], conversations: [], missingColumns: [])

    func conversation(_ id: Int64?) -> Conversation? {
        guard let id else { return nil }
        return conversations.first { $0.id == id }
    }
}

enum ChatDBError: LocalizedError {
    case cannotOpen(String)
    case notAuthorized
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "macOS will not let Replies read your messages yet. Grant it Full Disk Access."
        case .cannotOpen(let why):
            return "Could not open the message database: \(why)"
        case .queryFailed(let why):
            return "Could not read the message database: \(why)"
        }
    }
}
