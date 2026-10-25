import Foundation

/// UTF-8 JSON scanner locating existing string-value tokens without reserializing the document.
/// Replacing one token retains every other byte: order, whitespace, metadata and unknown fields.
public struct JSONText {
    public struct StringToken: Sendable {
        public let path: [String]
        public let value: String
        public let span: Range<Int>
    }

    public static func tokens(in data: Data) throws -> [StringToken] {
        try Reader(Array(data)).read()
    }

    public static func replace(_ data: Data, path: [String], with text: String) throws -> Data {
        let candidates = try tokens(in: data).filter { $0.path == path }
        guard candidates.count == 1, let token = candidates.first else {
            throw LocalizationFailure.conflict("Existing JSON string path missing or duplicated: \(path.joined(separator: "/"))")
        }
        let encoded = try JSONEncoder().encode(text)
        var bytes = Array(data)
        bytes.replaceSubrange(token.span, with: encoded)
        let result = Data(bytes)
        // Ensure the mutation keeps valid JSON.
        _ = try JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])
        return result
    }

    private final class Reader {
        let b: [UInt8]
        var p = 0
        var out: [StringToken] = []
        init(_ b: [UInt8]) { self.b = b }
        var end: Bool { p >= b.count }

        func ws() { while !end && [32,9,10,13].contains(b[p]) { p += 1 } }
        func expect(_ char: UInt8) throws {
            ws()
            guard !end && b[p] == char else { throw LocalizationFailure.malformed("Invalid JSON punctuation at byte \(p)") }
            p += 1
        }
        func quoted() throws -> (String, Range<Int>) {
            ws()
            let start = p
            guard !end && b[p] == 34 else { throw LocalizationFailure.malformed("Expected JSON string at byte \(p)") }
            p += 1
            var finished = false
            while !end {
                let c = b[p]; p += 1
                if c == 92 { guard !end else { break }; p += 1 }
                else if c == 34 { finished = true; break }
            }
            guard finished else { throw LocalizationFailure.malformed("Unterminated JSON string") }
            let span = start..<p
            let string = try JSONDecoder().decode(String.self, from: Data(b[span]))
            return (string, span)
        }
        func value(_ path: [String], depth: Int) throws {
            guard depth < 96 else { throw LocalizationFailure.malformed("JSON nesting too deep") }
            ws()
            guard !end else { throw LocalizationFailure.malformed("Unexpected end of JSON") }
            if b[p] == 123 {
                p += 1; ws()
                if !end && b[p] == 125 { p += 1; return }
                var seenKeys = Set<String>()
                while true {
                    let k = try quoted().0
                    guard seenKeys.insert(k).inserted else {
                        throw LocalizationFailure.malformed("Duplicate JSON object key at \(path.joined(separator: "/")): \(k)")
                    }
                    try expect(58)
                    try value(path + [k], depth: depth+1)
                    ws()
                    if !end && b[p] == 125 { p += 1; break }
                    try expect(44)
                }
            } else if b[p] == 91 {
                p += 1; ws()
                if !end && b[p] == 93 { p += 1; return }
                var i = 0
                while true {
                    try value(path + [String(i)], depth: depth+1)
                    i += 1
                    ws()
                    if !end && b[p] == 93 { p += 1; break }
                    try expect(44)
                }
            } else if b[p] == 34 {
                let (str, span) = try quoted()
                out.append(StringToken(path: path, value: str, span: span))
            } else {
                let start = p
                while !end && ![32,9,10,13,44,93,125].contains(b[p]) { p += 1 }
                guard p > start else { throw LocalizationFailure.malformed("Empty JSON literal at byte \(p)") }
                let literal = String(decoding: b[start..<p], as: UTF8.self)
                guard literal == "true" || literal == "false" || literal == "null" || Double(literal) != nil else {
                    throw LocalizationFailure.malformed("Invalid JSON literal \(literal)")
                }
            }
        }
        func read() throws -> [StringToken] {
            try value([], depth: 0)
            ws()
            guard end else { throw LocalizationFailure.malformed("Trailing JSON data") }
            return out
        }
    }
}
