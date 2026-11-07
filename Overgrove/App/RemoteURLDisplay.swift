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
    static func short(_ url: String) -> String {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
            // userinfo (masked) ends at the last `@` before the first `/`.
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            let host = rest[..<hostEnd].split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            return trimmed(host + rest[hostEnd...])
        }
        // scp-like `[user@]host:path`, git's rule: a colon before the first slash.
        if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains("/"), !rest.hasPrefix("/") {
            var host = rest[..<colon]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            let path = rest[rest.index(after: colon)...]
            return trimmed(String(host) + "/" + path.drop { $0 == "/" })
        }
        return url
    }

    private static func trimmed(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result
    }
}
