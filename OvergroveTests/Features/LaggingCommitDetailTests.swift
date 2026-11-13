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

    private func model(_ hexDigit: Character, loaded: Bool) -> CommitDetailModel {
        let detail: CommitDetailStore.Detail =
            loaded
            ? .loaded(
                CommitDetailModelTests.detail(
                    message: "commit \(hexDigit)\n", files: [CommitDetailModelTests.stat("a.swift", .modified, 1, 0)]))
            : .loading
        return CommitDetailModel(commit: commit(hexDigit), detail: detail, pills: [], showsAllFiles: false)
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
        LaggingCommitDetail(model: model) { shown in Probe(sha: shown.fullSHA, sink: sink) }
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

    func testDelayedSpinnerRenders() throws {
        let host = NSHostingView(rootView: DelayedProgressView().frame(width: 40, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(loadingIndicatorDelay, .milliseconds(150))
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    }
}
