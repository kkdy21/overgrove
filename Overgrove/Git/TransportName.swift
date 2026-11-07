import Foundation

/// How git picks a transport for a remote URL (transport.c), used to report repository-chosen remote helpers and to
/// classify `transport '<name>' not allowed` refusals (#161, T5).
///
/// `GIT_ALLOW_PROTOCOL` blocks helpers at fetch time; `isBuiltInFetchForm` also refuses them before fetch starts
/// (#350).
enum TransportName {
    /// Schemes git handles itself or with its own bundled helpers (`git-remote-http(s)`, `-ftp(s)`). Any other
    /// `<scheme>://` URL runs an external `git-remote-<scheme>`.
    static let builtInSchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "git", "ssh", "git+ssh", "ssh+git", "file",
    ]

    /// git's `is_urlschemechar`: the first character is a letter or digit, later ones may also be `+`, `-`, `.`.
    static func isSchemeName(_ name: some StringProtocol) -> Bool {
        var isFirst = true
        for scalar in name.unicodeScalars {
            guard scalar.isASCII else { return false }
            let isAlphanumeric = scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
            guard isAlphanumeric || (!isFirst && "+-.".unicodeScalars.contains(scalar)) else { return false }
            isFirst = false
        }
        return !isFirst
    }

    /// Schemes fetch accepts, compared as git does (case-sensitive): git's native transports and the http(s) helpers
    /// git ships. Matches `GitEnvironment.allowedProtocols` (#350).
    static let fetchSchemes: Set<String> = ["https", "http", "ssh", "git", "file", "git+ssh", "ssh+git"]

    /// Shown when fetch refuses a remote that is not in a built-in transport form (#350).
    static let nonBuiltInRemoteReason =
        "This remote does not use a built-in transport (https, ssh, git, or a local path); fetching it is disabled."

    /// Whether git would fetch `url` with a built-in transport: `<scheme>://` with a scheme in `fetchSchemes`, an
    /// scp-style address, or a path. Any `<name>::<address>` form, an unknown or differently cased scheme, and
    /// `ftp(s)` are not (#350, T5). Checked before every fetch, together with `remote.<n>.vcs` and
    /// `url.<base>.insteadOf` (`RepoConfigInspector`).
    ///
    /// Follows transport.c and `is_url` byte by byte, as git does: a run of scheme characters from the start (the
    /// first alphanumeric, later ones also `+`, `-`, `.`), then `::` (a helper, even with an empty name) or `://`.
    /// String comparison would treat canonically equivalent text as equal, which git does not.
    static func isBuiltInFetchForm(_ url: String) -> Bool {
        let bytes = Array(url.utf8)
        var end = 0
        while end < bytes.count, isSchemeByte(bytes[end], isFirst: end == 0) { end += 1 }
        let rest = bytes[end...]
        if rest.starts(with: "::".utf8) { return false }
        if end > 0, rest.starts(with: "://".utf8) {
            return fetchSchemes.contains(String(decoding: bytes[..<end], as: UTF8.self))
        }
        return true
    }

    /// git's `is_urlschemechar` on one byte.
    private static func isSchemeByte(_ byte: UInt8, isFirst: Bool) -> Bool {
        let isAlphanumeric =
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        return isAlphanumeric
            || (!isFirst && (byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")))
    }

    /// The external helper a remote URL makes git run, or `nil` for a built-in transport, an scp-style address, or a
    /// path. Covers `<helper>::<address>` (the helper name may even be empty) and `<scheme>://` with a scheme git
    /// does not handle itself. Scheme comparison ignores case: on a case-insensitive volume `EvilHelper://` finds
    /// `git-remote-evilhelper`.
    static func remoteHelper(forURL url: String) -> Substring? {
        if let separator = url.range(of: "::") {
            let name = url[..<separator.lowerBound]
            if name.isEmpty || isSchemeName(name) { return name }
        }
        if let separator = url.range(of: "://") {
            let scheme = url[..<separator.lowerBound]
            if isSchemeName(scheme), !builtInSchemes.contains(scheme.lowercased()) { return scheme }
        }
        return nil
    }
}
