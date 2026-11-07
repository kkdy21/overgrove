import Foundation

/// The result of inspecting a repository's own configuration (ADR-0009, security-review.md §3.3).
struct RepoConfigInspection: Sendable, Equatable {
    struct Remote: Sendable, Equatable {
        let name: RemoteName
        /// Raw URL, for GitHub owner/name detection only. Never display it: use `displayURL`.
        let url: String
        /// Credential-masked URL for the UI.
        let displayURL: String
    }

    let report: RepoSecurityReport
    /// `-c` arguments for every git command in this repository (filter drivers, T4).
    let neutralization: [String]
    /// `-c` arguments for `git fetch` only: credential helper reset and trusted re-insertion (T6), TLS restore (T11).
    let fetchAuthentication: [String]
    /// `core.sshCommand` from a trusted scope; repository-local values are ignored (T5).
    let trustedSSHCommand: String?
    let remotes: [Remote]
    /// Set when queries are fine but `git fetch` must not run (e.g. a repository-local CA or client certificate).
    let fetchBlockingReason: String?
    /// False when the effective configuration can change without any stamped config file changing, so the inspection
    /// must not be cached: `includeIf.onbranch:` depends on HEAD, and a repository-controlled include can read a file
    /// the fingerprint does not cover (#88, fail closed).
    let isCacheable: Bool
    /// A promisor remote or `extensions.partialclone` exists in any scope (#212).
    let isPartialClone: Bool

    /// Arguments for `GitClient`. `nil` when the report blocks queries (fail closed).
    var safetyContext: RepoSafetyContext? {
        guard !report.isBlocked else { return nil }
        return RepoSafetyContext(
            inspectedNeutralization: neutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            fetchBlockingReason: fetchBlockingReason,
            isPartialClone: isPartialClone
        )
    }
}

/// Inspects `git config --list --show-scope -z --includes` output and decides how to neutralize keys that can make
/// git run programs (ADR-0009). Only `local` and `worktree` scopes are untrusted; anything that cannot be handled
/// safely blocks queries (fail closed).
enum RepoConfigInspector {
    static func inspect(_ listing: ConfigParser.Listing) -> RepoConfigInspection {
        var findings: [RepoSecurityReport.Finding] = []
        var blockingReason: String?
        var neutralizedDrivers: [String] = []
        var restoreTLS: [String] = []
        var resetProxies: [String] = []
        var hasUntrustedHelper = false
        var fetchBlockingReason: String?

        if listing.isPartial {
            blockingReason = "The configuration listing was truncated, so it could not be inspected completely."
        }

        for entry in listing.entries where entry.scope.isRepositoryControlled {
            // git splits `-c key=value` at the first "=", so such a key could inject another setting (review of #150).
            if entry.subsection?.contains("=") == true, ["http", "credential", "filter"].contains(entry.section) {
                blockingReason = "A configuration key contains \"=\" and cannot be overridden safely."
            }
            guard let (threat, handling) = classify(entry) else { continue }
            findings.append(RepoSecurityReport.Finding(entry: entry, threat: threat, handling: handling))

            switch (entry.section, entry.variable) {
            case ("filter", _):
                guard let driver = entry.subsection else { continue }
                if !ConfigParser.isNeutralizableDriverName(driver) {
                    blockingReason = "A filter driver name contains characters that cannot be neutralized safely."
                } else if !neutralizedDrivers.contains(driver) {
                    neutralizedDrivers.append(driver)
                }
            case ("credential", "helper"):
                hasUntrustedHelper = true
            case ("http", "sslverify"):
                // Always force true: git accepts many spellings of false (0k, 0x0, -0, …), so never guess.
                if !restoreTLS.contains(entry.key) { restoreTLS.append(entry.key) }
            case ("http", "proxy"):
                if !resetProxies.contains(entry.key) { resetProxies.append(entry.key) }
            case ("http", "sslcainfo"), ("http", "sslcapath"), ("http", "sslcert"), ("http", "sslkey"):
                fetchBlockingReason = "This repository sets its own TLS certificate files; fetching is disabled."
            default:
                break
            }
        }

        let neutralization = neutralizedDrivers.flatMap { driver in
            [
                "-c", "filter.\(driver).clean=", "-c", "filter.\(driver).smudge=", "-c", "filter.\(driver).process=",
                "-c", "filter.\(driver).required=false",
            ]
        }

        var fetchAuthentication: [String] = []
        if hasUntrustedHelper {
            // Reset every helper read so far, then re-insert the trusted ones in their original order and keys.
            // The generic reset also clears URL-specific helpers read earlier, so re-insertion must come after it.
            fetchAuthentication += ["-c", "credential.helper="]
            for entry in listing.entries
            where !entry.scope.isRepositoryControlled && entry.section == "credential" && entry.variable == "helper" {
                fetchAuthentication += ["-c", "\(entry.key)=\(entry.value ?? "")"]
            }
        }
        fetchAuthentication += restoreTLS.flatMap { ["-c", "\($0)=true"] }
        // A repository-local proxy could receive credentials released by a trusted helper (review of #150).
        // Re-assert the trusted value for the same key, or an empty value (no proxy).
        for key in resetProxies {
            let trusted = listing.entries.last { !$0.scope.isRepositoryControlled && $0.key == key }?.value ?? ""
            fetchAuthentication += ["-c", "\(key)=\(trusted)"]
        }

        let trustedSSHCommand =
            listing.entries.last {
                !$0.scope.isRepositoryControlled && $0.section == "core" && $0.variable == "sshcommand"
            }?.value

        var remotes: [RepoConfigInspection.Remote] = []
        for entry in listing.entries where entry.section == "remote" && entry.variable == "url" {
            guard let subsection = entry.subsection, let name = RemoteName(subsection), let url = entry.value,
                !remotes.contains(where: { $0.name == name })
            else { continue }
            remotes.append(.init(name: name, url: url, displayURL: CredentialMasker.mask(url)))
        }

        let dependsOnHEAD = listing.entries.contains {
            $0.section == "includeif" && ($0.subsection?.lowercased().hasPrefix("onbranch:") ?? false)
        }
        // git resolves relative and nested include paths against the including file, which the listing does not
        // name, so the included files cannot be stamped reliably (#88).
        let readsUnstampedFiles = listing.entries.contains {
            $0.scope.isRepositoryControlled && ["include", "includeif"].contains($0.section.lowercased())
                && $0.variable.lowercased() == "path"
        }

        return RepoConfigInspection(
            report: RepoSecurityReport(findings: findings, blockingReason: blockingReason),
            neutralization: neutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            remotes: remotes,
            fetchBlockingReason: fetchBlockingReason,
            isCacheable: !dependsOnHEAD && !readsUnstampedFiles,
            isPartialClone: listing.entries.contains(where: isPartialCloneSetting)
        )
    }

    /// security-review.md §3.3. Returns `nil` for keys that need no attention.
    static func classify(_ entry: ConfigEntry) -> (threat: String?, handling: RepoSecurityReport.Handling)? {
        let section = entry.section
        let variable = entry.variable
        let value = entry.value ?? ""
        switch section {
        case "filter" where ["clean", "smudge", "process", "required"].contains(variable):
            return ("T4", .neutralized)
        case "credential" where variable == "helper":
            return ("T6", .neutralized)
        case "core":
            switch variable {
            case "sshcommand", "gitproxy": return ("T5", .neutralized)
            case "alternaterefscommand": return ("T5", .reported)
            case "fsmonitor": return ("T1", .reported)
            case "hookspath": return ("T2", .reported)
            case "askpass": return ("T12", .reported)
            case "worktree": return ("T14", .warned)
            // A path that points at a FIFO or device could stall git until the timeout (review of #148).
            case "attributesfile", "excludesfile": return ("T15", .warned)
            default: return nil
            }
        case "remote":
            if variable == "uploadpack" { return ("T5", .neutralized) }
            // Settings that would widen what fetch writes; the pinned fetch arguments override them (#209).
            if variable == "fetch", let remote = entry.subsection, writesOutsideRemoteNamespace(value, remote: remote) {
                return ("T13", .neutralized)
            }
            if variable == "prunetags" || variable == "tagopt" { return ("T13", .neutralized) }
            // Partial clone: reads lazy-fetch from the promisor remote. Queries allow no transport (#212).
            if variable == "promisor" || variable == "partialclonefilter" { return ("T5", .neutralized) }
            if variable == "mirror" { return ("T13", .reported) }
            // A remote helper chosen by the repository. `GIT_ALLOW_PROTOCOL` refuses it at fetch time (#161).
            if variable == "vcs" { return ("T5", .reported) }
            if variable == "url", TransportName.remoteHelper(forURL: value) != nil { return ("T5", .reported) }
            return nil
        case "http":
            if variable == "sslverify" || variable == "proxy" { return ("T11", .neutralized) }
            if ["sslcainfo", "sslcapath", "sslcert", "sslkey"].contains(variable) { return ("T11", .warned) }
            return nil
        case "diff" where variable == "external" || variable == "textconv" || variable == "command":
            return ("T3", .reported)
        case "diff" where variable == "orderfile":
            return ("T15", .warned)
        case "extensions" where variable == "partialclone":
            return ("T5", .neutralized)
        case "fetch" where variable == "prunetags" || variable == "bundleuri":
            return ("T13", .neutralized)
        case "gpg" where variable == "program":
            return ("T7", .reported)
        case "log" where variable == "showsignature":
            return ("T7", .reported)
        case "protocol" where variable == "allow":
            return ("T5", .reported)
        case "url" where variable == "insteadof" || variable == "pushinsteadof":
            return ("T5", .reported)
        case "include" where variable == "path", "includeif" where variable == "path":
            return (nil, .reported)
        case "fetch" where variable == "recursesubmodules", "submodule" where variable == "recurse":
            return ("T5", .reported)
        case "submodule" where variable == "update" && value.hasPrefix("!"):
            return (nil, .reported)
        case "gc" where variable == "auto", "maintenance":
            return ("T8", .reported)
        case "uploadpack" where variable == "packobjectshook":
            return (nil, .reported)
        case "safe" where variable == "directory":
            return (nil, .reported)
        // Re-encoded output could shift `-z` fields; the common `i18n.logOutputEncoding=UTF-8` overrides both (#205).
        case "i18n" where variable == "logoutputencoding" || variable == "commitencoding":
            return ("T15", .reported)
        default:
            return nil
        }
    }
}

extension RepoConfigInspector {
    /// `remote.<n>.promisor` set to anything but a clear false, or a non-empty `extensions.partialclone`, in any scope:
    /// lazy fetch runs the repository's own uploadpack whichever scope made the remote a promisor (fail closed).
    static func isPartialCloneSetting(_ entry: ConfigEntry) -> Bool {
        switch (entry.section, entry.variable) {
        case ("remote", "promisor"):
            return !["false", "no", "off", "0"].contains((entry.value ?? "true").lowercased())
        case ("extensions", "partialclone"):
            return !(entry.value ?? "").isEmpty
        default:
            return false
        }
    }

    /// Whether a fetch refspec writes outside `refs/remotes/<remote>/`. A refspec without a destination only fills
    /// `FETCH_HEAD`, and a negative refspec (`^…`) writes nothing.
    static func writesOutsideRemoteNamespace(_ refspec: String, remote: String) -> Bool {
        let spec = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        guard !spec.hasPrefix("^"), let colon = spec.firstIndex(of: ":") else { return false }
        let destination = spec[spec.index(after: colon)...]
        return !destination.isEmpty && !destination.hasPrefix("refs/remotes/\(remote)/")
    }
}

/// Caches inspections per directory until one of its configuration files changes (#88, overview.md §5).
///
/// Keys are chosen by the caller (`RepositoryService` uses the repository ID and the worktree path, so a repository's
/// entries can be dropped together). The cache is bounded: the least recently used entry is evicted.
actor RepoConfigInspectionCache {
    /// File identity and change times from `stat(2)` for every configuration file git reads in a directory.
    ///
    /// The status change time (`st_ctime`) moves on every write and cannot be set from user space, unlike the
    /// modification time (`touch -m`, archive extraction); the device and inode catch a file replaced by another.
    struct Fingerprint: Sendable, Equatable {
        private struct Stamp: Sendable, Equatable {
            let device: Int64
            let inode: UInt64
            let size: Int64
            let modified: [Int64]
            let changed: [Int64]
        }

        private let stamps: [String: Stamp?]

        /// Stamps the given files, following symbolic links as git does; missing files are recorded as absent, so
        /// creating one invalidates the cache.
        static func make(_ files: [URL]) -> Fingerprint {
            var stamps: [String: Stamp?] = [:]
            for file in files {
                var info = stat()
                guard stat(file.path, &info) == 0 else {
                    stamps[file.path] = .some(nil)
                    continue
                }
                stamps[file.path] = Stamp(
                    device: Int64(info.st_dev),
                    inode: UInt64(info.st_ino),
                    size: Int64(info.st_size),
                    modified: [Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)],
                    changed: [Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
                )
            }
            return Fingerprint(stamps: stamps)
        }
    }

    static let defaultCapacity = 256

    private var entries: BoundedCache<String, (fingerprint: Fingerprint, inspection: RepoConfigInspection)>

    init(capacity: Int = RepoConfigInspectionCache.defaultCapacity) {
        entries = BoundedCache(capacity: capacity)
    }

    func inspection(for key: String, fingerprint: Fingerprint) -> RepoConfigInspection? {
        guard let stored = entries.value(for: key), stored.fingerprint == fingerprint else { return nil }
        return stored.inspection
    }

    func store(_ inspection: RepoConfigInspection, for key: String, fingerprint: Fingerprint) {
        guard inspection.isCacheable else {
            entries.removeValue(for: key)
            return
        }
        entries.insert((fingerprint, inspection), for: key)
    }

    func invalidate(_ key: String) {
        entries.removeValue(for: key)
    }

    func invalidate(keysWithPrefix prefix: String) {
        entries.removeAll { $0.hasPrefix(prefix) }
    }
}
