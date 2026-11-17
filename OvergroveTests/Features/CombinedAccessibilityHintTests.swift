import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// A row whose children are combined into one accessibility element reads its hint once (#682).
///
/// A hint set before `.accessibilityElement(children: .combine)` lands on every element under it, and combining joins
/// them: the S-05 Path row read `Copy Path, Copy Path` and a Security row its threat twice. These tests read the
/// accessibility tree SwiftUI builds for an assistive app: VoiceOver and the Accessibility API tell an app they are
/// there through `AXEnhancedUserInterface`, which is set here and cleared afterwards. Windows are offscreen and never
/// ordered in, so nothing shows on screen.
@MainActor
final class CombinedAccessibilityHintTests: XCTestCase {
    private struct Element {
        let role: String
        let label: String
        let value: String
        let help: String

        /// What VoiceOver reads as the element's text: the label, or a static text's value.
        var text: String { [label, value].filter { !$0.isEmpty }.joined(separator: ", ") }
    }

    private static let setAttribute = NSSelectorFromString("accessibilitySetValue:forAttribute:")

    override func setUp() async throws {
        setEnhancedUserInterface(true)
    }

    override func tearDown() async throws {
        setEnhancedUserInterface(false)
    }

    private func setEnhancedUserInterface(_ isOn: Bool) {
        guard NSApp.responds(to: Self.setAttribute) else { return }
        _ = NSApp.perform(Self.setAttribute, with: NSNumber(value: isOn), with: "AXEnhancedUserInterface")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Every accessibility element of `view`, depth first.
    private func elements(_ view: some View, size: CGSize = CGSize(width: 344, height: 120)) throws -> [Element] {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(Tokens.Color.surfacePanel))
        defer { window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let root = try XCTUnwrap(window.contentView)
        var found: [Element] = []
        collect(root, into: &found)
        XCTAssertGreaterThan(found.count, 1, "SwiftUI built the accessibility tree")
        return found
    }

    /// SwiftUI's nodes answer the `NSAccessibility` methods without declaring the protocol, so they are called by name.
    private func collect(_ element: Any, into found: inout [Element]) {
        guard let object = element as? NSObject else { return }
        func string(_ name: String) -> String {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return "" }
            return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
        }
        found.append(
            Element(
                role: string("accessibilityRole"), label: string("accessibilityLabel"),
                value: string("accessibilityValue"), help: string("accessibilityHelp")))
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children) else { return }
        for child in object.perform(children)?.takeUnretainedValue() as? [Any] ?? [] {
            collect(child, into: &found)
        }
    }

    /// No hint is the same text said two or more times over (`A, A`).
    private func assertNoRepeatedHint(
        _ elements: [Element], file: StaticString = #filePath, line: UInt = #line
    ) {
        for element in elements where !element.help.isEmpty {
            let parts = element.help.components(separatedBy: ", ")
            for count in 2...max(2, parts.count) where parts.count % count == 0 {
                let size = parts.count / count
                let chunks = stride(from: 0, to: parts.count, by: size).map { Array(parts[$0..<$0 + size]) }
                XCTAssertFalse(
                    Set(chunks.map { $0.joined(separator: ", ") }).count == 1,
                    "\(element.text): the hint repeats: \(element.help)", file: file, line: line)
            }
        }
    }

    private func copyButton() -> some View {
        Button {
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .hoverButtonStyle()
        .toolTip("Copy Path")
        .accessibilityLabel("Copy path")
    }

    // MARK: - toolTip(_:) (#665)

    /// The view and its tooltip area are one element: alone it reads its label and hint once.
    func testToolTipButtonReadsItsLabelAndHintOnce() throws {
        let found = try elements(copyButton())
        let button = try XCTUnwrap(found.first { $0.role == NSAccessibility.Role.button.rawValue })
        XCTAssertEqual(button.label, "Copy path")
        XCTAssertEqual(button.help, "Copy Path")
    }

    /// Inside a combined row, the button's hint is read once and its label stays in the row's text.
    func testToolTipButtonInACombinedRowReadsItsHintOnce() throws {
        let found = try elements(
            HStack {
                Text("Path")
                Text("~/dev/api")
                copyButton()
            }
            .accessibilityElement(children: .combine))
        let row = try XCTUnwrap(found.first { $0.text.contains("~/dev/api") })
        XCTAssertEqual(row.text, "Path, ~/dev/api, Copy path")
        XCTAssertEqual(row.help, "Copy Path")
    }

    /// `.help` on the one control that has it, as in Manage Repositories' rows, is one hint in the combined row. Only a
    /// hint over several elements repeats.
    func testHelpOnOneButtonInACombinedRowIsReadOnce() throws {
        let found = try elements(
            HStack {
                Text("api")
                Button("Remove") {}.help("Remove “api” from Overgrove. The folder is not changed.")
            }
            .accessibilityElement(children: .combine))
        let row = try XCTUnwrap(found.first { $0.text.contains("api") })
        XCTAssertEqual(row.help, "Remove “api” from Overgrove. The folder is not changed.")
    }

    // MARK: - Screens

    /// S-05: the Path row (path and copy button) and the Security card's "Other repository settings" rows.
    func testWorktreeDetailRowsReadTheirHintsOnce() throws {
        func entry(_ key: String) -> ConfigEntry {
            let parts = key.split(separator: ".").map(String.init)
            return ConfigEntry(
                scope: .local, section: parts[0], subsection: parts.count == 3 ? parts[1] : nil,
                variable: parts.last ?? "", value: "x")
        }
        let now = Date()
        let inspection = WorktreeInspection(
            inspection: RepoConfigInspector.inspect(
                ConfigParser.Listing(
                    entries: [entry("core.alternaterefscommand"), entry("filter.lfs.process")], isPartial: false)),
            failure: nil, inspectedAt: now, gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
            commonArguments: GitEnvironment.commonArguments, diffArguments: ["diff", "--no-ext-diff", "--no-textconv"],
            hookExecutables: [], realPath: nil)
        let model = WorktreeDetailModel(
            entry: WorktreeListing.entry(
                "/tmp/dev/api-wt/57", branch: "fix/57",
                state: .loaded(WorktreeListing.state(branch: "fix/57"))),
            inspection: inspection, fetchStatus: .idle(lastFetched: now), now: now, home: "/tmp/dev")
        XCTAssertNotNil(model.copyablePath)
        let other = try XCTUnwrap(model.security?.others.first { $0.key == "core.alternaterefscommand" })
        XCTAssertEqual(other.threat, "T5")

        let found = try elements(WorktreeDetailView(model: model), size: CGSize(width: 344, height: 1_200))
        let path = try XCTUnwrap(found.first { $0.text.contains("Copy path") }, "the Path row")
        XCTAssertEqual(path.help, "Copy Path")
        let threat = try XCTUnwrap(found.first { $0.text.contains("core.alternaterefscommand") }, "the setting's row")
        XCTAssertEqual(threat.help, "Threat T5 in docs/design/security-review.md")
        assertNoRepeatedHint(found)
    }

    /// S-02's Submodules card: a row's tooltip text is its hint, once.
    func testSubmoduleRowsReadTheirHintsOnce() throws {
        let model = try XCTUnwrap(
            SubmoduleSectionModel(
                .loaded(
                    SubmoduleListing(
                        submodules: [
                            SubmoduleStatus(
                                path: GitPath("libs/untrusted"), isListed: true,
                                state: .notInspected(.blocked(reason: "filter driver name not allowed"))),
                            SubmoduleStatus(path: GitPath("vendor/http"), isListed: true, state: .clean),
                        ],
                        omitted: 0, isGitmodulesRefused: false))))
        guard case .rows(let rows) = model.content else { return XCTFail("\(model.content)") }
        let help = try XCTUnwrap(rows.first { $0.path == "libs/untrusted" }?.help)
        let found = try elements(SubmoduleSectionView(model: model), size: CGSize(width: 344, height: 240))
        let row = try XCTUnwrap(found.first { $0.text.contains("libs/untrusted") })
        XCTAssertEqual(row.help, help)
        assertNoRepeatedHint(found)
    }

    /// S-11's COMMITS AHEAD rows: the subject and author tooltip is the hint, once.
    func testComparisonCommitRowsReadTheirHintsOnce() throws {
        var session = ComparisonSession(
            worktree: GitPath("/tmp/dev/api-wt/42"), base: FullRefName("refs/heads/main"),
            bases: [FullRefName("refs/heads/main")!])
        session.result = .loaded(
            ComparisonModelTests.comparison(
                files: [ComparisonModelTests.stat("internal/http/middleware.go", .modified, 30, 4)],
                commits: [ComparisonModelTests.commit("b", "feat(ratelimit): add sliding window limiter")]))
        let model = ComparisonModel(session: session, workingState: nil)
        let found = try elements(
            ComparisonListView(title: "feat/42", session: session, model: model, onSelect: { _ in }, onShowAll: {}),
            size: CGSize(width: 344, height: 520))
        let row = try XCTUnwrap(found.first { $0.text.contains("add sliding window limiter") })
        XCTAssertEqual(row.help, "feat(ratelimit): add sliding window limiter\nAlex Kim")
        assertNoRepeatedHint(found)
    }
}
