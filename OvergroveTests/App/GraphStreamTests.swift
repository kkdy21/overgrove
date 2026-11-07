import Foundation
import XCTest

@testable import Overgrove

/// `GraphStream` (#254): pages are served as commits arrive, a complete stream ends the history, and a stream that
/// stops early sends later pages back to `--skip`.
final class GraphStreamTests: XCTestCase {
    /// The fixture's nine records, each as its own chunk.
    private static let records: [Data] = {
        let data = LogParserFixtures.sha1Graph
        var records: [Data] = []
        var start = data.startIndex
        var nuls = 0
        for index in data.indices where data[index] == 0 {
            nuls += 1
            if nuls % 7 == 0 {
                records.append(Data(data[start...index]))
                start = index + 1
            }
        }
        return records
    }()

    private static let all = try! LogParser.parseGraph(LogParserFixtures.sha1Graph).commits

    /// A stream fed by the test: `start` never reads anything itself.
    private func stream(maximum: Int = 100) -> (GraphStream, Gate) {
        let gate = Gate()
        let stream = GraphStream(maximum: maximum)
        stream.start { _ in await gate.wait() }
        return (stream, gate)
    }

    func testAPageArrivesAsSoonAsItsCommitsDo() async throws {
        let (stream, gate) = stream()
        let page = Task { await stream.page(skip: 0, limit: 3) }
        stream.receive(Self.records[0] + Self.records[1])
        try await Task.sleep(for: .milliseconds(30))
        stream.receive(Self.records[2])
        let result = await page.value
        XCTAssertEqual(result, .commits(Array(Self.all.prefix(3))))
        XCTAssertFalse(stream.hasEnded, "the page did not wait for the end")
        gate.open(finishedNormally: true)
    }

    func testACompleteStreamEndsTheHistoryWithAShortPage() async throws {
        let (stream, gate) = stream()
        for record in Self.records { stream.receive(record) }
        gate.open(finishedNormally: true)
        _ = await stream.page(skip: 0, limit: 1)
        try await waitUntil { stream.hasEnded }
        let result1 = await stream.page(skip: 6, limit: 5)
        XCTAssertEqual(result1, .commits(Array(Self.all[6...])))
        let result2 = await stream.page(skip: 9, limit: 5)
        XCTAssertEqual(result2, .commits([]), "past the end: an empty page")
    }

    func testAStreamThatStoppedEarlySendsLaterPagesToSkip() async throws {
        let (stream, gate) = stream()
        stream.receive(Self.records[0] + Self.records[1])
        gate.open(finishedNormally: false)  // timeout, output cap, failure
        try await waitUntil { stream.hasEnded }
        let result3 = await stream.page(skip: 0, limit: 2)
        XCTAssertEqual(result3, .commits(Array(Self.all.prefix(2))), "what arrived")
        let result4 = await stream.page(skip: 0, limit: 3)
        XCTAssertEqual(result4, .beyond, "not covered: read it with --skip")
    }

    func testTheCommitCeilingIsNotTheEndOfHistory() async throws {
        let (stream, gate) = stream(maximum: 4)
        for record in Self.records.prefix(4) { stream.receive(record) }
        gate.open(finishedNormally: true)
        try await waitUntil { stream.hasEnded }
        let result5 = await stream.page(skip: 0, limit: 4)
        XCTAssertEqual(result5, .commits(Array(Self.all.prefix(4))))
        let result6 = await stream.page(skip: 4, limit: 4)
        XCTAssertEqual(result6, .beyond, "there may be more history past the ceiling")
    }

    func testAnIncompleteLastRecordIsNotAWholeHistory() async throws {
        let (stream, gate) = stream()
        stream.receive(Self.records[0] + Self.records[1].prefix(10))
        gate.open(finishedNormally: true)
        try await waitUntil { stream.hasEnded }
        let result7 = await stream.page(skip: 0, limit: 5)
        XCTAssertEqual(result7, .beyond)
    }

    func testGarbageEndsTheStreamEarly() async throws {
        let (stream, gate) = stream()
        stream.receive(Self.records[0])
        stream.receive(Data("x\0\0\0\0\0\0\0".utf8))
        XCTAssertTrue(stream.hasEnded)
        let result8 = await stream.page(skip: 0, limit: 1)
        XCTAssertEqual(result8, .commits([Self.all[0]]))
        let result9 = await stream.page(skip: 0, limit: 2)
        XCTAssertEqual(result9, .beyond)
        gate.open(finishedNormally: true)
    }

    /// Security review of #254 (T15): garbage ends the stream and stops git at once, instead of leaving it running to
    /// its timeout or output cap.
    func testGarbageStopsTheReadingProcess() async throws {
        let gate = Gate()
        let stopped = Flag()
        let stream = GraphStream(maximum: 100)
        stream.start { _ in
            let finished = await gate.wait()
            if Task.isCancelled { stopped.set() }
            return finished
        }
        stream.receive(Data("x\0\0\0\0\0\0\0".utf8))
        try await waitUntil { stopped.isSet }
    }

    func testACancelledWaiterReturnsAtOnceAndTheStreamGoesOn() async throws {
        let (stream, gate) = stream()
        let page = Task { await stream.page(skip: 0, limit: 5) }
        try await Task.sleep(for: .milliseconds(30))
        page.cancel()
        let result10 = await page.value
        XCTAssertEqual(result10, .cancelled)
        XCTAssertFalse(stream.hasEnded, "another page may still want the stream")
        for record in Self.records { stream.receive(record) }
        let result11 = await stream.page(skip: 0, limit: 5)
        XCTAssertEqual(result11, .commits(Array(Self.all.prefix(5))))
        gate.open(finishedNormally: true)
    }

    func testCancellingTheStreamReleasesWaiters() async throws {
        let (stream, _) = stream()
        let page = Task { await stream.page(skip: 0, limit: 5) }
        try await Task.sleep(for: .milliseconds(30))
        stream.cancel()
        let result12 = await page.value
        XCTAssertEqual(result12, .beyond)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The test's stand-in for git finishing: `wait` returns when `open` is called (or the task is cancelled).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: Bool? = lock.withLock {
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            open(finishedNormally: false)
        }
    }

    func open(finishedNormally: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = finishedNormally
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: finishedNormally)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
