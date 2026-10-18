import Foundation

/// Line-based unified diff for the install preview (`FileChange.unifiedDiff`, brief §3.7.1).
///
/// Myers' O((N+M)·D) algorithm on the part between the common prefix and suffix (an installer edit touches a
/// few lines, so D is small). A pathological middle section falls back to "replace the whole block", which is
/// still a correct diff, just not a minimal one.
enum UnifiedDiff {
    /// Lines of context around each change.
    static let contextLines = 3
    /// Upper bound on the Myers trace size (`D · (N+M)` integers) before falling back.
    static let maxTraceCells = 4_000_000

    /// A unified diff from `old` to `new` (`nil` = the file does not exist). Empty when the texts are equal.
    static func make(old: String?, new: String?, label: String) -> String {
        if old == new { return "" }
        let a = lines(old ?? "")
        let b = lines(new ?? "")
        let ops = editScript(a, b)
        var out = "--- \(old == nil ? "/dev/null" : label)\n+++ \(new == nil ? "/dev/null" : label)\n"
        for hunk in hunks(ops) {
            out += render(hunk, ops: ops, a: a, b: b)
        }
        return out
    }

    // MARK: - Lines

    /// Splits into lines that keep their terminator, so "x" and "x\n" differ (as in diff(1)).
    static func lines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        let utf8 = text.utf8
        var start = utf8.startIndex
        var u = utf8.startIndex
        while u < utf8.endIndex {
            let next = utf8.index(after: u)
            if utf8[u] == 0x0A {
                result.append(text[start..<next])
                start = next
            }
            u = next
        }
        if start < utf8.endIndex { result.append(text[start...]) }
        return result
    }

    // MARK: - Edit script

    enum Op: Equatable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    static func editScript(_ a: [Substring], _ b: [Substring]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, same(a[prefix], b[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              same(a[a.count - 1 - suffix], b[b.count - 1 - suffix]) { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        var ops: [Op] = (0..<prefix).map { .equal($0, $0) }
        let middle = myers(midA, midB) ?? (midA.indices.map { Op.delete($0) } + midB.indices.map { Op.insert($0) })
        for op in middle {
            switch op {
            case .equal(let x, let y): ops.append(.equal(x + prefix, y + prefix))
            case .delete(let x): ops.append(.delete(x + prefix))
            case .insert(let y): ops.append(.insert(y + prefix))
            }
        }
        for s in 0..<suffix {
            ops.append(.equal(a.count - suffix + s, b.count - suffix + s))
        }
        return ops
    }

    /// Byte equality (String `==` uses canonical equivalence, which would hide a byte-level change).
    private static func same(_ x: Substring, _ y: Substring) -> Bool { x.utf8.elementsEqual(y.utf8) }

    /// Myers shortest edit script; `nil` when the trace would exceed `maxTraceCells`.
    private static func myers(_ a: [Substring], _ b: [Substring]) -> [Op]? {
        let n = a.count
        let m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        let maxD = n + m
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...maxD {
            if (d + 1) * v.count > maxTraceCells { return nil }
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, same(a[x], b[y]) {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    found = true
                    break search
                }
            }
        }
        guard found else { return nil }
        var ops: [Op] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
            let prevX = v[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                ops.append(.equal(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == prevX {
                    ops.append(.insert(prevY))
                } else {
                    ops.append(.delete(prevX))
                }
            }
            x = prevX
            y = prevY
        }
        return ops.reversed()
    }

    // MARK: - Hunks

    /// Ranges of `ops` indices that form hunks (changes plus context, merged when close).
    static func hunks(_ ops: [Op]) -> [Range<Int>] {
        let changed = ops.indices.filter { if case .equal = ops[$0] { false } else { true } }
        guard let first = changed.first else { return [] }
        var result: [Range<Int>] = []
        var lower = max(0, first - contextLines)
        var upper = min(ops.count, first + 1 + contextLines)
        for index in changed.dropFirst() {
            if index - contextLines <= upper {
                upper = min(ops.count, index + 1 + contextLines)
            } else {
                result.append(lower..<upper)
                lower = max(0, index - contextLines)
                upper = min(ops.count, index + 1 + contextLines)
            }
        }
        result.append(lower..<upper)
        return result
    }

    private static func render(_ hunk: Range<Int>, ops: [Op], a: [Substring], b: [Substring]) -> String {
        // Line numbers before the hunk start.
        var oldBefore = 0
        var newBefore = 0
        for op in ops[..<hunk.lowerBound] {
            switch op {
            case .equal: oldBefore += 1; newBefore += 1
            case .delete: oldBefore += 1
            case .insert: newBefore += 1
            }
        }
        var oldCount = 0
        var newCount = 0
        var body = ""
        for op in ops[hunk] {
            switch op {
            case .equal(let x, _):
                oldCount += 1
                newCount += 1
                body += line(" ", a[x])
            case .delete(let x):
                oldCount += 1
                body += line("-", a[x])
            case .insert(let y):
                newCount += 1
                body += line("+", b[y])
            }
        }
        let oldStart = oldCount == 0 ? oldBefore : oldBefore + 1
        let newStart = newCount == 0 ? newBefore : newBefore + 1
        return "@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@\n" + body
    }

    private static func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }

    private static func line(_ prefix: String, _ text: Substring) -> String {
        var bytes = Array(text.utf8)
        guard bytes.last == 0x0A else {
            return prefix + text + "\n\\ No newline at end of file\n"
        }
        bytes.removeLast()
        if bytes.last == 0x0D { bytes.removeLast() }
        return prefix + String(decoding: bytes, as: UTF8.self) + "\n"
    }
}
