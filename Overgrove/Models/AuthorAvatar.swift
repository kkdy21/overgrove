import Foundation

/// The initials avatar for a commit author (design-tokens.md §3.5, #159). Never a network picture: nothing leaves the
/// machine, and the email is never handed to a third party.
enum AuthorAvatar {
    static let colorCount = 8

    /// `color.avatar.<index>`: FNV-1a (32-bit) of the trimmed, lowercased email, mod 8. Stable across runs, windows,
    /// and repositories (Swift's `hashValue` is seeded per run, so it is not used).
    static func colorIndex(email: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(colorCount))
    }

    /// Up to two initials: the first letters of the first and last words of the name, uppercased. One word gives one
    /// letter; an empty name gives `?`. Letters are whole characters, so composed scripts stay intact.
    static func initials(name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation && $0 != "'" })
        guard let first = words.first?.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        guard words.count > 1, let last = words.last?.first(where: { $0.isLetter || $0.isNumber }) else {
            return String(first).uppercased()
        }
        return (String(first) + String(last)).uppercased()
    }
}
