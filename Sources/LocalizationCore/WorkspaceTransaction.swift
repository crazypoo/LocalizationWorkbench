import Foundation

/// Independent, file-backed editing engine. Its inputs are data, not UI state.
/// Mutation previews do not touch the original project.
public enum WorkspaceEdit: Hashable, Sendable {
    case set(group: String, key: String, variant: String, language: String, value: String)
    case addKey(group: String, key: String)
    case addPlural(group: String, key: String, variable: String, valueType: String)
    case renameKey(group: String, old: String, new: String)
    case deleteKey(group: String, key: String)
    case addLanguage(group: String, language: String)
    case comment(group: String, key: String, text: String)

    public var summary: String {
        switch self {
        case let .set(g,k,v,l,_): return "Edit \(g) · \(k) \(v) [\(l)]"
        case let .addKey(g,k): return "Add key \(k) · \(g)"
        case let .addPlural(g,k,v,_): return "Add plural key \(k) (\(v)) · \(g)"
        case let .renameKey(g,a,b): return "Rename \(a) → \(b) · \(g)"
        case let .deleteKey(g,k): return "Delete \(k) · \(g)"
        case let .addLanguage(g,l): return "Add \(l) · \(g)"
        case let .comment(g,k,_): return "Comment \(k) · \(g)"
        }
    }
}

public struct FileDelta: Sendable, Identifiable {
    public let url: URL
    public let format: LocalizationFormat
    public let original: Data?
    public let updated: Data
    public let rewrite: Bool
    public var id: String { url.path }
    public var originalText: String { original.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public var updatedText: String { String(data: updated, encoding: .utf8) ?? "<Binary data>" }
    public var added: Bool { original == nil }
}

public struct WorkspaceChangeSet: Sendable {
    public let root: URL
    public let edits: [WorkspaceEdit]
    public let files: [FileDelta]
    public var byteDelta: Int { files.reduce(0) { $0 + $1.updated.count - ($1.original?.count ?? 0) } }
}

public enum WorkspaceTransactions {
    private struct WorkingFile {
        var document: LocalizedDocument
        var original: Data?
        var data: Data
        var rewrite = false
    }

    /// The builder works on a scratch copy. All modifications remain staged until commit.
    public static func preview(snapshot: WorkspaceSnapshot, edits: [WorkspaceEdit]) throws -> WorkspaceChangeSet {
        let root = snapshot.root.standardizedFileURL
        var working: [URL: WorkingFile] = [:]
        for doc in snapshot.documents {
            let data = try Data(contentsOf: doc.url)
            guard let baseline = snapshot.baselineFiles[doc.url.path], data == baseline else {
                throw LocalizationFailure.conflict("File changed since project scan: \(doc.url.lastPathComponent). Reload before editing.")
            }
            working[doc.url.standardizedFileURL] = WorkingFile(document: doc, original: data, data: data)
        }
        for edit in edits {
            let group = edit.groupName
            let groupDocs = working.keys.sorted(by: { $0.path < $1.path }).compactMap { working[$0]?.document }.filter { $0.group == group }
            guard !groupDocs.isEmpty else { throw LocalizationFailure.missing("Unknown file group: \(group)") }
            switch edit {
            case let .set(_, key, variant, language, value):
                guard !key.isEmpty, !language.isEmpty else { throw LocalizationFailure.malformed("Key and language cannot be empty") }
                if let catalog = groupDocs.first(where: { $0.format == .xcstrings }) {
                    try mutate(catalog, &working) { data in
                        try catalogSet(data: data, key: key, variant: variant, language: language, value: value)
                    }
                } else if let doc = groupDocs.first(where: { $0.language == language }) {
                    switch doc.format {
                    case .strings:
                        guard variant.isEmpty else { throw LocalizationFailure.unsupported(".strings has no variants") }
                        try mutate(doc, &working) { data in
                            let pairs = try LegacyStrings.parse(data)
                            return (try pairs.contains(where: { $0.key == key })
                                ? LegacyStrings.replaceValue(data, key: key, with: value)
                                : LegacyStrings.appendValue(data, key: key, value: value), false)
                        }
                    case .stringsdict:
                        guard !variant.isEmpty else { throw LocalizationFailure.unsupported("Use a plural/width leaf path for stringsdict") }
                        try mutate(doc, &working) { data in
                            var root = try plist(data)
                            try plistSet(&root, path: [key] + variant.split(separator: "/").map(String.init), value: value)
                            return (try serializePlist(root), true)
                        }
                    case .xcstrings: break
                    }
                } else {
                    guard let template = groupDocs.first(where: { $0.format == .strings && $0.language != nil }), variant.isEmpty else {
                        throw LocalizationFailure.unsupported("A target language file does not exist. Add the language first or use .xcstrings")
                    }
                    let newDoc = try derivedDocument(template: template, language: language, root: root)
                    guard working[newDoc.url] == nil else { throw LocalizationFailure.conflict("File already exists") }
                    let data = try LegacyStrings.appendValue(Data(), key: key, value: value)
                    working[newDoc.url] = WorkingFile(document: newDoc, original: nil, data: data)
                }
            case let .addKey(_, key):
                guard !key.isEmpty else { throw LocalizationFailure.malformed("Key cannot be blank") }
                for doc in groupDocs {
                    switch doc.format {
                    case .strings:
                        try mutate(doc, &working) { data in (try LegacyStrings.appendValue(data, key: key, value: ""), false) }
                    case .xcstrings:
                        try mutate(doc, &working) { data in
                            var obj = try catalogJSON(data)
                            var strings = obj["strings"] as? [String: Any] ?? [:]
                            guard strings[key] == nil else { throw LocalizationFailure.conflict("Duplicate key: \(key)") }
                            strings[key] = ["extractionState": "manual", "localizations": [String: Any]()]
                            obj["strings"] = strings
                            return (try serializeJSON(obj), true)
                        }
                    case .stringsdict:
                        throw LocalizationFailure.unsupported("Create a .stringsdict rule with its mandatory plural metadata in Xcode, then edit its variants here")
                    }
                }
            case let .addPlural(_, key, variable, valueType):
                guard !key.isEmpty, !variable.isEmpty,
                      variable.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                      Set(["d", "i", "u", "ld", "lld", "f"]).contains(valueType) else {
                    throw LocalizationFailure.malformed("Provide a valid plural key, variable name and numeric value type")
                }
                guard groupDocs.allSatisfy({ $0.format == .stringsdict }) else {
                    throw LocalizationFailure.unsupported("Add plural rules only to .stringsdict resources")
                }
                for doc in groupDocs {
                    try mutate(doc, &working) { data in
                        var obj = try plist(data)
                        guard obj[key] == nil else { throw LocalizationFailure.conflict("Duplicate plural key: \(key)") }
                        obj[key] = [
                            "NSStringLocalizedFormatKey": "%#@\(variable)@",
                            variable: ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": valueType, "other": ""]
                        ] as [String: Any]
                        return (try serializePlist(obj), true)
                    }
                }
            case let .renameKey(_, old, new):
                guard !old.isEmpty, !new.isEmpty, old != new else { throw LocalizationFailure.malformed("Provide two different non-empty keys") }
                for doc in groupDocs {
                    switch doc.format {
                    case .strings:
                        let pairs = try LegacyStrings.parse(working[doc.url]!.data)
                        if pairs.contains(where: { $0.key == old }) {
                            try mutate(doc, &working) { data in (try LegacyStrings.renameKey(data, from: old, to: new), false) }
                        }
                    case .stringsdict:
                        try mutate(doc, &working) { data in
                            var obj = try plist(data)
                            guard obj[new] == nil else { throw LocalizationFailure.conflict("Duplicate target key") }
                            if let value = obj.removeValue(forKey: old) { obj[new] = value }
                            return (try serializePlist(obj), true)
                        }
                    case .xcstrings:
                        try mutate(doc, &working) { data in
                            var obj = try catalogJSON(data)
                            var table = obj["strings"] as? [String: Any] ?? [:]
                            guard table[new] == nil else { throw LocalizationFailure.conflict("Duplicate target key") }
                            guard let value = table.removeValue(forKey: old) else { throw LocalizationFailure.missing("Missing key: \(old)") }
                            table[new] = value; obj["strings"] = table
                            return (try serializeJSON(obj), true)
                        }
                    }
                }
            case let .deleteKey(_, key):
                for doc in groupDocs {
                    switch doc.format {
                    case .strings:
                        if try LegacyStrings.parse(working[doc.url]!.data).contains(where: { $0.key == key }) {
                            try mutate(doc, &working) { data in (try LegacyStrings.removeKey(data, key: key), false) }
                        }
                    case .stringsdict:
                        try mutate(doc, &working) { data in
                            var obj = try plist(data); obj.removeValue(forKey: key)
                            return (try serializePlist(obj), true)
                        }
                    case .xcstrings:
                        try mutate(doc, &working) { data in
                            var obj = try catalogJSON(data)
                            var table = obj["strings"] as? [String: Any] ?? [:]
                            table.removeValue(forKey: key); obj["strings"] = table
                            return (try serializeJSON(obj), true)
                        }
                    }
                }
            case let .addLanguage(_, language):
                guard !language.isEmpty, language.range(of: #"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
                    throw LocalizationFailure.malformed("Invalid locale identifier: \(language)")
                }
                if let catalog = groupDocs.first(where: { $0.format == .xcstrings }) {
                    try mutate(catalog, &working) { data in
                        var obj = try catalogJSON(data)
                        var strings = obj["strings"] as? [String: Any] ?? [:]
                        for (key, raw) in strings {
                            var entry = raw as? [String: Any] ?? [:]
                            var localizations = entry["localizations"] as? [String: Any] ?? [:]
                            if localizations[language] == nil { localizations[language] = ["stringUnit": ["state": "new", "value": ""]] }
                            entry["localizations"] = localizations; strings[key] = entry
                        }
                        obj["strings"] = strings
                        return (try serializeJSON(obj), true)
                    }
                } else {
                    guard let template = groupDocs.first(where: { ($0.format == .strings || $0.format == .stringsdict) && $0.language != nil }) else {
                        throw LocalizationFailure.unsupported("Cannot derive a new localized file from this resource")
                    }
                    guard !groupDocs.contains(where: { $0.language == language }) else { throw LocalizationFailure.conflict("Language \(language) already exists") }
                    let doc = try derivedDocument(template: template, language: language, root: root)
                    let bytes: Data
                    if template.format == .strings {
                        let entries = try LegacyStrings.parse(working[template.url]!.data)
                        var result = Data()
                        for pair in entries { result = try LegacyStrings.appendValue(result, key: pair.key, value: "") }
                        bytes = result
                    } else {
                        let dict = try plist(working[template.url]!.data)
                        bytes = try serializePlist(blankPlurals(dict))
                    }
                    working[doc.url] = WorkingFile(document: doc, original: nil, data: bytes, rewrite: template.format == .stringsdict)
                }
            case let .comment(_, key, text):
                for doc in groupDocs {
                    switch doc.format {
                    case .strings:
                        if try LegacyStrings.parse(working[doc.url]!.data).contains(where: { $0.key == key }) {
                            try mutate(doc, &working) { data in (try LegacyStrings.insertComment(data, key: key, comment: text), false) }
                        }
                    case .xcstrings:
                        try mutate(doc, &working) { data in
                            var obj = try catalogJSON(data)
                            var entries = obj["strings"] as? [String: Any] ?? [:]
                            guard var entry = entries[key] as? [String: Any] else { throw LocalizationFailure.missing("Missing key") }
                            entry["comment"] = text; entries[key] = entry; obj["strings"] = entries
                            return (try serializeJSON(obj), true)
                        }
                    case .stringsdict: throw LocalizationFailure.unsupported("Comments in .stringsdict require a metadata-preserving XML editor")
                    }
                }
            }
        }
        let files = working.values.compactMap { file -> FileDelta? in
            guard file.original != file.data else { return nil }
            return FileDelta(url: file.document.url, format: file.document.format, original: file.original, updated: file.data, rewrite: file.rewrite)
        }.sorted { $0.url.path < $1.url.path }
        return WorkspaceChangeSet(root: root, edits: edits, files: files)
    }

    /// Two-phase consistency guard and best-effort rollback. Writes are backed up outside source folders.
    public static func commit(_ set: WorkspaceChangeSet) throws {
        let fm = FileManager.default
        let root = set.root.standardizedFileURL.resolvingSymlinksInPath().path
        guard !set.files.isEmpty else { return }
        for delta in set.files {
            let target = delta.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard target.hasPrefix(root + "/") else { throw LocalizationFailure.conflict("Refusing to write outside the workspace: \(target)") }
            let exists = fm.fileExists(atPath: delta.url.path)
            guard exists == (delta.original != nil) else { throw LocalizationFailure.conflict("File created or removed externally: \(target)") }
            if let original = delta.original {
                guard try Data(contentsOf: delta.url) == original else {
                    throw LocalizationFailure.conflict("File changed externally: \(delta.url.lastPathComponent). Reload first.")
                }
            }
        }
        let backup = set.root.appendingPathComponent(".localization-workbench-backups", isDirectory: true)
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for (index, delta) in set.files.enumerated() {
            let name = String(format: "%04d", index) + "-" + delta.url.lastPathComponent + ".bak"
            if let original = delta.original {
                try original.write(to: backup.appendingPathComponent(name), options: .atomic)
            }
            records.append(["relativePath": String(delta.url.path.dropFirst(set.root.path.count + 1)),
                            "backupFile": delta.original == nil ? NSNull() : name as Any,
                            "created": delta.original == nil])
        }
        let manifest: [String: Any] = ["version": 1, "workspaceRoot": set.root.path,
                                       "createdAt": ISO8601DateFormatter().string(from: Date()), "files": records]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: backup.appendingPathComponent("manifest.json"), options: .atomic)
        var written: [FileDelta] = []
        do {
            for delta in set.files {
                try fm.createDirectory(at: delta.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try delta.updated.write(to: delta.url, options: .atomic)
                written.append(delta)
            }
        } catch {
            for delta in written.reversed() {
                if let original = delta.original { try? original.write(to: delta.url, options: .atomic) }
                else { try? fm.removeItem(at: delta.url) }
            }
            throw LocalizationFailure.conflict("Save failed (automatic rollback attempted): \(error.localizedDescription). Backup at \(backup.path)")
        }
    }

    private static func mutate(_ doc: LocalizedDocument, _ working: inout [URL: WorkingFile], operation: (Data) throws -> (Data, Bool)) throws {
        guard var w = working[doc.url.standardizedFileURL] else { throw LocalizationFailure.missing("Missing file: \(doc.url.path)") }
        let (next, rewrite) = try operation(w.data)
        w.data = next; w.rewrite = w.rewrite || rewrite
        working[doc.url.standardizedFileURL] = w
    }

    private static func derivedDocument(template: LocalizedDocument, language: String, root: URL) throws -> LocalizedDocument {
        guard let old = template.language, template.url.deletingLastPathComponent().lastPathComponent == old + ".lproj" else {
            throw LocalizationFailure.unsupported("Cannot derive a new .lproj path for \(template.url.lastPathComponent)")
        }
        let parent = template.url.deletingLastPathComponent().deletingLastPathComponent()
        let target = parent.appendingPathComponent(language + ".lproj", isDirectory: true).appendingPathComponent(template.url.lastPathComponent).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw LocalizationFailure.conflict("Invalid target path") }
        return LocalizedDocument(url: target, format: template.format, group: template.group, language: language)
    }

    private static func catalogJSON(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], obj["strings"] is [String: Any] else {
            throw LocalizationFailure.malformed("Invalid .xcstrings root")
        }
        return obj
    }
    private static func serializeJSON(_ obj: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(obj) else { throw LocalizationFailure.malformed("Invalid catalog object") }
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }
    private static func catalogSet(data: Data, key: String, variant: String, language: String, value: String) throws -> (Data, Bool) {
        let suffix = variant.isEmpty ? ["stringUnit", "value"] : variant.split(separator: "/").map(String.init) + ["stringUnit", "value"]
        let path = ["strings", key, "localizations", language] + suffix
        let found = try JSONText.tokens(in: data).filter { $0.path == path }
        if found.count == 1 {
            var updated = try JSONText.replace(data, path: path, with: value)
            let statePath = Array(path.dropLast()) + ["state"]
            if let state = try JSONText.tokens(in: updated).first(where: { $0.path == statePath }),
               state.value == "new" {
                updated = try JSONText.replace(updated, path: statePath, with: "translated")
            }
            return (updated, false)
        }
        guard found.isEmpty else { throw LocalizationFailure.conflict("Ambiguous catalog entry") }
        var obj = try catalogJSON(data)
        var strings = obj["strings"] as? [String: Any] ?? [:]
        guard var entry = strings[key] as? [String: Any] else { throw LocalizationFailure.missing("Missing catalog key: \(key)") }
        var locales = entry["localizations"] as? [String: Any] ?? [:]
        var localization = locales[language] as? [String: Any] ?? [:]
        if variant.isEmpty {
            localization["stringUnit"] = ["state": "translated", "value": value]
        } else {
            let parts = variant.split(separator: "/").map(String.init)
            guard parts.first == "variations", parts.count >= 3 else { throw LocalizationFailure.unsupported("Unrecognized catalog variant path") }
            try setNestedJSON(&localization, path: parts + ["stringUnit", "value"], value: value)
        }
        locales[language] = localization; entry["localizations"] = locales; strings[key] = entry; obj["strings"] = strings
        return (try serializeJSON(obj), true)
    }
    private static func setNestedJSON(_ obj: inout [String: Any], path: [String], value: String) throws {
        guard let head = path.first else { return }
        if path.count == 1 { obj[head] = value; return }
        var next = obj[head] as? [String: Any] ?? [:]
        try setNestedJSON(&next, path: Array(path.dropFirst()), value: value)
        if path.count == 2 && head == "stringUnit" && next["state"] == nil { next["state"] = "translated" }
        obj[head] = next
    }
    private static func blankPlurals(_ obj: [String: Any]) -> [String: Any] {
        // Preserve the required plural metadata and localized format template;
        // create blank values rather than incorrectly copying translations.
        var result: [String: Any] = [:]
        for (key, value) in obj {
            if let child = value as? [String: Any] { result[key] = blankPlurals(child) }
            else if value is String {
                result[key] = Set(["NSStringLocalizedFormatKey", "NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"]).contains(key) ? value : ""
            } else { result[key] = value }
        }
        return result
    }

    private static func plist(_ data: Data) throws -> [String: Any] {
        guard let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LocalizationFailure.malformed("Invalid .stringsdict root")
        }
        return obj
    }
    private static func serializePlist(_ obj: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
    }
    private static func plistSet(_ obj: inout [String: Any], path: [String], value: String) throws {
        guard let first = path.first else { throw LocalizationFailure.malformed("Missing .stringsdict path") }
        if path.count == 1 {
            guard obj[first] is String || (Set(["zero", "one", "two", "few", "many", "other"]).contains(first) && obj["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType") else {
                throw LocalizationFailure.unsupported("Cannot create arbitrary .stringsdict metadata")
            }
            obj[first] = value
        } else {
            guard var child = obj[first] as? [String: Any] else { throw LocalizationFailure.missing("Missing dictionary branch: \(first)") }
            try plistSet(&child, path: Array(path.dropFirst()), value: value)
            obj[first] = child
        }
    }
}

private extension WorkspaceEdit {
    var groupName: String {
        switch self {
        case let .set(g,_,_,_,_), let .addKey(g,_), let .addPlural(g,_,_,_), let .renameKey(g,_,_), let .deleteKey(g,_),
             let .addLanguage(g,_), let .comment(g,_,_): return g
        }
    }
}
