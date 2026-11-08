import Foundation

/// One streamed history of a repository at one ref set (#254, ADR-0010 §3): a single `graphStream` process whose
/// commits pages are served from as they arrive. Without a commit-graph file each `--skip` page re-sorted the whole
/// history (~400 ms on the bench repository); the stream sorts once.
///
/// Concurrency: all state is guarded by `lock`. `receive` and `finish` are called from the process's queue (stdout
/// observer) and the reading task; `page` is awaited by `RepositoryService`.
final class GraphStream: @unchecked Sendable {
    /// What a page request gets.
    enum PageResult: Equatable {
        /// Commits `skip ..< skip + limit`; fewer only when the history ended there.
        case commits([CommitNode])
        /// The stream stopped early (its commit ceiling, the output cap, a timeout, or a failure) before this page:
        /// read it with `--skip` instead.
        case beyond
        /// The caller was cancelled while waiting.
        case cancelled
    }

    /// How the stream ended.
    enum End: Equatable {
        /// git finished below the commit ceiling: the history is complete.
        case complete
        /// Stopped early: later pages come from `--skip`.
        case early
    }

    /// The most commits one stream reads (`ReadOnlyGitCommand.maximumLimit`).
    let maximum: Int

    private let lock = NSLock()
    private var commits: [CommitNode] = []
    private var parser = GraphStreamParser()
    private var end: End?
    private var waiters: [UUID: (needed: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var refSetVerified = false

    init(maximum: Int = ReadOnlyGitCommand.maximumLimit) {
        self.maximum = maximum
    }

    /// Starts reading with `read`, which streams stdout into `receive` and returns whether git finished normally
    /// and complete (`true`) or stopped early (`false`, also for errors and cancellation).
    func start(_ read: @escaping @Sendable (GraphStream) async -> Bool) {
        let task = Task { [self] in
            let finishedNormally = await read(self)
            finish(normally: finishedNormally)
        }
        lock.withLock { self.task = task }
    }

    /// Stops the process; waiting pages get `.beyond` (and read with `--skip` if they are still wanted).
    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
        finish(normally: false)
    }

    /// `cancel()` was called: the stream stopped early on request, not because the history or git ended it.
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// `RepositoryService` checked that git read the ref set this stream is kept for (#373). Checked once, after the
    /// first page arrived: by then git has resolved its refs.
    var isRefSetVerified: Bool { lock.withLock { refSetVerified } }

    func markRefSetVerified() { lock.withLock { refSetVerified = true } }

    /// A stdout chunk, in order. A parse error ends the stream early.
    func receive(_ chunk: Data) {
        let (ready, stop): ([CheckedContinuation<Void, Never>], Task<Void, Never>?) = lock.withLock {
            guard end == nil else { return ([], nil) }
            do {
                commits += try parser.feed(chunk)
            } catch {
                // Garbage: stop git too, rather than let it run to its timeout or output cap for nothing (security
                // review of #254, T15).
                end = .early
                return (takeAllWaiters(), task)
            }
            return (takeSatisfiedWaiters(), nil)
        }
        stop?.cancel()
        for continuation in ready { continuation.resume() }
    }

    /// The commits `skip ..< skip + limit`, waiting until they have arrived or the stream has ended.
    func page(skip: Int, limit: Int) async -> PageResult {
        let skip = max(0, skip)
        let needed = skip + max(1, limit)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let isReady = lock.withLock {
                    if commits.count >= needed || end != nil || Task.isCancelled { return true }
                    waiters[id] = (needed, continuation)
                    return false
                }
                if isReady { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume()
        }
        return lock.withLock {
            if commits.count >= needed { return .commits(Array(commits[skip..<needed])) }
            if Task.isCancelled && end == nil { return .cancelled }
            guard end == .complete else { return .beyond }
            return .commits(skip < commits.count ? Array(commits[skip...]) : [])
        }
    }

    /// Commits received so far (tests and measurements).
    var receivedCount: Int { lock.withLock { commits.count } }

    var hasEnded: Bool { lock.withLock { end != nil } }

    private func finish(normally: Bool) {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard end == nil else { return [] }
            // A normal finish must also end on a record boundary.
            let isWhole = normally && (try? parser.finish(truncated: false)) != nil
            // Below the ceiling, a whole stream is the whole history; at the ceiling there may be more.
            end = isWhole && commits.count < maximum ? .complete : .early
            return takeAllWaiters()
        }
        for continuation in ready { continuation.resume() }
    }

    /// Under `lock`.
    private func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
        let ready = waiters.filter { $0.value.needed <= commits.count }
        for id in ready.keys { waiters.removeValue(forKey: id) }
        return ready.values.map(\.continuation)
    }

    /// Under `lock`.
    private func takeAllWaiters() -> [CheckedContinuation<Void, Never>] {
        defer { waiters.removeAll() }
        return waiters.values.map(\.continuation)
    }
}
