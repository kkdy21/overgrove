import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import Overgrove

/// SEC-T14-14: Quick Look (#399) is offered on macOS 15 and later only, and previews a regular working tree file
/// inside its worktree, up to `QuickLook.maximumSize`: not a link (even one inside), a hard link, a FIFO, a folder, a
/// path with `..` or through a folder leading outside, a file outside, or web content.
@MainActor
final class QuickLookTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
            .appendingPathComponent("overgrove-ql-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOnlyOnMacOS15AndLater() {
        XCTAssertFalse(
            QuickLook.isAvailable(on: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)))
        XCTAssertTrue(
            QuickLook.isAvailable(on: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        XCTAssertTrue(
            QuickLook.isAvailable(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)))
    }

    func testSECT14_14_OnlyRegularFilesInsideTheWorktree() throws {
        try Data("x\n".utf8).write(to: root.appendingPathComponent("a.md"))
        XCTAssertEqual(QuickLook.target(GitPath("a.md"), in: root), .success(root.appendingPathComponent("a.md")))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside-link"), withDestinationURL: root.appendingPathComponent("a.md"))
        XCTAssertEqual(
            QuickLook.target(GitPath("inside-link"), in: root), .failure(.notAFile), "links are not followed")

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).md")
        try Data("y\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        XCTAssertEqual(QuickLook.target(GitPath("out"), in: root), .failure(.notAFile))

        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertEqual(QuickLook.target(GitPath("pipe"), in: root), .failure(.notAFile), "FIFOs never pass")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        XCTAssertEqual(QuickLook.target(GitPath("dir"), in: root), .failure(.notAFile))
        XCTAssertEqual(
            QuickLook.target(GitPath("../\(outside.lastPathComponent)"), in: root), .failure(.outsideRepository))
        XCTAssertEqual(QuickLook.target(GitPath("missing.md"), in: root), .failure(.missing), "a deleted file row")

        // A folder on the way that leads outside.
        let outsideDir = root.deletingLastPathComponent().appendingPathComponent("outdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try Data("z\n".utf8).write(to: outsideDir.appendingPathComponent("f.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linkdir"), withDestinationURL: outsideDir)
        XCTAssertEqual(QuickLook.target(GitPath("linkdir/f.md"), in: root), .failure(.outsideRepository))

        // A hard link to a file elsewhere.
        try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("hard.md"))
        XCTAssertEqual(QuickLook.target(GitPath("hard.md"), in: root), .failure(.notAFile))

        // Web content may load remote resources in its preview.
        for name in ["page.html", "pic.SVG", "site.webloc", "page.xht", "mail.eml"] {
            try Data("<x/>\n".utf8).write(to: root.appendingPathComponent(name))
            XCTAssertEqual(QuickLook.target(GitPath(name), in: root), .failure(.webContent), name)
        }

        let big = root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(QuickLook.maximumSize + 1))
        try handle.close()
        XCTAssertEqual(QuickLook.target(GitPath("big.bin"), in: root), .failure(.tooLarge))
    }

    /// SEC-T14-468-1: every type whose system preview renders web content, or hands off a location, is refused: by
    /// its extension, and by its type's conformance (macOS 26 measurement, #468). `.xht` previews as `public.xhtml`,
    /// `.svg` as `public.html`; mail messages render their HTML part; internet shortcuts name a URL.
    func testSECT14_468_1_WebContentTypesAreRefused() {
        for name in [
            "a.html", "a.htm", "a.shtml", "a.shtm", "a.xhtml", "a.xht", "a.xhtm", "a.svg", "a.svgz", "a.webarchive",
            "a.mht", "a.mhtml", "a.webloc", "a.inetloc", "a.eml", "a.emlx", "a.url", "A.XHT", "b.EML",
        ] {
            XCTAssertTrue(QuickLook.isWebContent(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.md", "a.txt", "a.png", "a.pdf", "a.json", "a.swift", "a.rtf", "Makefile", "a.xml"] {
            XCTAssertFalse(QuickLook.isWebContent(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    /// SEC-T14-468-1: a type another app declares as conforming to HTML (or another refused type) is refused by
    /// conformance even when its extension is not listed.
    func testSECT14_468_1_ConformanceDecidesForUnlistedExtensions() {
        XCTAssertTrue(QuickLook.refusedTypes.contains { UTType("public.xhtml")!.conforms(to: $0) })
        XCTAssertTrue(QuickLook.isWebContent(type: UTType(filenameExtension: "xht")))
        XCTAssertFalse(QuickLook.isWebContent(type: UTType(filenameExtension: "png")))
        XCTAssertFalse(QuickLook.isWebContent(type: nil))
    }

    func testTheRowActionShowsOrRefuses() async throws {
        try Data("x\n".utf8).write(to: root.appendingPathComponent("a.md"))
        let suite = "overgrove-ql-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(WorktreeListing(entries: [], isPartial: false))),
            graphLoader: SampleGraphLoader(), commitLoader: StubCommitLoader())
        XCTAssertEqual(state.rowMenuActions.canQuickLook, QuickLook.isAvailable())

        state.quickLook(GitPath("a.md"), in: GitPath(root.path), available: false)
        XCTAssertNil(state.quickLookURL, "nothing on macOS 14")
        state.quickLook(GitPath("a.md"), in: GitPath(root.path), available: true)
        XCTAssertEqual(state.quickLookURL, root.appendingPathComponent("a.md"))
        state.quickLookURL = nil
        state.quickLook(GitPath("../x"), in: GitPath(root.path), available: true)
        XCTAssertNil(state.quickLookURL)
        XCTAssertEqual(state.alert?.title, "Can’t Preview")
    }
}
