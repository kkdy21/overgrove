import Foundation
import XCTest

@testable import Overgrove

/// `StashDetailModel` and `StashRow` (#71): screens.md S-04 and the sidebar STASHES rows, without views.
final class StashDetailModelTests: XCTestCase {
    static let base = ObjectID("0f047e0dd48aa0c692d9b03dba6d7e7ea09ad232")!
    static let index = ObjectID(String(repeating: "b", count: 40))!
    static let untracked = ObjectID(String(repeating: "c", count: 40))!

    static func stash(
        _ index: Int = 0, subject: String = "WIP on main: 0f047e0 base2", branch: String? = "main",
        message: String = "0f047e0 base2", parents: [ObjectID] = [base, StashDetailModelTests.index]
    ) -> Stash {
        Stash(
            index: index, oid: ObjectID(String(repeating: "\(index % 10)", count: 40)) ?? base, subject: subject,
            branch: branch, message: message, date: Date(timeIntervalSince1970: 1_793_853_652), parents: parents)
    }

    static func file(_ path: String, _ added: Int?, _ deleted: Int?, untracked: Bool = false) -> FileStat {
        FileStat(
            path: GitPath(path), originalPath: nil, status: nil, added: added, deleted: deleted,
            isFromUntracked: untracked)
    }

    func testHeaderAndInfo() {
        let model = StashDetailModel(stash: Self.stash(), state: .loading)
        XCTAssertEqual(model.refName, "stash@{0}")
        XCTAssertEqual(model.subject, "WIP on main: 0f047e0 base2")
        XCTAssertEqual(
            model.baseCommit, "0f047e0  base2  (from message)", "the message names the real base, so its subject shows")
        XCTAssertEqual(model.oid, Self.stash().oid.hex)
        XCTAssertEqual(model.branch, "main")
        XCTAssertEqual(model.includes, "index · working tree")
        XCTAssertNil(model.files)
        XCTAssertNil(model.filesUnavailable)
    }

    /// A message that does not name the real first parent shows the SHA alone; the message is only text.
    func testBaseCommitIgnoresAMessageThatNamesAnotherCommit() {
        XCTAssertEqual(StashDetailModel.baseCommitText(Self.base, message: "deadbee forged subject"), "0f047e0")
        XCTAssertEqual(StashDetailModel.baseCommitText(Self.base, message: "exp: try"), "0f047e0")
        XCTAssertEqual(StashDetailModel.baseCommitText(Self.base, message: "0f04 short"), "0f047e0", "too short")
    }

    func testUntrackedStashAndFiles() {
        let stash = Self.stash(parents: [Self.base, Self.index, Self.untracked])
        let detail = StashDetail(
            stash: stash,
            files: [
                Self.file("Sources/Parsing/Status.swift", 42, 8), Self.file("logo.png", nil, nil),
                Self.file("Sources/Untracked.swift", 20, 0, untracked: true),
            ],
            isPartial: false)
        let model = StashDetailModel(stash: stash, state: .loaded(detail))
        XCTAssertEqual(model.includes, "index · working tree · untracked")
        XCTAssertEqual(model.files?.map(\.fileName), ["Status.swift", "logo.png", "Untracked.swift"])
        XCTAssertEqual(model.files?.map(\.lineChange), ["+42 −8", nil, "+20 −0"])
        XCTAssertEqual(model.files?.map(\.isFromUntracked), [false, false, true])
        XCTAssertTrue(model.hasUntrackedFiles)
    }

    func testUnavailableAndEscaping() {
        let stash = Self.stash(
            subject: "On fe\u{202E}at: x\u{2028}y", branch: "fe\u{202E}at", message: "x\u{2028}y")
        let model = StashDetailModel(stash: stash, state: .unavailable("git failed\u{2028}"))
        XCTAssertEqual(model.subject, "On fe\\u{202E}at: x\\u{2028}y")
        XCTAssertEqual(model.branch, "fe\\u{202E}at")
        XCTAssertEqual(model.filesUnavailable, "git failed\\u{2028}")
        XCTAssertEqual(StashRow(stash).message, "x\\u{2028}y")
        XCTAssertEqual(StashRow(stash).accessibilityLabel, "stash@{0}, x\\u{2028}y")
    }

    func testUnrepresentablePathIsNotSelectable() {
        let stash = Self.stash()
        let file = FileStat(
            path: GitPath(raw: Data([0x61, 0xFF])), originalPath: nil, status: nil, added: 1, deleted: 0,
            isFromUntracked: false)
        let model = StashDetailModel(
            stash: stash, state: .loaded(StashDetail(stash: stash, files: [file], isPartial: true)))
        XCTAssertEqual(model.files?.first?.isSelectable, false)
        XCTAssertTrue(model.isFileListPartial)
    }
}
