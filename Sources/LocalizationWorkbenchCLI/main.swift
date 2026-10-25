import Foundation
import LocalizationCore

/// Optional headless interface for build scripts and translation automation.
enum WorkbenchCommand {
    static func main(_ args: [String]) throws {
        guard args.count >= 3 else { printHelp(); return }
        let command = args[1]
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let snap = try WorkspaceLoader.load(at: root)
        switch command {
        case "scan":
            print("Workspace: \(snap.root.path)")
            print("Documents: \(snap.documents.count) | Languages: \(snap.languages.joined(separator: ", ")) | Keys/Variants: \(snap.rows.count)")
            for name in Set(snap.documents.map(\.group)).sorted() {
                let rows = snap.rows.filter { $0.group == name }
                print("  \(name) — \(rows.count) entries")
            }
        case "validate":
            let strict = args.contains("--strict")
            for issue in snap.issues {
                print("\(issue.severity.rawValue.uppercased()) | \(issue.file) | \(issue.detail)")
            }
            let errors = snap.issues.filter { $0.severity == .error }.count
            let warnings = snap.issues.filter { $0.severity == .warning }.count
            print("Validation complete: \(errors) errors, \(warnings) warnings")
            if errors > 0 || (strict && warnings > 0) { exit(2) }
        case "export":
            let text = TranslationExchange.export(snapshot: snap)
            if let name = argValue("--output", in: args) {
                try text.write(to: URL(fileURLWithPath: name), atomically: true, encoding: .utf8)
                print("Exported \(snap.rows.count) rows to \(name)")
            } else { print(text, terminator: "") }
        case "import":
            guard let csv = argValue("--csv", in: args) else { throw LocalizationFailure.missing("import needs --csv path") }
            let text = try String(contentsOf: URL(fileURLWithPath: csv), encoding: .utf8)
            let edits = try TranslationExchange.edits(fromCSV: text, snapshot: snap)
            let changes = try WorkspaceTransactions.preview(snapshot: snap, edits: edits)
            print("Prepared \(edits.count) edited translations across \(changes.files.count) files")
            for change in changes.files { print("  \(change.rewrite ? "REWRITE" : "TARGETED") | \(change.url.path)") }
            if args.contains("--write") {
                try WorkspaceTransactions.commit(changes)
                print("Saved with backups")
            } else { print("Dry-run. Re-run with --write to commit") }
        default:
            printHelp()
        }
    }
    private static func argValue(_ flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i+1 < args.count else { return nil }
        return args[i+1]
    }
    static func printHelp() {
        print("""
        Localization Workbench CLI
        Usage:
          localization-workbench scan <project-directory>
          localization-workbench validate <project-directory> [--strict]
          localization-workbench export <project-directory> [--output translations.csv]
          localization-workbench import <project-directory> --csv translations.csv [--write]

        Imports are dry-run by default. --write creates backups and verifies source-file conflicts.
        """)
    }
}

do {
    try WorkbenchCommand.main(CommandLine.arguments)
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
