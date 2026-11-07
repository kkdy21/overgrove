import Foundation
import XCTest

@testable import Overgrove

/// `WorktreeDetailModel` and `WorktreeSecurityModel` (#67): screens.md S-05 and security-review.md §6.
final class WorktreeDetailModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// A value that must never appear on screen: config values may hold secrets.
    private let secret = "s3cr3t-value"

    private func entry(_ scope: ConfigEntry.Scope, _ key: String, _ value: String? = nil) -> ConfigEntry {
        let first = key.firstIndex(of: ".")!
        let last = key.lastIndex(of: ".")!
        return ConfigEntry(
            scope: scope, section: String(key[..<first]),
            subsection: first == last ? nil : String(key[key.index(after: first)..<last]),
            variable: String(key[key.index(after: last)...]), value: value ?? secret)
    }

    private func inspection(
        _ entries: [ConfigEntry], failure: String? = nil, hooks: [String] = [],
        common: [String] = GitEnvironment.commonArguments, diff: [String]? = nil, realPath: String? = nil
    ) -> WorktreeInspection {
        WorktreeInspection(
            inspection: failure == nil
                ? RepoConfigInspector.inspect(ConfigParser.Listing(entries: entries, isPartial: false)) : nil,
            failure: failure, inspectedAt: now, gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
            commonArguments: common,
            diffArguments: diff
                ?? (try! ReadOnlyGitCommand.worktreeDiff(path: GitPath("f"), staged: false)
                    .subcommandArguments()),
            hookExecutables: hooks, realPath: realPath)
    }

    private func security(_ entries: [ConfigEntry], hooks: [String] = []) -> WorktreeSecurityModel {
        WorktreeSecurityModel(inspection(entries, hooks: hooks))
    }

    /// #262: a very large configuration shortens the report and the remote list, and S-05 says so.
    func testShortenedReportIsAnnounced() {
        let remotes = (0..<(RepoConfigInspector.maximumRemotes + 2)).map {
            ConfigEntry(
                scope: .local, section: "remote", subsection: "r\($0)", variable: "url", value: "https://x.invalid")
        }
        let note = security(remotes).limitNote
        XCTAssertEqual(note, "This configuration is very large: 2 more remotes are not listed.")
        XCTAssertNil(security([]).limitNote)
    }

    private func row(_ title: String, in model: WorktreeSecurityModel) throws -> WorktreeSecurityModel.Row {
        try XCTUnwrap(model.rows.first { $0.title == title }, title)
    }

    // MARK: Security rows (§6)

    func testCleanRepositoryShowsEveryRowApplied() {
        let model = security([entry(.global, "user.name", "Kim")])
        XCTAssertEqual(
            model.rows.map(\.title),
            [
                "Hooks disabled", "fsmonitor disabled", "External diff and textconv disabled", "Filters neutralized",
                "Transport commands neutralized", "Repository credential helpers ignored", "TLS verification kept on",
                "Remote URL credentials masked",
            ])
        XCTAssertTrue(model.rows.allSatisfy { $0.mark == .applied && $0.details.isEmpty })
        XCTAssertNil(model.blockingReason)
        XCTAssertNil(model.fetchBlockingReason)
        XCTAssertEqual(model.others, [])
        XCTAssertEqual(model.gitVersion, "git 2.50.1")
    }

    /// Each §6 row turns ⚠ for its own keys (as git prints them, lowercased), listing key names only.
    func testEachRowListsItsRepositoryKeys() throws {
        let cases: [(String, [String])] = [
            ("Hooks disabled", ["core.hookspath", "hook.lint.command", "hook.lint.event"]),
            ("fsmonitor disabled", ["core.fsmonitor"]),
            ("External diff and textconv disabled", ["diff.external", "diff.go.textconv"]),
            ("Filters neutralized", ["filter.lfs.process", "filter.lfs.clean"]),
            ("Transport commands neutralized", ["core.sshcommand", "core.gitproxy", "remote.origin.uploadpack"]),
            ("Repository credential helpers ignored", ["credential.helper"]),
            ("TLS verification kept on", ["http.sslverify"]),
        ]
        for (title, keys) in cases {
            let model = security(keys.map { entry(.local, $0) })
            let row = try row(title, in: model)
            XCTAssertEqual(row.mark, .neutralized, title)
            XCTAssertEqual(row.details, keys, title)
            XCTAssertEqual(model.rows.filter { $0.mark != .applied }.map(\.title), [title], "only \(title) changes")
            XCTAssertEqual(model.others, [], "\(title): covered by its row")
        }
    }

    /// ext:: remotes are reported under the transport row (§6).
    func testRemoteHelperURLIsATransportFinding() throws {
        let model = security([entry(.local, "remote.evil.url", "ext::sh -c id")])
        XCTAssertEqual(try row("Transport commands neutralized", in: model).details, ["remote.evil.url"])
    }

    func testExecutableHooksTurnTheHooksRowWarning() throws {
        let row = try row("Hooks disabled", in: security([], hooks: ["hooks/pre-commit", "hooks/post-checkout"]))
        XCTAssertEqual(row.mark, .neutralized)
        XCTAssertEqual(row.details, ["hooks/pre-commit", "hooks/post-checkout"])
    }

    /// #354: a config-defined hook that cannot be neutralized shows ✕ on the hooks row and stops queries.
    func testUnneutralizableConfigHookShowsUnknown() throws {
        let model = security([entry(.local, "hook.a=b.command")])
        XCTAssertEqual(try row("Hooks disabled", in: model).mark, .unknown)
        XCTAssertNotNil(model.blockingReason)
    }

    /// #354: the hooks row checks the arguments that really run: a repository hook without its
    /// `hook.<name>.enabled=false` (here dropped on purpose) shows ✕.
    func testConfigHookWithoutItsArgumentShowsUnknown() throws {
        let inspected = RepoConfigInspector.inspect(
            ConfigParser.Listing(entries: [entry(.local, "hook.lint.command")], isPartial: false))
        XCTAssertTrue(WorktreeSecurityModel.configHooksNeutralized(inspected))
        let regressed = RepoConfigInspection(
            report: inspected.report, neutralization: [], fetchAuthentication: inspected.fetchAuthentication,
            trustedSSHCommand: inspected.trustedSSHCommand, remotes: inspected.remotes,
            fetchBlockingReason: inspected.fetchBlockingReason, isCacheable: inspected.isCacheable,
            isPartialClone: inspected.isPartialClone)
        XCTAssertFalse(WorktreeSecurityModel.configHooksNeutralized(regressed))
    }

    /// The ✓ conditions come from the real arguments: dropping one shows ✕.
    func testMissingSafetyArgumentsShowUnknown() throws {
        let noHooks = GitEnvironment.commonArguments.filter { $0 != "core.hooksPath=/dev/null" }
        let model = WorktreeSecurityModel(inspection([], common: noHooks, diff: ["diff", "-M"]))
        XCTAssertEqual(try row("Hooks disabled", in: model).mark, .unknown)
        XCTAssertEqual(try row("fsmonitor disabled", in: model).mark, .applied)
        XCTAssertEqual(try row("External diff and textconv disabled", in: model).mark, .unknown)
    }

    func testBlockedInspectionShowsTheReasonAndUnknownRows() throws {
        let model = security([entry(.local, "filter.bad name!.clean")])
        let reason = try XCTUnwrap(model.blockingReason)
        XCTAssertTrue(reason.contains("filter driver"), reason)
        XCTAssertEqual(try row("Hooks disabled", in: model).mark, .unknown)
        XCTAssertEqual(try row("fsmonitor disabled", in: model).mark, .unknown)
        XCTAssertEqual(try row("Filters neutralized", in: model).mark, .unknown)
        XCTAssertEqual(try row("External diff and textconv disabled", in: model).mark, .applied, "no ✕ column (§6)")
    }

    func testFailedInspectionShowsTheFailure() throws {
        let model = WorktreeSecurityModel(inspection([], failure: "git did not respond\u{202E}"))
        XCTAssertEqual(model.failure, "git did not respond\\u{202E}")
        XCTAssertNil(model.blockingReason, "a failed re-read is not a stopped query (§6)")
        XCTAssertEqual(model.rows.map(\.title).count, 4, "configuration rows need an inspection")
        XCTAssertTrue(
            model.rows.filter { $0.title != "External diff and textconv disabled" }.allSatisfy { $0.mark == .unknown })
    }

    /// SEC-T11-04 (S-05): URLs with credentials show masked, never with the secret, with removal advice.
    func testSECT11_04_RemoteURLCredentialsAreMasked() throws {
        let model = security([
            entry(.local, "remote.origin.url", "https://kim:\(secret)@github.com/acme/api.git"),
            entry(.local, "remote.mirror.url", "https://github.com/acme/api.git"),
        ])
        let row = try row("Remote URL credentials masked", in: model)
        XCTAssertEqual(row.mark, .neutralized)
        XCTAssertEqual(row.details.count, 1)
        // Host and path by default (Settings › Show full remote URLs off, #86); the full masked URL when on.
        XCTAssertEqual(row.details[0], "origin: github.com/acme/api")
        let full = WorktreeSecurityModel(
            inspection([
                entry(.local, "remote.origin.url", "https://kim:\(secret)@github.com/acme/api.git")
            ]), showsFullRemoteURLs: true)
        let fullRow = try self.row("Remote URL credentials masked", in: full)
        XCTAssertTrue(fullRow.details[0].hasPrefix("origin: https://"), fullRow.details[0])
        XCTAssertFalse(row.details[0].contains(secret))
        XCTAssertFalse(fullRow.details[0].contains(secret))
        XCTAssertFalse(fullRow.details[0].contains("kim"))
        XCTAssertEqual(row.advice, "Remove the credentials from the URL and let a credential helper store them.")
        XCTAssertNil(try self.row("Remote URL credentials masked", in: security([])).advice)
    }

    /// A filter blocked because its name has `=` shows ✕, not "overridden" (security review of #67).
    func testFilterBlockedByEqualsSignIsUnknown() throws {
        let model = security([entry(.local, "filter.a=b.clean")])
        XCTAssertNotNil(model.blockingReason)
        XCTAssertEqual(try row("Filters neutralized", in: model).mark, .unknown)
        // Blocked for another reason: filters themselves were fine.
        let other = security([entry(.local, "http.a=b.proxy"), entry(.local, "filter.lfs.clean")])
        XCTAssertNotNil(other.blockingReason)
        XCTAssertEqual(try row("Filters neutralized", in: other).mark, .neutralized)
    }

    /// Keys listed under "other" are masked too (`url.<url>.insteadof`).
    func testOtherKeysAreMasked() {
        let model = security([entry(.local, "url.https://kim:\(secret)@h.example/.insteadof", "https://h.example/")])
        XCTAssertEqual(model.others.count, 1)
        XCTAssertFalse(model.others[0].key.contains(secret), model.others[0].key)
    }

    func testFetchBlockingAndPartialCloneBanners() {
        let tls = security([entry(.local, "http.sslCAInfo".lowercased())])
        XCTAssertEqual(
            tls.fetchBlockingReason, "This repository sets its own TLS certificate files; fetching is disabled.")
        let partial = security([entry(.local, "remote.origin.promisor", "true")])
        XCTAssertNotNil(partial.fetchBlockingReason)
    }

    /// Findings no row covers (#205, #209, #212 keys and the rest) are listed with their handling.
    func testOtherFindingsAreListedWithTheirHandling() {
        let model = security([
            entry(.local, "i18n.logoutputencoding", "JOHAB"),
            entry(.local, "fetch.bundleuri"),
            entry(.local, "remote.origin.promisor", "true"),
            entry(.local, "remote.origin.fetch", "+refs/heads/*:refs/heads/*"),
            entry(.worktree, "core.worktree"),
            entry(.local, "include.path"),
        ])
        XCTAssertEqual(
            model.others.map { "\($0.key) \($0.handling)" },
            [
                "i18n.logoutputencoding already blocked", "fetch.bundleuri overridden",
                "remote.origin.promisor overridden", "remote.origin.fetch overridden",
                "core.worktree (worktree) review",
                "include.path already blocked",
            ])
        XCTAssertEqual(model.others.first?.threat, "T15")
    }

    /// No configuration value reaches any displayed string; key names are escaped.
    func testValuesNeverShownAndKeysEscaped() throws {
        let model = security([
            entry(.local, "filter.lfs\u{202E}x.process"), entry(.local, "core.sshcommand"),
            entry(.local, "credential.https://h.example.helper"), entry(.local, "gpg.program"),
        ])
        let texts = model.rows.flatMap { [$0.title] + $0.details } + model.others.flatMap { [$0.key, $0.handling] }
        XCTAssertFalse(texts.contains { $0.contains(secret) })
        XCTAssertEqual(try row("Filters neutralized", in: model).details, ["filter.lfs\\u{202E}x.process"])
    }

    /// A URL subsection with credentials (`credential.<url>.helper`, `http.<url>.sslverify`) is masked in the key.
    func testURLSubsectionsAreMasked() throws {
        let model = security([
            entry(.local, "credential.https://kim:\(secret)@h.example.helper"),
            entry(.local, "http.https://kim:\(secret)@h.example.sslverify", "false"),
            // #244: without a scheme, with and without a user name
            entry(.local, "credential.kim:\(secret)@h2.example.helper"),
            entry(.local, "url.\(secret)@h3.example:org.insteadof", "https://h3.example/org"),
        ])
        let keys = model.rows.flatMap(\.details) + model.others.map(\.key)
        XCTAssertEqual(keys.count, 4, "\(keys)")
        XCTAssertFalse(keys.contains { $0.contains(secret) }, "\(keys)")
    }

    func testWorktreeScopeIsNamed() throws {
        let model = security([entry(.worktree, "core.fsmonitor")])
        XCTAssertEqual(try row("fsmonitor disabled", in: model).details, ["core.fsmonitor (worktree)"])
    }

    // MARK: Info card

    private func listingEntry(
        _ state: WorktreeListing.State, branch: String? = "feat/57", lock: Worktree.Lock = .unlocked,
        isPrunable: Bool = false, path: String = "/tmp/dev/api-wt/57"
    ) -> WorktreeListing.Entry {
        WorktreeListing.entry(path, branch: branch, lock: lock, isPrunable: isPrunable, state: state)
    }

    private func info(_ model: WorktreeDetailModel) -> [String: String] {
        Dictionary(uniqueKeysWithValues: model.info.map { ($0.label, $0.value) })
    }

    func testInfoCard() {
        let state = WorktreeListing.state(
            branch: "feat/57", staged: 2, unstaged: 2, untracked: 1,
            upstream: .tracking(upstream: "origin/feat/57", ahead: 1, behind: 0))
        let model = WorktreeDetailModel(
            entry: listingEntry(.loaded(state)), inspection: inspection([]),
            fetchStatus: .idle(lastFetched: now.addingTimeInterval(-120)), now: now, home: "/tmp/dev")
        XCTAssertEqual(model.info.map(\.label), ["Path", "HEAD", "Branch", "Upstream", "State", "Lock", "Last fetch"])
        let values = info(model)
        XCTAssertEqual(values["Path"], "~/api-wt/57")
        XCTAssertEqual(values["HEAD"], "a91f3c2")
        XCTAssertEqual(values["Branch"], "feat/57")
        XCTAssertEqual(values["Upstream"], "origin/feat/57  ↑1 ↓0")
        XCTAssertEqual(values["State"], "4 changed · 1 untracked · 0 conflicts")
        XCTAssertEqual(values["Lock"], "Not locked")
        XCTAssertEqual(values["Last fetch"], "2 min ago (repository)")
        XCTAssertEqual(model.copyablePath, "/tmp/dev/api-wt/57")
        XCTAssertNotNil(model.security)
    }

    func testInfoCardVariants() {
        let detached = WorktreeDetailModel(
            entry: listingEntry(
                .loaded(WorktreeListing.state(branch: nil, upstream: .gone(upstream: "origin/x"))), branch: nil,
                lock: .locked(reason: "release\n\u{202E}")),
            inspection: nil, fetchStatus: .never, now: now, home: "/tmp/dev")
        let values = info(detached)
        XCTAssertEqual(values["Branch"], "detached")
        XCTAssertEqual(values["Upstream"], "origin/x (gone)")
        XCTAssertEqual(values["Lock"], "Locked: release\\u{A}\\u{202E}")
        XCTAssertEqual(values["Last fetch"], "Never fetched (repository)")
        XCTAssertNil(detached.security, "still loading")
        XCTAssertNil(detached.securityUnavailable)

        let failed = WorktreeDetailModel(
            entry: listingEntry(.loaded(WorktreeListing.state(branch: "x"))), inspection: nil,
            fetchStatus: .failed(lastFetched: now.addingTimeInterval(-7_200)), now: now, home: "/tmp/dev")
        XCTAssertEqual(info(failed)["Last fetch"], "2 h ago, last attempt failed (repository)")
    }

    /// screens.md S-05: prunable shows `Directory missing` and dims the rest; no inspection is attempted.
    func testMissingWorktree() {
        let entry = listingEntry(.missing, isPrunable: true)
        XCTAssertFalse(WorktreeDetailModel.shouldInspect(entry))
        let model = WorktreeDetailModel(entry: entry, inspection: nil, fetchStatus: .never, now: now, home: "/tmp/dev")
        XCTAssertEqual(model.info.first?.value, "~/api-wt/57 — Directory missing")
        XCTAssertTrue(model.info.first?.isWarning == true)
        XCTAssertTrue(model.info.dropFirst().allSatisfy(\.isDimmed))
        XCTAssertNil(model.security)
        XCTAssertNotNil(model.securityUnavailable)
    }

    func testSymlinkedPathIsWarned() {
        let model = WorktreeDetailModel(
            entry: listingEntry(.loaded(WorktreeListing.state(branch: "x"))),
            inspection: inspection([], realPath: "/tmp/elsewhere/57"), fetchStatus: .never, now: now,
            home: "/tmp/dev")
        XCTAssertEqual(model.info.first?.value, "~/api-wt/57 — Symlink to /tmp/elsewhere/57")
        XCTAssertTrue(model.info.first?.isWarning == true)
    }

    func testOnlyVerifiedWorktreesAreInspected() {
        XCTAssertTrue(WorktreeDetailModel.shouldInspect(listingEntry(.loaded(WorktreeListing.state(branch: "x")))))
        XCTAssertTrue(WorktreeDetailModel.shouldInspect(listingEntry(.notQueried(.inspectionBlocked("r")))))
        for state: WorktreeListing.State in [
            .missing, .failed(.timeout(seconds: 15)), .notQueried(.foreignRepository), .notQueried(.duplicate),
            .notQueried(.limit),
            .notQueried(.unrepresentablePath),
        ] {
            XCTAssertFalse(WorktreeDetailModel.shouldInspect(listingEntry(state)), "\(state)")
        }
    }

    func testCopyPathOnlyForPlainPaths() {
        let model = WorktreeDetailModel(
            entry: listingEntry(.loaded(WorktreeListing.state(branch: "x")), path: "/tmp/x\nrm -rf ~"),
            inspection: nil, fetchStatus: .never, now: now)
        XCTAssertNil(model.copyablePath)
    }
}
