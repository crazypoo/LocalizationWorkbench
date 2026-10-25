#if os(macOS)
import AppKit
import SwiftUI
import LocalizationCore

@MainActor
final class WorkbenchStore: ObservableObject {
    @Published var snapshot: WorkspaceSnapshot?
    @Published var selectedGroup: String?
    @Published var selectedRowID: String?
    @Published var search = ""
    @Published var filter: Filter = .all
    @Published var drafts: [String: String] = [:]
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

    @Published var inputKey = ""
    @Published var inputPluralVariable = "count"
    @Published var inputPluralType = "d"
    @Published var inputRename = ""
    @Published var inputLanguage = "fr"
    @Published var inputVariant = "variations/plural/one"
    @Published var inputValue = ""
    @Published var inputComment = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", missing = "Missing", changed = "Changed", issues = "Warnings"
        var id: String { rawValue }
    }

    var groups: [String] { Array(Set(snapshot?.documents.map(\.group) ?? [])).sorted() }
    var selectedRow: TranslationRow? { snapshot?.rows.first { $0.id == selectedRowID } }
    var rootName: String { snapshot?.root.lastPathComponent ?? "No project" }

    func langs(_ group: String?) -> [String] {
        guard let snap = snapshot else { return [] }
        guard let group else { return snap.languages }
        var found = Set(snap.documents.filter { $0.group == group }.compactMap(\.language))
        for row in snap.rows where row.group == group { found.formUnion(row.values.keys) }
        if found.isEmpty, let doc = snap.documents.first(where: { $0.group == group && $0.format == .xcstrings }),
           let bytes = try? Data(contentsOf: doc.url),
           let dict = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           let source = dict["sourceLanguage"] as? String { found.insert(source) }
        return found.sorted()
    }

    func isMissing(_ row: TranslationRow) -> Bool {
        langs(row.group).contains { (row.values[$0] ?? "").isEmpty }
    }
    func isProblem(_ row: TranslationRow) -> Bool {
        (snapshot?.issues ?? []).contains { $0.file == row.group && $0.detail.contains(row.key) }
    }
    func isChanged(_ row: TranslationRow) -> Bool {
        langs(row.group).contains { getDraft(row, $0) != (row.values[$0] ?? "") } ||
        staged.contains { $0.summary.contains(row.key) }
    }
    var rows: [TranslationRow] {
        guard let snap = snapshot else { return [] }
        return snap.rows.filter { row in
            (selectedGroup == nil || selectedGroup == row.group) &&
            (search.isEmpty || row.key.localizedCaseInsensitiveContains(search) || row.variant.localizedCaseInsensitiveContains(search) || row.values.values.contains { $0.localizedCaseInsensitiveContains(search) }) &&
            (filter == .all || filter == .missing && isMissing(row) || filter == .changed && isChanged(row) || filter == .issues && isProblem(row))
        }
    }
    func completion(_ group: String) -> Double {
        guard let snap = snapshot else { return 0 }
        let r = snap.rows.filter { $0.group == group }
        let target = langs(group)
        let all = r.count * target.count
        guard all > 0 else { return 0 }
        let present = r.reduce(0) { total, row in total + target.filter { !(row.values[$0] ?? "").isEmpty }.count }
        return Double(present) / Double(all)
    }
    func fileIcon(_ group: String) -> String {
        if group.hasSuffix("xcstrings") { return "curlybraces.square" }
        if group.hasSuffix("stringsdict") { return "text.badge.star" }
        return "doc.plaintext"
    }
    func cacheKey(_ row: TranslationRow, _ lang: String) -> String { row.id + "||" + lang }
    func getDraft(_ row: TranslationRow, _ lang: String) -> String { drafts[cacheKey(row, lang)] ?? row.values[lang] ?? "" }
    func setDraft(_ row: TranslationRow, _ lang: String, value: String) { drafts[cacheKey(row, lang)] = value }
    var unsavedDraftCount: Int {
        guard let snap = snapshot else { return 0 }
        return snap.rows.reduce(0) { count, row in
            count + langs(row.group).filter { getDraft(row, $0) != (row.values[$0] ?? "") }.count
        }
    }

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
                snapshot = newSnapshot
                selectedGroup = selected.flatMap { g in newSnapshot.documents.contains { $0.group == g } ? g : nil }
                selectedRowID = nil
                drafts = [:]
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
        drafts = [:]; staged = []; redoStack = []; changes = nil
    }
    func addKey() {
        guard let group = selectedGroup, !inputKey.isEmpty else { return }
        if group.hasSuffix(".stringsdict") {
            stage(.addPlural(group: group, key: inputKey, variable: inputPluralVariable, valueType: inputPluralType))
        } else {
            stage(.addKey(group: group, key: inputKey))
        }
        showAddKeySheet = false; inputKey = ""
    }
    func renameKey() {
        guard let row = selectedRow, !inputRename.isEmpty else { return }
        stage(.renameKey(group: row.group, old: row.key, new: inputRename))
        showRenameSheet = false; inputRename = ""
    }
    func deleteKey() {
        guard let row = selectedRow else { return }
        stage(.deleteKey(group: row.group, key: row.key))
        showDeleteConfirmation = false
    }
    func addLanguage() {
        guard let group = selectedGroup, !inputLanguage.isEmpty else { return }
        stage(.addLanguage(group: group, language: inputLanguage))
        showAddLanguageSheet = false
    }
    func addVariant() {
        guard let row = selectedRow, !inputVariant.isEmpty, !inputLanguage.isEmpty else { return }
        stage(.set(group: row.group, key: row.key, variant: inputVariant, language: inputLanguage, value: inputValue))
        showVariantSheet = false
    }
    func addComment() {
        guard let row = selectedRow else { return }
        stage(.comment(group: row.group, key: row.key, text: inputComment))
        showCommentSheet = false
    }
    func review() {
        stageDrafts()
        guard let snapshot else { return }
        guard !staged.isEmpty else { message = "No changes to save"; return }
        do { changes = try WorkspaceTransactions.preview(snapshot: snapshot, edits: staged) }
        catch { message = error.localizedDescription }
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
        .sheet(isPresented: $store.showAddKeySheet) { addKeySheet }
        .sheet(isPresented: $store.showRenameSheet) { renameSheet }
        .sheet(isPresented: $store.showAddLanguageSheet) { addLanguageSheet }
        .sheet(isPresented: $store.showVariantSheet) { variantSheet }
        .sheet(isPresented: $store.showCommentSheet) { commentSheet }
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
            Button { store.showAddKeySheet = true } label: { Label("Key", systemImage: "plus") }
                .disabled(store.selectedGroup == nil)
                .help("Add a key to selected resource")
            Button { store.showAddLanguageSheet = true } label: { Label("Language", systemImage: "globe.badge.chevron.backward") }
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search keys, values or variants", text: $store.search)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Picker("Filter", selection: $store.filter) {
                    ForEach(WorkbenchStore.Filter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 110)
                Text("\(store.rows.count) rows").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if store.rows.isEmpty {
                Spacer()
                ContentUnavailableView("No matching translations", systemImage: "text.magnifyingglass", description: Text("Try another resource or filter"))
                Spacer()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            matrixHeading("KEY / VARIANT", width: 230)
                            ForEach(store.langs(store.selectedGroup), id: \.self) { lang in
                                matrixHeading(lang.uppercased(), width: 265)
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
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
                                    .frame(width: 230, alignment: .leading)
                                    .frame(minHeight: 64, alignment: .topLeading)
                                    .background(store.selectedRowID == row.id ? Color.accentColor.opacity(0.17) : .clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Copy Key") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.key, forType: .string)
                                    }
                                    Button("Rename Key…") {
                                        store.selectedRowID = row.id
                                        store.inputRename = row.key
                                        store.showRenameSheet = true
                                    }
                                    Button("Add Variant…") {
                                        store.selectedRowID = row.id
                                        store.inputLanguage = store.langs(row.group).first ?? "en"
                                        store.showVariantSheet = true
                                    }
                                    Divider()
                                    Button("Delete Key…", role: .destructive) {
                                        store.selectedRowID = row.id
                                        store.showDeleteConfirmation = true
                                    }
                                }
                                Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1)
                                ForEach(store.langs(store.selectedGroup), id: \.self) { lang in
                                    matrixCell(row: row, lang: lang)
                                    Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1)
                                }
                            }
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.028))
                            Divider().opacity(0.6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func matrixHeading(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 13)
            .border(Color.secondary.opacity(0.1), width: 0.5)
    }
    private func matrixCell(row: TranslationRow, lang: String) -> some View {
        let value = row.values[lang]
        let dirty = store.getDraft(row, lang) != (value ?? "")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if value == nil || value == "" {
                    Image(systemName: "circle.dotted").foregroundStyle(.orange)
                    Text("Missing").font(.system(size: 9)).foregroundStyle(.orange)
                } else if dirty {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.mint)
                    Text("Edited").font(.system(size: 9)).foregroundStyle(.mint)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Translated").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextField("Enter translation", text: Binding(
                get: { store.getDraft(row, lang) },
                set: { store.setDraft(row, lang, value: $0) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .font(.system(size: 12))
            .accessibilityLabel("\(row.key), \(lang)")
        }
        .padding(9)
        .frame(width: 265, alignment: .leading)
        .frame(minHeight: 64, alignment: .topLeading)
        .background(dirty ? Color.accentColor.opacity(0.07) : .clear)
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
                                TextEditor(text: Binding(
                                    get: { store.getDraft(row, lang) },
                                    set: { store.setDraft(row, lang, value: $0) }
                                ))
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 83)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
                            }
                        }
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    Button("Rename") { store.inputRename = row.key; store.showRenameSheet = true }
                    Button("Variant") { store.inputLanguage = store.langs(row.group).first ?? "en"; store.showVariantSheet = true }
                    Button("Comment") { store.showCommentSheet = true }
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
                    Button { store.staged.remove(at: index) } label: { Image(systemName: "xmark.circle") }
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
        formSheet("Add Language", hint: "Use a BCP 47 identifier such as fr, es, zh-Hans or pt-BR. Xcode project membership for new .lproj files must be configured separately.") {
            TextField("Language identifier", text: $store.inputLanguage)
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
