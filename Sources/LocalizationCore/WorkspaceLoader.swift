import Foundation

public enum WorkspaceLoader {
    /// Scans a workspace without altering any file or Xcode project metadata.
    public static func load(at chosenURL: URL) throws -> WorkspaceSnapshot {
        let root = (["xcodeproj", "xcworkspace"].contains(chosenURL.pathExtension)) ? chosenURL.deletingLastPathComponent() : chosenURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw LocalizationFailure.missing("Open an existing directory or Xcode project")
        }
        let rootComponents = root.standardizedFileURL.pathComponents
        let ignored = Set([".git", ".build", "Pods", "Carthage", "DerivedData", "build", ".swiftpm", "node_modules", ".localization-workbench-backups"])
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            throw LocalizationFailure.missing("Unable to read workspace directory")
        }
        var docs: [LocalizedDocument] = []
        var baselineFiles: [String: Data] = [:]
        var table: [String: TranslationRow] = [:]
        var issues: [LocalizationIssue] = []
        var languageSet = Set<String>()
        var groupLanguages: [String: Set<String>] = [:]
        var catalogSource: [String: String] = [:]

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if ignored.contains(name) || name.hasSuffix(".framework") || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let type = LocalizationFormat(rawValue: url.pathExtension) else { continue }
            let relativeParts = Array(url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count))
            guard !relativeParts.isEmpty else { continue }
            let localeIndex = relativeParts.lastIndex(where: { $0.hasSuffix(".lproj") })
            let locale = localeIndex.map { String(relativeParts[$0].dropLast(6)) }
            let group = relativeParts.enumerated().filter { $0.offset != localeIndex }.map(\.element).joined(separator: "/")
            let document = LocalizedDocument(url: url, format: type, group: group, language: locale)
            docs.append(document)
            if let locale {
                languageSet.insert(locale)
                groupLanguages[group, default: []].insert(locale)
            }
            do {
                let data = try Data(contentsOf: url)
                baselineFiles[url.path] = data
                switch type {
                case .strings:
                    guard let locale else { issues.append(.init(.warning, file: group, detail: "Unlocalized .strings file")); continue }
                    var seen = Set<String>()
                    for pair in try LegacyStrings.parse(data) {
                        if !seen.insert(pair.key).inserted {
                            issues.append(.init(.error, file: group, detail: "Duplicate key: \(pair.key) [\(locale)]"))
                        }
                        merge(group: group, key: pair.key, variant: "", locale: locale, value: pair.value, into: &table)
                    }
                case .stringsdict:
                    guard let locale else { issues.append(.init(.warning, file: group, detail: "Unlocalized .stringsdict file")); continue }
                    guard let property = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                        throw LocalizationFailure.malformed("Invalid stringsdict root")
                    }
                    for (key, nested) in property {
                        for problem in validatePluralMetadata(nested, path: key) {
                            issues.append(.init(.error, file: group, detail: "\(locale): \(problem)"))
                        }
                        for leaf in flattenedPlistStrings(nested, path: []) {
                            merge(group: group, key: key, variant: leaf.path.joined(separator: "/"), locale: locale, value: leaf.value, into: &table)
                        }
                    }
                case .xcstrings:
                    // JSONSerialization silently collapses duplicate keys; reject ambiguous catalogs.
                    _ = try JSONText.tokens(in: data)
                    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let catalog = obj["strings"] as? [String: Any] else {
                        throw LocalizationFailure.malformed("Invalid xcstrings catalog")
                    }
                    let srcLang = obj["sourceLanguage"] as? String
                    if let srcLang {
                        languageSet.insert(srcLang)
                        groupLanguages[group, default: []].insert(srcLang)
                        catalogSource[group] = srcLang
                    }
                    for (key, content) in catalog {
                        let entry = content as? [String: Any] ?? [:]
                        for problem in validateCatalogPlurals(entry, path: key) {
                            issues.append(.init(.error, file: group, detail: problem))
                        }
                        if let langs = entry["localizations"] as? [String: Any] {
                            for (lang, localization) in langs {
                                languageSet.insert(lang)
                                groupLanguages[group, default: []].insert(lang)
                                for leaf in flattenedCatalog(localization, path: []) {
                                    merge(group: group, key: key, variant: leaf.path.joined(separator: "/"), locale: lang, value: leaf.value, into: &table)
                                }
                            }
                        }
                        // Source-language entries may be implicit in string catalogs. Display their
                        // source key as a read-only baseline; setting a translation makes it explicit.
                        if let srcLang, (entry["localizations"] as? [String: Any])?[srcLang] == nil {
                            merge(group: group, key: key, variant: "", locale: srcLang, value: key, into: &table)
                        }
                        // Register keys even when untranslated. The key is the source text or a symbolic key.
                        let id = TranslationRow(group: group, key: key).id
                        if table[id] == nil && (entry["localizations"] as? [String: Any])?.isEmpty != false {
                            table[id] = TranslationRow(group: group, key: key)
                        }
                    }
                }
            } catch {
                issues.append(.init(.error, file: group, detail: "Read/parse failed: \(error.localizedDescription)"))
            }
        }
        let languages = languageSet.sorted()
        let rows = table.values.sorted { ($0.group, $0.key, $0.variant) < ($1.group, $1.key, $1.variant) }
        // Variants are language-specific. Only check missing ordinary rows; variant support is validated separately.
        for row in rows where row.variant.isEmpty {
            for lang in (groupLanguages[row.group] ?? []).sorted() where (row.values[lang] ?? "").isEmpty && catalogSource[row.group] != lang {
                issues.append(.init(.warning, file: row.group, detail: "Missing \(lang): \(row.key)"))
            }
        }
        for row in rows {
            let signatureMap = row.values.mapValues { formatPlaceholders($0) }
            if let first = signatureMap.sorted(by: { $0.key < $1.key }).first {
                for (lang, sig) in signatureMap where sig != first.value {
                    issues.append(.init(.warning, file: row.group, detail: "Placeholder mismatch \(lang) / \(first.key): \(row.key)"))
                }
            }
        }
        return WorkspaceSnapshot(root: root, documents: docs.sorted { $0.url.path < $1.url.path }, rows: rows, languages: languages, issues: issues.sorted { $0.file < $1.file }, baselineFiles: baselineFiles)
    }

    private static func validatePluralMetadata(_ item: Any, path: String) -> [String] {
        guard let dictionary = item as? [String: Any] else { return [] }
        var problems: [String] = []
        if dictionary["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType" {
            if dictionary["other"] as? String == nil { problems.append("Missing required 'other' plural category at \(path)") }
            if dictionary["NSStringFormatValueTypeKey"] as? String == nil { problems.append("Missing plural numeric type at \(path)") }
        }
        for (key, nested) in dictionary {
            problems.append(contentsOf: validatePluralMetadata(nested, path: path + "/" + key))
        }
        return problems
    }

    private static func validateCatalogPlurals(_ item: Any, path: String) -> [String] {
        guard let dictionary = item as? [String: Any] else { return [] }
        var problems: [String] = []
        if let variations = dictionary["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: Any], plural["other"] == nil {
            problems.append("Missing required 'other' plural category at \(path)")
        }
        for (key, nested) in dictionary {
            problems.append(contentsOf: validateCatalogPlurals(nested, path: path + "/" + key))
        }
        return problems
    }

    private static func merge(group: String, key: String, variant: String, locale: String, value: String, into table: inout [String: TranslationRow]) {
        var row = TranslationRow(group: group, key: key, variant: variant)
        if let existing = table[row.id] { row = existing }
        row.values[locale] = value
        table[row.id] = row
    }

    private static func flattenedPlistStrings(_ value: Any, path: [String]) -> [(path: [String], value: String)] {
        if let s = value as? String {
            if ["NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"].contains(path.last ?? "") { return [] }
            return [(path, s)]
        }
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().flatMap { flattenedPlistStrings(dict[$0]!, path: path + [$0]) }
        }
        return []
    }

    private static func flattenedCatalog(_ value: Any, path: [String]) -> [(path: [String], value: String)] {
        guard let dict = value as? [String: Any] else { return [] }
        if let unit = dict["stringUnit"] as? [String: Any], let text = unit["value"] as? String { return [(path, text)] }
        return dict.keys.sorted().flatMap { k in flattenedCatalog(dict[k]!, path: path + [k]) }
    }

    private static func formatPlaceholders(_ s: String) -> [String] {
        // All printf placeholders except escaped percent; preserve positional indices and types.
        let pattern = #"%(?:[1-9]\d*\$)?[-+# 0']*\d*(?:\.\d+)?(?:hh|ll|h|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.matches(in: s, range: r).compactMap { Range($0.range, in: s).map { String(s[$0]) } }.sorted()
    }
}
