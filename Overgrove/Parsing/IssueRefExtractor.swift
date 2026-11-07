import Foundation

/// Finds GitHub issue numbers in branch names, commit subjects and commit trailers (parsing-spec.md §11.3, G8).
///
/// The result is only a candidate: the UI links a number when it is in the fetched issue list and shows a grey `#n`
/// otherwise. Matching is done by hand on Unicode scalars instead of `Regex` so that the boundary rules that keep out
/// false positives (`C#10`, `#define`, `&#123;`, `issue#12`) are explicit, and so that only ASCII digits count
/// (`\d` would also accept full-width and other Unicode digits).
enum IssueRefExtractor {
    /// GitHub issue numbers are positive and, in practice, short. Longer runs are treated as something else (a hash,
    /// a phone number) rather than cut to their first seven digits.
    static let maxDigits = 7

    private static let branchTypes: Set<Substring> = [
        "feat", "fix", "docs", "test", "chore", "spike", "refactor", "perf", "ci",
    ]
    private static let closingKeywords = ["Closes", "Fixes", "Resolves"]

    // MARK: - Branch names

    /// `feat/12-x` → 12. Accepts a short name or `refs/heads/…`.
    ///
    /// `^(?:feat|fix|…)/(\d{1,7})-` wins; otherwise the first path segment that starts with `(\d{1,7})-`.
    static func issueNumber(inBranch name: String) -> Int? {
        let shortName = name.hasPrefix("refs/heads/") ? name.dropFirst("refs/heads/".count) : Substring(name)
        let segments = shortName.split(separator: "/", omittingEmptySubsequences: false)
        if segments.count >= 2, branchTypes.contains(segments[0]), let number = leadingNumber(segments[1]) {
            return number
        }
        return segments.lazy.compactMap(leadingNumber).first
    }

    /// `12-rest` → 12: one to seven ASCII digits, then `-`.
    private static func leadingNumber(_ segment: Substring) -> Int? {
        let scalars = Array(segment.unicodeScalars)
        let count = digitRun(in: scalars, from: 0)
        guard count > 0, count < scalars.count, scalars[count] == "-" else { return nil }
        return issueNumber(scalars[0..<count])
    }

    // MARK: - Commit subjects

    /// `#n` references in a subject, unique and in order of appearance.
    ///
    /// `#` must not follow a word character, `&`, `/` or another `#`, and the digits must not run into a word
    /// character. `owner/repo#n` counts only when it names `repository` (`owner/repo`, compared case-insensitively
    /// like GitHub does); with no repository it never counts.
    static func issueNumbers(inSubject subject: String, repository: String?) -> [Int] {
        let scalars = Array(subject.unicodeScalars)
        var numbers: [Int] = []
        for index in scalars.indices where scalars[index] == "#" {
            let count = digitRun(in: scalars, from: index + 1)
            guard count > 0 else { continue }
            let end = index + 1 + count
            guard end == scalars.count || !isWordCharacter(scalars[end]) else { continue }
            guard let number = issueNumber(scalars[(index + 1)..<end]) else { continue }
            if isPlainReferenceStart(scalars, hashIndex: index)
                || referencesRepository(scalars, hashIndex: index, repository: repository)
            {
                numbers.append(number)
            }
        }
        return unique(numbers)
    }

    private static func isPlainReferenceStart(_ scalars: [Unicode.Scalar], hashIndex: Int) -> Bool {
        guard hashIndex > 0 else { return true }
        let previous = scalars[hashIndex - 1]
        return !isWordCharacter(previous) && previous != "&" && previous != "/" && previous != "#"
    }

    /// Reads `owner/repo` backwards from the `#` and compares it with `repository`.
    private static func referencesRepository(
        _ scalars: [Unicode.Scalar],
        hashIndex: Int,
        repository: String?
    ) -> Bool {
        guard let repository else { return false }
        var start = hashIndex
        while start > 0, isRepoNameCharacter(scalars[start - 1]) { start -= 1 }
        let repoStart = start
        guard repoStart < hashIndex, repoStart > 0, scalars[repoStart - 1] == "/" else { return false }
        start = repoStart - 1
        while start > 0, isOwnerCharacter(scalars[start - 1]) { start -= 1 }
        let ownerStart = start
        guard ownerStart < repoStart - 1 else { return false }
        // The owner must start the reference: `x/owner/repo#1` is a path, `evil-owner/repo#1` a different owner.
        if ownerStart > 0 {
            let before = scalars[ownerStart - 1]
            guard !isWordCharacter(before), !isRepoNameCharacter(before), before != "/" else { return false }
        }
        var slug = String.UnicodeScalarView()
        slug.append(contentsOf: scalars[ownerStart..<hashIndex])
        return String(slug).lowercased() == repository.lowercased()
    }

    // MARK: - Commit trailers

    /// `Refs: #n` (the whole line) and `Closes|Fixes|Resolves #n` (line start) in a full commit message (`%B`).
    static func issueNumbers(inTrailers message: String) -> [Int] {
        var numbers: [Int] = []
        // `\r\n` is a single `Character`, so split on any newline instead of on `"\n"`.
        for line in message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let number = refsTrailer(line) ?? closingTrailer(line) {
                numbers.append(number)
            }
        }
        return unique(numbers)
    }

    private static func refsTrailer(_ line: Substring) -> Int? {
        let prefix = "Refs: #"
        guard line.hasPrefix(prefix) else { return nil }
        let scalars = Array(line.dropFirst(prefix.count).unicodeScalars)
        guard !scalars.isEmpty, digitRun(in: scalars, from: 0) == scalars.count else { return nil }
        return issueNumber(scalars[...])
    }

    private static func closingTrailer(_ line: Substring) -> Int? {
        for keyword in closingKeywords {
            let prefix = keyword + " #"
            guard line.hasPrefix(prefix) else { continue }
            let scalars = Array(line.dropFirst(prefix.count).unicodeScalars)
            let count = digitRun(in: scalars, from: 0)
            guard count > 0 else { return nil }
            return issueNumber(scalars[0..<count])
        }
        return nil
    }

    // MARK: - Helpers

    /// Length of the ASCII digit run starting at `start`.
    private static func digitRun(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var end = start
        while end < scalars.count, ("0"..."9").contains(scalars[end]) { end += 1 }
        return end - start
    }

    /// A run of one to `maxDigits` ASCII digits as a positive issue number. A longer run is not an issue number.
    private static func issueNumber(_ digits: ArraySlice<Unicode.Scalar>) -> Int? {
        guard (1...maxDigits).contains(digits.count) else { return nil }
        let value = digits.reduce(0) { $0 * 10 + Int($1.value - 0x30) }
        return value > 0 ? value : nil
    }

    /// Letters, digits (any script) and `_`, like `\w` in the spec's `\b`.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// GitHub repository names: ASCII letters, digits, `-`, `_`, `.`.
    private static func isRepoNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (isOwnerCharacter(scalar) || scalar == "_" || scalar == ".")
    }

    /// GitHub owner names: ASCII letters, digits, `-`.
    private static func isOwnerCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-")
    }

    private static func unique(_ numbers: [Int]) -> [Int] {
        var seen: Set<Int> = []
        return numbers.filter { seen.insert($0).inserted }
    }
}
