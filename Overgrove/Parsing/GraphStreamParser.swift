import Foundation

/// The streamed graph's parser (#254, parsing-spec.md §5.1, PAR-LOG-13): `log --all --date-order -z <graph format>`
/// fed as it arrives, in chunks cut anywhere. A record is seven NUL-terminated fields, so the bytes up to every
/// seventh NUL are complete records; those go through `LogParser.parseGraph`, and the rest waits for the next chunk.
///
/// Memory: only the incomplete tail is kept (at most one record, bounded by the stream's stdout limit); parsed commits
/// are returned, not stored.
struct GraphStreamParser {
    private static let name = "LogParser"
    private static let fieldsPerRecord = LogParser.graphFieldCount

    private var pending = Data()
    /// Bytes of `pending` already scanned for NULs, and the NULs among them since the last complete record.
    private var scanned = 0
    private var nulsInRecord = 0
    /// Bytes consumed before `pending`, so errors name an offset in the whole stream.
    private var consumed = 0

    /// The commits completed by `chunk`, in stream order.
    mutating func feed(_ chunk: Data) throws -> [CommitNode] {
        pending.append(chunk)
        var lastRecordEnd: Int?
        var index = pending.startIndex + scanned
        while index < pending.endIndex {
            if pending[index] == 0 {
                nulsInRecord += 1
                if nulsInRecord == Self.fieldsPerRecord {
                    nulsInRecord = 0
                    lastRecordEnd = index + 1
                }
            }
            index += 1
        }
        scanned = pending.count
        guard let lastRecordEnd else { return [] }
        let records = pending[pending.startIndex..<lastRecordEnd]
        let commits: [CommitNode]
        do {
            commits = try LogParser.parseGraph(Data(records)).commits
        } catch let error as ParseError {
            throw ParseError(parser: error.parser, offset: consumed + error.offset, reason: error.reason)
        }
        let used = lastRecordEnd - pending.startIndex
        consumed += used
        pending = Data(pending[lastRecordEnd...])
        scanned = pending.count
        return commits
    }

    /// The stream ended. A complete stream must end on a record boundary; a truncated one (the stdout limit stopped
    /// it) drops its cut-off last record, like `parseGraph(truncated: true)`.
    func finish(truncated: Bool) throws {
        guard !pending.isEmpty, !truncated else { return }
        throw ParseError(parser: Self.name, offset: consumed + pending.count, reason: "incomplete record")
    }
}
