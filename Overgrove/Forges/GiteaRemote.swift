import Foundation

/// Which Gitea repository the issue panel reads, from the repository's remotes and the instances gt has credentials
/// for (ADR-0026 §2). The remote forms and host rule are the shared `HostedRemoteURL` and `RemoteHost` (#117); this
/// adds Gitea's instance match and `OWNER/NAME` rule.
///
/// A remote matches an instance when the hosts are equal, the remote's path is the instance's base path followed by
/// exactly `OWNER/NAME`, and, for an https remote (which carries no port), the instance has no port either; ssh
/// remotes do not compare ports. The repository keeps the instance as gt printed it, so `--host` is never rebuilt
/// from a remote. A remote on a host gt has no credentials for matches nothing.
enum GiteaRemote {
    /// `upstream` first, then configuration order (ADR-0026 §2).
    static let preferredNames = ["upstream"]

    /// The first remote, `upstream` first, whose URL is a repository on one of `instances`.
    static func repository(
        remotes: [(name: String, url: String)], instances: [GiteaInstance]
    ) -> GiteaRepository? {
        guard !instances.isEmpty else { return nil }
        let preferred = preferredNames.compactMap { name in remotes.first { $0.name == name } }
        let rest = remotes.filter { !preferredNames.contains($0.name) }
        return (preferred + rest).lazy.compactMap { repository(fromURL: $0.url, instances: instances) }.first
    }

    /// The repository `url` names on one of `instances`; with several matching instances on one host, the one with
    /// the longest base path.
    static func repository(fromURL url: String, instances: [GiteaInstance]) -> GiteaRepository? {
        guard let remote = HostedRemoteURL(url) else { return nil }
        let segments = remote.pathSegments
        let matching = instances.filter { instance in
            instance.host == remote.host && (!remote.isHTTPS || instance.port == nil)
                && segments.count == instance.basePath.count + 2
                && segments.prefix(instance.basePath.count).elementsEqual(instance.basePath)
        }
        guard let instance = matching.max(by: { $0.basePath.count < $1.basePath.count }) else { return nil }
        let owner = segments[instance.basePath.count]
        let name = segments[instance.basePath.count + 1]
        // `NAME.git.git` is not a name a remote URL would carry.
        guard !name.hasSuffix(".git") else { return nil }
        return GiteaRepository(instance: instance, owner: owner, name: name)
    }

    /// Some remote is in a hosted form: only then is gt asked for its accounts (no remote, no gt).
    static func mayBeGitea(_ urls: [String]) -> Bool {
        urls.contains { HostedRemoteURL($0) != nil }
    }
}

extension GiteaRepository {
    /// gt's issue URL, only when it is exactly `INSTANCE/OWNER/NAME/issues/<number>` for this repository (OWNER and
    /// NAME compared ASCII case-insensitively) over https, on the instance's host and port with its base path, and
    /// nothing else (ADR-0026 §5). Anything else leaves only Copy URL.
    func browserURL(for issue: Issue) -> URL? {
        guard let parts = URLComponents(url: issue.url, resolvingAgainstBaseURL: false), parts.scheme == "https",
            parts.host == instance.host.name, parts.port == instance.port, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let base = instance.basePath
        guard path.count == base.count + 5, path[0].isEmpty, Array(path[1..<(base.count + 1)]) == base,
            Self.asciiCaseInsensitiveEqual(path[base.count + 1], owner),
            Self.asciiCaseInsensitiveEqual(path[base.count + 2], name), path[base.count + 3] == "issues",
            path[base.count + 4] == "\(issue.number)"
        else { return nil }
        return issue.url
    }

    private static func asciiCaseInsensitiveEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lower = { (byte: UInt8) in (0x41...0x5A).contains(byte) ? byte | 0x20 : byte }
        return lhs.utf8.map(lower) == rhs.utf8.map(lower)
    }
}
