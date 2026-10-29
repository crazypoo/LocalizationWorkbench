#if os(macOS)
import AppKit
import SwiftUI
import LocalizationCore

/// A cell owns its text changes, preventing the entire workspace from being
/// invalidated on every keystroke (especially expensive while scrolling).
@MainActor
fileprivate final class TranslationCellDraft: ObservableObject {
    let original: String
    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            onChange?(text)
        }
    }
    var onChange: (@MainActor (String) -> Void)?

    init(original: String) {
        self.original = original
        self.text = original
    }
    var isDirty: Bool { text != original }
}

private enum MatrixMetrics {
    static let keyWidth: CGFloat = 230
    static let languageWidth: CGFloat = 265
    static let separatorWidth: CGFloat = 1
    static let rowHeight: CGFloat = 82
    static let headerHeight: CGFloat = 43
}

@MainActor
final class WorkbenchStore: ObservableObject {
    @Published var snapshot: WorkspaceSnapshot?
    @Published var selectedGroup: String?
    @Published var selectedRowID: String?
    @Published var search = ""
    @Published var filter: Filter = .all
    // Only a change in *dirty cell count* needs to update the toolbar. Individual
    // text keystrokes publish through TranslationCellDraft, not WorkbenchStore.
    @Published private(set) var dirtyDraftCount = 0
    private var drafts: [String: String] = [:]
    private var cellDrafts: [String: TranslationCellDraft] = [:]
    private var groupLanguages: [String: [String]] = [:]
    private var groupCompletion: [String: Double] = [:]
    private var groupedRows: [String: [TranslationRow]] = [:]
    private var problemIDs: Set<String> = []
    private var cachedGroups: [String] = []
    @Published var staged: [WorkspaceEdit] = []
    @Published var redoStack: [WorkspaceEdit] = []
    @Published var changes: WorkspaceChangeSet?
    @Published var message: String?
    @Published var opening = false
    @Published var showIssues = false
    @Published var showInspector = true
    @Published var showOperations = false
    @Published var showVariantSheet = false
    @Published var showCommentSheet = false
    @Published var showAddKeySheet = false
    @Published var showRenameSheet = false
    @Published var showAddLanguageSheet = false
    @Published var showDeleteConfirmation = false
    @Published var formError: String?
    @Published var stagedNotice: String?
    private var showOperationsWhenFormCloses = false

    @Published var inputKey = ""
    @Published var inputPluralVariable = "count"
    @Published var inputPluralType = "d"
    @Published var inputRename = ""
    @Published var inputLanguage = "fr"
    @Published var customLanguage = ""
    @Published var inputVariant = "variations/plural/one"
    @Published var inputValue = ""
    @Published var inputComment = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", missing = "Missing", changed = "Changed", issues = "Warnings"
        var id: String { rawValue }
    }

    struct LanguageChoice: Identifiable {
        let id: String
        let name: String
    }

    // Stable BCP 47 identifiers: the ID, not the localized display name, is
    // written into the catalog or the new .lproj directory.
    static let languageChoices: [LanguageChoice] = [
        .init(id: "en", name: "English"),
        .init(id: "en-GB", name: "English (UK)"),
        .init(id: "en-AU", name: "English (Australia)"),
        .init(id: "zh-Hans", name: "Chinese (Simplified)"),
        .init(id: "zh-Hant", name: "Chinese (Traditional)"),
        .init(id: "zh-HK", name: "Chinese (Hong Kong)"),
        .init(id: "ja", name: "Japanese"),
        .init(id: "ko", name: "Korean"),
        .init(id: "fr", name: "French"),
        .init(id: "fr-CA", name: "French (Canada)"),
        .init(id: "de", name: "German"),
        .init(id: "es", name: "Spanish"),
        .init(id: "es-MX", name: "Spanish (Mexico)"),
        .init(id: "pt-BR", name: "Portuguese (Brazil)"),
        .init(id: "pt-PT", name: "Portuguese (Portugal)"),
        .init(id: "it", name: "Italian"),
        .init(id: "nl", name: "Dutch"),
        .init(id: "ru", name: "Russian"),
        .init(id: "uk", name: "Ukrainian"),
        .init(id: "pl", name: "Polish"),
        .init(id: "tr", name: "Turkish"),
        .init(id: "ar", name: "Arabic"),
        .init(id: "he", name: "Hebrew"),
        .init(id: "hi", name: "Hindi"),
        .init(id: "th", name: "Thai"),
        .init(id: "vi", name: "Vietnamese"),
        .init(id: "id", name: "Indonesian"),
        .init(id: "ms", name: "Malay"),
        .init(id: "km", name: "Khmer"),
        .init(id: "my", name: "Burmese"),
        .init(id: "fil", name: "Filipino"),
        .init(id: "sv", name: "Swedish"),
        .init(id: "da", name: "Danish"),
        .init(id: "fi", name: "Finnish"),
        .init(id: "nb", name: "Norwegian Bokmål"),
        .init(id: "cs", name: "Czech"),
        .init(id: "ro", name: "Romanian"),
        .init(id: "el", name: "Greek"),
        .init(id: "__custom__", name: "Other (custom BCP 47 identifier)")
    ]

    var selectableLanguages: [LanguageChoice] {
        guard let group = selectedGroup else { return Self.languageChoices }
        let stagedLanguages = staged.compactMap { edit -> String? in
            if case let .addLanguage(editGroup, language) = edit, editGroup == group { return language }
            return nil
        }
        let taken = Set(langs(group)).union(stagedLanguages)
        return Self.languageChoices.filter { !taken.contains($0.id) }
    }

    var groups: [String] { cachedGroups }
    var selectedRow: TranslationRow? { snapshot?.rows.first { $0.id == selectedRowID } }
    var rootName: String { snapshot?.root.lastPathComponent ?? "No project" }

    /// Called once per workspace load, not from each scrolling cell.
    private func rebuildIndex(_ snap: WorkspaceSnapshot) {
        cachedGroups = Array(Set(snap.documents.map(\.group))).sorted()
        groupedRows = Dictionary(grouping: snap.rows, by: \.group)
        var languages: [String: Set<String>] = [:]
        for doc in snap.documents {
            if let lang = doc.language { languages[doc.group, default: []].insert(lang) }
        }
        for row in snap.rows { languages[row.group, default: []].formUnion(row.values.keys) }
        // A catalog with no rows still has a source language. Read at most once.
        for doc in snap.documents where doc.format == .xcstrings && (languages[doc.group]?.isEmpty ?? true) {
            if let data = snap.baselineFiles[doc.url.path],
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let source = object["sourceLanguage"] as? String {
                languages[doc.group, default: []].insert(source)
            }
        }
        groupLanguages = languages.mapValues { $0.sorted() }
        groupCompletion = [:]
        for (group, rows) in groupedRows {
            let available = groupLanguages[group] ?? []
            let total = rows.count * available.count
            if total == 0 { groupCompletion[group] = 0; continue }
            let count = rows.reduce(into: 0) { tally, row in
                for lang in available where !(row.values[lang] ?? "").isEmpty { tally += 1 }
            }
            groupCompletion[group] = Double(count) / Double(total)
        }
        let issueDetails = Dictionary(grouping: snap.issues, by: \.file).mapValues { $0.map(\.detail) }
        problemIDs = Set(snap.rows.lazy.filter { row in
            (issueDetails[row.group] ?? []).contains { $0.contains(row.key) }
        }.map(\.id))
    }

    func langs(_ group: String?) -> [String] {
        group.flatMap { groupLanguages[$0] } ?? snapshot?.languages ?? []
    }
    func isMissing(_ row: TranslationRow) -> Bool {
        langs(row.group).contains { (row.values[$0] ?? "").isEmpty }
    }
    func isProblem(_ row: TranslationRow) -> Bool { problemIDs.contains(row.id) }
    func isChanged(_ row: TranslationRow) -> Bool {
        langs(row.group).contains { getDraft(row, $0) != (row.values[$0] ?? "") } ||
        staged.contains { $0.affects(row) }
    }
    var rows: [TranslationRow] {
        guard let snap = snapshot else { return [] }
        let candidates = selectedGroup.flatMap { groupedRows[$0] } ?? snap.rows
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty && filter == .all { return candidates }
        return candidates.filter { row in
            (term.isEmpty || row.key.localizedCaseInsensitiveContains(term) ||
             row.variant.localizedCaseInsensitiveContains(term) ||
             row.values.values.contains { $0.localizedCaseInsensitiveContains(term) }) &&
            (filter == .all || filter == .missing && isMissing(row) ||
             filter == .changed && isChanged(row) || filter == .issues && isProblem(row))
        }
    }
    func completion(_ group: String) -> Double { groupCompletion[group] ?? 0 }
    func fileIcon(_ group: String) -> String {
        if group.hasSuffix("xcstrings") { return "curlybraces.square" }
        if group.hasSuffix("stringsdict") { return "text.badge.star" }
        return "doc.plaintext"
    }
    func cacheKey(_ row: TranslationRow, _ lang: String) -> String { row.id + "||" + lang }
    func getDraft(_ row: TranslationRow, _ lang: String) -> String {
        drafts[cacheKey(row, lang)] ?? row.values[lang] ?? ""
    }
    fileprivate func cellDraft(for row: TranslationRow, language: String) -> TranslationCellDraft {
        let key = cacheKey(row, language)
        if let existing = cellDrafts[key] { return existing }
        let original = row.values[language] ?? ""
        let cell = TranslationCellDraft(original: original)
        cell.onChange = { [weak self] text in
            guard let self else { return }
            let previouslyDirty = self.drafts[key] != nil
            if text == original { self.drafts.removeValue(forKey: key) }
            else { self.drafts[key] = text }
            let nowDirty = text != original
            if previouslyDirty != nowDirty { self.dirtyDraftCount = self.drafts.count }
        }
        cellDrafts[key] = cell
        return cell
    }
    var unsavedDraftCount: Int { dirtyDraftCount }

    func open() {
        let panel = NSOpenPanel()
        panel.title = "Open a localization project"
        panel.message = "Select the project directory, .xcodeproj or .xcworkspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        opening = true
        let selected = selectedGroup
        Task {
            do {
                let newSnapshot = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceLoader.load(at: url)
                }.value
                rebuildIndex(newSnapshot)
                cellDrafts.removeAll()
                drafts.removeAll()
                dirtyDraftCount = 0
                snapshot = newSnapshot
                selectedGroup = selected.flatMap { g in newSnapshot.documents.contains { $0.group == g } ? g : nil } ?? cachedGroups.first
                selectedRowID = nil
                staged = []
                redoStack = []
                changes = nil
                UserDefaults.standard.set(url.path, forKey: "LastProjectPath")
            } catch { message = error.localizedDescription }
            opening = false
        }
    }
    func openRecent() {
        if let path = UserDefaults.standard.string(forKey: "LastProjectPath"), FileManager.default.fileExists(atPath: path) {
            load(URL(fileURLWithPath: path))
        } else { open() }
    }

    func stage(_ edit: WorkspaceEdit) {
        if case let .set(g,k,v,l,_) = edit {
            staged.removeAll { other in
                if case let .set(g2,k2,v2,l2,_) = other { return g == g2 && k == k2 && v == v2 && l == l2 }
                return false
            }
        }
        staged.append(edit)
        redoStack.removeAll()
        stagedNotice = "Staged: \(edit.summary)"
    }
    func removeStaged(at index: Int) {
        guard staged.indices.contains(index) else { return }
        staged.remove(at: index)
        // Removing an arbitrary operation invalidates the redo history.
        redoStack.removeAll()
        stagedNotice = staged.isEmpty ? nil : "\(staged.count) operations remain staged"
    }
    func prepareAddKey() {
        guard selectedGroup != nil else { message = "Select a resource in the sidebar first."; return }
        inputKey = ""
        formError = nil
        showAddKeySheet = true
    }
    func prepareAddLanguage() {
        guard selectedGroup != nil else { message = "Select a resource in the sidebar first."; return }
        guard let first = selectableLanguages.first else {
            message = "All languages in the picker already exist in this resource."
            return
        }
        inputLanguage = first.id
        customLanguage = ""
        formError = nil
        showAddLanguageSheet = true
    }
    func prepareRename(_ row: TranslationRow) {
        selectedRowID = row.id
        inputRename = row.key
        formError = nil
        showRenameSheet = true
    }
    func prepareVariant(_ row: TranslationRow) {
        selectedRowID = row.id
        inputLanguage = langs(row.group).first ?? "en"
        if row.group.hasSuffix(".stringsdict") {
            inputVariant = String(row.variant.split(separator: "/").first ?? "count") + "/one"
        } else {
            inputVariant = "variations/plural/one"
        }
        inputValue = ""
        formError = nil
        showVariantSheet = true
    }
    func prepareComment() {
        formError = nil
        showCommentSheet = true
    }
    func didDismissForm() {
        guard showOperationsWhenFormCloses else { return }
        showOperationsWhenFormCloses = false
        showOperations = true
    }
    private func stageFromForm(_ edit: WorkspaceEdit) {
        stage(edit)
        formError = nil
        // Present the operations sheet only after the current sheet has dismissed.
        showOperationsWhenFormCloses = true
    }
    private func keyExistsOrIsStaged(group: String, key: String, excluding oldKey: String? = nil) -> Bool {
        if snapshot?.rows.contains(where: { $0.group == group && $0.key == key && $0.key != oldKey }) == true {
            return true
        }
        return staged.contains { edit in
            switch edit {
            case let .addKey(g, k), let .addPlural(g, k, _, _):
                return g == group && k == key
            case let .renameKey(g, _, new):
                return g == group && new == key
            default:
                return false
            }
        }
    }
    func stageDrafts() {
        guard let snap = snapshot else { return }
        for row in snap.rows {
            let deleted = staged.contains { edit in
                if case let .deleteKey(group, key) = edit { return group == row.group && key == row.key }
                return false
            }
            if deleted { continue }
            var destinationKey = row.key
            for edit in staged {
                if case let .renameKey(group, old, new) = edit, group == row.group, old == destinationKey {
                    destinationKey = new
                }
            }
            for lang in langs(row.group) {
                let current = getDraft(row, lang)
                if current != (row.values[lang] ?? "") {
                    stage(.set(group: row.group, key: destinationKey, variant: row.variant, language: lang, value: current))
                }
            }
        }
    }
    func undo() {
        guard let last = staged.popLast() else { return }
        redoStack.append(last)
    }
    func redo() {
        guard let last = redoStack.popLast() else { return }
        staged.append(last)
    }
    func discard() {
        for cell in cellDrafts.values where cell.isDirty { cell.text = cell.original }
        drafts.removeAll()
        dirtyDraftCount = 0
        staged = []; redoStack = []; changes = nil
        stagedNotice = nil
    }
    func addKey() {
        guard let group = selectedGroup else {
            formError = "Select a resource in the sidebar before adding a key."
            return
        }
        let key = inputKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { formError = "Enter a non-empty key."; return }
        guard !keyExistsOrIsStaged(group: group, key: key) else {
            formError = "The key already exists or is staged in this resource."
            return
        }
        if group.hasSuffix(".stringsdict") {
            let variable = inputPluralVariable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard variable.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                formError = "Use a valid plural variable, for example count."
                return
            }
            stageFromForm(.addPlural(group: group, key: key, variable: variable, valueType: inputPluralType))
        } else {
            stageFromForm(.addKey(group: group, key: key))
        }
        showAddKeySheet = false
        inputKey = ""
    }
    func renameKey() {
        guard let row = selectedRow else { formError = "Select a translation row first."; return }
        let newKey = inputRename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newKey.isEmpty, newKey != row.key else {
            formError = "Enter a different, non-empty key."
            return
        }
        guard !keyExistsOrIsStaged(group: row.group, key: newKey) else {
            formError = "The new key already exists or is staged in this resource."
            return
        }
        stageFromForm(.renameKey(group: row.group, old: row.key, new: newKey))
        showRenameSheet = false
        inputRename = ""
    }
    func deleteKey() {
        guard let row = selectedRow else { return }
        stage(.deleteKey(group: row.group, key: row.key))
        showDeleteConfirmation = false
    }
    func addLanguage() {
        guard let group = selectedGroup else { formError = "Select a resource first."; return }
        guard selectableLanguages.contains(where: { $0.id == inputLanguage }) else {
            formError = "Choose a language not already present in this resource."
            return
        }
        let language = (inputLanguage == "__custom__" ? customLanguage : inputLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard language.range(of: #"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
            formError = "Enter a valid BCP 47 identifier, such as sr-Latn or fr-CA."
            return
        }
        let alreadyStaged = staged.contains { edit in
            if case let .addLanguage(g, locale) = edit { return g == group && locale == language }
            return false
        }
        guard !langs(group).contains(language), !alreadyStaged else {
            formError = "This language already exists or is staged in the resource."
            return
        }
        stageFromForm(.addLanguage(group: group, language: language))
        showAddLanguageSheet = false
    }
    func addVariant() {
        guard let row = selectedRow else { formError = "Select a translation row first."; return }
        guard row.group.hasSuffix(".xcstrings") || row.group.hasSuffix(".stringsdict") else {
            formError = "Variants are supported only for .xcstrings and .stringsdict."
            return
        }
        let variant = inputVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = inputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !variant.isEmpty, !language.isEmpty else {
            formError = "Provide both a language and a variant path."
            return
        }
        stageFromForm(.set(group: row.group, key: row.key, variant: variant, language: language, value: inputValue))
        showVariantSheet = false
    }
    func addComment() {
        guard let row = selectedRow else { formError = "Select a translation row first."; return }
        guard !row.group.hasSuffix(".stringsdict") else {
            formError = ".stringsdict comments are not supported."
            return
        }
        stageFromForm(.comment(group: row.group, key: row.key, text: inputComment))
        showCommentSheet = false
    }
    func review() {
        stageDrafts()
        guard let snapshot else { return }
        guard !staged.isEmpty else { message = "No changes to save"; return }
        do {
            let preview = try WorkspaceTransactions.preview(snapshot: snapshot, edits: staged)
            guard !preview.files.isEmpty else {
                message = "The staged operations produce no file changes."
                return
            }
            changes = preview
        } catch { message = error.localizedDescription }
    }
    func commit() {
        guard let set = changes else { return }
        do {
            try WorkspaceTransactions.commit(set)
            changes = nil
            load(set.root)
        } catch { message = error.localizedDescription }
    }
    func exportCSV() {
        guard let snap = snapshot else { return }
        let panel = NSSavePanel()
        panel.title = "Export translations as CSV"
        panel.nameFieldStringValue = "translations.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TranslationExchange.export(snapshot: snap, group: selectedGroup).write(to: url, atomically: true, encoding: .utf8) }
        catch { message = error.localizedDescription }
    }
    func importCSV() {
        guard let snap = snapshot else { return }
        let panel = NSOpenPanel()
        panel.title = "Import translations from CSV"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try TranslationExchange.edits(fromCSV: String(contentsOf: url, encoding: .utf8), snapshot: snap)
            for edit in imported { stage(edit) }
            message = "Staged \(imported.count) CSV changes. Review before saving."
        } catch { message = error.localizedDescription }
    }
}

@main
struct LocalizationWorkbenchApp: App {
    @StateObject private var store = WorkbenchStore()
    var body: some Scene {
        WindowGroup("Localization Workbench") {
            WorkbenchWindow(store: store)
                .frame(minWidth: 1020, minHeight: 650)
                .preferredColorScheme(nil)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { store.open() }.keyboardShortcut("o")
                Button("Open Recent Project") { store.openRecent() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Translations") {
                Button("Stage Edited Cells") { store.stageDrafts() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Review & Save…") { store.review() }.keyboardShortcut("s")
                Divider()
                Button("Undo Staged Operation") { store.undo() }.keyboardShortcut("z").disabled(store.staged.isEmpty)
                Button("Redo Staged Operation") { store.redo() }.keyboardShortcut("z", modifiers: [.command,.shift]).disabled(store.redoStack.isEmpty)
                Divider()
                Button("Export CSV…") { store.exportCSV() }.keyboardShortcut("e", modifiers: [.command,.shift])
                Button("Import CSV…") { store.importCSV() }.keyboardShortcut("i", modifiers: [.command,.shift])
            }
            CommandMenu("View") {
                Toggle("Show Inspector", isOn: $store.showInspector)
                Button("Show Diagnostics") { store.showIssues = true }.keyboardShortcut("d", modifiers: [.command,.shift])
            }
        }
    }
}

private struct WorkbenchWindow: View {
    @ObservedObject var store: WorkbenchStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 255, max: 340)
        } detail: {
            VStack(spacing: 0) {
                topToolbar
                Divider()
                if store.opening {
                    Spacer(); ProgressView("Scanning localization resources…"); Spacer()
                } else if store.snapshot == nil {
                    welcome
                } else {
                    HSplitView {
                        translationMatrix
                            .frame(minWidth: 550)
                        if store.showInspector {
                            inspector
                                .frame(minWidth: 220, idealWidth: 285, maxWidth: 370)
                        }
                    }
                    bottomBar
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Color(red: 0.2, green: 0.65, blue: 0.61))
        .alert("Localization Workbench", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .sheet(isPresented: $store.showIssues) { diagnosticsSheet }
        .sheet(isPresented: $store.showOperations) { operationsSheet }
        .sheet(isPresented: $store.showAddKeySheet, onDismiss: { store.didDismissForm() }) { addKeySheet }
        .sheet(isPresented: $store.showRenameSheet, onDismiss: { store.didDismissForm() }) { renameSheet }
        .sheet(isPresented: $store.showAddLanguageSheet, onDismiss: { store.didDismissForm() }) { addLanguageSheet }
        .sheet(isPresented: $store.showVariantSheet, onDismiss: { store.didDismissForm() }) { variantSheet }
        .sheet(isPresented: $store.showCommentSheet, onDismiss: { store.didDismissForm() }) { commentSheet }
        .sheet(isPresented: Binding(get: { store.changes != nil }, set: { if !$0 { store.changes = nil } })) { changeReview }
        .confirmationDialog("Delete this key from all translations in this resource?", isPresented: $store.showDeleteConfirmation) {
            Button("Stage Key Deletion", role: .destructive) { store.deleteKey() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe.americas.fill")
                    .font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LOCALIZATION").font(.caption2.weight(.heavy)).tracking(1.1)
                    Text("WORKBENCH").font(.caption2.weight(.heavy)).tracking(1.1)
                }
                Spacer()
            }
            .padding(.horizontal, 15).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button { store.selectedGroup = nil; store.selectedRowID = nil } label: {
                        HStack {
                            Image(systemName: "square.grid.2x2")
                            Text("All resources")
                            Spacer()
                            Text("\(store.groups.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(9)
                        .background(store.selectedGroup == nil ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(["xcstrings", "strings", "stringsdict"], id: \.self) { ext in
                        let groups = store.groups.filter { $0.hasSuffix("." + ext) }
                        if !groups.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ext == "xcstrings" ? "STRING CATALOGS" : ext == "strings" ? "LEGACY STRINGS" : "PLURAL DICTIONARIES")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 8)
                                ForEach(groups, id: \.self) { group in
                                    Button {
                                        store.selectedGroup = group
                                        store.selectedRowID = nil
                                    } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: store.fileIcon(group)).frame(width: 18)
                                                Text(group).lineLimit(2).truncationMode(.middle).font(.system(size: 12, weight: .medium))
                                                Spacer(minLength: 1)
                                            }
                                            HStack {
                                                ProgressView(value: store.completion(group))
                                                    .controlSize(.mini)
                                                Text("\(Int(store.completion(group)*100))%")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(9)
                                        .background(store.selectedGroup == group ? Color.accentColor.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(store.rootName).lineLimit(1).truncationMode(.middle).font(.caption)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button { store.open() } label: { Label("Open…", systemImage: "folder.badge.plus") }
                    Spacer()
                    Text("\(store.snapshot?.documents.count ?? 0) files")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedGroup?.components(separatedBy: "/").last ?? store.rootName)
                    .font(.headline).lineLimit(1)
                Text(store.selectedGroup == nil ? "Project overview" : (store.selectedGroup ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 150, maxWidth: 260, alignment: .leading)
            Spacer(minLength: 2)
            Button { store.prepareAddKey() } label: { Label("Key", systemImage: "plus") }
                .disabled(store.selectedGroup == nil)
                .help("Add a key to selected resource")
            Button { store.prepareAddLanguage() } label: { Label("Language", systemImage: "globe.badge.chevron.backward") }
                .disabled(store.selectedGroup == nil)
            Button { store.importCSV() } label: { Image(systemName: "square.and.arrow.down") }.help("Import CSV")
            Button { store.exportCSV() } label: { Image(systemName: "square.and.arrow.up") }.help("Export CSV")
            Divider().frame(height: 20)
            Button { store.showIssues = true } label: {
                Label("\(store.snapshot?.issues.count ?? 0)", systemImage: "exclamationmark.triangle")
            }.help("Diagnostics")
            Button { store.showOperations = true } label: {
                Label("\(store.staged.count)", systemImage: "tray.full")
            }.help("Staged operations")
            Button { store.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle Inspector")
            Button { store.review() } label: { Label("Review & Save", systemImage: "checkmark.shield") }
                .buttonStyle(.borderedProminent)
                .disabled(store.snapshot == nil || (store.staged.isEmpty && store.unsavedDraftCount == 0))
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var translationMatrix: some View {
        // Resolve these once per matrix update, not inside each row/cell.
        let visibleRows = store.rows
        let languages = store.langs(store.selectedGroup)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search keys, values or variants", text: $store.search)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Picker("Filter", selection: $store.filter) {
                    ForEach(WorkbenchStore.Filter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 110)
                Text("\(visibleRows.count) rows").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if visibleRows.isEmpty {
                Spacer()
                ContentUnavailableView("No matching translations", systemImage: "text.magnifyingglass", description: Text("Try another resource or filter"))
                Spacer()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            matrixHeading("KEY / VARIANT", width: MatrixMetrics.keyWidth)
                            matrixSeparator
                            ForEach(languages, id: \.self) { lang in
                                matrixHeading(lang.uppercased(), width: MatrixMetrics.languageWidth)
                                matrixSeparator
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        // The row's identity is the domain ID. Enumerating an array on
                        // every redraw used to allocate unnecessarily during typing.
                        ForEach(visibleRows) { row in
                            HStack(alignment: .top, spacing: 0) {
                                Button {
                                    store.selectedRowID = row.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .top) {
                                            Text(row.key)
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.primary)
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 3)
                                            if store.isProblem(row) { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                                        }
                                        if !row.variant.isEmpty {
                                            Text(row.variant)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        if store.isChanged(row) {
                                            Label("Modified", systemImage: "circle.fill")
                                                .font(.system(size: 9)).foregroundStyle(.mint)
                                        }
                                    }
                                    .padding(10)
                                    .frame(width: MatrixMetrics.keyWidth, height: MatrixMetrics.rowHeight, alignment: .topLeading)
                                    .background(store.selectedRowID == row.id ? Color.accentColor.opacity(0.17) : .clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Copy Key") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.key, forType: .string)
                                    }
                                    Button("Rename Key…") { store.prepareRename(row) }
                                    Button("Add Variant…") { store.prepareVariant(row) }
                                        .disabled(row.group.hasSuffix(".strings"))
                                    Divider()
                                    Button("Delete Key…", role: .destructive) {
                                        store.selectedRowID = row.id
                                        store.showDeleteConfirmation = true
                                    }
                                }
                                matrixSeparator
                                ForEach(languages, id: \.self) { lang in
                                    MatrixTranslationCell(row: row, language: lang,
                                                          draft: store.cellDraft(for: row, language: lang))
                                    matrixSeparator
                                }
                            }
                            .frame(height: MatrixMetrics.rowHeight)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.12))
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.secondary.opacity(0.10)).frame(height: 0.5)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var matrixSeparator: some View {
        Rectangle().fill(Color.secondary.opacity(0.12))
            .frame(width: MatrixMetrics.separatorWidth)
    }
    private func matrixHeading(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            // Padding is INSIDE the fixed-width frame. It used to add 20pt
            // on top of width, which desynchronized every subsequent column.
            .padding(.horizontal, 10)
            .frame(width: width, height: MatrixMetrics.headerHeight, alignment: .leading)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("INSPECTOR").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "slider.horizontal.3").foregroundStyle(.tertiary)
            }.padding(.top, 15)
            if let row = store.selectedRow {
                Text(row.key).font(.title3.weight(.semibold)).textSelection(.enabled)
                if !row.variant.isEmpty {
                    Text(row.variant).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(row.group).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                Text("Translations").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(store.langs(row.group), id: \.self) { lang in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(lang).font(.subheadline.bold())
                                    Spacer()
                                    if (row.values[lang] ?? "").isEmpty { Text("Missing").font(.caption2).foregroundStyle(.orange) }
                                }
                                InspectorTranslationEditor(draft: store.cellDraft(for: row, language: lang))
                            }
                        }
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    Button("Rename") { store.prepareRename(row) }
                    Button("Variant") { store.prepareVariant(row) }
                        .disabled(row.group.hasSuffix(".strings"))
                    Button("Comment") { store.prepareComment() }
                        .disabled(row.group.hasSuffix(".stringsdict"))
                }.controlSize(.small)
                Button(role: .destructive) { store.showDeleteConfirmation = true } label: {
                    Label("Delete key across locales", systemImage: "trash")
                }.controlSize(.small)
                Spacer(minLength: 0)
            } else {
                Spacer()
                Image(systemName: "character.book.closed")
                    .font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                Text("Select a translation row to edit or inspect its language values")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 15)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Circle().fill(store.snapshot?.issues.contains(where: { $0.severity == .error }) == true ? Color.red : Color.green).frame(width: 7, height: 7)
            Text("\(store.snapshot?.documents.count ?? 0) documents")
            Text("\(store.snapshot?.languages.count ?? 0) languages")
            Text("\(store.unsavedDraftCount) edited cells")
            Text("\(store.staged.count) staged operations")
            if let notice = store.stagedNotice {
                Text(notice).foregroundStyle(.green).lineLimit(1).help(notice)
            }
            Spacer()
            Button("Stage edits") { store.stageDrafts() }.buttonStyle(.link).disabled(store.unsavedDraftCount == 0)
            Button("Discard") { store.discard() }.buttonStyle(.link).disabled(store.staged.isEmpty && store.unsavedDraftCount == 0)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "character.book.closed.fill").font(.system(size: 66)).foregroundStyle(.mint)
            Text("All languages. One workbench.").font(.title.bold())
            Text("Edit .strings, .stringsdict and .xcstrings side by side.\nKeep backups and inspect every write before it reaches your project.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Open Project…") { store.open() }.buttonStyle(.borderedProminent)
                Button("Open Recent") { store.openRecent() }
            }.controlSize(.large)
            Spacer()
            Text("LOCAL FILES ONLY · NO NETWORK UPLOAD").font(.caption2.bold()).tracking(1.4).foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    private var diagnosticsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Localization Diagnostics", systemImage: "exclamationmark.triangle").font(.title2.bold())
                Spacer()
                Text("\(store.snapshot?.issues.count ?? 0) findings").foregroundStyle(.secondary)
            }
            List(store.snapshot?.issues ?? []) { issue in
                HStack(alignment: .top) {
                    Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.file).font(.subheadline.bold())
                        Text(issue.detail).font(.caption).textSelection(.enabled)
                    }
                }.padding(.vertical, 3)
            }
            HStack { Spacer(); Button("Close") { store.showIssues = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 770, height: 530)
    }
    private var operationsSheet: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Staged Operations").font(.title2.bold())
            Text("Operations are applied in order to an in-memory copy of project files.")
                .font(.caption).foregroundStyle(.secondary)
            List(Array(store.staged.enumerated()), id: \.offset) { index, edit in
                HStack {
                    Text("\(index + 1).").foregroundStyle(.secondary).font(.caption.monospacedDigit())
                    Text(edit.summary).textSelection(.enabled)
                    Spacer()
                    Button { store.removeStaged(at: index) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Undo") { store.undo() }.disabled(store.staged.isEmpty)
                Button("Redo") { store.redo() }.disabled(store.redoStack.isEmpty)
                Button("Discard All", role: .destructive) { store.discard() }
                Spacer()
                Button("Close") { store.showOperations = false }
                Button("Review & Save") { store.showOperations = false; store.review() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 670, height: 410)
    }

    private var addKeySheet: some View {
        formSheet("Add Localization Key", hint: "Creates a blank translation in each .strings language, or a new .xcstrings entry.") {
            TextField("Key", text: $store.inputKey)
            if store.selectedGroup?.hasSuffix(".stringsdict") == true {
                TextField("Plural variable (e.g. count)", text: $store.inputPluralVariable)
                Picker("Numeric value type", selection: $store.inputPluralType) {
                    ForEach(["d", "i", "u", "ld", "lld", "f"], id: \.self) { Text($0).tag($0) }
                }
            }
        } action: {
            store.addKey()
        }
    }
    private var renameSheet: some View {
        formSheet("Rename Key", hint: "Changes the key in every language of this resource, retaining existing values.") {
            TextField("New key", text: $store.inputRename)
        } action: { store.renameKey() }
    }
    private var addLanguageSheet: some View {
        formSheet("Add Language", hint: "Choose a language for the selected resource. Xcode project membership for new .lproj files must be configured separately.") {
            Picker("Language", selection: $store.inputLanguage) {
                ForEach(store.selectableLanguages) { choice in
                    Text("\(choice.name) (\(choice.id))").tag(choice.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.inputLanguage == "__custom__" {
                TextField("BCP 47 identifier (e.g. sr-Latn)", text: $store.customLanguage)
            }
        } action: { store.addLanguage() }
    }
    private var variantSheet: some View {
        formSheet("Edit or Add Variant", hint: "For catalogs: variations/plural/one or variations/device/iphone. For .stringsdict: count/one.") {
            TextField("Language", text: $store.inputLanguage)
            TextField("Variant path", text: $store.inputVariant)
            TextField("Translation", text: $store.inputValue, axis: .vertical).lineLimit(2...5)
        } action: { store.addVariant() }
    }
    private var commentSheet: some View {
        formSheet("Add Translator Comment", hint: "For .strings this inserts a new /* comment */ before the key. For .xcstrings it updates the entry comment.") {
            TextField("Comment", text: $store.inputComment, axis: .vertical).lineLimit(3...6)
        } action: { store.addComment() }
    }
    private func formSheet<Fields: View>(_ title: String, hint: String, @ViewBuilder fields: () -> Fields, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(title).font(.title2.bold())
            Text(hint).font(.callout).foregroundStyle(.secondary)
            fields()
            if let error = store.formError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { closeForms() }.keyboardShortcut(.cancelAction)
                Button("Stage Operation") { action() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 500)
    }
    private func closeForms() {
        store.showAddKeySheet = false; store.showRenameSheet = false; store.showAddLanguageSheet = false
        store.showVariantSheet = false; store.showCommentSheet = false
    }
    private var changeReview: some View {
        ChangeReviewSheet(store: store)
    }
}

/// The matrix cell observes only its own text, so editing one language does not
/// trigger a full matrix layout and redraw. Long text stays editable in Inspector.
private struct MatrixTranslationCell: View {
    let row: TranslationRow
    let language: String
    @ObservedObject var draft: TranslationCellDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if draft.isDirty {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.mint)
                    Text("Edited").font(.system(size: 9)).foregroundStyle(.mint)
                } else if draft.original.isEmpty {
                    Image(systemName: "circle.dotted").foregroundStyle(.orange)
                    Text("Missing").font(.system(size: 9)).foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Translated").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextField("Enter translation", text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...3)
                .font(.system(size: 12))
                .accessibilityLabel("\(row.key), \(language)")
        }
        .padding(9)
        .frame(width: MatrixMetrics.languageWidth, height: MatrixMetrics.rowHeight, alignment: .topLeading)
        .background(draft.isDirty ? Color.accentColor.opacity(0.07) : .clear)
    }
}

private struct InspectorTranslationEditor: View {
    @ObservedObject var draft: TranslationCellDraft

    var body: some View {
        TextEditor(text: $draft.text)
            .font(.system(.body, design: .monospaced))
            .frame(height: 83)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
    }
}

private struct ChangeReviewSheet: View {
    @ObservedObject var store: WorkbenchStore
    @State private var selectedPath: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Changes").font(.title2.bold())
                    Text("No source file will be modified until you confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(store.changes?.files.count ?? 0) files", systemImage: "doc.on.doc")
            }
            HSplitView {
                List(selection: $selectedPath) {
                    ForEach(store.changes?.files ?? []) { file in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.url.lastPathComponent).font(.callout.bold())
                            Text(file.url.deletingLastPathComponent().lastPathComponent)
                                .font(.caption2).foregroundStyle(.secondary)
                            if file.rewrite {
                                Label("Whole-file reformat", systemImage: "exclamationmark.triangle")
                                    .font(.caption2).foregroundStyle(.orange)
                            } else {
                                Text(file.added ? "New file" : "Targeted edit").font(.caption2).foregroundStyle(.mint)
                            }
                        }
                        .tag(file.url.path)
                        .padding(.vertical, 4)
                    }
                }.frame(minWidth: 210, idealWidth: 255)
                if let file = store.changes?.files.first(where: { $0.url.path == (selectedPath ?? store.changes?.files.first?.url.path) }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file.url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if file.rewrite {
                            Label("Structure change: the serializer may reorder keys or normalize whitespace. Review the full before/after data.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack(spacing: 10) {
                            previewPane("BEFORE", file.originalText)
                            Divider()
                            previewPane("AFTER", file.updatedText)
                        }
                    }.padding(10)
                } else { ContentUnavailableView("No changed files", systemImage: "checkmark.circle") }
            }
            HStack {
                Label("Automatic backups and external-edit conflict checking are enabled", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.changes = nil }.keyboardShortcut(.cancelAction)
                Button("Save All + Backup") { store.commit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.changes?.files.isEmpty != false)
            }
        }.padding(18).frame(minWidth: 940, minHeight: 590)
    }
    private func previewPane(_ title: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(String(source.prefix(60000)) + (source.count > 60000 ? "\n… Preview limited to 60,000 characters" : ""))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
        }.frame(maxWidth: .infinity)
    }
}
#else
@main
struct LocalizationWorkbenchApp {
    static func main() { print("Open this SwiftUI application with Xcode on macOS 14+.") }
}
#endif
