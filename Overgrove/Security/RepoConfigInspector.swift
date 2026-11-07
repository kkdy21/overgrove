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
    /// False when the effective configuration can change without any config file changing
    /// (`includeIf.onbranch:` depends on HEAD), so the inspection must not be cached.
    let isCacheable: Bool

    /// Arguments for `GitClient`. `nil` when the report blocks queries (fail closed).
    var safetyContext: RepoSafetyContext? {
        guard !report.isBlocked else { return nil }
        return RepoSafetyContext(
            inspectedNeutralization: neutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            fetchBlockingReason: fetchBlockingReason
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

        return RepoConfigInspection(
            report: RepoSecurityReport(findings: findings, blockingReason: blockingReason),
            neutralization: neutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            remotes: remotes,
            fetchBlockingReason: fetchBlockingReason,
            isCacheable: !dependsOnHEAD
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
        default:
            return nil
        }
    }
}

extension RepoConfigInspector {
    /// Whether a fetch refspec writes outside `refs/remotes/<remote>/`. A refspec without a destination only fills
    /// `FETCH_HEAD`, and a negative refspec (`^…`) writes nothing.
    static func writesOutsideRemoteNamespace(_ refspec: String, remote: String) -> Bool {
        let spec = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        guard !spec.hasPrefix("^"), let colon = spec.firstIndex(of: ":") else { return false }
        let destination = spec[spec.index(after: colon)...]
        return !destination.isEmpty && !destination.hasPrefix("refs/remotes/\(remote)/")
    }
}

/// Caches inspections per repository until one of its configuration files changes (modification time or size).
actor RepoConfigInspectionCache {
    struct Fingerprint: Sendable, Equatable {
        fileprivate let stamps: [String: [Double]]

        /// Stamps the given files; missing files are recorded as absent, so creating one invalidates the cache.
        static func make(_ files: [URL]) -> Fingerprint {
            var stamps: [String: [Double]] = [:]
            for file in files {
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                let size = (attributes?[.size] as? NSNumber)?.doubleValue ?? -1
                stamps[file.path] = [modified, size]
            }
            return Fingerprint(stamps: stamps)
        }
    }

    private var entries: [String: (Fingerprint, RepoConfigInspection)] = [:]

    func inspection(for repositoryID: String, fingerprint: Fingerprint) -> RepoConfigInspection? {
        guard let (stored, inspection) = entries[repositoryID], stored == fingerprint else { return nil }
        return inspection
    }

    func store(_ inspection: RepoConfigInspection, for repositoryID: String, fingerprint: Fingerprint) {
        guard inspection.isCacheable else {
            entries[repositoryID] = nil
            return
        }
        entries[repositoryID] = (fingerprint, inspection)
    }

    func invalidate(_ repositoryID: String) {
        entries[repositoryID] = nil
    }
}
