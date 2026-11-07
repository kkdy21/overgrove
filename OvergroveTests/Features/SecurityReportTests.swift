import Foundation
import XCTest

@testable import Overgrove

/// S-05's copied security report (#110, security-review.md T11): key names and verdicts only.
final class SecurityReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let secret = "s3cr3t-value"
    private let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    private let home = "/Users/report-test-user"

    private func entry(
        _ section: String, _ subsection: String?, _ variable: String, _ value: String? = nil,
        scope: ConfigEntry.Scope = .local
    ) -> ConfigEntry {
        ConfigEntry(scope: scope, section: section, subsection: subsection, variable: variable, value: value ?? secret)
    }

    private func inspection(
        _ entries: [ConfigEntry], failure: String? = nil, hooks: [String] = [],
        common: [String] = GitEnvironment.commonArguments
    ) -> WorktreeInspection {
        WorktreeInspection(
            inspection: failure == nil
                ? RepoConfigInspector.inspect(ConfigParser.Listing(entries: entries, isPartial: false)) : nil,
            failure: failure, inspectedAt: now, gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
            commonArguments: common,
            diffArguments: try! ReadOnlyGitCommand.worktreeDiff(path: GitPath("f"), staged: false)
                .subcommandArguments(),
            hookExecutables: hooks, realPath: nil)
    }

    private func report(
        _ entries: [ConfigEntry], failure: String? = nil, hooks: [String] = [],
        common: [String] = GitEnvironment.commonArguments
    ) -> String {
        SecurityReport.text(
            isMainWorktree: false, inspection: inspection(entries, failure: failure, hooks: hooks, common: common),
            appVersion: "0.1.0", home: home)
    }

    /// Everything a hostile or careless configuration can hold that must not leave the machine in a pasted report.
    private var hostileEntries: [ConfigEntry] {
        [
            entry("remote", "origin", "url", "https://kim:\(token)@git.example.com/acme/api.git"),
            entry("remote", "mirror", "url", "ssh://deploy@10.0.0.7:2222\(home)/mirror.git"),
            entry("remote", "origin", "uploadpack", "\(home)/bin/evil-pack --token=\(secret)"),
            entry("credential", "https://kim:\(token)@git.example.com", "helper", "store --file \(home)/.cred"),
            entry("http", "https://internal.example.com/", "sslverify", "false"),
            entry("http", nil, "proxy", "http://user:pw@proxy.example.com:8080"),
            entry("url", "https://kim:\(token)@git.example.com/", "insteadof", "gh:"),
            entry("includeif", "gitdir:\(home)/secret-project/", "path", "\(home)/.gitconfig-work"),
            entry("core", nil, "sshcommand", "ssh -i \(home)/.ssh/id_deploy"),
            entry("core", nil, "hookspath", "\(home)/hooks"),
            entry("filter", "lfs", "process", "git-lfs filter-process --token \(secret)"),
            entry("core", nil, "pager", "less \(secret)"),
            entry("diff", "secret", "textconv", "\(home)/bin/dump"),
            entry("gpg", nil, "program", "\(home)/bin/gpg-\(secret)", scope: .worktree),
            // Remote and driver names that are a host or an address (security review of #110).
            entry("remote", "git.example.com", "url", "https://kim:\(token)@git.example.com/x.git"),
            entry("remote", "10.0.0.7", "uploadpack", "pack"),
            entry("http", nil, "sslcert", "\(home)/certs/client.pem"),
            entry("alias", nil, "deploy", "!\(home)/bin/deploy --token \(secret)"),
            entry("submodule", "libs/secret-project", "update", "!\(home)/bin/update"),
            entry("diff", nil, "orderfile", "\(home)/order.txt"),
            entry("core", nil, "worktree", "\(home)/elsewhere", scope: .worktree),
        ]
    }

    func testSECT11_06_ReportHasKeyNamesAndVerdictsButNoValuesURLsOrPaths() {
        let text = report(hostileEntries, hooks: ["hooks/pre-commit", "+3 more"])
        // Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to read the report.
        if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"] {
            try? Data(text.utf8).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("security-report.txt"))
        }
        for leak in [
            secret, token, "kim", "git.example.com", "internal.example.com", "proxy.example.com", "10.0.0.7", home,
            "report-test-user", "secret-project", "id_deploy", ".gitconfig-work", "https:", "http:", "ssh:", "://",
            "@", "evil-pack", "less ", "acme/api", "client.pem", "certs", "deploy --token", "libs/",
            "order.txt", "elsewhere",
        ] {
            XCTAssertFalse(text.contains(leak), "the report must not contain \(leak):\n\(text)")
        }
        for expected in [
            "filter.lfs.process", "core.sshcommand", "core.hookspath", "remote.origin.uploadpack",
            "credential.<url>.helper", "http.<url>.sslverify", "url.<url>.insteadof", "includeif.<condition>.path",
            "diff.secret.textconv", "gpg.program (worktree)", "core.pager", "hooks/pre-commit", "+3 more",
            "origin (credentials in URL)", "<remote> (credentials in URL)", "remote.<name>.uploadpack",
            "submodule.<name>.update", "alias.deploy", "diff.orderfile", "core.worktree (worktree)",
            "Fetch disabled: This repository sets its own TLS certificate files",
        ] {
            XCTAssertTrue(text.contains(expected), "missing \(expected):\n\(text)")
        }
    }

    /// #107: the report states the untrusted mode and counts remotes on this Mac, without names, paths, or URLs.
    func testReportStatesUntrustedModeAndCountsLocalRemotes() {
        let entries = [
            ConfigEntry(
                scope: .local, section: "remote", subsection: "origin", variable: "url", value: "/srv/git/api.git"),
            ConfigEntry(
                scope: .local, section: "remote", subsection: "github", variable: "url",
                value: "https://github.com/acme/api.git"),
        ]
        let trusted = report(entries)
        XCTAssertTrue(trusted.contains("Untrusted: no"), trusted)
        XCTAssertTrue(trusted.contains("Remotes on this Mac: 1"), trusted)
        XCTAssertFalse(trusted.contains("/srv/git"), trusted)
        let untrusted = SecurityReport.text(
            isMainWorktree: false, inspection: inspection(entries), appVersion: "0.1.0", home: home, isUntrusted: true)
        XCTAssertTrue(untrusted.contains("Untrusted: yes"), untrusted)
    }

    func testReportFollowsTheSecurityCard() {
        let text = report([entry("filter", "lfs", "process")])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "Overgrove security report")
        XCTAssertTrue(lines.contains("Worktree: linked worktree"))
        XCTAssertTrue(lines.contains("Inspected: 2027-01-15T08:00:00Z · local and worktree scopes · git 2.50.1"))
        XCTAssertTrue(lines.contains("Overgrove: 0.1.0"))
        XCTAssertTrue(lines.contains("✓ Hooks disabled"))
        XCTAssertTrue(lines.contains("⚠ Filters neutralized: filter.lfs.process"))
        XCTAssertTrue(lines.contains("✓ Remote URL credentials masked"))
        XCTAssertEqual(lines.last, SecurityReport.footer)
    }

    func testUnknownRowsBlockingAndFailureAreReportedWithoutDetails() {
        let missingGuards = report([], common: [])
        XCTAssertTrue(missingGuards.contains("✕ Hooks disabled (not confirmed)"))
        XCTAssertTrue(missingGuards.contains("✕ fsmonitor disabled (not confirmed)"))

        let blocked = report([entry("filter", "bad=name", "clean")])
        XCTAssertTrue(blocked.contains("\nQueries stopped: "), blocked)
        XCTAssertTrue(blocked.contains("filter.<name>.clean"), "the refused driver name is not quoted")
        XCTAssertFalse(blocked.contains("bad=name"))

        // A failure message can carry a path or a remote's text: only the fact that it failed is copied.
        let failed = report([], failure: "fatal: unable to read \(home)/repo/.git/config.worktree (\(token))")
        XCTAssertTrue(failed.contains("Configuration not read for this worktree."))
        XCTAssertFalse(failed.contains(home))
        XCTAssertFalse(failed.contains(token))
    }

    func testOtherFindingsCarryHandlingAndThreat() {
        let text = report([entry("core", nil, "pager", "less")])
        XCTAssertTrue(text.contains("Other repository settings"))
        XCTAssertTrue(text.contains("- core.pager: already blocked (T14)"))
    }

    func testLastGuardMasksEscapesAndShortensHome() {
        XCTAssertEqual(SecurityReport.guarded("x\u{202E}y", home: home), PathValidator.displayable("x\u{202E}y"))
        XCTAssertEqual(SecurityReport.guarded("see \(home)/dev and \(home)", home: home), "see ~/dev and ~")
        XCTAssertEqual(SecurityReport.guarded("https://a:b@host", home: home), "https://***@host")
    }

    func testOddSubsectionsAreReplacedNotQuoted() {
        XCTAssertEqual(SecurityReport.keyName(entry("remote", "origin", "uploadpack")), "remote.origin.uploadpack")
        XCTAssertEqual(SecurityReport.keyName(entry("filter", "lfs", "smudge")), "filter.lfs.smudge")
        XCTAssertEqual(SecurityReport.keyName(entry("filter", "my driver/x", "clean")), "filter.<name>.clean")
        XCTAssertEqual(SecurityReport.keyName(entry("remote", "o@host", "url")), "remote.<name>.url")
        XCTAssertEqual(SecurityReport.keyName(entry("remote", "git.corp.example", "url")), "remote.<name>.url")
        XCTAssertEqual(SecurityReport.keyName(entry("remote", "10.0.0.7", "url")), "remote.<name>.url")
        XCTAssertEqual(SecurityReport.keyName(entry("remote", "upstream", "url")), "remote.upstream.url")
        XCTAssertEqual(
            SecurityReport.keyName(entry("includeif", "onbranch:main", "path")), "includeif.<condition>.path")
        XCTAssertEqual(SecurityReport.keyName(entry("http", "plain", "sslverify")), "http.<url>.sslverify")
        XCTAssertEqual(
            SecurityReport.keyName(entry("core", nil, "worktree", scope: .worktree)), "core.worktree (worktree)")
    }

    func testHookLinesKeepOnlyPlainNames() {
        XCTAssertEqual(
            SecurityReport.hookLines(["hooks/pre-commit", "hooks/\(home)x", "+3 more", "hooks (a link, not followed)"]),
            ["hooks/pre-commit", "hooks/<file>", "+3 more", "hooks (a link, not followed)"])
    }

    /// The S-05 model offers the report only when it shows a SECURITY section.
    func testDetailModelOffersTheReportWithTheSecuritySection() throws {
        let worktree = Worktree(
            path: GitPath("\(home)/dev/api"), head: ObjectID(String(repeating: "a", count: 40)),
            branch: "refs/heads/kim-at-git-internal-corp", isMain: true, isDetached: false, isBare: false,
            lock: .unlocked,
            isPrunable: false, prunableReason: nil)
        let state = WorkingState(
            headCommit: nil, head: .branch("main"), upstream: .none, stashCount: 0, staged: [], unstaged: [],
            untracked: [], conflicted: [], isPartial: false, skippedRecords: 0)
        for full in [false, true] {
            let loaded = WorktreeDetailModel(
                entry: WorktreeListing.Entry(worktree: worktree, state: .loaded(state)),
                inspection: inspection(hostileEntries), fetchStatus: .never, now: now, home: home,
                showsFullRemoteURLs: full, appVersion: "0.1.0")
            let text = SecurityReport.text(try XCTUnwrap(loaded.securityReport))
            XCTAssertTrue(text.hasPrefix("Overgrove security report\nWorktree: main worktree\n"))
            XCTAssertFalse(text.contains(home), "the worktree path stays out of the report")
            XCTAssertFalse(text.contains("/dev/api"))
            XCTAssertFalse(text.contains("kim-at-git-internal-corp"), "branch names are not copied")
            XCTAssertFalse(text.contains("git.example.com"), "full remote URLs setting: still no hosts")
        }

        let missing = WorktreeDetailModel(
            entry: WorktreeListing.Entry(worktree: worktree, state: .missing), inspection: inspection([]),
            fetchStatus: .never, now: now, home: home)
        XCTAssertNil(missing.securityReport)
        let notLoaded = WorktreeDetailModel(
            entry: WorktreeListing.Entry(worktree: worktree, state: .loaded(state)), inspection: nil,
            fetchStatus: .never, now: now, home: home)
        XCTAssertNil(notLoaded.securityReport)
    }

    func testLongListsAreCut() {
        let filters = (0..<80).map { entry("filter", "f\($0)", "clean") }
        let text = report(filters)
        let line = text.split(separator: "\n").first { $0.hasPrefix("⚠ Filters neutralized") } ?? ""
        XCTAssertTrue(line.hasSuffix("+30 more"), String(line))

        let pagers = (0..<70).map { entry("pager", "cmd\($0)", "x", "less") }
        let others = report(pagers).split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(others.count, SecurityReport.maximumDetails + 1)
        XCTAssertEqual(others.last, "- +20 more")
    }
}
