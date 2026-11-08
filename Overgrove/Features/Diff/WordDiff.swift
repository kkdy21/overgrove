import Foundation

/// Word-level changes between a removed line and the added line paired with it (screens.md S-10, #387).
///
/// Computed in the app from the patch, not with `git diff --word-diff`, whose output would need another parser. The
/// text comes from the repository, so every step is bounded (T15): long lines and large comparisons are left to the
/// line background.
enum WordDiff {
    /// A line longer than this (in Unicode scalars) is not compared.
    static let maximumLineScalars = 1_000
    /// A run of removed or added lines longer than this is not compared.
    static let maximumRunLines = 200
    /// Paired lines compared per file; the rest are left to the line background. 2,000 keeps a 10,000-line diff within
    /// PB-9 (200 ms for parsing and rows, measured with one word changed per line, PERF-09).
    static let maximumPairedLinesPerFile = 2_000
    /// LCS table cells for one pair, and for one file.
    static let maximumCellsPerPair = 250_000
    static let maximumCellsPerFile = 5_000_000

    /// The changed scalar ranges of `old` and `new`, merged where adjacent. `nil` when the pair is not marked: a line
    /// too long, a table over `maximumCellsPerPair` or over what is left of `budget` (then nothing is spent), or no
    /// token in common (the whole line changed; the line background says enough).
    static func changes(old: String, new: String, budget: inout Int) -> (old: [Range<Int>], new: [Range<Int>])? {
        // Compared as bytes: `String` equality folds canonically equivalent text, which the view shows differently.
        guard !old.utf8.elementsEqual(new.utf8) else { return nil }
        let oldValues = old.unicodeScalars.map(\.value)
        let newValues = new.unicodeScalars.map(\.value)
        guard oldValues.count <= maximumLineScalars, newValues.count <= maximumLineScalars else { return nil }
        // Pointers taken once for the whole comparison: token comparisons are the inner loop (PERF-09).
        return oldValues.withUnsafeBufferPointer { oldBuffer in
            newValues.withUnsafeBufferPointer { newBuffer in
                compare(oldBuffer, newBuffer, budget: &budget)
            }
        }
    }

    private static func compare(
        _ old: UnsafeBufferPointer<UInt32>, _ new: UnsafeBufferPointer<UInt32>, budget: inout Int
    ) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard let oldBase = old.baseAddress, let newBase = new.baseAddress else { return nil }
        let allOld = tokens(old)
        let allNew = tokens(new)
        func sameToken(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            a.count == b.count
                && (a.isEmpty
                    || memcmp(oldBase + a.lowerBound, newBase + b.lowerBound, a.count * 4) == 0)
        }
        // Tokens the two lines share at the start and the end need no table (most edits touch a few words).
        var prefix = 0
        while prefix < allOld.count, prefix < allNew.count, sameToken(allOld[prefix], allNew[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < allOld.count - prefix, suffix < allNew.count - prefix,
            sameToken(allOld[allOld.count - 1 - suffix], allNew[allNew.count - 1 - suffix])
        {
            suffix += 1
        }
        let oldTokens = Array(allOld[prefix..<(allOld.count - suffix)])
        let newTokens = Array(allNew[prefix..<(allNew.count - suffix)])
        let cells = (oldTokens.count + 1) * (newTokens.count + 1)
        guard cells <= maximumCellsPerPair, cells <= budget else { return nil }
        budget -= cells

        func same(_ i: Int, _ j: Int) -> Bool { sameToken(oldTokens[i], newTokens[j]) }
        // lcs[i][j]: the longest common subsequence of old[i...] and new[j...].
        let width = newTokens.count + 1
        var lcs = [Int32](repeating: 0, count: cells)
        for i in stride(from: oldTokens.count - 1, through: 0, by: -1) {
            for j in stride(from: newTokens.count - 1, through: 0, by: -1) {
                lcs[i * width + j] =
                    same(i, j)
                    ? lcs[(i + 1) * width + j + 1] + 1 : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        guard lcs[0] > 0 || prefix + suffix > 0 else { return nil }

        // Walk from the start, taking a match as early as possible.
        var oldChanged: [Range<Int>] = []
        var newChanged: [Range<Int>] = []
        var i = 0
        var j = 0
        while i < oldTokens.count || j < newTokens.count {
            if i < oldTokens.count, j < newTokens.count, same(i, j),
                lcs[i * width + j] == lcs[(i + 1) * width + j + 1] + 1
            {
                i += 1
                j += 1
            } else if j == newTokens.count
                || (i < oldTokens.count && lcs[(i + 1) * width + j] >= lcs[i * width + j + 1])
            {
                append(oldTokens[i], to: &oldChanged)
                i += 1
            } else {
                append(newTokens[j], to: &newChanged)
                j += 1
            }
        }
        return (oldChanged, newChanged)
    }

    private static func append(_ range: Range<Int>, to ranges: inout [Range<Int>]) {
        if let last = ranges.last, last.upperBound == range.lowerBound {
            ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
        } else {
            ranges.append(range)
        }
    }

    /// Runs of word scalars (letters, digits, `_`, combining marks), runs of whitespace, and any other scalar alone.
    static func tokens(_ values: UnsafeBufferPointer<UInt32>) -> [Range<Int>] {
        enum Class { case word, space, other }
        func classify(_ value: UInt32) -> Class {
            if value < 0x80 {
                if value == 0x5F || (0x30...0x39).contains(value) || (0x41...0x5A).contains(value)
                    || (0x61...0x7A).contains(value)
                {
                    return .word
                }
                return value == 0x20 || value == 0x09 ? .space : .other
            }
            guard let scalar = Unicode.Scalar(value) else { return .other }
            let properties = scalar.properties
            if properties.isAlphabetic || properties.numericType != nil || properties.generalCategory == .nonspacingMark
                || properties.generalCategory == .spacingMark
            {
                return .word
            }
            return properties.isWhitespace ? .space : .other
        }
        var tokens: [Range<Int>] = []
        var start = 0
        while start < values.count {
            let kind = classify(values[start])
            var end = start + 1
            if kind != .other {
                while end < values.count, classify(values[end]) == kind { end += 1 }
            }
            tokens.append(start..<end)
            start = end
        }
        return tokens
    }
}
