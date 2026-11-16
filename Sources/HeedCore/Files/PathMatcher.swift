import Foundation

/// The finder's paths, laid out for matching: every path's bytes, and the same lowercased, in one buffer each, so
/// matching 134k paths is a scan over memory rather than over Swift strings. Built once per list, off the main actor,
/// and never changed after (hence the unchecked `Sendable`). Plain pointers, as Swift's arrays check bounds on every
/// byte in debug builds.
public final class PathIndex: @unchecked Sendable {
    public let paths: [String]
    /// Path `i` is `bytes[starts[i] ..< starts[i + 1]]`; its file name starts at `names[i]`.
    let lower: UnsafeMutablePointer<UInt8>
    let bytes: UnsafeMutablePointer<UInt8>
    let starts: UnsafeMutablePointer<Int32>
    let names: UnsafeMutablePointer<Int32>

    public init(_ paths: [String]) {
        self.paths = paths
        let size = paths.reduce(0) { $0 + $1.utf8.count }
        bytes = .allocate(capacity: max(size, 1))
        lower = .allocate(capacity: max(size, 1))
        starts = .allocate(capacity: paths.count + 1)
        names = .allocate(capacity: max(paths.count, 1))
        var at = 0
        starts[0] = 0
        for (i, path) in paths.enumerated() {
            var name = at
            for byte in path.utf8 {
                bytes[at] = byte
                lower[at] = PathMatcher.lowercase(byte)
                at += 1
                if byte == UInt8(ascii: "/") { name = at }
            }
            names[i] = Int32(name)
            starts[i + 1] = Int32(at)
        }
    }

    deinit {
        bytes.deallocate()
        lower.deallocate()
        starts.deallocate()
        names.deallocate()
    }

    public var count: Int { paths.count }
}

/// The finder's fuzzy match: every word of the query must appear in the path in order (a subsequence), anywhere;
/// a word found in the file name scores over one spread across folders, and matches at word starts (after `/`, `-`,
/// `_`, `.`, a space, or a lower-to-upper case change) and in runs score higher, as fzf scores. Case-insensitive.
public enum PathMatcher {
    public struct Match: Hashable, Sendable {
        public var path: String
        public var score: Int
    }

    /// The top `limit` matches, best first (ties: the shorter path, then the path), and every path that matched, so
    /// a longer query can search only those (`among`). Nil when the task was cancelled (the next key came).
    public static func search(
        _ query: String, in index: PathIndex, among candidates: [Int32]? = nil, limit: Int = 50
    ) -> (top: [Match], matched: [Int32])? {
        // The words one after another in one buffer, word `w` at `wordStarts[w] ..< wordStarts[w + 1]`.
        var flat: [UInt8] = []
        var wordStarts = [0]
        for word in query.split(whereSeparator: \.isWhitespace) {
            flat.append(contentsOf: word.utf8.map(lowercase))
            wordStarts.append(flat.count)
        }
        guard !flat.isEmpty else { return ([], []) }
        var top: [(score: Int, length: Int32, index: Int32)] = []
        top.reserveCapacity(limit + 1)
        var matched: [Int32] = []
        let total = candidates?.count ?? index.count
        let cancelled = flat.withUnsafeBufferPointer { flatBuffer in
            (candidates ?? []).withUnsafeBufferPointer { picked in
                let words = flatBuffer.baseAddress!
                for position in 0 ..< total {
                    if position & 4095 == 0, Task.isCancelled { return true }
                    let i = candidates == nil ? position : Int(picked[position])
                    let start = Int(index.starts[i]), end = Int(index.starts[i + 1]), name = Int(index.names[i])
                    var score = 0
                    var failed = false
                    for w in 0 ..< wordStarts.count - 1 {
                        guard let wordScore = self.score(
                            words + wordStarts[w], wordStarts[w + 1] - wordStarts[w], in: index,
                            start: start, end: end, name: name
                        ) else {
                            failed = true
                            break
                        }
                        score += wordScore
                    }
                    if failed { continue }
                    matched.append(Int32(i))
                    let entry = (score: score, length: Int32(end - start), index: Int32(i))
                    if top.count == limit, let last = top.last, !better(entry, than: last) { continue }
                    let at = top.firstIndex { better(entry, than: $0) } ?? top.count
                    top.insert(entry, at: at)
                    if top.count > limit { top.removeLast() }
                }
                return false
            }
        }
        if cancelled { return nil }
        return (top.map { Match(path: index.paths[Int($0.index)], score: $0.score) }, matched)
    }

    private static func better(
        _ lhs: (score: Int, length: Int32, index: Int32), than rhs: (score: Int, length: Int32, index: Int32)
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.length != rhs.length { return lhs.length < rhs.length }
        return lhs.index < rhs.index
    }

    static let scoreMatch = 16
    static let gapStart = -3
    static let gapExtension = -1
    static let bonusSegment = 10
    static let bonusWord = 8
    static let bonusCamel = 7
    static let bonusConsecutive = 5
    static let bonusName = 24
    static let bonusNameStart = 12

    /// One word's score in one path, nil when it is not a subsequence of it.
    static func score(
        _ query: UnsafePointer<UInt8>, _ count: Int, in index: PathIndex, start: Int, end: Int, name: Int
    ) -> Int? {
        let lower = UnsafePointer(index.lower), bytes = UnsafePointer(index.bytes)
        // In the file name alone, else anywhere in the path.
        if let inName = window(query, count, lower: lower, from: name, to: end) {
            var score = run(
                query,
                count,
                lower: lower,
                bytes: bytes,
                from: inName.lowerBound,
                to: inName.upperBound,
                start: start
            ) + bonusName
            if inName.lowerBound == name { score += bonusNameStart }
            return score
        }
        guard let anywhere = window(query, count, lower: lower, from: start, to: end) else { return nil }
        return run(
            query,
            count,
            lower: lower,
            bytes: bytes,
            from: anywhere.lowerBound,
            to: anywhere.upperBound,
            start: start
        )
    }

    /// The shortest stretch of `lower[from..<to]` holding `query` as a subsequence that ends earliest: forward to
    /// where the match first completes, then back to the latest start (fzf's v1).
    static func window(
        _ query: UnsafePointer<UInt8>, _ count: Int, lower: UnsafePointer<UInt8>, from: Int, to: Int
    ) -> Range<Int>? {
        guard count > 0 else { return from ..< from }
        // memchr jumps to each next byte of the query.
        var position = from
        for q in 0 ..< count {
            guard position < to, let hit = memchr(lower + position, Int32(query[q]), to - position) else {
                return nil
            }
            position = UnsafeRawPointer(lower).distance(to: hit) + 1
        }
        let last = position - 1
        position = last
        var q = count - 1
        while position >= from {
            if lower[position] == query[q] {
                if q == 0 { break }
                q -= 1
            }
            position -= 1
        }
        return position ..< last + 1
    }

    /// The score of matching `query` greedily in `from..<to`, where the match is known to fit.
    static func run(
        _ query: UnsafePointer<UInt8>, _ count: Int, lower: UnsafePointer<UInt8>, bytes: UnsafePointer<UInt8>,
        from: Int, to: Int, start: Int
    ) -> Int {
        var score = 0
        var q = 0
        var inGap = false
        var runBonus = 0
        var previousMatched = false
        for position in from ..< to where q < count {
            if lower[position] == query[q] {
                let bonus = boundary(bytes: bytes, at: position, start: start)
                if previousMatched {
                    runBonus = max(runBonus, bonus, bonusConsecutive)
                    score += scoreMatch + runBonus
                } else {
                    runBonus = bonus
                    score += scoreMatch + (q == 0 ? bonus * 2 : bonus)
                }
                q += 1
                previousMatched = true
                inGap = false
            } else {
                score += inGap ? gapExtension : gapStart
                inGap = true
                previousMatched = false
                runBonus = 0
            }
        }
        return score
    }

    static func boundary(bytes: UnsafePointer<UInt8>, at position: Int, start: Int) -> Int {
        guard position > start else { return bonusSegment }
        let previous = bytes[position - 1], current = bytes[position]
        switch previous {
        case UInt8(ascii: "/"): return bonusSegment
        case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: " "): return bonusWord
        default:
            let previousLower = previous >= UInt8(ascii: "a") && previous <= UInt8(ascii: "z")
            let currentUpper = current >= UInt8(ascii: "A") && current <= UInt8(ascii: "Z")
            return previousLower && currentUpper ? bonusCamel : 0
        }
    }

    static func lowercase(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
    }
}
