import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Stashes in the commit graph (#384, ADR-0010 §5 as amended): virtual rows above their base commits.
@MainActor
final class GraphStashTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stash(_ index: Int, base: Character?, message: String) -> Stash {
        Stash(
            index: index, oid: ObjectID(String(format: "%040x", 0x5000 + index))!,
            subject: "On main: \(message)", branch: "main", message: message,
            date: now.addingTimeInterval(-Double(index + 1) * 3_600),
            parents: base.map { [SampleGraphLoader.oid($0), ObjectID(String(repeating: "e", count: 40))!] } ?? [])
    }

    private lazy var stashes = [
        stash(1, base: "2", message: "try a smaller window"),
        stash(0, base: "2", message: "half-done refill test"),
        stash(2, base: "4", message: "notes on the merge"),
        stash(3, base: "9", message: "on a commit outside the graph"),
        stash(4, base: nil, message: "no parents"),
    ]

    private func loadedStore() async throws -> GraphStore {
        let store = GraphStore(loader: SampleGraphLoader())
        store.load(
            Repository(
                rootURL: URL(fileURLWithPath: "/tmp/dev/api"),
                commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"), isBare: false),
            focus: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.status, .loaded)
        return store
    }

    /// Grouped by the base commit's row, newest (`stash@{0}`) first; a base not loaded, or none, is not placed.
    func testPlacement() async throws {
        let store = try await loadedStore()
        let rows = GraphStashPlacement.byBaseRow(stashes, index: { store.index(of: $0) })
        let two = try XCTUnwrap(store.index(of: SampleGraphLoader.oid("2")))
        let four = try XCTUnwrap(store.index(of: SampleGraphLoader.oid("4")))
        XCTAssertEqual(rows[two]?.map(\.index), [0, 1])
        XCTAssertEqual(rows[four]?.map(\.index), [2])
        XCTAssertEqual(rows.count, 2, "the stash outside the graph and the one without parents stay in the sidebar")
    }

    func testText() {
        var hostile = stash(0, base: "2", message: "evil\u{1B}[31m")
        let text = GraphStashText(hostile, now: now)
        XCTAssertEqual(text.refName, "stash@{0}")
        XCTAssertFalse(text.message.contains("\u{1B}"), "control characters are made visible")
        XCTAssertEqual(text.date, "1h")
        XCTAssertTrue(text.accessibilityLabel.hasPrefix("Stash stash@{0}: "), text.accessibilityLabel)
        XCTAssertTrue(text.accessibilityLabel.contains("made on 2222222"), text.accessibilityLabel)
        hostile = stash(4, base: nil, message: "x")
        XCTAssertFalse(GraphStashText(hostile, now: now).accessibilityLabel.contains("made on"))
    }

    func testShowStashesIsOnByDefaultAndStored() throws {
        let suite = "overgrove-stash-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showsGraphStashes)
        settings.showsGraphStashes = false
        XCTAssertFalse(AppSettings(defaults: defaults).showsGraphStashes)
    }

    /// Two stashes on a commit with a line passing beside it, one on the merge, one selected: at 100 % and 150 %.
    func testStashRowsRender() async throws {
        let store = try await loadedStore()
        for zoom in [GraphZoom.actualSize, GraphZoom(step: GraphZoom.scales.count - 1)] {
            let view = GraphView(
                store: store, now: now, stashes: stashes, selectedStash: stashes[1].oid
            )
            .environment(\.graphZoom, zoom)
            for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let size = CGSize(width: 960, height: 420 * zoom.scale)
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    try png.write(
                        to: URL(fileURLWithPath: directory)
                            .appendingPathComponent("graph-stashes-\(zoom.percent)-\(mode).png"))
                }
            }
        }
    }
}
