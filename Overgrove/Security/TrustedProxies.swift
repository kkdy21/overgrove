import Foundation

/// The proxy the trusted scopes (system, global, Apple built-in) give for a URL, for replacing a repository's own
/// proxy settings during fetch (#150, #355).
///
/// A repository's proxy could read requests that carry credentials from a trusted helper, so it is overridden. Writing
/// an empty value instead would break a user behind a company proxy: the override is more specific than their
/// `http.proxy`. So the override carries the value git would have used without the repository's setting.
///
/// The same lookup serves the other proxy settings a repository must not choose (#367): `proxyAuthMethod` and
/// `proxySSLCertPasswordProtected` are read per variable, with a default for when no trusted value exists.
///
/// The URL matching follows git's `http.<url>.*` rules (scheme, host with `*` labels, port, path prefix, user;
/// precedence host, then path, then user; the last of equals wins) without git's percent-decoding. Whatever it
/// picks is a trusted value or nothing, never the repository's, so a mismatch can only cost a working proxy.
struct TrustedProxies {
    /// The last trusted value per exact key, for `remote.<name>.proxy` (bytes, see `RepoConfigInspector`).
    private var byKey: [[UInt8]: String] = [:]
    /// The last trusted `http.proxy`.
    private var generic: String?
    /// Trusted `http.<url>.proxy` entries in configuration order.
    private var patterns: [(url: ProxyURL, value: String)] = []

    /// Trusted values of `variable` (lowercase, as `ConfigParser` gives it), for `http.<variable>`,
    /// `http.<url>.<variable>`, and `remote.<name>.<variable>`. `implicitValue` is what a key written without `=`
    /// means: `true` for a boolean (git reads `[http] sslCertPasswordProtected` as true, but `-c key=` as false).
    init(_ entries: [ConfigEntry], variable: String = "proxy", implicitValue: String = "") {
        for entry in entries where !entry.scope.isRepositoryControlled && entry.variable == variable {
            let value = entry.value ?? implicitValue
            switch (entry.section, entry.subsection) {
            case ("remote", _):
                byKey[Array(entry.key.utf8)] = value
            case ("http", nil):
                generic = value
            case ("http", let pattern?):
                if let url = ProxyURL(pattern) { patterns.append((url, value)) }
            default:
                break
            }
        }
    }

    /// The trusted proxy for `url`: the best matching `http.<url>.proxy`, else `http.proxy`. `nil` when there is none
    /// or `url` is not a URL git would match (then the caller writes an empty value).
    func proxy(for url: String?) -> String? {
        guard let url, let target = ProxyURL(url) else { return generic }
        var best: (rank: ProxyURL.Rank, value: String)?
        for (pattern, value) in patterns {
            guard let rank = pattern.rank(matching: target) else { continue }
            if best.map({ rank >= $0.rank }) ?? true { best = (rank, value) }
        }
        return best?.value ?? generic
    }

    /// The value to override a repository's key with, or `fallback` when the trusted scopes give none. `remoteURL` is
    /// the remote's URL for `remote.<name>.<variable>`.
    func value(replacing entry: ConfigEntry, remoteURL: String?, fallback: String = "") -> String {
        switch (entry.section, entry.subsection) {
        case ("remote", _):
            return byKey[Array(entry.key.utf8)] ?? proxy(for: remoteURL) ?? fallback
        case ("http", nil):
            return generic ?? fallback
        case ("http", let pattern?):
            return proxy(for: pattern) ?? fallback
        default:
            return fallback
        }
    }
}

/// A URL or `http.<url>` pattern, split the way git's urlmatch compares them.
struct ProxyURL {
    /// Host match length, path match length, user matched: compared in this order, larger wins.
    typealias Rank = (host: Int, path: Int, user: Int)

    let scheme: String
    let user: String?
    /// Lowercased (ASCII only, like git), compared as bytes.
    let host: [UInt8]
    let port: String
    /// Without a trailing `/`; empty for the root.
    let path: String

    init?(_ string: String) {
        guard let separator = string.range(of: "://") else { return nil }
        let scheme = string[..<separator.lowerBound].lowercased()
        guard !scheme.isEmpty else { return nil }
        let rest = string[separator.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = rest[..<slash]
        var user: String?
        if let at = authority.lastIndex(of: "@") {
            let userInfo = authority[..<at]
            user = String(userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            authority = authority[authority.index(after: at)...]
        }
        var host = authority
        var port = ""
        if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
            let digits = authority[authority.index(after: colon)...]
            if digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber) {
                host = authority[..<colon]
                port = String(digits)
            }
        }
        guard !host.isEmpty else { return nil }
        if port.isEmpty { port = ["http": "80", "https": "443"][scheme] ?? "" }
        var path = String(rest[slash...])
        while path.hasSuffix("/") { path.removeLast() }

        self.scheme = scheme
        self.user = user
        self.host = Array(host.utf8).map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        self.port = port
        self.path = path
    }

    /// How well this pattern matches `url`, or `nil` when it does not apply.
    func rank(matching url: ProxyURL) -> Rank? {
        guard scheme == url.scheme, port == url.port else { return nil }
        if let user, user != url.user { return nil }
        let patternLabels = host.split(separator: 0x2E, omittingEmptySubsequences: false)
        let urlLabels = url.host.split(separator: 0x2E, omittingEmptySubsequences: false)
        guard patternLabels.count == urlLabels.count,
            zip(patternLabels, urlLabels).allSatisfy({ $0.elementsEqual([0x2A]) || $0.elementsEqual($1) })
        else { return nil }
        let pathBytes = Array(path.utf8)
        let urlPath = Array(url.path.utf8)
        guard
            pathBytes.isEmpty || urlPath == pathBytes
                || (urlPath.starts(with: pathBytes) && urlPath.count > pathBytes.count
                    && urlPath[pathBytes.count] == 0x2F)
        else { return nil }
        return (host.count, pathBytes.count, user == nil ? 0 : 1)
    }
}
