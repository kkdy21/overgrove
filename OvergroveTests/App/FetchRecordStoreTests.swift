import Foundation
import XCTest

@testable import Overgrove

/// `FetchRecordStore` (#77, overview.md §8): the last attempt and last success per repository, and the `FETCH_HEAD`
/// estimate when there is no record.
final class FetchRecordStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-fetchhead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func repository(_ name: String = "api") -> Repository {
        let root = directory.appendingPathComponent(name, isDirectory: true)
        return Repository(rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_767_225_600 + seconds) }

    func testSavesTheLastAttemptAndKeepsTheLastSuccess() {
        let store = FetchRecordStore(defaults: defaults)
        XCTAssertNil(store.entry(for: "repo"))

        store.save(FetchRecord(repositoryID: "repo", finishedAt: date(0), succeeded: true, summary: nil))
        XCTAssertEqual(store.entry(for: "repo")?.lastSucceededAt, date(0))

        store.save(
            FetchRecord(
                repositoryID: "repo", finishedAt: date(60), succeeded: false,
                summary: "Authentication failed for origin"
            ))
        let entry = store.entry(for: "repo")
        XCTAssertEqual(entry?.last.finishedAt, date(60))
        XCTAssertEqual(entry?.last.succeeded, false)
        XCTAssertEqual(entry?.last.summary, "Authentication failed for origin")
        XCTAssertEqual(entry?.lastSucceededAt, date(0), "a failure keeps the last success")

        // Kept across instances (UserDefaults), per repository.
        let reopened = FetchRecordStore(defaults: defaults)
        XCTAssertEqual(reopened.entry(for: "repo"), entry)
        XCTAssertNil(reopened.entry(for: "other"))
    }

    func testRemoveForgetsOneRepository() {
        let store = FetchRecordStore(defaults: defaults)
        store.save(FetchRecord(repositoryID: "a", finishedAt: date(0), succeeded: true, summary: nil))
        store.save(FetchRecord(repositoryID: "b", finishedAt: date(0), succeeded: true, summary: nil))
        store.remove("a")
        XCTAssertNil(store.entry(for: "a"))
        XCTAssertNotNil(store.entry(for: "b"))
    }

    func testLongSummaryIsCutAndUnreadableDataIsIgnored() {
        let store = FetchRecordStore(defaults: defaults)
        store.save(
            FetchRecord(
                repositoryID: "a", finishedAt: date(0), succeeded: false, summary: String(repeating: "x", count: 1_000))
        )
        XCTAssertEqual(store.entry(for: "a")?.last.summary?.count, FetchRecordStore.maximumSummaryLength)

        defaults.set(Data("not json".utf8), forKey: FetchRecordStore.key)
        XCTAssertNil(store.entry(for: "a"), "an unreadable store reads as no records")
    }

    // MARK: Status on open

    func testStatusFromTheRecord() {
        let store = FetchRecordStore(defaults: defaults)
        let repository = repository()
        store.save(FetchRecord(repositoryID: repository.id, finishedAt: date(0), succeeded: true, summary: nil))
        XCTAssertEqual(store.status(for: repository), .idle(lastFetched: date(0)))
        store.save(FetchRecord(repositoryID: repository.id, finishedAt: date(60), succeeded: false, summary: nil))
        XCTAssertEqual(store.status(for: repository), .failed(lastFetched: date(0)))
    }

    /// Without a record, `FETCH_HEAD`'s modification time is shown as an estimate.
    func testFetchHeadModificationTimeIsAnEstimate() throws {
        let store = FetchRecordStore(defaults: defaults)
        let repository = repository()
        XCTAssertEqual(store.status(for: repository), .never)

        try FileManager.default.createDirectory(at: repository.commonGitDirectoryURL, withIntermediateDirectories: true)
        let fetchHead = repository.commonGitDirectoryURL.appendingPathComponent("FETCH_HEAD")
        try Data("abc\t\tbranch 'main' of origin\n".utf8).write(to: fetchHead)
        try FileManager.default.setAttributes([.modificationDate: date(-3_600)], ofItemAtPath: fetchHead.path)
        XCTAssertEqual(store.status(for: repository), .estimated(lastFetched: date(-3_600)))

        // A record wins over the estimate.
        store.save(FetchRecord(repositoryID: repository.id, finishedAt: date(0), succeeded: true, summary: nil))
        XCTAssertEqual(store.status(for: repository), .idle(lastFetched: date(0)))
    }

    /// A symbolic link is not followed: its target could be any file the repository points at.
    func testSymbolicLinkFetchHeadIsIgnored() throws {
        let repository = repository()
        try FileManager.default.createDirectory(at: repository.commonGitDirectoryURL, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: repository.commonGitDirectoryURL.appendingPathComponent("FETCH_HEAD"), withDestinationURL: target)
        XCTAssertNil(FetchRecordStore.estimatedLastFetch(commonDirectory: repository.commonGitDirectoryURL))

        let other = self.repository("dir")
        let directoryEntry = other.commonGitDirectoryURL.appendingPathComponent("FETCH_HEAD")
        try FileManager.default.createDirectory(at: directoryEntry, withIntermediateDirectories: true)
        XCTAssertNil(
            FetchRecordStore.estimatedLastFetch(commonDirectory: other.commonGitDirectoryURL),
            "only a regular file counts")
    }
}
