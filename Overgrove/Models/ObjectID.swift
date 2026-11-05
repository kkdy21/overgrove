/// A full git object ID: 40 lowercase hex digits (SHA-1) or 64 (SHA-256) (parsing-spec.md §1.7).
struct ObjectID: Sendable, Hashable {
    let hex: String

    /// Returns `nil` unless `hex` is exactly 40 or 64 lowercase hexadecimal digits.
    init?(_ hex: some StringProtocol) {
        let utf8 = hex.utf8
        guard utf8.count == 40 || utf8.count == 64,
            utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        self.hex = String(hex)
    }

    var isSHA256: Bool { hex.utf8.count == 64 }

    /// Abbreviation for display only. Never pass it back to git; use `hex`.
    var short: String { String(hex.prefix(7)) }
}

extension ObjectID: CustomStringConvertible {
    var description: String { hex }
}
