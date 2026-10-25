import Foundation

/// Conservative parser: preserves comments, ordering, whitespace and UTF-8 file contents.
/// Only values in valid quoted key/value records can be edited. Ambiguous records fail closed.
public struct LegacyStrings {
    public struct Pair: Sendable {
        public let key: String
        public let value: String
        public let quotedValueRange: Range<Int> // UTF-8 byte range, includes surrounding quotes
        public let quotedKeyRange: Range<Int>
        public let entryRange: Range<Int>
    }

    public static func parse(_ data: Data) throws -> [Pair] {
        guard String(data: data, encoding: .utf8) != nil else { throw LocalizationFailure.unsupported("Only UTF-8 .strings can be edited safely") }
        let scanner = Scanner(bytes: Array(data))
        return try scanner.parse()
    }

    public static func replaceValue(_ data: Data, key: String, with replacement: String) throws -> Data {
        let entries = try parse(data)
        let matches = entries.filter { $0.key == key }
        guard matches.count == 1, let range = matches.first?.quotedValueRange else {
            throw LocalizationFailure.conflict("Key ‘\(key)’ missing or duplicated; refusing unsafe edit")
        }
        var bytes = Array(data)
        let escaped = escape(replacement)
        bytes.replaceSubrange(range, with: Array(("\"" + escaped + "\"").utf8))
        return Data(bytes)
    }

    public static func appendValue(_ data: Data, key: String, value: String) throws -> Data {
        let entries = try parse(data)
        guard !entries.contains(where: { $0.key == key }) else { throw LocalizationFailure.conflict("Duplicate key: \(key)") }
        var bytes = Array(data)
        if let tail = bytes.last, tail != 10 && tail != 13 { bytes.append(10) }
        bytes.append(contentsOf: Array(("\"" + escape(key) + "\" = \"" + escape(value) + "\";\n").utf8))
        return Data(bytes)
    }

    public static func removeKey(_ data: Data, key: String) throws -> Data {
        let matches = try parse(data).filter { $0.key == key }
        guard matches.count == 1, let span = matches.first?.entryRange else {
            throw LocalizationFailure.conflict("Missing or duplicate key: \(key)")
        }
        var b = Array(data)
        b.removeSubrange(span)
        return Data(b)
    }

    public static func renameKey(_ data: Data, from old: String, to new: String) throws -> Data {
        let entries = try parse(data)
        guard !entries.contains(where: { $0.key == new }),
              let p = entries.first(where: { $0.key == old }), entries.filter({ $0.key == old }).count == 1 else {
            throw LocalizationFailure.conflict("Cannot rename missing, duplicate or conflicting key")
        }
        var b = Array(data)
        b.replaceSubrange(p.quotedKeyRange, with: Array(("\"" + escape(new) + "\"").utf8))
        return Data(b)
    }

    public static func insertComment(_ data: Data, key: String, comment: String) throws -> Data {
        guard !comment.contains("*/") else { throw LocalizationFailure.malformed("Comment cannot contain */") }
        let entries = try parse(data).filter { $0.key == key }
        guard entries.count == 1, let range = entries.first?.entryRange else { throw LocalizationFailure.missing("Key not found") }
        let prefix = "/* " + comment + " */\n"
        var b = Array(data)
        b.insert(contentsOf: Array(prefix.utf8), at: range.lowerBound)
        return Data(b)
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }

    private final class Scanner {
        let b: [UInt8]
        var p = 0
        init(bytes: [UInt8]) { b = bytes }
        var end: Bool { p >= b.count }

        func skip() throws {
            while !end {
                if b[p] == 32 || b[p] == 9 || b[p] == 10 || b[p] == 13 || b[p] == 0xEF && p + 2 < b.count && b[p+1] == 0xBB && b[p+2] == 0xBF {
                    if b[p] == 0xEF { p += 3 } else { p += 1 }
                } else if p + 1 < b.count && b[p] == 47 && b[p+1] == 47 {
                    p += 2
                    while !end && b[p] != 10 { p += 1 }
                } else if p + 1 < b.count && b[p] == 47 && b[p+1] == 42 {
                    p += 2
                    var closed = false
                    while p + 1 < b.count {
                        if b[p] == 42 && b[p+1] == 47 { p += 2; closed = true; break }
                        p += 1
                    }
                    if !closed { throw LocalizationFailure.malformed("Unterminated /* comment */") }
                } else { break }
            }
        }

        func quoted() throws -> (value: String, byteRange: Range<Int>) {
            guard !end && b[p] == 34 else { throw LocalizationFailure.malformed("Expected quoted .strings token at byte \(p)") }
            let begin = p
            p += 1
            var content: [UInt8] = []
            var terminated = false
            while !end {
                let c = b[p]; p += 1
                if c == 34 { terminated = true; break }
                if c == 92 {
                    guard !end else { throw LocalizationFailure.malformed("Trailing escape at byte \(p)") }
                    let n = b[p]; p += 1
                    switch n {
                    case 110: content.append(10)
                    case 114: content.append(13)
                    case 116: content.append(9)
                    case 92: content.append(92)
                    case 34: content.append(34)
                    case 85, 117: // Traditional \Uhhhh UTF-16 escape.
                        guard p+4 <= b.count else { throw LocalizationFailure.malformed("Truncated Unicode escape") }
                        guard let digits = String(bytes: b[p..<p+4], encoding: .ascii),
                              let codepoint = UInt32(digits, radix: 16),
                              let scalar = UnicodeScalar(codepoint) else {
                            throw LocalizationFailure.malformed("Unsupported Unicode escape (including surrogate pair)")
                        }
                        content.append(contentsOf: String(scalar).utf8)
                        p += 4
                    default:
                        throw LocalizationFailure.malformed("Unsupported escape \\ at byte \(p-1): \(n)")
                    }
                } else { content.append(c) }
            }
            guard terminated, let decoded = String(bytes: content, encoding: .utf8) else {
                throw LocalizationFailure.malformed("Unterminated or non-UTF8 string at byte \(begin)")
            }
            return (decoded, begin..<p)
        }

        func parse() throws -> [Pair] {
            var out: [Pair] = []
            while true {
                try skip()
                if end { break }
                let starting = p
                let keyToken = try quoted()
                let key = keyToken.value
                try skip()
                guard !end && b[p] == 61 else { throw LocalizationFailure.malformed("Expected = after key ‘\(key)’") }
                p += 1
                try skip()
                let value = try quoted()
                try skip()
                guard !end && b[p] == 59 else { throw LocalizationFailure.malformed("Expected ; after key ‘\(key)’") }
                p += 1
                out.append(Pair(key: key, value: value.value, quotedValueRange: value.byteRange, quotedKeyRange: keyToken.byteRange, entryRange: starting..<p))
            }
            return out
        }
    }
}
