import Foundation

/// One line of a hunk. `content` is the raw bytes after the one-character prefix.
struct PatchLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case context
        case added
        case removed
        /// `\ No newline at end of file`: belongs to the line before it.
        case noNewline
    }

    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let content: Data
}

/// `@@ -oldStart,oldCount +newStart,newCount @@ section`.
struct PatchHunk: Sendable, Equatable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    /// The text after the second `@@` (git's function-context hint), raw bytes.
    let section: Data
    let lines: [PatchLine]
}

/// One `diff --git` block (parsing-spec.md §11.5).
struct FilePatch: Sendable, Equatable {
    struct SubmoduleChange: Sendable, Equatable {
        let old: ObjectID?
        let new: ObjectID?
    }

    var oldPath: GitPath?
    var newPath: GitPath?
    var oldMode: String?
    var newMode: String?
    var isNewFile = false
    var isDeletedFile = false
    var renameFrom: GitPath?
    var renameTo: GitPath?
    var copyFrom: GitPath?
    var copyTo: GitPath?
    var similarity: Int?
    var isBinary = false
    /// `diff --cc` / `diff --combined` of a conflicted file. Its body is not read.
    var isCombined = false
    /// `* Unmerged path <path>`: what `git diff --cached` (and some unmerged states) print instead of a patch.
    var isUnmerged = false
    var submodule: SubmoduleChange?
    var hunks: [PatchHunk] = []

    /// Mode `120000`: the content is the link target string (T14).
    var isSymlink: Bool { newMode == "120000" || (newMode == nil && oldMode == "120000") }
    var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}

/// Parses one file's raw patch from `git diff` or `git diff-tree -p` (parsing-spec.md §11.5).
///
/// Hunk line counts decide where each hunk ends, so file content that looks like a header (`+diff --git`, `-@@`)
/// stays content. Anything that does not fit the format fails instead of being guessed at.
enum PatchParser {
    struct Listing: Sendable, Equatable {
        let files: [FilePatch]
        /// The output was cut at the size limit; the last incomplete line was dropped.
        let isPartial: Bool

        var lineCount: Int { files.reduce(0) { $0 + $1.lineCount } }
    }

    private static let name = "PatchParser"

    static func parse(_ data: Data, truncated: Bool = false) throws -> Listing {
        var lines = splitLines(data)
        if truncated, let last = lines.last, last.upperBound == data.endIndex, data.last != 0x0A {
            lines.removeLast()  // the incomplete last line
        }
        var reader = Reader(data: data, lines: lines, truncated: truncated)
        // `diff-tree` with a single commit prints that commit's OID first (root commits, untracked stash parents).
        if let first = reader.peek(), ObjectID(String(decoding: data[first], as: UTF8.self)) != nil {
            reader.index += 1
        }
        var files: [FilePatch] = []
        while let line = reader.peek() {
            if startsWith(line, in: data, "* Unmerged path ") {
                reader.index += 1
                var patch = FilePatch()
                patch.isUnmerged = true
                patch.newPath = GitPath(raw: Data(data[(line.lowerBound + 16)..<line.upperBound]))
                files.append(patch)
                continue
            }
            guard
                startsWith(line, in: data, "diff --git ") || startsWith(line, in: data, "diff --cc ")
                    || startsWith(line, in: data, "diff --combined ")
            else { throw ParseError(parser: name, offset: line.lowerBound, reason: "expected a diff header") }
            files.append(try reader.file())
        }
        return Listing(files: files, isPartial: truncated)
    }

    // MARK: Reader

    private struct Reader {
        let data: Data
        let lines: [Range<Data.Index>]
        let truncated: Bool
        var index = 0

        func peek() -> Range<Data.Index>? { index < lines.count ? lines[index] : nil }

        mutating func next() -> Range<Data.Index>? {
            defer { index += 1 }
            return peek()
        }

        func text(_ range: Range<Data.Index>) -> Data { data[range] }

        mutating func file() throws -> FilePatch {
            var patch = FilePatch()
            guard let first = next() else {
                throw ParseError(parser: PatchParser.name, offset: data.endIndex, reason: "missing diff header")
            }
            if !startsWith(first, in: data, "diff --git ") {
                patch.isCombined = true
                // A combined body's lines start with a two-column prefix, never with "diff --".
                while let line = peek(), !startsWith(line, in: data, "diff --") { index += 1 }
                return patch
            }
            try header(&patch)
            while let line = peek(), startsWith(line, in: data, "@@ ") {
                if patch.isBinary {
                    throw ParseError(
                        parser: PatchParser.name, offset: line.lowerBound, reason: "hunk in a binary patch")
                }
                index += 1
                patch.hunks.append(try hunk(line))
            }
            if let line = peek(), !startsWith(line, in: data, "diff --") {
                throw ParseError(
                    parser: PatchParser.name, offset: line.lowerBound, reason: "unexpected line after hunk")
            }
            patch.submodule = PatchParser.submodule(patch, data: data)
            return patch
        }

        mutating func header(_ patch: inout FilePatch) throws {
            while let line = peek(), !startsWith(line, in: data, "@@ "), !startsWith(line, in: data, "diff --") {
                index += 1
                func value(after prefix: String) -> Data? {
                    startsWith(line, in: data, prefix)
                        ? data[(line.lowerBound + prefix.utf8.count)..<line.upperBound] : nil
                }
                if let mode = value(after: "old mode ") {
                    patch.oldMode = try PatchParser.mode(mode, at: line.lowerBound)
                } else if let mode = value(after: "new mode ") {
                    patch.newMode = try PatchParser.mode(mode, at: line.lowerBound)
                } else if let mode = value(after: "new file mode ") {
                    patch.isNewFile = true
                    patch.newMode = try PatchParser.mode(mode, at: line.lowerBound)
                } else if let mode = value(after: "deleted file mode ") {
                    patch.isDeletedFile = true
                    patch.oldMode = try PatchParser.mode(mode, at: line.lowerBound)
                } else if let path = value(after: "rename from ") {
                    patch.renameFrom = GitPath(raw: try PatchParser.unquote(path, at: line.lowerBound))
                } else if let path = value(after: "rename to ") {
                    patch.renameTo = GitPath(raw: try PatchParser.unquote(path, at: line.lowerBound))
                } else if let path = value(after: "copy from ") {
                    patch.copyFrom = GitPath(raw: try PatchParser.unquote(path, at: line.lowerBound))
                } else if let path = value(after: "copy to ") {
                    patch.copyTo = GitPath(raw: try PatchParser.unquote(path, at: line.lowerBound))
                } else if let score = value(after: "similarity index ") {
                    patch.similarity = try PatchParser.percent(score, at: line.lowerBound)
                } else if let index = value(after: "index ") {
                    // `index <oid>..<oid>[ <mode>]`: the mode is the only part used (submodules).
                    let parts = index.split(separator: 0x20)
                    if parts.count == 2, patch.newMode == nil, patch.oldMode == nil {
                        let mode = try PatchParser.mode(Data(parts[1]), at: line.lowerBound)
                        patch.oldMode = mode
                        patch.newMode = mode
                    }
                } else if let path = value(after: "--- ") {
                    patch.oldPath = try PatchParser.diffPath(path, at: line.lowerBound)
                } else if let path = value(after: "+++ ") {
                    patch.newPath = try PatchParser.diffPath(path, at: line.lowerBound)
                } else if startsWith(line, in: data, "Binary files ") {
                    patch.isBinary = true
                }
                // Anything else (`dissimilarity index`, future headers) is ignored.
            }
        }

        mutating func hunk(_ headerLine: Range<Data.Index>) throws -> PatchHunk {
            let (oldStart, oldCount, newStart, newCount, section) = try PatchParser.hunkHeader(
                data[headerLine], at: headerLine.lowerBound)
            var oldLeft = oldCount
            var newLeft = newCount
            var oldNumber = oldStart
            var newNumber = newStart
            var lines: [PatchLine] = []
            lines.reserveCapacity(oldCount + newCount)
            while oldLeft > 0 || newLeft > 0 {
                guard let line = next() else {
                    if truncated { break }
                    throw ParseError(parser: PatchParser.name, offset: data.endIndex, reason: "hunk ends early")
                }
                let content = line.isEmpty ? data[line] : data[(line.lowerBound + 1)..<line.upperBound]
                // An empty line is an empty context line (`diff.suppressBlankEmpty`).
                let prefix = line.isEmpty ? UInt8(ascii: " ") : data[line.lowerBound]
                switch prefix {
                case UInt8(ascii: " "):
                    guard oldLeft > 0, newLeft > 0 else { throw overflow(line) }
                    lines.append(
                        PatchLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, content: content))
                    oldNumber += 1
                    newNumber += 1
                    oldLeft -= 1
                    newLeft -= 1
                case UInt8(ascii: "-"):
                    guard oldLeft > 0 else { throw overflow(line) }
                    lines.append(PatchLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, content: content))
                    oldNumber += 1
                    oldLeft -= 1
                case UInt8(ascii: "+"):
                    guard newLeft > 0 else { throw overflow(line) }
                    lines.append(PatchLine(kind: .added, oldNumber: nil, newNumber: newNumber, content: content))
                    newNumber += 1
                    newLeft -= 1
                case UInt8(ascii: "\\"):
                    // Only right after a content line: never first, never twice in a row.
                    guard let last = lines.last, last.kind != .noNewline else {
                        throw ParseError(
                            parser: PatchParser.name, offset: line.lowerBound, reason: "misplaced no-newline marker")
                    }
                    lines.append(PatchLine(kind: .noNewline, oldNumber: nil, newNumber: nil, content: content))
                default:
                    throw ParseError(
                        parser: PatchParser.name, offset: line.lowerBound, reason: "unexpected line in hunk")
                }
            }
            // `\ No newline at end of file` for the hunk's last line.
            if let line = peek(), !line.isEmpty, data[line.lowerBound] == UInt8(ascii: "\\") {
                index += 1
                lines.append(
                    PatchLine(
                        kind: .noNewline, oldNumber: nil, newNumber: nil,
                        content: data[(line.lowerBound + 1)..<line.upperBound]))
            }
            return PatchHunk(
                oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, section: section,
                lines: lines)
        }

        private func overflow(_ line: Range<Data.Index>) -> ParseError {
            ParseError(
                parser: PatchParser.name, offset: line.lowerBound, reason: "more lines than the hunk header says")
        }
    }

    // MARK: Fields

    /// `@@ -a[,b] +c[,d] @@[ section]`.
    static func hunkHeader(_ line: Data, at offset: Int) throws -> (Int, Int, Int, Int, Data) {
        let bytes = [UInt8](line)
        func fail() -> ParseError { ParseError(parser: name, offset: offset, reason: "malformed hunk header") }
        guard bytes.starts(with: Array("@@ -".utf8)) else { throw fail() }
        var position = 4
        func number() throws -> Int {
            let start = position
            while position < bytes.count, (0x30...0x39).contains(bytes[position]) { position += 1 }
            // At most 9 digits: no overflow, and no real file has a billion lines.
            guard position > start, position - start <= 9 else { throw fail() }
            return bytes[start..<position].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        func range() throws -> (Int, Int) {
            let start = try number()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ",") else { return (start, 1) }
            position += 1
            return (start, try number())
        }
        let (oldStart, oldCount) = try range()
        guard bytes[position...].starts(with: Array(" +".utf8)) else { throw fail() }
        position += 2
        let (newStart, newCount) = try range()
        guard bytes[position...].starts(with: Array(" @@".utf8)) else { throw fail() }
        position += 3
        if position < bytes.count {
            guard bytes[position] == UInt8(ascii: " ") else { throw fail() }
            position += 1
        }
        return (oldStart, oldCount, newStart, newCount, Data(bytes[position...]))
    }

    /// Six octal digits.
    static func mode(_ text: Data, at offset: Int) throws -> String {
        guard text.count == 6, text.allSatisfy({ (0x30...0x37).contains($0) }) else {
            throw ParseError(parser: name, offset: offset, reason: "malformed mode")
        }
        return String(decoding: text, as: UTF8.self)
    }

    static func percent(_ text: Data, at offset: Int) throws -> Int {
        guard text.last == UInt8(ascii: "%"), (2...4).contains(text.count),
            text.dropLast().allSatisfy({ (0x30...0x39).contains($0) }),
            let value = Int(String(decoding: text.dropLast(), as: UTF8.self)), value <= 100
        else { throw ParseError(parser: name, offset: offset, reason: "malformed similarity") }
        return value
    }

    /// The path of a `---`/`+++` line: `/dev/null`, or `a/<path>` / `b/<path>`, possibly quoted. git appends a TAB
    /// when the name contains a space.
    static func diffPath(_ text: Data, at offset: Int) throws -> GitPath? {
        var raw = try unquote(text.last == 0x09 ? text.dropLast() : text, at: offset)
        if raw == Data("/dev/null".utf8) { return nil }
        if raw.starts(with: Data("a/".utf8)) || raw.starts(with: Data("b/".utf8)) { raw = raw.dropFirst(2) }
        return GitPath(raw: Data(raw))
    }

    /// C-style quoting as git writes it (`quote_c_style`): `"…"` with `\a \b \t \n \v \f \r \" \\` and `\ooo`.
    /// Unquoted text is returned as is.
    static func unquote(_ text: Data, at offset: Int) throws -> Data {
        guard text.first == UInt8(ascii: "\"") else { return Data(text) }
        func fail() -> ParseError { ParseError(parser: name, offset: offset, reason: "malformed quoted path") }
        let bytes = [UInt8](text)
        guard bytes.count >= 2, bytes.last == UInt8(ascii: "\"") else { throw fail() }
        var result = Data()
        var position = 1
        let end = bytes.count - 1
        while position < end {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") { throw fail() }
            guard byte == UInt8(ascii: "\\") else {
                result.append(byte)
                position += 1
                continue
            }
            position += 1
            guard position < end else { throw fail() }
            let escaped = bytes[position]
            switch escaped {
            case UInt8(ascii: "a"): result.append(0x07)
            case UInt8(ascii: "b"): result.append(0x08)
            case UInt8(ascii: "t"): result.append(0x09)
            case UInt8(ascii: "n"): result.append(0x0A)
            case UInt8(ascii: "v"): result.append(0x0B)
            case UInt8(ascii: "f"): result.append(0x0C)
            case UInt8(ascii: "r"): result.append(0x0D)
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): result.append(escaped)
            case UInt8(ascii: "0")...UInt8(ascii: "3"):
                guard position + 2 < end,
                    (0x30...0x37).contains(bytes[position + 1]), (0x30...0x37).contains(bytes[position + 2])
                else { throw fail() }
                result.append(
                    ((escaped - 0x30) << 6) | ((bytes[position + 1] - 0x30) << 3) | (bytes[position + 2] - 0x30))
                position += 2
            default:
                throw fail()
            }
            position += 1
        }
        return result
    }

    /// `Subproject commit <oid>[-dirty]` on both sides of a mode-160000 patch.
    static func submodule(_ patch: FilePatch, data: Data) -> FilePatch.SubmoduleChange? {
        guard patch.oldMode == "160000" || patch.newMode == "160000" else { return nil }
        let prefix = Data("Subproject commit ".utf8)
        var old: ObjectID?
        var new: ObjectID?
        for line in patch.hunks.flatMap(\.lines) {
            guard line.content.starts(with: prefix) else {
                if line.kind == .noNewline { continue }
                return nil
            }
            let hex = String(
                decoding: line.content.dropFirst(prefix.count).prefix { $0 != UInt8(ascii: "-") }, as: UTF8.self)
            switch line.kind {
            case .removed: old = ObjectID(hex)
            case .added: new = ObjectID(hex)
            case .context:
                old = ObjectID(hex)
                new = old
            case .noNewline: break
            }
        }
        return FilePatch.SubmoduleChange(old: old, new: new)
    }

    // MARK: Bytes

    /// Line ranges without the LF. A trailing LF does not start an empty line.
    static func splitLines(_ data: Data) -> [Range<Data.Index>] {
        var lines: [Range<Data.Index>] = []
        var start = data.startIndex
        var position = data.startIndex
        while let newline = data[position...].firstIndex(of: 0x0A) {
            lines.append(start..<newline)
            start = data.index(after: newline)
            position = start
        }
        if start < data.endIndex { lines.append(start..<data.endIndex) }
        return lines
    }
}

private func startsWith(_ line: Range<Data.Index>, in data: Data, _ prefix: String) -> Bool {
    let bytes = prefix.utf8
    guard line.count >= bytes.count else { return false }
    return data[line.lowerBound..<(line.lowerBound + bytes.count)].elementsEqual(bytes)
}
