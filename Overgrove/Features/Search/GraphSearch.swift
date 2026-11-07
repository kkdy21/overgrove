import SwiftUI

/// The toolbar search over the loaded graph (screens.md S-01, #74): message, author, SHA prefix, ref name, or issue
/// number (`#12`). Pure and in memory: no git runs, so only loaded pages are searched (the summary says so).
struct GraphSearchQuery: Equatable, Sendable {
    /// Lowercased, trimmed.
    let text: String
    /// `#12` (or `12`): commits whose subject references the issue, or that a branch named for it points at.
    let issueNumber: Int?
    /// 4–64 hex digits: commits whose SHA starts with them.
    let shaPrefix: String?

    /// `nil` for an empty or whitespace-only query (no search, nothing dimmed).
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        text = trimmed.lowercased()
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        issueNumber =
            (1...IssueRefExtractor.maxDigits).contains(digits.utf8.count)
                && digits.utf8.allSatisfy { (0x30...0x39).contains($0) }
            ? Int(digits).flatMap { $0 > 0 ? $0 : nil } : nil
        shaPrefix =
            (4...64).contains(trimmed.utf8.count) && trimmed.utf8.allSatisfy(Self.isHex) ? trimmed.lowercased() : nil
    }

    func matches(_ commit: CommitNode, pills: [GraphRefPill], issueRepository: String?) -> Bool {
        if let shaPrefix, commit.oid.hex.hasPrefix(shaPrefix) { return true }
        if let issueNumber {
            if CommitLink.issueNumbers(in: commit.subject, repository: issueRepository).contains(issueNumber) {
                return true
            }
            // A branch named for the issue (`feat/12-x`) at this commit.
            if pills.contains(where: { IssueRefExtractor.issueNumber(inBranch: $0.title) == issueNumber }) {
                return true
            }
            // `#12` means the issue, not any text with `12` in it.
            if text.hasPrefix("#") { return false }
        }
        return contains(commit.subject) || contains(commit.authorName) || contains(commit.authorEmail)
            || commit.coAuthors.contains(where: contains)
            || pills.contains { contains($0.title) || contains($0.tooltip) }
    }

    private func contains(_ field: String) -> Bool {
        field.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

/// The result over the loaded pages, in graph order (newest first).
struct GraphSearchResult: Equatable {
    let query: GraphSearchQuery
    let matches: [ObjectID]
    let matchSet: Set<ObjectID>
    let searchedCount: Int
    /// Every commit is loaded, so no older match can be missing.
    let isComplete: Bool

    init(
        query: GraphSearchQuery, commits: [CommitNode], pills: [ObjectID: [GraphRefPill]], issueRepository: String?,
        isComplete: Bool
    ) {
        self.query = query
        matches = commits.filter { query.matches($0, pills: pills[$0.oid] ?? [], issueRepository: issueRepository) }
            .map(\.oid)
        matchSet = Set(matches)
        searchedCount = commits.count
        self.isComplete = isComplete
    }

    /// `3 matches in 1,500 loaded commits · older commits are searched as they load` (the loaded-page notice).
    var summary: String {
        let count = matches.count
        let found = count == 0 ? "No matches" : "\(count.formatted()) \(count == 1 ? "match" : "matches")"
        let scope =
            isComplete
            ? "in all \(searchedCount.formatted()) commits"
            : "in \(searchedCount.formatted()) loaded commits · older commits are searched as they load"
        return "\(found) \(scope)"
    }

    /// The match after (or before) `current` in graph order, wrapping around; the first (or last) without one.
    func step(from current: ObjectID?, forward: Bool) -> ObjectID? {
        guard !matches.isEmpty else { return nil }
        guard let current, let index = matches.firstIndex(of: current) else {
            return forward ? matches.first : matches.last
        }
        let next = (index + (forward ? 1 : -1) + matches.count) % matches.count
        return matches[next]
    }
}

/// The sidebar's Filter field (⌥⌘F, screens.md S-01): rows whose name contains the text, case-insensitively.
enum SidebarFilter {
    /// `nil` when the field is empty.
    static func query(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func matches(_ query: String?, _ fields: String?...) -> Bool {
        guard let query else { return true }
        return fields.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Branch rows that match, with the folders that hold them (opened, so matches show). Folder counts are the
    /// matching rows.
    static func branches(_ nodes: [BranchNode], query: String?) -> [BranchNode] {
        guard let query else { return nodes }
        return nodes.compactMap { node -> BranchNode? in
            switch node {
            case .branch(let row):
                return matches(query, row.fullDisplayName) ? node : nil
            case .folder(let id, let name, _, let children):
                let kept = branches(children, query: query)
                return kept.isEmpty ? nil : .folder(id: id, name: name, count: count(kept), children: kept)
            }
        }
    }

    private static func count(_ nodes: [BranchNode]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .branch: total + 1
            case .folder(_, _, _, let children): total + count(children)
            }
        }
    }

    /// Every folder in `nodes`, to show filtered branches without opening folders by hand.
    static func folderIDs(_ nodes: [BranchNode]) -> Set<String> {
        nodes.reduce(into: Set<String>()) { ids, node in
            if case .folder(let id, _, _, let children) = node {
                ids.insert(id)
                ids.formUnion(folderIDs(children))
            }
        }
    }
}

/// The sidebar's Filter field (⌥⌘F): Edit › Filter Sidebar focuses it, ⎋ clears it.
struct SidebarFilterField: View {
    @Binding var text: String
    /// Changes when ⌥⌘F asks for focus.
    let focusRequest: Int

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = "" }
                .accessibilityLabel("Filter the sidebar")
            if text.isEmpty {
                Text("⌥⌘F").font(Tokens.Font.monoSmall).accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear the filter")
                .accessibilityLabel("Clear the filter")
            }
        }
        .font(Tokens.Font.callout)
        .foregroundStyle(Tokens.Color.textTertiary)
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowSidebar)
        .background(Tokens.Color.surfaceControl, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .onChange(of: focusRequest) { _, _ in isFocused = true }
    }
}
