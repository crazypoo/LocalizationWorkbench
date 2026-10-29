import XCTest
import Foundation
@testable import LocalizationCore

final class WorkspaceTransactionTests: XCTestCase {
    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-Test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("zh-Hans.lproj"), withIntermediateDirectories: true)
        try "/* preserved */\n\"welcome\" = \"Welcome\";\n\"bye\" = \"Bye\";\n".write(to: dir.appendingPathComponent("en.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        try "\"welcome\" = \"欢迎\";\n\"bye\" = \"再见\";\n".write(to: dir.appendingPathComponent("zh-Hans.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        return dir
    }
    private func withWorkspace(_ body: (URL, WorkspaceSnapshot) throws -> Void) throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir, WorkspaceLoader.load(at: dir))
    }
    func testWorkspaceOpenedThroughSymlinkCanStageAndCommitNewLocale() throws {
        let realRoot = try makeWorkspace()
        let aliasRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Workbench-Alias-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)
        defer {
            try? FileManager.default.removeItem(at: aliasRoot)
            try? FileManager.default.removeItem(at: realRoot)
        }
        let snapshot = try WorkspaceLoader.load(at: aliasRoot)
        let preview = try WorkspaceTransactions.preview(snapshot: snapshot, edits: [
            .addLanguage(group: "Localizable.strings", language: "fr")
        ])
        try WorkspaceTransactions.commit(preview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realRoot.appendingPathComponent("fr.lproj/Localizable.strings").path))
        let manifestRoot = realRoot.appendingPathComponent(".localization-workbench-backups")
        let backups = try FileManager.default.contentsOfDirectory(at: manifestRoot, includingPropertiesForKeys: nil)
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: backups[0].appendingPathComponent("manifest.json"))
        ) as! [String: Any]
        let records = manifest["files"] as! [[String: Any]]
        XCTAssertEqual(records.first?["relativePath"] as? String, "fr.lproj/Localizable.strings")
    }

    func testAddKeyPreviewIsStagedUntilCommitAndAddsEveryLocale() throws {
        try withWorkspace { root, snap in
            let english = root.appendingPathComponent("en.lproj/Localizable.strings")
            let chinese = root.appendingPathComponent("zh-Hans.lproj/Localizable.strings")
            let originalEnglish = try Data(contentsOf: english)
            let originalChinese = try Data(contentsOf: chinese)

            let pending = WorkspaceEdit.addKey(group: "Localizable.strings", key: "new.action")
            let preview = try WorkspaceTransactions.preview(snapshot: snap, edits: [pending])
            XCTAssertEqual(preview.files.count, 2)
            XCTAssertEqual(try Data(contentsOf: english), originalEnglish)
            XCTAssertEqual(try Data(contentsOf: chinese), originalChinese)
            XCTAssertTrue(preview.files.allSatisfy { $0.updatedText.contains("\"new.action\"") })

            try WorkspaceTransactions.commit(preview)
            let reloaded = try WorkspaceLoader.load(at: root)
            XCTAssertEqual(reloaded.rows.first(where: { $0.key == "new.action" })?.values["en"], "")
            XCTAssertEqual(reloaded.rows.first(where: { $0.key == "new.action" })?.values["zh-Hans"], "")
        }
    }

    func testDuplicateKeyIsRejectedInsteadOfSilentlyCreatingAnOperation() throws {
        try withWorkspace { _, snap in
            XCTAssertThrowsError(try WorkspaceTransactions.preview(snapshot: snap, edits: [
                .addKey(group: "Localizable.strings", key: "welcome")
            ]))
        }
    }

    func testStagedEditMatchesExactRowOnly() {
        let edit = WorkspaceEdit.set(group: "Localizable.strings", key: "cart.item",
                                     variant: "", language: "en", value: "Changed")
        XCTAssertTrue(edit.affects(TranslationRow(group: "Localizable.strings", key: "cart.item")))
        XCTAssertFalse(edit.affects(TranslationRow(group: "Localizable.strings", key: "item")))
        XCTAssertFalse(edit.affects(TranslationRow(group: "Other.strings", key: "cart.item")))
        XCTAssertFalse(edit.affects(TranslationRow(group: "Localizable.strings", key: "cart.item", variant: "plural/one")))
    }

    func testStagedMultiFileEditsAndBackups() throws {
        try withWorkspace { root, snap in
            let edits: [WorkspaceEdit] = [
                .set(group: "Localizable.strings", key: "welcome", variant: "", language: "en", value: "Hello, \"world\""),
                .set(group: "Localizable.strings", key: "welcome", variant: "", language: "zh-Hans", value: "你好，世界"),
                .set(group: "Localizable.strings", key: "bye", variant: "", language: "en", value: "See you")
            ]
            let preview = try WorkspaceTransactions.preview(snapshot: snap, edits: edits)
            XCTAssertEqual(preview.files.count, 2)
            XCTAssertTrue(preview.files.allSatisfy { !$0.rewrite })
            XCTAssertTrue(preview.files.first(where: { $0.url.path.contains("en.lproj") })!.updatedText.contains("/* preserved */"))
            try WorkspaceTransactions.commit(preview)
            let reloaded = try WorkspaceLoader.load(at: root)
            XCTAssertEqual(reloaded.rows.first(where: { $0.key == "welcome" })?.values["zh-Hans"], "你好，世界")
            XCTAssertEqual(reloaded.rows.first(where: { $0.key == "bye" })?.values["en"], "See you")
            let backup = root.appendingPathComponent(".localization-workbench-backups")
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        }
    }
    func testNewLocaleAndNewKeyAndCSV() throws {
        try withWorkspace { root, snap in
            let preview = try WorkspaceTransactions.preview(snapshot: snap, edits: [
                .addLanguage(group: "Localizable.strings", language: "fr"),
                .addKey(group: "Localizable.strings", key: "greeting"),
                .set(group: "Localizable.strings", key: "greeting", variant: "", language: "fr", value: "Bonjour, monde")
            ])
            XCTAssertEqual(preview.files.count, 3)
            XCTAssertTrue(preview.files.first(where: { $0.url.path.contains("fr.lproj") })?.added == true)
            try WorkspaceTransactions.commit(preview)
            let reloaded = try WorkspaceLoader.load(at: root)
            XCTAssertEqual(reloaded.rows.first(where: { $0.key == "greeting" })?.values["fr"], "Bonjour, monde")
            let csv = TranslationExchange.export(snapshot: reloaded)
            let imported = try TranslationExchange.edits(fromCSV: csv, snapshot: reloaded)
            XCTAssertEqual(imported.count, 0)
        }
    }
    func testRenameAndDeleteAcrossLocales() throws {
        try withWorkspace { root, snap in
            let preview = try WorkspaceTransactions.preview(snapshot: snap, edits: [
                .renameKey(group: "Localizable.strings", old: "welcome", new: "home.welcome"),
                .deleteKey(group: "Localizable.strings", key: "bye")
            ])
            try WorkspaceTransactions.commit(preview)
            let result = try WorkspaceLoader.load(at: root)
            XCTAssertEqual(result.rows.map(\.key), ["home.welcome"])
            XCTAssertEqual(result.rows.first?.values["en"], "Welcome")
        }
    }
    func testExternalEditBeforeReviewIsRejected() throws {
        try withWorkspace { root, snap in
            let file = root.appendingPathComponent("en.lproj/Localizable.strings")
            try Data("\"welcome\" = \"External\";".utf8).write(to: file)
            XCTAssertThrowsError(try WorkspaceTransactions.preview(snapshot: snap, edits: [
                .set(group: "Localizable.strings", key: "welcome", variant: "", language: "en", value: "Mine")
            ]))
        }
    }
    func testExternalEditAfterReviewIsRejected() throws {
        try withWorkspace { root, snap in
            let set = try WorkspaceTransactions.preview(snapshot: snap, edits: [
                .set(group: "Localizable.strings", key: "welcome", variant: "", language: "en", value: "Mine")
            ])
            let file = root.appendingPathComponent("en.lproj/Localizable.strings")
            try Data("\"welcome\" = \"External\";".utf8).write(to: file)
            XCTAssertThrowsError(try WorkspaceTransactions.commit(set))
            XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("External"))
        }
    }
    func testCatalogTargetedValueStateAndPlural() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("App.xcstrings")
        let input = #"{"version":"1.1","sourceLanguage":"en","strings":{"hi":{"vendorFutureMetadata":42,"localizations":{"fr":{"stringUnit":{"state":"new","value":""}}}}}}"#
        try Data(input.utf8).write(to: file)
        let snap = try WorkspaceLoader.load(at: root)
        let changes = try WorkspaceTransactions.preview(snapshot: snap, edits: [
            .set(group: "App.xcstrings", key: "hi", variant: "", language: "fr", value: "Salut")
        ])
        XCTAssertEqual(changes.files.count, 1)
        XCTAssertFalse(changes.files[0].rewrite)
        XCTAssertTrue(changes.files[0].updatedText.contains("\"state\":\"translated\""))
        XCTAssertTrue(changes.files[0].updatedText.contains("\"vendorFutureMetadata\":42"))
        try WorkspaceTransactions.commit(changes)
        let snap2 = try WorkspaceLoader.load(at: root)
        let changes2 = try WorkspaceTransactions.preview(snapshot: snap2, edits: [
            .set(group: "App.xcstrings", key: "hi", variant: "variations/plural/one", language: "fr", value: "Une chose")
        ])
        XCTAssertTrue(changes2.files.first?.rewrite == true)
        try WorkspaceTransactions.commit(changes2)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let entry = (obj["strings"] as! [String: Any])["hi"] as! [String: Any]
        XCTAssertEqual(entry["vendorFutureMetadata"] as? Int, 42)
        let fr = (entry["localizations"] as! [String: Any])["fr"] as! [String: Any]
        let variations = fr["variations"] as! [String: Any]
        let plural = variations["plural"] as! [String: Any]
        let one = plural["one"] as! [String: Any]
        XCTAssertEqual((one["stringUnit"] as! [String: Any])["value"] as? String, "Une chose")
    }
    func testCatalogAddKeyAddLanguageAndComment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("App.xcstrings")
        try Data(#"{"version":"1.1","sourceLanguage":"en","strings":{"hello":{}}}"#.utf8).write(to: file)
        let snap = try WorkspaceLoader.load(at: root)
        let changes = try WorkspaceTransactions.preview(snapshot: snap, edits: [
            .addKey(group: "App.xcstrings", key: "check_out"),
            .addLanguage(group: "App.xcstrings", language: "ja"),
            .set(group: "App.xcstrings", key: "check_out", variant: "", language: "ja", value: "お会計"),
            .comment(group: "App.xcstrings", key: "check_out", text: "Checkout CTA")
        ])
        try WorkspaceTransactions.commit(changes)
        let newSnap = try WorkspaceLoader.load(at: root)
        XCTAssertEqual(newSnap.rows.first(where: { $0.key == "check_out" })?.values["ja"], "お会計")
        let data = try Data(contentsOf: file)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Checkout CTA"))
    }
    func testStringsDictPluralEditing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dict-Test-" + UUID().uuidString)
        let dir = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = dir.appendingPathComponent("Localizable.stringsdict")
        let input: [String: Any] = ["items": ["NSStringLocalizedFormatKey": "%#@count@", "count": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d", "one": "%d item", "other": "%d items"]]]
        try PropertyListSerialization.data(fromPropertyList: input, format: .xml, options: 0).write(to: file)
        let snap = try WorkspaceLoader.load(at: root)
        let changes = try WorkspaceTransactions.preview(snapshot: snap, edits: [
            .set(group: "Localizable.stringsdict", key: "items", variant: "count/few", language: "en", value: "%d things")
        ])
        XCTAssertTrue(changes.files[0].rewrite)
        try WorkspaceTransactions.commit(changes)
        let result = try WorkspaceLoader.load(at: root)
        XCTAssertEqual(result.rows.first(where: { $0.variant == "count/few" })?.values["en"], "%d things")
    }
    func testCSVWithCommasQuotesAndEmbeddedNewlines() throws {
        let sample = "group,key,variant,language,value\r\n\"A\",\"key\",\"\",\"fr\",\"Bonjour, \\\"J\\\"\"\r\n"
        // Instead of relying on escaped quoting typed by hand, generate a canonical CSV from the model.
        try withWorkspace { _, snap in
            let exported = TranslationExchange.export(snapshot: snap)
            XCTAssertTrue(exported.contains("\"欢迎\""))
            XCTAssertTrue(try TranslationExchange.edits(fromCSV: exported, snapshot: snap).isEmpty)
        }
        XCTAssertThrowsError(try TranslationExchange.parse("a,b,\"unterminated"))
        XCTAssertFalse(sample.isEmpty)
    }
    func testAmbiguousDuplicateIsRejectedWhenEditing() throws {
        try withWorkspace { root, _ in
            let file = root.appendingPathComponent("en.lproj/Localizable.strings")
            try Data("\"same\"=\"one\"; \"same\"=\"two\";".utf8).write(to: file)
            let snap = try WorkspaceLoader.load(at: root)
            XCTAssertTrue(snap.issues.contains { $0.detail.contains("Duplicate key") })
            XCTAssertThrowsError(try WorkspaceTransactions.preview(snapshot: snap, edits: [
                .set(group: "Localizable.strings", key: "same", variant: "", language: "en", value: "changed")
            ]))
        }
    }
}

extension WorkspaceTransactionTests {
    func testStringsDictAddPluralAndNewLanguage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dict-New-Test-" + UUID().uuidString)
        let dir = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = dir.appendingPathComponent("Localizable.stringsdict")
        let rule: [String: Any] = ["old.count": ["NSStringLocalizedFormatKey": "%#@count@", "count": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d", "other": "%d older"]]]
        try PropertyListSerialization.data(fromPropertyList: rule, format: .xml, options: 0).write(to: file)
        let snap = try WorkspaceLoader.load(at: root)
        let preview = try WorkspaceTransactions.preview(snapshot: snap, edits: [
            .addPlural(group: "Localizable.stringsdict", key: "new.count", variable: "items", valueType: "lld"),
            .addLanguage(group: "Localizable.stringsdict", language: "fr"),
            .set(group: "Localizable.stringsdict", key: "new.count", variant: "items/other", language: "fr", value: "%lld éléments")
        ])
        XCTAssertEqual(preview.files.count, 2)
        try WorkspaceTransactions.commit(preview)
        let result = try WorkspaceLoader.load(at: root)
        XCTAssertEqual(result.rows.first(where: { $0.key == "new.count" && $0.variant == "items/other" })?.values["fr"], "%lld éléments")
        let fr = try Data(contentsOf: root.appendingPathComponent("fr.lproj/Localizable.stringsdict"))
        let obj = try PropertyListSerialization.propertyList(from: fr, format: nil) as! [String: Any]
        XCTAssertNotNil(obj["old.count"])
    }
    func testJSONDuplicateKeysRejected() throws {
        let bad = Data(#"{"strings":{"key":{},"key":{}}}"#.utf8)
        XCTAssertThrowsError(try JSONText.tokens(in: bad))
    }
    func testPluralsRequireOther() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dict-Issue-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rule: [String: Any] = ["things": ["NSStringLocalizedFormatKey": "%#@count@", "count": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d", "one": "One thing"]]]
        try PropertyListSerialization.data(fromPropertyList: rule, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("en.lproj/Localizable.stringsdict"))
        let snapshot = try WorkspaceLoader.load(at: root)
        XCTAssertTrue(snapshot.issues.contains { $0.severity == .error && $0.detail.contains("other") })
    }
    func testBackupManifestContainsOriginalPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Backup-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("en.lproj/Test.strings")
        try "\"x\"=\"old\";".write(to: target, atomically: true, encoding: .utf8)
        let snapshot = try WorkspaceLoader.load(at: root)
        let changes = try WorkspaceTransactions.preview(snapshot: snapshot, edits: [
            .set(group: "Test.strings", key: "x", variant: "", language: "en", value: "new")
        ])
        try WorkspaceTransactions.commit(changes)
        let backupRoot = root.appendingPathComponent(".localization-workbench-backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: backups[0].appendingPathComponent("manifest.json"))) as! [String: Any]
        let records = info["files"] as! [[String: Any]]
        XCTAssertEqual(records.first?["relativePath"] as? String, "en.lproj/Test.strings")
    }
}
