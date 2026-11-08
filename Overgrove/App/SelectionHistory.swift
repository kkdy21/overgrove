import Foundation

/// Back and forward over the main selection (`⌘[` / `⌘]`, interaction.md §1.4, #378), like a browser.
///
/// Pure value; `AppState` records each selection the user makes and asks it where to go. Entries hold identifiers only
/// (path, SHA, OID, number), so a stale one is detected by the caller (`isAvailable`) and dropped, never shown.
struct SelectionHistory: Equatable {
    struct Entry: Equatable {
        let selection: MainSelection
        /// The focused worktree when it was chosen; going back restores it too (information-architecture.md §2.2).
        let focus: GitPath?

        /// The same thing to look at: the two segments of one worktree (`Changes`, `Worktree`) are one target.
        func isSameTarget(as other: Entry) -> Bool {
            if let path = selection.worktreePath, let otherPath = other.selection.worktreePath {
                return path == otherPath
            }
            return selection == other.selection
        }
    }

    /// Entries per window, back, current, and forward together; the oldest go first.
    static let maximumEntries = 50

    private var back: [Entry] = []
    private(set) var current: Entry?
    private var forward: [Entry] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// A selection the user made. The same target as the current entry only updates it (a segment switch).
    mutating func record(_ entry: Entry) {
        if let current, current.isSameTarget(as: entry) {
            self.current = entry
            return
        }
        if let current { back.append(current) }
        current = entry
        forward = []
        let overflow = back.count + 1 - Self.maximumEntries
        if overflow > 0 { back.removeFirst(overflow) }
    }

    /// A selection the app made (a refresh falling back to the focused worktree): it replaces the current entry.
    mutating func replaceCurrent(_ entry: Entry) {
        current = entry
    }

    /// The nearest earlier entry that `isAvailable`, which becomes current; unavailable ones on the way are dropped.
    /// `nil` when there is none, and then nothing moves.
    mutating func goBack(isAvailable: (Entry) -> Bool) -> Entry? {
        while let candidate = back.popLast() {
            guard isAvailable(candidate) else { continue }
            if let current { forward.append(current) }
            current = candidate
            return candidate
        }
        return nil
    }

    /// The nearest later entry that `isAvailable`; see `goBack`.
    mutating func goForward(isAvailable: (Entry) -> Bool) -> Entry? {
        while let candidate = forward.popLast() {
            guard isAvailable(candidate) else { continue }
            if let current { back.append(current) }
            current = candidate
            return candidate
        }
        return nil
    }

    mutating func clear() {
        back = []
        current = nil
        forward = []
    }
}
