import Foundation

/// S-03 rows and texts (screens.md S-03, #69). Pure, so it is tested without views; repository strings are escaped.
struct CommitDetailModel: Equatable {
    struct Person: Equatable {
        let name: String
        let email: String
        let initials: String
        let avatarIndex: Int
    }

    struct CoAuthor: Equatable {
        /// The name part of the trailer (`Coding Agent`), escaped.
        let title: String
        /// The whole trailer value, for the tooltip.
        let tooltip: String
        let isAI: Bool
    }

    struct BodyLine: Equatable, Identifiable {
        let id: Int
        let text: String
        /// A trailer of the last paragraph (`Co-Authored-By: …`, `Refs: #12`), shown in `text.secondary`.
        let isTrailer: Bool
    }

    struct FileRow: Equatable, Identifiable {
        let stat: FileStat
        let kindLetter: String
        let directory: String
        let fileName: String
        /// `+12 −3`, or `binary`.
        let lineChange: String
        let isSelectable: Bool
        /// `Modified, src/a.swift, 2 lines added, 1 removed` (interaction.md §6.1).
        var accessibilityLabel: String { WipDetailModel.fileAccessibilityLabel(stat) }
        var id: GitPath { stat.path }
    }

    enum Files: Equatable {
        case loading
        case failed(String)
        case loaded(rows: [FileRow], hidden: Int)
    }

    /// Files shown before `Show all n files` (screens.md S-03).
    static let fileLimit = 1_000

    let title: String
    let shortSHA: String
    let fullSHA: String
    let author: Person
    let coAuthors: [CoAuthor]
    let date: String
    /// Only when someone else committed it.
    let committer: Person?
    let parents: [ObjectID]
    let pills: [GraphRefPill]
    let issues: [Int]
    let body: [BodyLine]
    let files: Files
    /// `Files (4)`.
    let filesHeader: String
    /// `+73 −11`; empty until the files load.
    let totalLineChange: String
    /// `Changes vs first parent` for merges (the file list diffs against it).
    let filesNote: String?
    /// The message or file list was cut at the output limit.
    let isPartial: Bool

    init(
        commit: CommitNode, detail: CommitDetailStore.Detail?, pills: [GraphRefPill], showsAllFiles: Bool,
        rule: AIAgentRule = .builtIn, timeZone: TimeZone = .current, issueRepository: String? = nil
    ) {
        title = PathValidator.displayable(commit.subject)
        shortSHA = commit.oid.short
        fullSHA = commit.oid.hex
        author = Self.person(commit.authorName, commit.authorEmail)
        coAuthors = commit.coAuthors.map { value in
            let name = value.split(separator: "<", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
            return CoAuthor(
                title: PathValidator.displayable(name.flatMap { $0.isEmpty ? nil : $0 } ?? value),
                tooltip: PathValidator.displayable(value), isAI: rule.isAgent(value))
        }
        date = Self.format(commit.authorDate, timeZone: timeZone)
        parents = commit.parents
        self.pills = pills
        filesNote = commit.isMerge ? "Changes vs first parent" : nil

        var message = commit.subject
        switch detail {
        case .loaded(let loaded):
            message = loaded.message
            committer =
                loaded.committerEmail.lowercased() == loaded.authorEmail.lowercased()
                    && loaded.committerName == loaded.authorName
                ? nil : Self.person(loaded.committerName, loaded.committerEmail)
            let rows = loaded.files.map(Self.fileRow)
            let shown = showsAllFiles ? rows : Array(rows.prefix(Self.fileLimit))
            files = .loaded(rows: shown, hidden: rows.count - shown.count)
            filesHeader = "Files (\(loaded.files.count))"
            let added = loaded.files.compactMap(\.added).reduce(0, +)
            let deleted = loaded.files.compactMap(\.deleted).reduce(0, +)
            totalLineChange = "+\(added) −\(deleted)"
            isPartial = loaded.isPartial
        case .failed(let reason):
            committer = nil
            files = .failed(reason)
            filesHeader = "Files"
            totalLineChange = ""
            isPartial = false
        case .loading, nil:
            committer = nil
            files = .loading
            filesHeader = "Files"
            totalLineChange = ""
            isPartial = false
        }
        body = Self.bodyLines(message)
        // `owner/repo#n` counts for the repository the issues are read from (#82).
        var numbers = CommitLink.issueNumbers(in: commit.subject, repository: issueRepository)
        for number in IssueRefExtractor.issueNumbers(inTrailers: message) where !numbers.contains(number) {
            numbers.append(number)
        }
        issues = numbers
    }

    private static func person(_ name: String, _ email: String) -> Person {
        Person(
            name: PathValidator.displayable(name), email: PathValidator.displayable(email),
            initials: AuthorAvatar.initials(name: name), avatarIndex: AuthorAvatar.colorIndex(email: email))
    }

    /// `2026-11-06 09:41 (+09:00)` in the local time zone.
    static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm '('xxx')'"
        return formatter.string(from: date)
    }

    /// The message without its subject line, with the last paragraph's `Key: value` lines marked as trailers.
    static func bodyLines(_ message: String) -> [BodyLine] {
        var lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }
        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let lastBlank = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trailerStart = (lastBlank ?? -1) + 1
        let lastParagraph = lines[trailerStart...]
        let isTrailerBlock = !lastParagraph.isEmpty && lastParagraph.allSatisfy(isTrailer) && lastBlank != nil
        return lines.enumerated().map { index, line in
            BodyLine(
                id: index, text: PathValidator.displayable(line), isTrailer: isTrailerBlock && index >= trailerStart)
        }
    }

    /// `Token: value`, where the token is letters, digits, and `-` (git interpret-trailers).
    private static func isTrailer(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return false }
        return line[..<colon].allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func fileRow(_ stat: FileStat) -> FileRow {
        let change = FileChange(path: stat.path, originalPath: stat.originalPath, status: stat.status ?? .modified)
        let (directory, fileName) = WipDetailModel.displayParts(change)
        let parts = [
            (stat.added ?? 0) > 0 ? "+\(stat.added ?? 0)" : nil,
            (stat.deleted ?? 0) > 0 ? "−\(stat.deleted ?? 0)" : nil,
        ].compactMap { $0 }
        let lineChange = stat.isBinary ? "binary" : (parts.isEmpty ? "±0" : parts.joined(separator: " "))
        return FileRow(
            stat: stat, kindLetter: String((stat.status ?? .modified).code), directory: directory, fileName: fileName,
            lineChange: lineChange,
            isSelectable: stat.path.isRepresentable && (stat.originalPath?.isRepresentable ?? true))
    }
}
