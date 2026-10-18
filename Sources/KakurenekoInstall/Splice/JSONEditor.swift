import Foundation

/// Format-preserving editor for JSON/JSONC documents (brief §3.7.3: "JSON: parse to validate, then splice
/// textually into the specific array; JSONC: comment-aware splice").
///
/// Every edit is a textual replacement computed from the parse tree's byte offsets; the document is re-parsed
/// after each edit, so later edits always see fresh offsets. Insertions follow the jsonc-parser convention
/// (append `,<newline><indent><value>` right after the last child) and removals are their exact inverse
/// (delete from the end of the previous child to the end of the removed one), so install followed by uninstall
/// restores the original bytes in the canonical case.
struct JSONEditor {
    private(set) var bytes: [UInt8]
    private(set) var root: JSONNode
    let dialect: JSONSyntax.Dialect
    /// Path for error messages.
    let path: String
    let renderer: JSONRenderer

    /// Parses `text`; throws `InstallError.unparseable` when it is not valid in `dialect`.
    init(text: String, dialect: JSONSyntax.Dialect, path: String) throws {
        let bytes = Array(text.utf8)
        do {
            root = try JSONSyntax.parse(bytes, dialect: dialect)
        } catch {
            throw InstallError.unparseable(path: path, reason: error.description)
        }
        self.bytes = bytes
        self.dialect = dialect
        self.path = path
        renderer = JSONRenderer(indentUnit: Self.detectIndentUnit(bytes, root: root), newline: Self.detectNewline(bytes))
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    // MARK: Lookup

    /// The node at `keys` (objects only; last duplicate key wins), or nil.
    func node(at keys: [String]) -> JSONNode? {
        var current = root
        for key in keys {
            guard let member = current.member(key) else { return nil }
            current = member.value
        }
        return current
    }

    /// True when any string (key or value) inside `node` contains `marker` (decoded, so `\/` escapes match).
    func contains(_ marker: String, in node: JSONNode) -> Bool {
        switch node.kind {
        case .object(let members): members.contains { $0.key.contains(marker) || contains(marker, in: $0.value) }
        case .array(let elements): elements.contains { contains(marker, in: $0) }
        case .string(let s): s.contains(marker)
        case .number, .bool, .null: false
        }
    }

    // MARK: Primitive edits

    /// Appends `literal` as the last element of the array at `keys`.
    mutating func appendElement(_ literal: JSONLiteral, toArrayAt keys: [String]) throws {
        guard let array = node(at: keys), array.elements != nil else {
            throw InstallError.unexpectedStructure(path: path, reason: "\(Self.describe(keys)) is not an array")
        }
        let renderer = renderer
        try appendChild(to: array) { indent, inline in renderer.render(literal, indent: indent, inline: inline) }
    }

    /// Appends `"key": literal` as the last member of the object at `keys`.
    mutating func appendMember(_ key: String, _ literal: JSONLiteral, toObjectAt keys: [String]) throws {
        guard let object = node(at: keys), object.members != nil else {
            throw InstallError.unexpectedStructure(path: path, reason: "\(Self.describe(keys)) is not an object")
        }
        let renderer = renderer
        try appendChild(to: object) { indent, inline in
            JSONRenderer.quote(key) + ": " + renderer.render(literal, indent: indent, inline: inline)
        }
    }

    /// Removes child `index` (member or element) of the container at `keys`.
    mutating func removeChild(at index: Int, ofContainerAt keys: [String]) throws {
        guard let container = node(at: keys) else {
            throw InstallError.unexpectedStructure(path: path, reason: "\(Self.describe(keys)) is missing")
        }
        try removeChild(at: index, of: container)
    }

    // MARK: Layout

    private mutating func appendChild(to container: JSONNode, render: (_ indent: String, _ inline: Bool) -> String) throws {
        let kids = Self.childRanges(of: container)
        let childIndent = self.childIndent(of: container, kids: kids)
        if let last = kids.last {
            if isMultiline(container, kids: kids) {
                try replace(last.end..<last.end, with: "," + renderer.newline + childIndent + render(childIndent, false))
            } else {
                try replace(last.end..<last.end, with: ", " + render(childIndent, true))
            }
            return
        }
        let open = container.start
        let close = container.end - 1
        // Comments inside an empty container (`{ /* TODO */ }`) are kept: they follow the new child.
        let trivia = String(decoding: bytes[(open + 1)..<close], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let keptTrivia = trivia.isEmpty ? "" : " " + trivia
        if bytes[(open + 1)..<close].contains(0x0A) {
            try replace((open + 1)..<(open + 1), with: renderer.newline + childIndent + render(childIndent, false))
        } else if container.start == root.start || isMultiline(root, kids: Self.childRanges(of: root)) {
            let closingIndent = lineIndent(at: container.start)
            try replace((open + 1)..<close,
                        with: renderer.newline + childIndent + render(childIndent, false) + keptTrivia
                            + renderer.newline + closingIndent)
        } else {
            try replace((open + 1)..<close, with: render(childIndent, true) + keptTrivia + (keptTrivia.isEmpty ? "" : " "))
        }
    }

    private mutating func removeChild(at index: Int, of container: JSONNode) throws {
        let kids = Self.childRanges(of: container)
        guard kids.indices.contains(index) else {
            throw InstallError.unexpectedStructure(path: path, reason: "child \(index) out of range")
        }
        if kids.count == 1 {
            try replace(soleChildRemovalRange(kids[0], of: container), with: "")
            // Nothing but whitespace left: `{}` / `[]` as before. Comments (commented-out settings) stay.
            if let interior = interiorRange(ofContainerStartingAt: container.start),
               bytes[interior].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
                try replace(interior, with: "")
            }
        } else if index > 0 {
            try replace(kids[index - 1].end..<kids[index].end, with: "")
        } else {
            try replace(kids[0].start..<kids[1].start, with: "")
        }
    }

    /// The bytes of a container's only child, with its own line (indentation and line break) when nothing else
    /// shares that line, and a trailing comma — but never the comments around it.
    private func soleChildRemovalRange(_ child: (start: Int, end: Int), of container: JSONNode) -> Range<Int> {
        let lowerBound = container.start + 1
        let upperBound = container.end - 1
        var start = child.start
        let lineStartOffset = lineStart(of: child.start)
        let ownLine = lineStartOffset >= lowerBound
            && bytes[lineStartOffset..<child.start].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        if ownLine { start = lineStartOffset }
        var end = child.end
        var probe = end
        while probe < upperBound, bytes[probe] == 0x20 || bytes[probe] == 0x09 { probe += 1 }
        if probe < upperBound, bytes[probe] == 0x2C { end = probe + 1 } // trailing comma (JSONC)
        if ownLine {
            var rest = end
            while rest < upperBound, bytes[rest] == 0x20 || bytes[rest] == 0x09 || bytes[rest] == 0x0D { rest += 1 }
            if rest < upperBound, bytes[rest] == 0x0A { end = rest + 1 }
        }
        return start..<max(start, end)
    }

    /// The interior (between the brackets) of the container that starts at `start` in the current tree.
    private func interiorRange(ofContainerStartingAt start: Int) -> Range<Int>? {
        func find(_ node: JSONNode) -> JSONNode? {
            if node.start == start, node.members != nil || node.elements != nil { return node }
            switch node.kind {
            case .object(let members): for member in members { if let hit = find(member.value) { return hit } }
            case .array(let elements): for element in elements { if let hit = find(element) { return hit } }
            default: break
            }
            return nil
        }
        guard let node = find(root), node.end - 1 >= node.start + 1 else { return nil }
        return (node.start + 1)..<(node.end - 1)
    }

    private mutating func replace(_ range: Range<Int>, with text: String) throws {
        var updated = bytes
        updated.replaceSubrange(range, with: Array(text.utf8))
        do {
            root = try JSONSyntax.parse(updated, dialect: dialect)
        } catch {
            throw InstallError.unexpectedStructure(path: path, reason: "splice produced invalid JSON (\(error.description))")
        }
        bytes = updated
    }

    /// `(start, end)` of each member (key start … value end) or element.
    static func childRanges(of container: JSONNode) -> [(start: Int, end: Int)] {
        switch container.kind {
        case .object(let members): members.map { ($0.start, $0.end) }
        case .array(let elements): elements.map { ($0.start, $0.end) }
        default: []
        }
    }

    private func isMultiline(_ container: JSONNode, kids: [(start: Int, end: Int)]) -> Bool {
        guard container.members != nil || container.elements != nil else { return false }
        let upTo = kids.first?.start ?? (container.end - 1)
        guard upTo > container.start + 1 else { return false }
        return bytes[(container.start + 1)..<upTo].contains(0x0A)
    }

    private func childIndent(of container: JSONNode, kids: [(start: Int, end: Int)]) -> String {
        if let first = kids.first, isMultiline(container, kids: kids) {
            let start = lineStart(of: first.start)
            if bytes[start..<first.start].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                return String(decoding: bytes[start..<first.start], as: UTF8.self)
            }
        }
        return lineIndent(at: container.start) + renderer.indentUnit
    }

    private func lineStart(of offset: Int) -> Int {
        var s = offset
        while s > 0, bytes[s - 1] != 0x0A { s -= 1 }
        return s
    }

    /// Leading whitespace of the line containing `offset`.
    private func lineIndent(at offset: Int) -> String {
        let s = lineStart(of: offset)
        var e = s
        while e < bytes.count, bytes[e] == 0x20 || bytes[e] == 0x09 { e += 1 }
        return String(decoding: bytes[s..<e], as: UTF8.self)
    }

    static func detectNewline(_ bytes: [UInt8]) -> String {
        if let lf = bytes.firstIndex(of: 0x0A), lf > 0, bytes[lf - 1] == 0x0D { return "\r\n" }
        return "\n"
    }

    /// The indentation of the root object's first child line (falls back to two spaces).
    static func detectIndentUnit(_ bytes: [UInt8], root: JSONNode) -> String {
        guard let first = childRanges(of: root).first else { return "  " }
        var s = first.start
        while s > 0, bytes[s - 1] != 0x0A { s -= 1 }
        let prefix = bytes[s..<first.start]
        guard s > 0, !prefix.isEmpty, prefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return "  " }
        return String(decoding: prefix, as: UTF8.self)
    }

    static func describe(_ keys: [String]) -> String {
        keys.isEmpty ? "the top level" : "\"" + keys.joined(separator: ".") + "\""
    }
}

// MARK: - Hook containers

/// One event's entries in a hooks container (`"Stop": [entry, …]`).
struct HookEventEntries: Sendable {
    var event: String
    var entries: [JSONLiteral]
}

extension JSONEditor {
    /// True when every entry of `events` is present (semantically) in the object at `containerKeys`.
    func containsAll(_ events: [HookEventEntries], in containerKeys: [String]) -> Bool {
        guard let container = node(at: containerKeys), container.members != nil else { return events.isEmpty }
        for event in events {
            guard let array = container.member(event.event)?.value.elements else { return false }
            for entry in event.entries where !array.contains(where: { $0.value == entry.value }) { return false }
        }
        return true
    }

    /// Number of array elements (or nested handlers) under `containerKeys` that contain `marker`.
    func markedEntryCount(_ marker: String, in containerKeys: [String]) -> Int {
        guard let members = node(at: containerKeys)?.members else { return 0 }
        var count = 0
        for member in members {
            guard let elements = member.value.elements else { continue }
            for element in elements where contains(marker, in: element) {
                if let handlers = element.member("hooks")?.value.elements {
                    count += max(1, handlers.filter { contains(marker, in: $0) }.count)
                } else {
                    count += 1
                }
            }
        }
        return count
    }

    /// Appends `events` under `containerKeys`, creating the container (and any missing parent objects) and
    /// event arrays as needed. Existing entries are never touched.
    mutating func appendHookEntries(_ events: [HookEventEntries], containerKeys: [String]) throws {
        guard root.members != nil else {
            throw InstallError.unexpectedStructure(path: path, reason: "the top level is not an object")
        }
        // Walk down to the deepest existing object; create the rest in one insertion.
        var existing: [String] = []
        for (depth, key) in containerKeys.enumerated() {
            guard let parent = node(at: existing), parent.members != nil else {
                throw InstallError.unexpectedStructure(path: path, reason: "\(Self.describe(existing)) is not an object")
            }
            if parent.member(key) == nil {
                var literal = JSONLiteral.object(events.map { JSONField(key: $0.event, value: .array($0.entries)) })
                for missing in containerKeys[(depth + 1)...].reversed() {
                    literal = .object([JSONField(key: missing, value: literal)])
                }
                try appendMember(key, literal, toObjectAt: existing)
                return
            }
            existing.append(key)
        }
        guard node(at: containerKeys)?.members != nil else {
            throw InstallError.unexpectedStructure(path: path, reason: "\(Self.describe(containerKeys)) is not an object")
        }
        for event in events {
            let eventKeys = containerKeys + [event.event]
            if let current = node(at: eventKeys) {
                guard current.elements != nil else {
                    throw InstallError.unexpectedStructure(path: path, reason: "\(Self.describe(eventKeys)) is not an array")
                }
                for entry in event.entries { try appendElement(entry, toArrayAt: eventKeys) }
            } else {
                try appendMember(event.event, .array(event.entries), toObjectAt: containerKeys)
            }
        }
    }

    /// Removes every entry under `containerKeys` that contains `marker` (brief §3.7.4):
    /// * a matcher group whose `hooks` array mixes our handler with the user's keeps the user's handlers;
    /// * event arrays that became empty are dropped;
    /// * the container itself is dropped when it became empty and is not the top level.
    /// - Returns: whether anything was removed.
    @discardableResult
    mutating func removeMarkedEntries(_ marker: String, containerKeys: [String]) throws -> Bool {
        var removedAny = false
        removal: while true {
            guard let container = node(at: containerKeys), let members = container.members else { break }
            for (memberIndex, member) in members.enumerated() {
                guard let elements = member.value.elements else { continue }
                for (elementIndex, element) in elements.enumerated() where contains(marker, in: element) {
                    let eventKeys = containerKeys + [member.key]
                    // Mixed group: drop only our handlers.
                    if let handlersMember = element.member("hooks"), let handlers = handlersMember.value.elements {
                        let ours = handlers.indices.filter { contains(marker, in: handlers[$0]) }
                        let markerOutsideHandlers = element.members?.contains {
                            $0.key != "hooks" && (contains(marker, in: $0.value) || $0.key.contains(marker))
                        } ?? false
                        if !ours.isEmpty, ours.count < handlers.count, !markerOutsideHandlers {
                            try removeNestedHandler(at: ours[ours.count - 1], eventKeys: eventKeys, groupIndex: elementIndex)
                            removedAny = true
                            continue removal
                        }
                    }
                    if elements.count == 1 {
                        try removeChild(at: memberIndex, ofContainerAt: containerKeys)
                    } else {
                        try removeChild(at: elementIndex, ofContainerAt: eventKeys)
                    }
                    removedAny = true
                    continue removal
                }
            }
            break
        }
        if removedAny, !containerKeys.isEmpty, let container = node(at: containerKeys), container.members?.isEmpty == true {
            let parentKeys = Array(containerKeys.dropLast())
            if let parent = node(at: parentKeys)?.members,
               let index = parent.lastIndex(where: { $0.key == containerKeys[containerKeys.count - 1] }) {
                try removeChild(at: index, ofContainerAt: parentKeys)
            }
        }
        return removedAny
    }

    /// Removes handler `handlerIndex` from `container[eventKeys][groupIndex].hooks`.
    private mutating func removeNestedHandler(at handlerIndex: Int, eventKeys: [String], groupIndex: Int) throws {
        guard let group = node(at: eventKeys)?.elements?[groupIndex],
              let handlers = group.member("hooks")?.value else {
            throw InstallError.unexpectedStructure(path: path, reason: "hook group vanished")
        }
        guard (handlers.elements?.count ?? 0) > 1 else {
            throw InstallError.unexpectedStructure(path: path, reason: "cannot remove the only handler of a mixed group")
        }
        try removeChild(at: handlerIndex, of: handlers)
    }
}
