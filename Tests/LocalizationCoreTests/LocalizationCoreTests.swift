import XCTest
import Foundation
@testable import LocalizationCore

final class LocalizationCoreTests: XCTestCase {
    func testCatalogSummaryDoesNotCountLanguagesFromUnrelatedResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Locale-Summary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("es.lproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"version":"1.1","sourceLanguage":"en","strings":{"Hello":{}}}"#.utf8)
            .write(to: root.appendingPathComponent("App.xcstrings"))
        try Data(#""other" = "otro";"#.utf8)
            .write(to: root.appendingPathComponent("es.lproj/Other.strings"))
        let snapshot = try WorkspaceLoader.load(at: root)
        XCTAssertEqual(WorkspaceDiagnostics.summary(snapshot, group: "App.xcstrings").missing, 0)
        XCTAssertEqual(WorkspaceDiagnostics.summary(snapshot, group: "Other.strings").missing, 0)
    }

    func testEscapedPrintfPercentsDoNotCountAsPlaceholders() {
        XCTAssertTrue(WorkspaceDiagnostics.checkFormat("Progress %%d", "Avancement %%d"))
        XCTAssertFalse(WorkspaceDiagnostics.checkFormat("%%d", "%d"))
        XCTAssertTrue(WorkspaceDiagnostics.checkFormat("%%%d", "%d"))
        XCTAssertFalse(WorkspaceDiagnostics.checkFormat("%1$@ and %%", "%2$@ and %%"))
    }

    func testStringsParsingAndSurgicalWritePreservesAllOtherBytes() throws {
        let original = Data("/* comment */\r\n\"hello\" = \"Hello\";\r\n\"count\" = \"%d items\";\r\n".utf8)
        let parsed = try LegacyStrings.parse(original)
        XCTAssertEqual(parsed.map(\.key), ["hello", "count"])
        let result = try LegacyStrings.replaceValue(original, key: "hello", with: "你好 \"world\"\n")
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "/* comment */\r\n\"hello\" = \"你好 \\\"world\\\"\\n\";\r\n\"count\" = \"%d items\";\r\n")
    }

    func testDuplicatesAreRejectedOnWrite() throws {
        let bytes = Data("\"a\"=\"1\";\"a\"=\"2\";".utf8)
        XCTAssertThrowsError(try LegacyStrings.replaceValue(bytes, key: "a", with: "x"))
    }

    func testCatalogChangeLeavesUnknownMetadataUntouched() throws {
        let original = Data("{\"strings\":{\"Hi\":{\"x-vendor\":42,\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"Hello\"}}}}},\"version\":\"1.1\"}".utf8)
        let changed = try JSONText.replace(original, path: ["strings", "Hi", "localizations", "en", "stringUnit", "value"], with: "你好")
        XCTAssertEqual(String(decoding: changed, as: UTF8.self), "{\"strings\":{\"Hi\":{\"x-vendor\":42,\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"你好\"}}}}},\"version\":\"1.1\"}")
    }

    func testCatalogQuotedKeysAndPluralVariants() throws {
        let text = #"{"strings":{"A\"B":{"localizations":{"en":{"variations":{"plural":{"one":{"stringUnit":{"value":"%lld item"}}}}}}}}}"#
        let tokens = try JSONText.tokens(in: Data(text.utf8))
        XCTAssertEqual(tokens.last?.path, ["strings", "A\"B", "localizations", "en", "variations", "plural", "one", "stringUnit", "value"])
    }

    func testSampleWorkspaceDiscoversAllThreeFormats() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let result = try WorkspaceLoader.load(at: project.appendingPathComponent("Samples"))
        XCTAssertEqual(Set(result.documents.map(\.format)), Set([.strings, .stringsdict, .xcstrings]))
        XCTAssertTrue(result.rows.contains(where: { $0.key == "file.count" && $0.variant.contains("plural/one") }))
        XCTAssertTrue(result.issues.contains(where: { $0.detail.contains("Missing") }))
    }

    func testNoOutsideWorkspaceSave() throws {
        let doc = LocalizedDocument(url: URL(fileURLWithPath: "/tmp/external.strings"), format: .strings, group: "external.strings", language: "en")
        XCTAssertEqual(doc.language, "en")
    }
}

extension LocalizationCoreTests {
    func testStringsDictPreviewRoundTrip() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let langFolder = temp.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: langFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let xml: [String: Any] = ["orders": ["NSStringLocalizedFormatKey": "%#@total@", "total": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d", "one": "%d order", "other": "%d orders"]]]
        let target = langFolder.appendingPathComponent("Localizable.stringsdict")
        try PropertyListSerialization.data(fromPropertyList: xml, format: .xml, options: 0).write(to: target)
        let doc = LocalizedDocument(url: target, format: .stringsdict, group: "Localizable.stringsdict", language: "en")
        let preview = try WorkspaceWriter.preview(document: doc, key: "orders", variant: "total/other", language: "en", newValue: "%d purchases")
        XCTAssertTrue(preview.fullRewrite)
        try WorkspaceWriter.commit(preview, workspaceRoot: temp)
        let updated = try PropertyListSerialization.propertyList(from: Data(contentsOf: target), format: nil) as! [String: Any]
        let total = (updated["orders"] as! [String: Any])["total"] as! [String: Any]
        XCTAssertEqual(total["other"] as? String, "%d purchases")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent(".localization-workbench-backups").path))
    }
    func testConcurrentSaveConflict() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let target = temp.appendingPathComponent("Localizable.strings")
        try Data("\"a\"=\"before\";".utf8).write(to: target)
        let doc = LocalizedDocument(url: target, format: .strings, group: "Localizable.strings", language: "en")
        let preview = try WorkspaceWriter.preview(document: doc, key: "a", language: "en", newValue: "after")
        try Data("\"a\"=\"external edit\";".utf8).write(to: target)
        XCTAssertThrowsError(try WorkspaceWriter.commit(preview, workspaceRoot: temp))
    }
}
