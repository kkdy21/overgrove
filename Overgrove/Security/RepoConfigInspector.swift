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
        var hasUntrustedHelper = false

        if listing.isPartial {
            blockingReason = "The configuration listing was truncated, so it could not be inspected completely."
        }

        for entry in listing.entries where entry.scope.isRepositoryControlled {
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
                if isFalse(entry.value) && !restoreTLS.contains(entry.key) { restoreTLS.append(entry.key) }
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

        return RepoConfigInspection(
            report: RepoSecurityReport(findings: findings, blockingReason: blockingReason),
            neutralization: neutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            remotes: remotes
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
            case "sshcommand", "gitproxy", "alternaterefscommand": return ("T5", .neutralized)
            case "fsmonitor": return ("T1", .reported)
            case "hookspath": return ("T2", .reported)
            case "askpass": return ("T12", .reported)
            case "worktree": return ("T14", .warned)
            default: return nil
            }
        case "remote":
            if variable == "uploadpack" { return ("T5", .neutralized) }
            if variable == "url", value.hasPrefix("ext::") || value.hasPrefix("fd::") { return ("T5", .reported) }
            return nil
        case "http":
            if variable == "sslverify" { return isFalse(entry.value) ? ("T11", .neutralized) : nil }
            if ["proxy", "sslcainfo", "sslcapath", "sslcert", "sslkey"].contains(variable) { return ("T11", .warned) }
            return nil
        case "diff" where variable == "external" || variable == "textconv" || variable == "command":
            return ("T3", .reported)
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

    /// git's boolean false spellings; an empty value also means false.
    private static func isFalse(_ value: String?) -> Bool {
        guard let value else { return false }  // valueless boolean means true
        return ["false", "no", "off", "0", ""].contains(value.lowercased())
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
        entries[repositoryID] = (fingerprint, inspection)
    }

    func invalidate(_ repositoryID: String) {
        entries[repositoryID] = nil
    }
}
