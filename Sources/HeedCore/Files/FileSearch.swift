import Foundation

/// One line ripgrep found: where it is and what it says, with the matches marked.
public struct SearchMatch: Hashable, Sendable, Identifiable {
    public var id: String { "\(path):\(line)" }
    /// Relative to the checkout.
    public var path: String
    public var line: Int
    /// 1-based, in UTF-16 units as editors count, of the first match on the line.
    public var column: Int
    /// The line as shown: leading blanks dropped, a long line cut around its first match.
    public var text: String
    /// The matches in `text`, as UTF-8 byte offsets.
    public var ranges: [Range<Int>]

    public init(path: String, line: Int, column: Int, text: String, ranges: [Range<Int>]) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
        self.ranges = ranges
    }
}

/// What `rg --json` reports, as it reports it.
public enum SearchEvent: Hashable, Sendable {
    case match(SearchMatch)
    /// ripgrep found a NUL in the file and stopped: what it matched there is dropped.
    case binary(path: String)
}

/// Reads `rg --json` output as it streams in: one JSON object per line, the last one possibly cut off until the next
/// chunk (or for good, when ripgrep was stopped).
public struct RipgrepParser: Sendable {
    private var pending = Data()
    /// Longer lines are cut to this many bytes around their first match.
    static let maxLine = 240

    public init() {}

    public mutating func feed(_ data: Data) -> [SearchEvent] {
        pending.append(data)
        var events: [SearchEvent] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[pending.startIndex ..< newline]
            pending = Data(pending[(newline + 1)...])
            if let event = Self.event(line) { events.append(event) }
        }
        return events
    }

    /// What is left once the stream ends: a whole object if ripgrep ended without a newline, else nothing.
    public mutating func finish() -> [SearchEvent] {
        defer { pending = Data() }
        return Self.event(pending).map { [$0] } ?? []
    }

    static func event(_ line: Data) -> SearchEvent? {
        guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, let data = object["data"] as? [String: Any],
              let path = text(data["path"])
        else { return nil }
        let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        switch type {
        case "match":
            guard let number = (data["line_number"] as? NSNumber)?.intValue, let raw = text(data["lines"]) else {
                return nil
            }
            let submatches = (data["submatches"] as? [[String: Any]] ?? []).compactMap { sub -> Range<Int>? in
                guard let start = (sub["start"] as? NSNumber)?.intValue, let end = (sub["end"] as? NSNumber)?.intValue,
                      end >= start
                else { return nil }
                return start ..< end
            }
            return .match(shown(path: relative, line: number, raw: raw, ranges: submatches))
        case "end":
            if data["binary_offset"] is NSNumber { return .binary(path: relative) }
            return nil
        default:
            return nil
        }
    }

    /// `{"text": …}`, or `{"bytes": <base64>}` for what is not UTF-8.
    private static func text(_ value: Any?) -> String? {
        guard let value = value as? [String: Any] else { return nil }
        if let text = value["text"] as? String { return text }
        if let bytes = value["bytes"] as? String, let data = Data(base64Encoded: bytes) {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    /// The line as the results list shows it, with its ranges moved along.
    static func shown(path: String, line: Int, raw: String, ranges: [Range<Int>]) -> SearchMatch {
        var bytes = Array(raw.utf8)
        while let last = bytes.last, last == 10 || last == 13 {
            bytes.removeLast()
        }
        let first = ranges.first?.lowerBound ?? 0
        let prefix = String(decoding: bytes[..<min(first, bytes.count)], as: UTF8.self)
        let column = prefix.utf16.count + 1
        var from = bytes.prefix { $0 == 32 || $0 == 9 }.count
        var to = bytes.count
        if to - from > maxLine {
            from = max(from, first - maxLine / 4)
            to = min(bytes.count, from + maxLine)
            // Never in the middle of a character.
            while from < to, bytes[from] & 0xC0 == 0x80 {
                from += 1
            }
            while to < bytes.count, to > from, bytes[to] & 0xC0 == 0x80 {
                to -= 1
            }
        }
        let text = String(decoding: bytes[from ..< to], as: UTF8.self)
        let moved = ranges.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, from) - from, upper = min(range.upperBound, to) - from
            return upper > lower ? lower ..< upper : nil
        }
        return SearchMatch(path: path, line: line, column: column, text: text, ranges: moved)
    }
}

/// Find in files: ripgrep in the checkout, literal and smart case (lower case finds any case), skipping what git
/// ignores and `[files] exclude`. Results stream; at most `limit` lines, then ripgrep is stopped.
public enum FileSearch {
    public static let limit = 2000

    public static func arguments(_ query: String, exclude: FileExclusion) -> [String] {
        var arguments = [
            "--json", "--fixed-strings", "--smart-case", "--hidden", "--max-filesize", "1M", "--glob", "!.git",
        ]
        for pattern in exclude.patterns {
            arguments += ["--glob", "!\(pattern)"]
        }
        return arguments + ["--", query, "."]
    }

    /// The events in batches as ripgrep prints them; ends at `limit` matches, or when the consumer stops (a new
    /// query), stopping ripgrep. ripgrep's exit 1 is "nothing found", not an error.
    public static func run(_ query: String, in root: String, exclude: FileExclusion)
        -> AsyncThrowingStream<[SearchEvent], Error>
    {
        AsyncThrowingStream { continuation in
            let reading = Task.detached {
                var parser = RipgrepParser()
                var matches = 0
                do {
                    for try await chunk in ProcessRunner.stream(
                        "rg", arguments(query, exclude: exclude), in: root, success: [0, 1]
                    ) {
                        var events: [SearchEvent] = []
                        for event in parser.feed(chunk) {
                            if case .match = event {
                                guard matches < limit else { break }
                                matches += 1
                            }
                            events.append(event)
                        }
                        if !events.isEmpty { continuation.yield(events) }
                        if matches >= limit {
                            continuation.finish()
                            return
                        }
                    }
                    let rest = parser.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }
}
