import Foundation

/// Modern macOS often leaves `message.text` NULL and puts the body in
/// `attributedBody` — an *old-style* `typedstream` archive of an
/// NSAttributedString. A reader that ignores this column silently loses a
/// large share of the history, which is the single most common bug in
/// chat.db readers.
///
/// `NSUnarchiver` (the only class that reads typedstream) is not available to
/// Swift, so the string is pulled out by walking the archive. Newer rows are
/// occasionally a keyed `bplist` archive instead, which is handled first.
enum AttributedBody {

    static func text(from data: Data) -> String? {
        if let s = keyedArchiveText(data), !s.isEmpty { return s }
        if let s = typedStreamText(data), !s.isEmpty { return s }
        return nil
    }

    // MARK: keyed archives (bplist00…)

    private static func keyedArchiveText(_ data: Data) -> String? {
        guard data.starts(with: Array("bplist00".utf8)) else { return nil }
        let classes = [NSAttributedString.self, NSString.self, NSDictionary.self,
                       NSArray.self, NSNumber.self, NSMutableAttributedString.self]
        guard let obj = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: classes, from: data) else { return nil }
        if let a = obj as? NSAttributedString { return a.string }
        if let s = obj as? NSString { return s as String }
        return nil
    }

    // MARK: typedstream

    /// The body sits after an `NSString` class marker, then a `+` (0x2B) type
    /// code, then a length, then UTF-8 bytes. Lengths above 127 are escaped:
    /// 0x81 → the next 2 bytes little-endian, 0x82 → 4 bytes.
    private static func typedStreamText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = find(Array("NSString".utf8), in: bytes) else { return nil }

        var i = marker + 8
        // The '+' type code follows within a few bytes of the class name.
        let searchEnd = min(i + 24, bytes.count)
        while i < searchEnd, bytes[i] != 0x2B { i += 1 }
        guard i < searchEnd, bytes[i] == 0x2B else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        var length = Int(bytes[i]); i += 1
        switch length {
        case 0x81:
            guard i + 1 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        case 0x82:
            guard i + 3 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
                   | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
            i += 4
        default:
            break
        }

        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i ..< (i + length)], encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
