import Foundation

/// How a remote URL is shown (S-08 "Show full remote URLs", #86, T11).
///
/// The input is always the credential-masked URL (`RepoConfigInspection.Remote.displayURL`), never the raw one, so
/// neither form can bring credentials back. Off (default): host and path only, e.g. `github.com/acme/api`. On: the
/// whole masked URL. The result is escaped for display.
enum RemoteURLDisplay {
    static func text(_ maskedURL: String, full: Bool) -> String {
        PathValidator.displayable(full ? maskedURL : short(maskedURL))
    }

    /// `https://***@github.com:443/acme/api.git` → `github.com/acme/api`; `git@github.com:acme/api.git` →
    /// `github.com/acme/api`; a local path stays as it is (it has no host).
    ///
    /// Only what git itself would read as a host is shortened. Anything else is returned whole, so a crafted URL
    /// cannot make the short form name a different host than git uses (security review of #86): `://` counts only
    /// after a real scheme (`git@evil:x/https://github.com/…` is scp-style to `evil`), and remote-helper URLs
    /// (`ext::…`, `<transport>::<address>`) are never shortened.
    static func short(_ url: String) -> String {
        // `<transport>::<address>` (git's remote-helper syntax, `ext::…`): shown whole.
        if let helper = url.range(of: "::"), isScheme(url[..<helper.lowerBound]) { return url }
        if let separator = url.range(of: "://"), isScheme(url[..<separator.lowerBound]) {
            var rest = url[separator.upperBound...]
            // userinfo (masked) ends at the last `@` before the first `/`.
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            guard let host = host(of: rest[..<hostEnd]) else { return url }
            return trimmed(host + rest[hostEnd...])
        }
        // scp-like `[user@]host:path`, git's rule: a colon before the first slash.
        if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/"), !url.hasPrefix("/") {
            var host = url[..<colon]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            guard !host.isEmpty else { return url }
            let path = url[url.index(after: colon)...]
            return trimmed(String(host) + "/" + path.drop { $0 == "/" })
        }
        return url
    }

    /// RFC 3986 scheme: a letter, then letters, digits, `+`, `-`, `.`.
    private static func isScheme(_ value: Substring) -> Bool {
        guard let first = value.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0))
        }
    }

    /// The host without its port: `example.com:443` → `example.com`, `[::1]:8080` → `[::1]`, empty for `file://`.
    /// `nil` when the authority is malformed (an unclosed `[`).
    private static func host(of authority: Substring) -> String? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            return String(authority[...close])
        }
        return String(authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    private static func trimmed(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result
    }
}
