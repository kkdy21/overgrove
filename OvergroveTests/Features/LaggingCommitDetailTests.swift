import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Stepping through commits keeps the last loaded one for up to 150 ms instead of flashing a loading state (#637).
@MainActor
final class LaggingCommitDetailTests: XCTestCase {
    private func commit(_ hexDigit: Character) -> CommitNode {
        CommitNode(
            oid: ObjectID(String(repeating: hexDigit, count: 40))!, parents: [], authorName: "Alex Kim",
            authorEmail: "alex@example.com", authorDate: Date(timeIntervalSince1970: 1_794_000_000),
            subject: "commit \(hexDigit)")
    }

    private func model(_ hexDigit: Character, loaded: Bool, pills: [GraphRefPill] = []) -> CommitDetailModel {
        let detail: CommitDetailStore.Detail =
            loaded
            ? .loaded(
                CommitDetailModelTests.detail(
                    message: "commit \(hexDigit)\n", files: [CommitDetailModelTests.stat("a.swift", .modified, 1, 0)]))
            : .loading
        return CommitDetailModel(commit: commit(hexDigit), detail: detail, pills: pills, showsAllFiles: false)
    }

    func testKeepsOnlyALoadedCommitWhileAnotherLoads() {
        let keeps = LaggingCommitDetail<EmptyView>.keepsShowing
        XCTAssertTrue(keeps(model("a", loaded: true), model("b", loaded: false)))
        XCTAssertFalse(keeps(model("a", loaded: true), model("b", loaded: true)), "a loaded commit shows at once")
        XCTAssertFalse(keeps(model("a", loaded: false), model("b", loaded: false)), "a loading state just follows")
        XCTAssertFalse(keeps(model("a", loaded: true), model("a", loaded: false)), "the same commit reloading")
    }

    private final class Sink { var shown: [String] = [] }

    private struct Probe: View {
        let sha: String
        let sink: Sink
        var body: some View {
            sink.shown.append(sha)
            return Text(sha)
        }
    }

    private func host(_ model: CommitDetailModel, _ sink: Sink) -> some View {
        LaggingCommitDetail(selected: ShownCommit(model: model, lane: 0)) { shown, _ in
            Probe(sha: shown?.model.fullSHA ?? "", sink: sink)
        }
    }

    private func pump(_ milliseconds: Int) {
        RunLoop.main.run(until: Date().addingTimeInterval(Double(milliseconds) / 1000))
    }

    /// B loads within the delay: the panel goes from A straight to loaded B, never to B loading.
    func testAFastLoadReplacesTheOldCommitDirectly() {
        let sink = Sink()
        let view = NSHostingView(rootView: AnyView(host(model("a", loaded: true), sink)))
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        view.layoutSubtreeIfNeeded()
        let a = model("a", loaded: true).fullSHA
        let b = model("b", loaded: true).fullSHA
        view.rootView = AnyView(host(model("b", loaded: false), sink))
        view.layoutSubtreeIfNeeded()
        pump(50)
        XCTAssertEqual(sink.shown.last, a, "A stays while B loads")
        view.rootView = AnyView(host(model("b", loaded: true), sink))
        view.layoutSubtreeIfNeeded()
        pump(20)
        XCTAssertEqual(sink.shown.last, b)
        pump(200)
        XCTAssertEqual(sink.shown.last, b, "the delay that was running does not bring anything back")
    }

    /// B is still loading after the delay: its loading state shows then.
    func testASlowLoadShowsTheNewCommitAfterTheDelay() {
        let sink = Sink()
        let view = NSHostingView(rootView: AnyView(host(model("a", loaded: true), sink)))
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        view.layoutSubtreeIfNeeded()
        view.rootView = AnyView(host(model("b", loaded: false), sink))
        view.layoutSubtreeIfNeeded()
        pump(400)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(sink.shown.last, model("b", loaded: false).fullSHA)
    }

    // MARK: - The whole panel (#649)

    private let pill = GraphRefPill(
        kind: .focusedBranch, title: "feature", hasMatchingRemote: false, tooltip: "refs/heads/feature")

    private func panel(_ model: CommitDetailModel, lane: Int) -> AnyView {
        AnyView(DetailPanel(focusedWorktree: nil, commitModel: model, commitLane: lane).frame(width: 360, height: 420))
    }

    private func snapshot(_ view: NSHostingView<AnyView>) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.tiffRepresentation
    }

    private func hostPanel(_ model: CommitDetailModel, lane: Int) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: panel(model, lane: lane))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 420)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// While A is kept, the header (`Commit <SHA>`, avatar), the rows and the Refs pill in A's lane color all stay on
    /// A: the panel draws exactly what it drew for A. B's lane differs, so a pill or header following the selection
    /// would change the pixels.
    func testTheHeaderAndTheRefsColorStayOnTheKeptCommit() throws {
        let a = model("a", loaded: true, pills: [pill])
        let bLoading = model("b", loaded: false)
        let view = hostPanel(a, lane: 1)
        pump(20)
        let showingA = try XCTUnwrap(snapshot(view))

        view.rootView = panel(bLoading, lane: 4)
        view.layoutSubtreeIfNeeded()
        pump(50)
        XCTAssertEqual(snapshot(view), showingA, "the header and the body both still show A in A's lane")

        pump(400)
        XCTAssertNotEqual(snapshot(view), showingA, "after the delay the panel shows B")
    }

    /// The header title follows the shown commit too, checked directly rather than through pixels.
    func testTheHeaderTitleFollowsTheShownCommit() {
        let a = model("a", loaded: true)
        let b = model("b", loaded: false)
        let sink = Sink()
        func host(_ model: CommitDetailModel, lane: Int) -> AnyView {
            AnyView(
                LaggingCommitDetail(selected: ShownCommit(model: model, lane: lane)) { shown, isSelected in
                    let header = DetailHeader(
                        DetailHeader.Subject(commit: shown.map { ($0.model.shortSHA, $0.model.author, $0.lane) }))
                    Probe(sha: "\(header.title) \(shown?.lane ?? -1) \(isSelected)", sink: sink)
                })
        }
        let view = NSHostingView(rootView: host(a, lane: 1))
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        view.layoutSubtreeIfNeeded()
        view.rootView = host(b, lane: 4)
        view.layoutSubtreeIfNeeded()
        pump(50)
        XCTAssertEqual(sink.shown.last, "Commit \(a.shortSHA) 1 false", "A's title and lane, not selected")
        pump(400)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(sink.shown.last, "Commit \(b.shortSHA) 4 true")
    }

    func testDelayedSpinnerRenders() throws {
        let host = NSHostingView(rootView: DelayedProgressView().frame(width: 40, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(loadingIndicatorDelay, .milliseconds(150))
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    }
}
