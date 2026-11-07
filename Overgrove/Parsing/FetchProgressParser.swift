import Foundation

/// Reads `git fetch --progress` stderr as it arrives (parsing-spec.md §11.4).
///
/// git rewrites a progress line with `\r` and ends it with `\n`, so both end a line. Lines are matched against
/// `[remote: ]<label>: <n>[, done.]` or `[remote: ]<label>: <p>% (<n>/<total>)[, <anything>]`. Anything else, including
/// a malformed number, is ignored: progress is cosmetic, and the `remote:` lines are written by the server.
///
/// Feed chunks in order with `consume(_:)`. The parser keeps only the unfinished last line, capped at
/// `maximumLineLength`.
struct FetchProgressParser: Sendable {
    /// Longer lines are dropped (a real progress line is under 120 bytes).
    static let maximumLineLength = 1024
    /// Counts above this are rejected rather than risking overflow.
    private static let maximumDigits = 15

    private static let labels: [(String, FetchProgress.Phase)] = [
        ("Enumerating objects: ", .enumerating), ("Counting objects: ", .counting),
        ("Compressing objects: ", .compressing), ("Receiving objects: ", .receiving),
        ("Resolving deltas: ", .resolving),
    ]

    private var pending = Data()
    /// Set while skipping the rest of a line that exceeded the cap.
    private var isDiscarding = false
    private var last: FetchProgress?

    /// Returns the updates completed by `chunk`, without repeats of the previous update.
    mutating func consume(_ chunk: Data) -> [FetchProgress] {
        var updates: [FetchProgress] = []
        for byte in chunk {
            guard byte != 0x0D && byte != 0x0A else {
                if !isDiscarding, let update = Self.parse(line: pending), update != last {
                    updates.append(update)
                    last = update
                }
                pending.removeAll(keepingCapacity: true)
                isDiscarding = false
                continue
            }
            guard !isDiscarding else { continue }
            if pending.count >= Self.maximumLineLength {
                pending.removeAll(keepingCapacity: true)
                isDiscarding = true
                continue
            }
            pending.append(byte)
        }
        return updates
    }

    /// Parses one line without its terminator.
    static func parse(line: Data) -> FetchProgress? {
        guard let text = String(data: line, encoding: .utf8) else { return nil }
        var rest = Substring(text)
        if rest.hasPrefix("remote: ") { rest = rest.dropFirst("remote: ".count) }
        // git pads `remote:` lines with spaces so a shorter line fully overwrites a longer one.
        while rest.last == " " { rest = rest.dropLast() }
        guard let (label, phase) = labels.first(where: { rest.hasPrefix($0.0) }) else { return nil }
        rest = rest.dropFirst(label.count)
        return phase == .enumerating ? parseCount(rest, phase: phase) : parsePercent(rest, phase: phase)
    }

    /// `304, done.` or `304`.
    private static func parseCount(_ text: Substring, phase: FetchProgress.Phase) -> FetchProgress? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        let suffix = text.dropFirst(digits.count)
        guard let count = number(digits), suffix.isEmpty || suffix == ", done." else { return nil }
        return FetchProgress(phase: phase, completed: count, total: nil, isDone: !suffix.isEmpty)
    }

    /// `  50% (152/304)`, optionally followed by `, <throughput>`, `, done.`, or `, completed with … objects.`.
    private static func parsePercent(_ text: Substring, phase: FetchProgress.Phase) -> FetchProgress? {
        var rest = text.drop { $0 == " " }
        let percentDigits = rest.prefix { $0.isASCII && $0.isNumber }
        rest = rest.dropFirst(percentDigits.count)
        guard let percent = number(percentDigits), percent <= 100, rest.hasPrefix("% (") else { return nil }
        rest = rest.dropFirst("% (".count)
        let completedDigits = rest.prefix { $0.isASCII && $0.isNumber }
        rest = rest.dropFirst(completedDigits.count)
        guard let completed = number(completedDigits), rest.hasPrefix("/") else { return nil }
        rest = rest.dropFirst()
        let totalDigits = rest.prefix { $0.isASCII && $0.isNumber }
        rest = rest.dropFirst(totalDigits.count)
        guard let total = number(totalDigits), completed <= total, rest.hasPrefix(")") else { return nil }
        rest = rest.dropFirst()
        guard rest.isEmpty || rest.hasPrefix(", ") else { return nil }
        let isDone = rest.hasSuffix(", done.") || rest.hasPrefix(", completed with ")
        return FetchProgress(phase: phase, completed: completed, total: total, isDone: isDone)
    }

    private static func number(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.count <= maximumDigits else { return nil }
        return Int(digits)
    }
}
