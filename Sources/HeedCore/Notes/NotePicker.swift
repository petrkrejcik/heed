import Foundation

// MARK: Fuzzy matching

/// Fuzzy subsequence scorer for the note picker.
/// A query matches a text when every query character appears in text in order.
/// Score components (higher = better match):
/// - Consecutive run bonus.
/// - Word-start bonus (after space, `-`, `/`, `.`).
/// - Length penalty (shorter paths score higher when tied).
public enum FuzzyMatcher {
    public struct Result: Equatable, Sendable {
        public var entry: NoteEntry
        public var score: Double
    }

    /// Returns `true` when every character of `query` appears in `text` (in order, case-insensitive).
    public static func isMatch(query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        let t = text.lowercased()
        var qi = q.startIndex
        for ch in t where ch == q[qi] {
            qi = q.index(after: qi)
            if qi == q.endIndex { return true }
        }
        return false
    }

    /// Score for how well `query` matches `text`. Higher is better; 0 means no match.
    public static func score(query: String, text: String) -> Double {
        guard !query.isEmpty else { return 1 }
        let q = query.lowercased()
        let t = text.lowercased()
        var qi = q.startIndex
        var score: Double = 0
        var prev: Character = " "
        var runLength = 0
        for ch in t {
            if qi == q.endIndex { break }
            if ch == q[qi] {
                runLength += 1
                // Word-start bonus.
                let isWordStart = " -/._".contains(prev)
                score += isWordStart ? 3 : 1
                // Consecutive run bonus.
                score += Double(runLength - 1) * 0.5
                qi = q.index(after: qi)
            } else {
                runLength = 0
            }
            prev = ch
        }
        // Did not match all query chars.
        if qi != q.endIndex { return 0 }
        // Slight penalty for longer texts (prefer shorter names).
        score -= Double(t.count) * 0.01
        return max(score, 0.001)
    }

    /// Ranks `entries` by how well they match `query`. Each word of the query must match the name, an alias or the
    /// folder, in any order; entries where one doesn't are excluded. `taskNotePath` and `epicNotePath` get a small
    /// bonus.
    public static func rank(
        entries: [NoteEntry],
        query: String,
        taskNotePath: String? = nil,
        epicNotePath: String? = nil
    ) -> [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var results: [Result] = []
        for entry in entries {
            var best: Double = 0
            for word in words {
                var wordBest = score(query: word, text: entry.name) * 3
                for alias in entry.aliases {
                    wordBest = max(wordBest, score(query: word, text: alias) * 2)
                }
                wordBest = max(wordBest, score(query: word, text: entry.folder))
                guard wordBest > 0 else {
                    best = 0
                    break
                }
                best += wordBest
            }
            guard best > 0 else { continue }
            // Small bonus for task note and epic.
            if entry.path == taskNotePath { best += 2 }
            if entry.path == epicNotePath { best += 1 }
            results.append(Result(entry: entry, score: best))
        }
        return results.sorted { $0.score > $1.score }
    }
}

// MARK: Note picker

/// `gN` / `:note [words]`: fuzzy search over the vault index. Modal, like `LinkPicker`.
public struct NotePicker: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The key was consumed but the picker state may have changed.
        case handled
        /// `⎋`: close without opening.
        case cancel
        /// Open the selected note; `show` focuses it (`↩`), false for `⌘↩` (background).
        case open(NoteEntry, show: Bool)
    }

    /// All vault entries, sorted for empty-query display.
    public let allEntries: [NoteEntry]
    /// The task's own note path (shown first when present).
    public let taskNotePath: String?
    /// The epic note path (shown second when present).
    public let epicNotePath: String?

    /// The typed query.
    public private(set) var query: String
    /// The cursor row in the visible list.
    public private(set) var cursor: Int

    // MARK: Computed display list

    /// The entries the picker shows, in display order.
    public var rows: [NoteEntry] {
        if query.isEmpty {
            return emptyQueryOrder()
        }
        return FuzzyMatcher.rank(
            entries: allEntries, query: query,
            taskNotePath: taskNotePath, epicNotePath: epicNotePath
        ).map(\.entry)
    }

    private func emptyQueryOrder() -> [NoteEntry] {
        var ordered: [NoteEntry] = []
        var seen: Set<String> = []
        func add(_ path: String?) {
            guard let path, let entry = allEntries.first(where: { $0.path == path }),
                  !seen.contains(path) else { return }
            ordered.append(entry)
            seen.insert(path)
        }
        add(taskNotePath)
        add(epicNotePath)
        // The rest by modified time descending.
        let rest = allEntries.filter { !seen.contains($0.path) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        ordered += rest
        return ordered
    }

    // MARK: Init

    public init(
        allEntries: [NoteEntry],
        taskNotePath: String?,
        epicNotePath: String?,
        query: String = ""
    ) {
        self.allEntries = allEntries
        self.taskNotePath = taskNotePath
        self.epicNotePath = epicNotePath
        self.query = query
        cursor = 0
    }

    // MARK: Key handling

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case .escape, KeyStroke("q", .control):
            return .cancel
        case KeyStroke("CR"):
            return open(show: true)
        case KeyStroke("CR", .command):
            return open(show: false)
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"):
            moveCursor(by: 1)
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"):
            moveCursor(by: -1)
        case KeyStroke("w", .control):
            dropLastWord()
        case KeyStroke("BS"):
            if !query.isEmpty { query.removeLast() }
            clampCursor()
        default:
            if !stroke.isNamed, stroke.modifiers.isEmpty {
                query += stroke.key
                clampCursor()
            } else if stroke.isNamed, stroke.key == "Space", stroke.modifiers.isEmpty {
                query += " "
                clampCursor()
            }
        }
        return .handled
    }

    private mutating func open(show: Bool) -> Outcome {
        let list = rows
        guard list.indices.contains(cursor) else { return .cancel }
        return .open(list[cursor], show: show)
    }

    private mutating func moveCursor(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        cursor = max(0, min(cursor + delta, count - 1))
    }

    private mutating func clampCursor() {
        let count = rows.count
        cursor = count > 0 ? max(0, min(cursor, count - 1)) : 0
    }

    private mutating func dropLastWord() {
        query = query.trimmingCharacters(in: .whitespaces)
        if let space = query.lastIndex(of: " ") {
            query = String(query[..<space])
        } else {
            query = ""
        }
        clampCursor()
    }
}
