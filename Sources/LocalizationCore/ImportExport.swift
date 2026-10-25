import Foundation

/// Exchange format is one row per target-language value, preserving multiline values.
/// Header: group,key,variant,language,value. Non-CSV project structure is never inferred from untrusted input.
public enum TranslationExchange {
    public static let header = ["group", "key", "variant", "language", "value"]

    public static func export(snapshot: WorkspaceSnapshot, group: String? = nil) -> String {
        var output = [header.map(escape).joined(separator: ",")]
        for row in snapshot.rows where group == nil || row.group == group {
            for lang in row.values.keys.sorted() {
                let values = [row.group, row.key, row.variant, lang, row.values[lang] ?? ""]
                output.append(values.map(escape).joined(separator: ","))
            }
        }
        return output.joined(separator: "\r\n") + "\r\n"
    }

    public static func edits(fromCSV csv: String, snapshot: WorkspaceSnapshot) throws -> [WorkspaceEdit] {
        let fields = try parse(csv)
        guard let first = fields.first, first == header else {
            throw LocalizationFailure.malformed("CSV header must be: group,key,variant,language,value")
        }
        let groups = Set(snapshot.documents.map(\.group))
        let keys = Dictionary(grouping: snapshot.rows, by: \.group).mapValues { Set($0.map(\.key)) }
        var result: [WorkspaceEdit] = []
        var seen = Set<String>()
        for line in fields.dropFirst() {
            guard line.count == 5 else { throw LocalizationFailure.malformed("CSV requires exactly five fields per record") }
            let (group, key, variant, lang, value) = (line[0],line[1],line[2],line[3],line[4])
            guard groups.contains(group), keys[group]?.contains(key) == true else {
                throw LocalizationFailure.missing("Unknown group/key in CSV: \(group) / \(key)")
            }
            guard !lang.isEmpty else { throw LocalizationFailure.malformed("Empty language in CSV") }
            let id = [group,key,variant,lang].map { "\($0.count):\($0)" }.joined(separator: "|")
            guard seen.insert(id).inserted else { throw LocalizationFailure.malformed("Duplicate row in CSV: \(key) / \(lang)") }
            let existing = snapshot.rows.first { $0.group == group && $0.key == key && $0.variant == variant }
            guard existing != nil else { throw LocalizationFailure.missing("Variant does not exist in workspace: \(key) / \(variant)") }
            if existing?.values[lang] != value {
                result.append(.set(group: group, key: key, variant: variant, language: lang, value: value))
            }
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func parse(_ text: String) throws -> [[String]] {
        // RFC 4180-compatible parser with CRLF, embedded commas, quotes and newlines.
        // Swift Character combines CRLF into one grapheme; scan Unicode scalars instead.
        let chars = text.unicodeScalars.map { Character(String($0)) }
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var i = 0, afterQuote = false
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; afterQuote = true }
                } else { field.append(ch) }
            } else if ch == "," {
                row.append(field); field = ""; afterQuote = false
            } else if ch == "\n" || ch == "\r" {
                row.append(field); field = ""; rows.append(row); row = []; afterQuote = false
                if ch == "\r" && i + 1 < chars.count && chars[i+1] == "\n" { i += 1 }
            } else if ch == "\"" && field.isEmpty && !afterQuote {
                quoted = true
            } else if afterQuote {
                throw LocalizationFailure.malformed("Unexpected characters after quoted CSV field at index \(i): \(ch)")
            } else { field.append(ch) }
            i += 1
        }
        guard !quoted else { throw LocalizationFailure.malformed("Unclosed quoted CSV field") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

public enum WorkspaceDiagnostics {
    public static func summary(_ snapshot: WorkspaceSnapshot, group: String? = nil) -> (total: Int, missing: Int, warnings: Int, errors: Int) {
        let rows = snapshot.rows.filter { group == nil || $0.group == group }
        let issues = snapshot.issues.filter { group == nil || $0.file == group }
        let missing = rows.reduce(0) { sum, row in
            // Only compare languages actually present in the same group.
            let groupLocales = Set(snapshot.documents.filter { $0.group == row.group }.compactMap(\.language))
            let langs = groupLocales.isEmpty ? Set(snapshot.languages) : groupLocales
            return sum + langs.filter { (row.values[$0] ?? "").isEmpty }.count
        }
        return (rows.count, missing, issues.filter { $0.severity == .warning }.count, issues.filter { $0.severity == .error }.count)
    }

    public static func checkFormat(_ source: String, target: String) -> Bool {
        // Match printf token type and position; `%%` is not a placeholder.
        let pattern = #"%(?:[1-9]\d*\$)?[-+# 0']*\d*(?:\.\d+)?(?:hh|ll|h|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
        func spec(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
        }
        return spec(source) == spec(target)
    }
}
