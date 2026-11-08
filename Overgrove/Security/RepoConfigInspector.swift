import Foundation

/// The result of inspecting a repository's own configuration (ADR-0009, security-review.md §3.3).
struct RepoConfigInspection: Sendable, Equatable {
    struct Remote: Sendable, Equatable {
        let name: RemoteName
        /// Raw URL, for GitHub owner/name detection only. Never display it: use `displayURL`.
        let url: String
        /// Credential-masked URL for the UI.
        let displayURL: String
        /// Every URL of the remote, after any `url.<base>.insteadOf` rewrite, is in a built-in transport form, and no
        /// `remote.<n>.vcs` is set (#350). Fetch runs only these remotes.
        let isBuiltInTransport: Bool
        /// A URL of the remote carries a password, as written or after a rewrite (#356). Fetch refuses the remote:
        /// git would send it, and after a successful fetch ask the trusted helper to store it for that host.
        var hasPasswordInURL = false
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
    /// A promisor remote (by `promisor` or by a filter) or `extensions.partialclone` exists in any scope (#212, #317).
    let isPartialClone: Bool
    /// Remotes past `RepoConfigInspector.maximumRemotes`, counted but not listed (#262).
    var omittedRemotes = 0

    /// Arguments for `GitClient`. `nil` when the report blocks queries (fail closed).
    var safetyContext: RepoSafetyContext? {
        guard !report.isBlocked else { return nil }
        return RepoSafetyContext(
            inspectedNeutralization: neutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            fetchBlockingReason: fetchBlockingReason,
            isPartialClone: isPartialClone,
            fetchableRemotes: Set(remotes.filter(\.isBuiltInTransport).map(\.name.value)),
            remotesWithPassword: Set(remotes.filter(\.hasPasswordInURL).map(\.name.value))
        )
    }
}

/// Inspects `git config --list --show-scope -z --includes` output and decides how to neutralize keys that can make
/// git run programs (ADR-0009). Only `local` and `worktree` scopes are untrusted; anything that cannot be handled
/// safely blocks queries (fail closed).
enum RepoConfigInspector {
    /// Bounds on what one inspection keeps (#262, T15). A repository decides its `config --list` output up to the
    /// 10 MB stdout cap, so every step here is linear in the listing, and these caps bound what is kept and passed on:
    /// - Filter drivers beyond this cannot all be neutralized: each adds eight arguments to every git command, and the
    ///   command line would outgrow the argument limit. Queries stop (fail closed).
    static let maximumNeutralizedDrivers = 256
    /// Fetch-only overrides (`http.<url>.sslVerify`, `http.<url>.proxy`) beyond this disable fetch; queries go on.
    static let maximumFetchOverrides = 256
    /// Remotes listed (configuration order). Fetch uses fewer still (`maximumFetchedRemotes`, #259); the rest are
    /// counted in `omittedRemotes`. Remotes never affect neutralization, so this is not fail closed.
    static let maximumRemotes = 1_000
    /// Findings kept for the report (S-05); the rest are counted in `omittedFindings`.
    static let maximumFindings = 1_000
    /// Bounds on the remote form check (#350, T15). Past any of them a remote is not fetchable; queries go on.
    /// - Remotes checked, the first in configuration order. More than one Fetch takes
    ///   (`RepositoryService.defaultMaximumFetchedRemotes`).
    static let maximumCheckedRemotes = 32
    /// - URLs per remote. Beyond this the remote is not fetchable.
    static let maximumURLsPerRemote = 4
    /// - `url.<base>.insteadOf` rewrites. Beyond this no remote is fetchable.
    static let maximumInsteadOfRewrites = 256
    /// - Bytes in a URL, a rewrite's base, or its prefix. A longer URL is not fetchable; a longer rewrite makes no
    ///   remote fetchable.
    static let maximumCheckedLength = 1_024

    static func inspect(_ listing: ConfigParser.Listing) -> RepoConfigInspection {
        var findings: [RepoSecurityReport.Finding] = []
        var omittedFindings = 0
        var blockingReason: String?
        // Arrays keep first-seen order (it becomes argument order); the sets make each check O(1) (#262).
        var neutralizedDrivers: [String] = []
        var seenDrivers = Set<String>()
        var restoreTLS: [String] = []
        var credentialSwitches: [String] = []
        var seenCredentialSwitches = Set<[UInt8]>()
        var seenTLS = Set<String>()
        var resetProxies: [String] = []
        var seenProxies = Set<String>()
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
            if findings.count < maximumFindings {
                findings.append(RepoSecurityReport.Finding(entry: entry, threat: threat, handling: handling))
            } else {
                omittedFindings += 1
            }

            switch (entry.section, entry.variable) {
            case ("filter", _):
                guard let driver = entry.subsection else { continue }
                if !ConfigParser.isNeutralizableDriverName(driver) {
                    blockingReason = "A filter driver name contains characters that cannot be neutralized safely."
                } else if seenDrivers.insert(driver).inserted {
                    neutralizedDrivers.append(driver)
                }
            case ("credential", "helper"):
                hasUntrustedHelper = true
            case ("http", "sslverify"):
                // Always force true: git accepts many spellings of false (0k, 0x0, -0, …), so never guess.
                if seenTLS.insert(entry.key).inserted { restoreTLS.append(entry.key) }
            case ("http", "proxy"):
                if seenProxies.insert(entry.key).inserted { resetProxies.append(entry.key) }
            case ("http", "sslcainfo"), ("http", "sslcapath"), ("http", "sslcert"), ("http", "sslkey"),
                ("http", "proxysslcainfo"), ("http", "proxysslcert"), ("http", "proxysslkey"):
                fetchBlockingReason = "This repository sets its own TLS certificate files; fetching is disabled."
            case ("http", "curloptresolve"):
                fetchBlockingReason = "This repository pins host names to addresses; fetching is disabled."
            case ("extensions", "refstorage"):
                fetchBlockingReason =
                    "This repository keeps its references in a location it chose; fetching is disabled."
            // URL-specific keys win over the generic ones fetch pins, so each is forced on under its own key (#356).
            case ("credential", "protectprotocol"), ("credential", "sanitizeprompt"):
                if seenCredentialSwitches.insert(Array(entry.key.utf8)).inserted {
                    credentialSwitches.append(entry.key)
                }
            default:
                break
            }
        }

        if neutralizedDrivers.count > maximumNeutralizedDrivers {
            blockingReason =
                "This repository defines \(neutralizedDrivers.count) filter drivers, more than Overgrove can "
                + "neutralize (\(maximumNeutralizedDrivers))."
        }
        if restoreTLS.count + resetProxies.count > maximumFetchOverrides {
            fetchBlockingReason =
                "This repository sets TLS or proxy options for too many URLs to override; fetching is disabled."
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
        fetchAuthentication += credentialSwitches.flatMap { ["-c", "\($0)=true"] }
        // A repository-local proxy could receive credentials released by a trusted helper (review of #150).
        // Re-assert the trusted value for the same key, or an empty value (no proxy). One pass collects the last
        // trusted value per proxy key, instead of a scan of the whole listing per key.
        var trustedProxies: [String: String] = [:]
        for entry in listing.entries
        where !entry.scope.isRepositoryControlled && seenProxies.contains(entry.key) {
            trustedProxies[entry.key] = entry.value ?? ""
        }
        for key in resetProxies {
            fetchAuthentication += ["-c", "\(key)=\(trustedProxies[key] ?? "")"]
        }

        let trustedSSHCommand =
            listing.entries.last {
                !$0.scope.isRepositoryControlled && $0.section == "core" && $0.variable == "sshcommand"
            }?.value

        var listedRemotes: [(name: RemoteName, url: String)] = []
        var seenRemotes = Set<String>()
        var omittedRemotes = 0
        for entry in listing.entries where entry.section == "remote" && entry.variable == "url" {
            guard let subsection = entry.subsection, let name = RemoteName(subsection), let url = entry.value,
                seenRemotes.insert(name.value).inserted
            else { continue }
            guard listedRemotes.count < maximumRemotes else {
                omittedRemotes += 1
                continue
            }
            listedRemotes.append((name, url))
        }
        let builtInRemotes = builtInRemoteNames(
            listing, among: listedRemotes.prefix(maximumCheckedRemotes).map(\.name.value))
        let withPassword = remotesWithPassword(listing, among: listedRemotes.map(\.name.value))
        let remotes = listedRemotes.map {
            RepoConfigInspection.Remote(
                name: $0.name, url: $0.url, displayURL: CredentialMasker.mask($0.url),
                isBuiltInTransport: builtInRemotes.contains($0.name.value),
                hasPasswordInURL: withPassword.contains($0.name.value))
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

        var inspection = RepoConfigInspection(
            report: RepoSecurityReport(
                findings: findings, blockingReason: blockingReason, omittedFindings: omittedFindings),
            neutralization: neutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            remotes: remotes,
            fetchBlockingReason: fetchBlockingReason,
            isCacheable: !dependsOnHEAD && !readsUnstampedFiles,
            isPartialClone: listing.entries.contains(where: isPartialCloneSetting)
        )
        inspection.omittedRemotes = omittedRemotes
        return inspection
    }

    /// git's boolean spellings: `pager.<cmd>=false` turns paging off and `true` uses the default pager; anything else is
    /// a command.
    private static func isBoolean(_ value: String) -> Bool {
        ["", "true", "false", "yes", "no", "on", "off", "1", "0"].contains(value.lowercased())
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
        // Off switches for git's credential CVE fixes (CVE-2024-50349, CVE-2024-52006); forced on for fetch (#356).
        case "credential" where variable == "protectprotocol" || variable == "sanitizeprompt":
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
            // Commands the app never runs, but a git typed in Open in Terminal does (#278, T14).
            case "pager", "editor": return ("T14", .reported)
            default: return nil
            }
        case "pager" where !isBoolean(value):
            return ("T14", .reported)
        case "sequence" where variable == "editor":
            return ("T14", .reported)
        case "alias" where value.hasPrefix("!"):
            return ("T14", .reported)
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
            // A remote helper chosen by the repository. Fetch refuses the remote before git starts (#350);
            // `GIT_ALLOW_PROTOCOL` refuses helpers outside the allowed transports (#161).
            if variable == "vcs" { return ("T5", .reported) }
            if variable == "url", TransportName.remoteHelper(forURL: value) != nil { return ("T5", .reported) }
            return nil
        case "http":
            if variable == "sslverify" || variable == "proxy" { return ("T11", .neutralized) }
            if ["sslcainfo", "sslcapath", "sslcert", "sslkey"].contains(variable) { return ("T11", .warned) }
            // The same policy for the proxy's TLS files and for pinning a host to an address (git 2.37+) (#356).
            if ["proxysslcainfo", "proxysslcert", "proxysslkey", "curloptresolve"].contains(variable) {
                return ("T11", .warned)
            }
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
        // git 2.42+: a shell command `git gc` / `repack` runs. The app never runs gc; Terminal git would (#356).
        case "gc" where variable == "recentobjectshook":
            return ("T14", .reported)
        // A file outside the repository read by every `git log` (a FIFO stalls it); the common arguments turn the
        // mailmap off (#356).
        case "mailmap" where variable == "file" || variable == "blob", "log" where variable == "mailmap":
            return ("T15", .neutralized)
        // Promisor remotes the server advertises (git 2.49+); fetch accepts none (#356).
        case "promisor":
            return ("T5", .neutralized)
        // git 2.54: a location for the ref store, written by fetch and read by every query. Only the plain backend
        // names keep the refs inside the repository (#356).
        case "extensions" where variable == "refstorage" && !isPlainRefStorage(value):
            return ("T13", .warned)
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
    /// The remotes among `candidates` that fetch may run: every URL is in a built-in transport form, as written and
    /// after a `url.<base>.insteadOf` rewrite, and no `remote.<n>.vcs` is set, whatever the scope of the setting
    /// (#350, T5). Fail closed: anything that cannot be checked like git leaves the remote out.
    ///
    /// - git applies only the longest matching rewrite; every match is checked here, which can only refuse more. A key
    ///   without a value counts as an empty prefix, which matches every URL.
    /// - An empty URL value is refused: on newer git it clears the remote's URL list, and git then reads legacy
    ///   remote files this inspection does not see.
    /// - Values are compared as bytes, as git does. The listing decodes invalid UTF-8 lossily, so a value with a
    ///   replacement character is not checked: such a URL is refused, and such a rewrite refuses every remote.
    /// - Work is bounded (#262, T15): at most `candidates` × `maximumURLsPerRemote` × `maximumInsteadOfRewrites`
    ///   checks of at most `maximumCheckedLength` bytes each, plus one pass over the listing.
    static func builtInRemoteNames(_ listing: ConfigParser.Listing, among candidates: [String]) -> Set<String> {
        let checked = Set(candidates)
        var rewrites: [(base: TransportName.ScannedBytes, prefix: [UInt8])] = []
        var areRewritesCheckable = true
        var urls: [String: [TransportName.ScannedBytes]] = [:]
        var refused = Set<String>()
        for entry in listing.entries {
            switch (entry.section, entry.variable) {
            case ("url", "insteadof"):
                let base = entry.subsection ?? ""
                let prefix = entry.value ?? ""
                if rewrites.count < maximumInsteadOfRewrites, isCheckable(base), isCheckable(prefix) {
                    rewrites.append((TransportName.ScannedBytes(base), Array(prefix.utf8)))
                } else {
                    areRewritesCheckable = false
                }
            case ("remote", "vcs"):
                if let name = entry.subsection, checked.contains(name) { refused.insert(name) }
            case ("remote", "url"):
                guard let name = entry.subsection, checked.contains(name), !refused.contains(name) else { continue }
                let url = entry.value ?? ""
                if url.isEmpty || !isCheckable(url) || urls[name, default: []].count >= maximumURLsPerRemote {
                    refused.insert(name)
                    urls[name] = nil
                } else {
                    urls[name, default: []].append(TransportName.ScannedBytes(url))
                }
            default:
                continue
            }
        }
        guard areRewritesCheckable else { return [] }
        let empty = TransportName.ScannedBytes("")
        var builtIn = Set<String>()
        for (name, values) in urls where !refused.contains(name) {
            let isBuiltIn = values.allSatisfy { url in
                TransportName.isBuiltInFetchForm(empty, url, from: 0)
                    && rewrites.allSatisfy { rewrite in
                        !hasPrefix(url.bytes, rewrite.prefix)
                            || TransportName.isBuiltInFetchForm(rewrite.base, url, from: rewrite.prefix.count)
                    }
            }
            if isBuiltIn { builtIn.insert(name) }
        }
        return builtIn
    }

    /// The backend names alone keep the ref store inside the repository; a value with a location does not (git 2.54).
    static func isPlainRefStorage(_ value: String) -> Bool {
        ["files", "reftable"].contains(value.lowercased())
    }

    /// The remotes among `candidates` with a password in a URL, as written or after any matching
    /// `url.<base>.insteadOf` rewrite, in any scope (#356). git 2.37+ refuses such a URL itself with
    /// `transfer.credentialsInUrl=die` (fetch pins it); this covers older git. Only `<scheme>://` URLs carry
    /// credentials. Bounded like `builtInRemoteNames`; a value it cannot check (too long, lossy) is left to that check,
    /// which refuses it.
    static func remotesWithPassword(_ listing: ConfigParser.Listing, among candidates: [String]) -> Set<String> {
        let checked = Set(candidates)
        var rewrites: [(base: [UInt8], prefix: [UInt8])] = []
        var urls: [String: [[UInt8]]] = [:]
        for entry in listing.entries {
            switch (entry.section, entry.variable) {
            case ("url", "insteadof"):
                let base = entry.subsection ?? ""
                let prefix = entry.value ?? ""
                if rewrites.count < maximumInsteadOfRewrites, isCheckable(base), isCheckable(prefix) {
                    rewrites.append((Array(base.utf8), Array(prefix.utf8)))
                }
            case ("remote", "url"):
                guard let name = entry.subsection, checked.contains(name), let url = entry.value, isCheckable(url),
                    urls[name, default: []].count < maximumURLsPerRemote
                else { continue }
                urls[name, default: []].append(Array(url.utf8))
            default:
                continue
            }
        }
        var found = Set<String>()
        for (name, values) in urls {
            let carriesPassword = values.contains { url in
                hasPassword(url)
                    || rewrites.contains { hasPrefix(url, $0.prefix) && hasPassword($0.base + url[$0.prefix.count...]) }
            }
            if carriesPassword { found.insert(name) }
        }
        return found
    }

    /// `<scheme>://<user>:<password>@…`: a `:` in the userinfo, which ends at the last `@` before the path.
    static func hasPassword(_ url: [UInt8]) -> Bool {
        let separator: [UInt8] = Array("://".utf8)
        guard let start = (0...max(0, url.count - separator.count)).first(where: { url[$0...].starts(with: separator) })
        else { return false }
        let authority = url[(start + separator.count)...].prefix { $0 != 0x2F }
        guard let at = authority.lastIndex(of: 0x40) else { return false }
        return authority[..<at].contains(0x3A)
    }

    /// git's `starts_with` on bytes.
    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard !prefix.isEmpty else { return true }
        guard prefix.count <= bytes.count else { return false }
        return bytes.withUnsafeBufferPointer { whole in
            prefix.withUnsafeBufferPointer { start in memcmp(whole.baseAddress, start.baseAddress, prefix.count) == 0 }
        }
    }

    /// Short enough to check, and decoded without loss, so its bytes are the ones git compares.
    private static func isCheckable(_ value: String) -> Bool {
        value.utf8.count <= maximumCheckedLength && !value.unicodeScalars.contains("\u{FFFD}")
    }

    /// Every setting that makes git treat a remote as a promisor, in any scope: `remote.<n>.promisor` set to anything
    /// but a clear false, any `remote.<n>.partialclonefilter` (git registers the remote for a filter alone), and any
    /// `extensions.partialclone`, even empty (#317). Lazy fetch runs the repository's own uploadpack whichever scope
    /// made the remote a promisor, so any of them counts (fail closed).
    static func isPartialCloneSetting(_ entry: ConfigEntry) -> Bool {
        switch (entry.section, entry.variable) {
        case ("remote", "promisor"):
            return !["false", "no", "off", "0"].contains((entry.value ?? "true").lowercased())
        case ("remote", "partialclonefilter"), ("extensions", "partialclone"):
            return true
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
