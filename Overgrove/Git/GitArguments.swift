/// Validated values that may be passed to git as arguments (docs/design/security-review.md T9).
///
/// Commands take these types instead of `String`, so an unvalidated ref, remote, or path cannot reach git. Commits
/// are addressed with `ObjectID`; stashes too (never `stash@{n}`). Paths always go after `--`, and the common
/// argument `--literal-pathspecs` turns off pathspec magic. `git check-ref-format` cannot be used for validation
/// because it does not accept `--` (verified), so the rules live here.

/// A full ref name such as `refs/heads/main` (git-check-ref-format rules, stricter where cheap).
struct FullRefName: Sendable, Hashable, CustomStringConvertible {
    let value: String

    init?(_ value: String) {
        guard Self.isValid(value) else { return nil }
        self.value = value
    }

    var description: String { value }

    static func isValid(_ value: String) -> Bool {
        guard value.hasPrefix("refs/"), value.utf8.count <= 1024 else { return false }
        if value.hasSuffix("/") || value.hasSuffix(".") || value.hasSuffix(".lock") { return false }
        if value.contains("..") || value.contains("//") || value.contains("@{") || value == "@" { return false }
        for byte in value.utf8 {
            // control characters, DEL, space, and characters git forbids or that act as revision syntax
            if byte < 0x20 || byte == 0x7F || byte == 0x20 { return false }
            switch byte {
            case UInt8(ascii: "~"), UInt8(ascii: "^"), UInt8(ascii: ":"), UInt8(ascii: "?"), UInt8(ascii: "*"),
                UInt8(ascii: "["), UInt8(ascii: "\\"):
                return false
            default:
                continue
            }
        }
        for component in value.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component.hasPrefix("-") || component.hasPrefix(".") { return false }
        }
        return true
    }
}

/// A remote name taken from the repository's configuration (git-command-catalog.md §4).
struct RemoteName: Sendable, Hashable, CustomStringConvertible {
    let value: String

    init?(_ value: String) {
        let utf8 = value.utf8
        guard (1...100).contains(utf8.count), !value.hasPrefix("-"), !value.contains(".."),
            utf8.allSatisfy({ byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "/")
                    || byte == UInt8(ascii: "-")
            })
        else { return nil }
        self.value = value
    }

    var description: String { value }
}

extension GitPath {
    /// `["--", path]`, or `nil` when the path cannot be passed back to git losslessly (parsing-spec.md §1.3).
    var pathspecArguments: [String]? {
        guard let argument else { return nil }
        return ["--", argument]
    }
}
