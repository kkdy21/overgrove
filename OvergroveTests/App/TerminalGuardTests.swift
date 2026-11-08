import Foundation
import XCTest

@testable import Overgrove

/// SEC-T14-08: Open in Terminal asks first unless the worktree's settings were checked and hold nothing that runs
/// code (#73, security-review.md T14).
@MainActor
final class TerminalGuardTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-terminal-\(UUID().uuidString)")
        for name in ["clean", "risky", "unchecked"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    private func inspection(_ entries: [(String, String?, String, String?)]) -> RepoConfigInspection {
        RepoConfigInspector.inspect(
            ConfigParser.Listing(
                entries: entries.map {
                    ConfigEntry(scope: .local, section: $0.0, subsection: $0.1, variable: $0.2, value: $0.3)
                }, isPartial: false))
    }

    func testReasons() {
        XCTAssertEqual(TerminalGuard.reasons(inspection: inspection([]), hooks: []), [], "clean: open directly")
        XCTAssertEqual(
            TerminalGuard.reasons(inspection: inspection([("user", nil, "name", "me")]), hooks: []), [],
            "a setting the inspector does not report does not ask")
        XCTAssertEqual(
            TerminalGuard.reasons(inspection: nil, hooks: []), ["The repository’s settings could not be checked."])
        XCTAssertEqual(
            TerminalGuard.reasons(inspection: inspection([]), hooks: ["hooks/post-index-change"]),
            ["hooks/post-index-change"], "an executable hook asks")

        let risky = TerminalGuard.reasons(
            inspection: inspection([
                ("core", nil, "fsmonitor", "./x"), ("core", nil, "fsmonitor", "./y"),
                ("filter", "lfs\u{202E}", "clean", "sh"),
            ]), hooks: [])
        XCTAssertEqual(
            risky,
            [
                "A filter driver name contains characters that cannot be neutralized safely.", "core.fsmonitor",
                "filter.lfs\\u{202E}.clean",
            ], "a blocked report says why first; keys once, escaped")
    }

    /// SEC-T14-10: every finding is a reason, whatever its threat or handling: the shell's git honours them all
    /// (#278).
    func testEveryFindingIsAReason() {
        let cases: [(String, String?, String, String?)] = [
            ("core", nil, "pager", "x"), ("pager", nil, "log", "x"), ("core", nil, "editor", "x"),
            ("sequence", nil, "editor", "x"), ("alias", nil, "st", "!x"), ("submodule", "lib", "update", "!x"),
            ("uploadpack", nil, "packobjectshook", "x"), ("include", nil, "path", "x"),
            ("core", nil, "attributesfile", "/tmp/fifo"), ("http", nil, "sslverify", "false"),
            // A config-defined hook (git 2.54+, #354) runs in Terminal's git too.
            ("hook", "lint", "command", "x"),
        ]
        for (section, subsection, variable, value) in cases {
            let key = [section, subsection, variable].compactMap { $0 }.joined(separator: ".")
            XCTAssertEqual(
                TerminalGuard.reasons(inspection: inspection([(section, subsection, variable, value)]), hooks: []),
                [key], key)
        }
    }

    func testListedKeysAreMaskedAndCapped() {
        let many = (0..<12).map { ("filter", "f\($0)", "smudge", "sh") as (String, String?, String, String?) }
        let reasons = TerminalGuard.reasons(inspection: inspection(many), hooks: [])
        XCTAssertEqual(reasons.count, TerminalGuard.maximumListedKeys + 1)
        XCTAssertEqual(reasons.last, "+4 more settings")

        let masked = TerminalGuard.reasons(
            inspection: inspection([("url", "https://bob:s3cret@example.com/", "insteadof", "x")]), hooks: [])
        XCTAssertFalse(masked.joined().contains("s3cret"), "\(masked)")

        // #244: scheme-less subsections
        let schemeless = TerminalGuard.reasons(
            inspection: inspection([
                ("url", "bob:s3cret@example.com:org", "insteadof", "x"),
                ("credential", "s3cret@h.example", "helper", "y"),
            ]), hooks: [])
        XCTAssertFalse(schemeless.joined().contains("s3cret"), "\(schemeless)")
    }

    func testOpenInTerminalOpensCleanAndConfirmsTheRest() async throws {
        let actions = RecordingRowActions()
        let clean = base.appendingPathComponent("clean").path
        let risky = base.appendingPathComponent("risky").path
        let unchecked = base.appendingPathComponent("unchecked").path
        func entry(_ path: String, isMain: Bool = false, inspection: RepoConfigInspection?) -> WorktreeListing.Entry {
            let mock = WorktreeListing.entry(
                path, branch: "main", isMain: isMain, state: .loaded(WorktreeListing.state(branch: "main")))
            return WorktreeListing.Entry(worktree: mock.worktree, state: mock.state, inspection: inspection)
        }
        let listing = WorktreeListing(
            entries: [
                entry(clean, isMain: true, inspection: inspection([])),
                entry(risky, inspection: inspection([("core", nil, "fsmonitor", "./x")])),
                entry(unchecked, inspection: nil),
            ], isPartial: false)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), graphLoader: SampleGraphLoader(),
            commitLoader: StubCommitLoader())
        state.rowActions = actions
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: URL(fileURLWithPath: clean), commonGitDirectoryURL: URL(fileURLWithPath: clean + "/.git"),
                    isBare: false), owner: nil))
        state.reload()
        await state.loadTask?.value

        state.openTerminal(at: GitPath(clean))
        XCTAssertNil(state.terminalConfirmation, "clean: no question")
        XCTAssertEqual(actions.terminals.count, 1)

        state.openTerminal(at: GitPath(risky))
        let confirmation = try XCTUnwrap(state.terminalConfirmation)
        XCTAssertEqual(confirmation.reasons, ["core.fsmonitor"])
        XCTAssertTrue(confirmation.message.contains("core.fsmonitor"))
        XCTAssertEqual(actions.terminals.count, 1, "nothing opens until Open Anyway")
        state.terminalConfirmation = nil
        XCTAssertEqual(actions.terminals.count, 1, "Cancel opens nothing")

        state.openTerminal(at: GitPath(unchecked))
        XCTAssertEqual(state.terminalConfirmation?.reasons, ["The repository’s settings could not be checked."])
        state.confirmOpenTerminal()
        XCTAssertEqual(actions.terminals.map(\.lastPathComponent), ["clean", "unchecked"])
    }
}
