import Foundation

public struct SavePreview {
    public let url: URL
    public let original: Data
    public let updated: Data
    public let before: String
    public let after: String
    public let fullRewrite: Bool

    public var changedByteCount: Int { abs(updated.count - original.count) }
    public var isChanged: Bool { original != updated }
}

public enum WorkspaceWriter {
    /// Edits an existing value only. Adding missing keys/locales and renaming keys are deliberately disabled in MVP.
    public static func preview(document: LocalizedDocument, key: String, variant: String = "", language: String, newValue: String) throws -> SavePreview {
        let original = try Data(contentsOf: document.url)
        var updated: Data
        var oldValue: String
        let rewrite: Bool
        switch document.format {
        case .strings:
            guard document.language == language, variant.isEmpty else {
                throw LocalizationFailure.unsupported("This .strings file does not contain the requested locale/variant")
            }
            let entries = try LegacyStrings.parse(original).filter { $0.key == key }
            guard entries.count == 1, let entry = entries.first else { throw LocalizationFailure.conflict("Missing or duplicate key") }
            oldValue = entry.value
            updated = try LegacyStrings.replaceValue(original, key: key, with: newValue)
            rewrite = false
        case .xcstrings:
            let path = ["strings", key, "localizations", language] + (variant.isEmpty ? [] : variant.components(separatedBy: "/")) + ["stringUnit", "value"]
            let hits = try JSONText.tokens(in: original).filter { $0.path == path }
            guard hits.count == 1, let token = hits.first else {
                throw LocalizationFailure.unsupported("Missing locale/variant: adding catalog structure is not in MVP")
            }
            oldValue = token.value
            updated = try JSONText.replace(original, path: path, with: newValue)
            rewrite = false
        case .stringsdict:
            guard document.language == language else { throw LocalizationFailure.unsupported("Wrong .stringsdict locale") }
            guard let input = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any] else {
                throw LocalizationFailure.malformed("Invalid stringsdict")
            }
            let path = [key] + variant.components(separatedBy: "/")
            guard let value = getNested(input, path: path) as? String else {
                throw LocalizationFailure.unsupported("Missing stringsdict value: \(path)")
            }
            oldValue = value
            guard let replacement = setNested(input, path: path, value: newValue) else { throw LocalizationFailure.malformed("Cannot change stringsdict") }
            updated = try PropertyListSerialization.data(fromPropertyList: replacement, format: .xml, options: 0)
            rewrite = true // XML plist serializer normalizes formatting. Always preview before commit.
        }
        return SavePreview(url: document.url, original: original, updated: updated, before: oldValue, after: newValue, fullRewrite: rewrite)
    }

    public static func commit(_ preview: SavePreview, workspaceRoot: URL) throws {
        guard preview.isChanged else { return }
        // Compare-on-save prevents overwriting a change made by Xcode or another editor.
        let current = try Data(contentsOf: preview.url)
        guard current == preview.original else { throw LocalizationFailure.conflict("File changed externally; reopen and retry") }
        let root = workspaceRoot.standardizedFileURL.path
        let target = preview.url.standardizedFileURL.path
        guard target.hasPrefix(root + "/") else { throw LocalizationFailure.conflict("File is outside the workspace") }
        let backupDirectory = workspaceRoot.appendingPathComponent(".localization-workbench-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let fileID = UUID().uuidString
        let backup = backupDirectory.appendingPathComponent("\(preview.url.lastPathComponent).\(fileID).bak")
        try preview.original.write(to: backup, options: .atomic)
        try preview.updated.write(to: preview.url, options: .atomic)
    }

    private static func getNested(_ dict: [String: Any], path: [String]) -> Any? {
        var current: Any = dict
        for item in path {
            guard let d = current as? [String: Any], let next = d[item] else { return nil }
            current = next
        }
        return current
    }
    private static func setNested(_ dict: [String: Any], path: [String], value: String) -> [String: Any]? {
        guard let first = path.first else { return nil }
        var copy = dict
        if path.count == 1 {
            guard copy[first] is String else { return nil }
            copy[first] = value
        } else {
            guard let sub = copy[first] as? [String: Any],
                  let replaced = setNested(sub, path: Array(path.dropFirst()), value: value) else { return nil }
            copy[first] = replaced
        }
        return copy
    }
}
