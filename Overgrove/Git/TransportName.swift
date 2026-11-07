import Foundation

/// How git picks a transport for a remote URL (transport.c), used to report repository-chosen remote helpers and to
/// classify `transport '<name>' not allowed` refusals (#161, T5).
///
/// `GIT_ALLOW_PROTOCOL` is what actually blocks helpers; this only explains them in reports and messages.
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
