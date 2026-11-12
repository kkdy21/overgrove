/// A hosting provider's host name taken from a remote URL (ADR-0025 §2). Provider independent: GitHub (#117) and
/// later GitLab and Gitea read the same remote forms and trust hosts the same way.
///
/// Only a lowercase ASCII DNS name: labels of 1–63 letters, digits, or `-` (not first or last), 253 bytes at most, at
/// least two labels, and a last label that does not start with a digit (so no IPv4 literal in decimal, octal, or hex
/// form such as `1.2.3.0x4`; `:` and `[` already rule out IPv6).
/// User information, ports, paths, and queries are never part of it.
struct RemoteHost: Sendable, Hashable, CustomStringConvertible {
    /// The lowercased name.
    let name: String

    /// `nil` unless `raw`, lowercased, is a DNS name as above.
    init?(_ raw: String) {
        let bytes = Array(raw.utf8).map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
        guard (1...253).contains(bytes.count) else { return nil }
        let labels = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(Self.isLabel),
            let last = labels.last, let first = last.first, !(0x30...0x39).contains(first)
        else { return nil }
        name = String(decoding: bytes, as: UTF8.self)
    }

    var description: String { name }

    private static func isLabel(_ label: ArraySlice<UInt8>) -> Bool {
        (1...63).contains(label.count) && label.first != UInt8(ascii: "-") && label.last != UInt8(ascii: "-")
            && label.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
    }
}

/// A remote URL in one of the three forms Overgrove reads for a hosting provider (ADR-0025 §2), split into the host
/// and the path segments:
///
/// - `https://HOST/PATH`
/// - `git@HOST:PATH`
/// - `ssh://git@HOST(:PORT)?/PATH` (the port is accepted and ignored)
///
/// Compared in UTF-8 bytes, so a combining mark cannot join a separator. `url.<base>.insteadOf` is never applied. One
/// trailing `.git` is dropped from the path; an empty segment (`//`, a trailing `/`) fails. What the segments mean
/// (`OWNER/NAME`, nested groups) is the provider's to decide.
struct HostedRemoteURL: Sendable, Equatable {
    let host: RemoteHost
    let pathSegments: [String]
    /// The `https://` form (which has no port); `false` for the two ssh forms. A provider whose instance URL can carry a
    /// port compares it only for https remotes (ADR-0026 §2).
    let isHTTPS: Bool

    init?(_ url: String) {
        let bytes = Array(url.utf8)
        let authority: ArraySlice<UInt8>
        let path: ArraySlice<UInt8>
        var isHTTPS = false
        if let rest = Self.dropPrefix("https://", bytes) {
            isHTTPS = true
            guard let slash = rest.firstIndex(of: UInt8(ascii: "/")) else { return nil }
            authority = rest[..<slash]
            path = rest[(slash + 1)...]
        } else if let rest = Self.dropPrefix("ssh://git@", bytes) {
            guard let slash = rest.firstIndex(of: UInt8(ascii: "/")) else { return nil }
            var hostPart = rest[..<slash]
            if let colon = hostPart.firstIndex(of: UInt8(ascii: ":")) {
                guard Self.isPort(hostPart[(colon + 1)...]) else { return nil }
                hostPart = hostPart[..<colon]
            }
            authority = hostPart
            path = rest[(slash + 1)...]
        } else if let rest = Self.dropPrefix("git@", bytes) {
            guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else { return nil }
            authority = rest[..<colon]
            path = rest[(colon + 1)...]
        } else {
            return nil
        }
        guard let host = RemoteHost(String(decoding: authority, as: UTF8.self)) else { return nil }
        var pathBytes = Array(path)
        if pathBytes.suffix(4).elementsEqual(".git".utf8) { pathBytes.removeLast(4) }
        let segments = pathBytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.host = host
        self.isHTTPS = isHTTPS
        pathSegments = segments.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func dropPrefix(_ prefix: String, _ bytes: [UInt8]) -> ArraySlice<UInt8>? {
        bytes.starts(with: prefix.utf8) ? bytes[prefix.utf8.count...] : nil
    }

    /// 1–5 ASCII digits, 1...65535.
    private static func isPort(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard (1...5).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }),
            let port = Int(String(decoding: bytes, as: UTF8.self))
        else { return false }
        return (1...65535).contains(port)
    }
}

/// The hosts a provider's remotes may point at (ADR-0025 §1): the provider's public host, plus the hosts the user has
/// logged in to with the provider's own CLI. A remote URL alone never adds a host: a repository can point its remote
/// anywhere, and the CLI would then send that host the user's token. Before the logins are read, or when they cannot
/// be, only the public host is trusted.
struct TrustedHosts: Sendable, Equatable {
    let publicHost: RemoteHost
    /// The hosts the CLI reports a login for; empty until read.
    let loggedIn: Set<RemoteHost>
    /// The CLI's login list was read (it may still be empty).
    let isLoginListRead: Bool

    /// Only `publicHost`, before the login list is read.
    init(publicHost: RemoteHost) {
        self.publicHost = publicHost
        loggedIn = []
        isLoginListRead = false
    }

    init(publicHost: RemoteHost, loggedIn: Set<RemoteHost>) {
        self.publicHost = publicHost
        self.loggedIn = loggedIn
        isLoginListRead = true
    }

    func contains(_ host: RemoteHost) -> Bool {
        host == publicHost || loggedIn.contains(host)
    }

    /// Some URL among `urls` is in a remote form for a host not trusted yet, and the login list has not been read, or
    /// the user asked to read it again (`rereading`: ⌘R or Check Again, #485): reading it may make that remote usable.
    /// Auto refresh never rereads, so it does not run the CLI on every tick.
    func mayTrustMore(_ urls: [String], rereading: Bool = false) -> Bool {
        (rereading || !isLoginListRead) && urls.contains { HostedRemoteURL($0).map { !contains($0.host) } ?? false }
    }
}
