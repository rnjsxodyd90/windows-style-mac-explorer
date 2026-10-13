import AppKit
import Quartz
import SwiftUI

@main
struct FileExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Windows Style Mac Explorer", id: "explorer") {
            ExplorerView()
        }
        .defaultSize(width: 1150, height: 720)
        .commands { ExplorerCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare `swift run` binary has no .app bundle, so macOS starts it without a Dock icon or keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ExplorerKey: FocusedValueKey {
    typealias Value = Explorer
}

extension FocusedValues {
    var explorer: Explorer? {
        get { self[ExplorerKey.self] }
        set { self[ExplorerKey.self] = newValue }
    }
}

// Ribbon buttons only exist while their tab is showing, so their keyboard shortcuts live in the menu bar instead.
struct ExplorerCommands: Commands {
    @FocusedValue(\.explorer) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { model?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Rename") { model?.renameSelection() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
            Button("Properties") {
                if let model { model.showProperties(model.selection) }
            }
            .keyboardShortcut("i")
        }
    }
}

// MARK: - Model

struct FileItem: Identifiable {
    let url: URL
    let name: String
    let isFolder: Bool
    let modified: Date
    let kind: String
    let size: Int64
    var id: String { url.path }

    init(_ url: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .fileSizeKey]
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys)
        self.url = url
        name = url.lastPathComponent
        isFolder = values?.isDirectory == true && values?.isPackage != true
        modified = values?.contentModificationDate ?? .distantPast
        kind = values?.localizedTypeDescription ?? ""
        size = Int64(values?.fileSize ?? 0)
    }
}

func displayName(_ url: URL) -> String {
    FileManager.default.displayName(atPath: url.path)
}

func itemCount(_ n: Int) -> String {
    n == 1 ? "1 item" : "\(n) items"
}

func uniqueURL(_ name: String, in folder: URL) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var url = folder.appending(path: name)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = folder.appending(path: ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        n += 1
    }
    return url
}

@MainActor @Observable
final class Explorer {
    private static let defaultPins = ["Desktop", "Downloads", "Documents", "Pictures"]
        .map { FileManager.default.homeDirectoryForCurrentUser.appending(path: $0).path }

    var current: URL {
        didSet {
            search = ""
            reload()
        }
    }
    private(set) var back: [URL] = []
    private(set) var forward: [URL] = []
    private(set) var items: [FileItem] = []
    private(set) var cut: Set<FileItem.ID> = []
    var selection: Set<FileItem.ID> = []
    var sortOrder = [KeyPathComparator(\FileItem.name, comparator: String.StandardComparator.localizedStandard)]
    var search = ""
    var showHidden = false {
        didSet { reload() }
    }
    var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinned") ?? Explorer.defaultPins {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned") }
    }
    var renaming: FileItem.ID?
    var newName = ""
    var properties: FileItem?
    var errorMessage: String?

    init(at folder: URL = FileManager.default.homeDirectoryForCurrentUser) {
        current = folder
        reload()
    }

    var visible: [FileItem] {
        let matches = search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let sorted = matches.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    func reload() {
        do {
            items = try FileManager.default
                .contentsOfDirectory(at: current, includingPropertiesForKeys: nil, options: showHidden ? [] : .skipsHiddenFiles)
                .map(FileItem.init)
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
        selection.formIntersection(items.map(\.id))
    }

    // MARK: Navigation

    func go(to url: URL) {
        guard url.path != current.path else { return }
        back.append(current)
        forward.removeAll()
        current = url
    }

    func goBack() {
        guard let url = back.popLast() else { return }
        forward.append(current)
        current = url
    }

    func goForward() {
        guard let url = forward.popLast() else { return }
        back.append(current)
        current = url
    }

    func goUp() {
        if current.path != "/" { go(to: current.deletingLastPathComponent()) }
    }

    func open(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            errorMessage = "Can't find \"\(path)\". Check the spelling and try again."
            return
        }
        if isFolder.boolValue { go(to: url) } else { NSWorkspace.shared.open(url) }
    }

    func open(_ ids: Set<FileItem.ID>) {
        let targets = items.filter { ids.contains($0.id) }
        if targets.count == 1, targets[0].isFolder {
            go(to: targets[0].url)
        } else {
            targets.forEach { NSWorkspace.shared.open($0.url) }
        }
    }

    func pin(_ ids: Set<FileItem.ID>) {
        let folders = items.filter { ids.contains($0.id) && $0.isFolder }.map(\.id)
        for path in folders.isEmpty ? [current.path] : folders where !pinned.contains(path) {
            pinned.append(path)
        }
    }

    func showProperties(_ ids: Set<FileItem.ID>) {
        properties = items.first { ids.contains($0.id) } ?? FileItem(current)
    }

    // MARK: File operations
    // TODO: file operations run synchronously on the main thread; move them to a background task with a progress bar if large copies freeze the UI.

    func newFolder() {
        let url = uniqueURL("New folder", in: current)
        guard attempt({ try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }) else { return }
        reload()
        selection = [url.path]
        startRename(url.path)
    }

    func startRename(_ id: FileItem.ID) {
        renaming = id
        newName = URL(fileURLWithPath: id).lastPathComponent
    }

    func renameSelection() {
        if selection.count == 1, let id = selection.first { startRename(id) }
    }

    func rename(_ id: FileItem.ID, to name: String) {
        let source = URL(fileURLWithPath: id)
        guard name != source.lastPathComponent else { return }
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = "A name can't be empty or contain \"/\"."
            return
        }
        let target = source.deletingLastPathComponent().appending(path: name)
        guard attempt({ try FileManager.default.moveItem(at: source, to: target) }) else { return }
        reload()
        selection = [target.path]
    }

    func copy(_ ids: Set<FileItem.ID>, cut isCut: Bool) {
        guard !ids.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(ids.map { URL(fileURLWithPath: $0) as NSURL })
        cut = isCut ? ids : []
    }

    func copyPaths(_ ids: Set<FileItem.ID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.sorted().joined(separator: "\n"), forType: .string)
    }

    func paste() {
        let sources = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let move = !cut.isEmpty && Set(sources.map(\.path)) == cut
        place(sources, in: current, move: move)
        if move { cut = [] }
    }

    func transfer(_ ids: Set<FileItem.ID>, move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = move ? "Move Here" : "Copy Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        place(ids.map { URL(fileURLWithPath: $0) }, in: folder, move: move)
    }

    private func place(_ sources: [URL], in folder: URL, move: Bool) {
        for source in sources where !(move && source.deletingLastPathComponent().path == folder.path) {
            let target = uniqueURL(source.lastPathComponent, in: folder)
            attempt {
                if move {
                    try FileManager.default.moveItem(at: source, to: target)
                } else {
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
        }
        reload()
    }

    func trash(_ ids: Set<FileItem.ID>) {
        for id in ids {
            attempt { try FileManager.default.trashItem(at: URL(fileURLWithPath: id), resultingItemURL: nil) }
        }
        reload()
    }

    func zip(_ ids: Set<FileItem.ID>) {
        let names = ids.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        guard let first = names.first else { return }
        let archive = uniqueURL(names.count == 1 ? "\(first).zip" : "Archive.zip", in: current)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = current
        process.arguments = ["-qry", archive.lastPathComponent, "--"] + names
        guard attempt({ try process.run() }) else { return }
        process.waitUntilExit()
        if process.terminationStatus != 0 { errorMessage = "Couldn't create \(archive.lastPathComponent)." }
        reload()
        selection = [archive.path]
    }

    @discardableResult
    private func attempt(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Views

let windowsBlue = Color(red: 0.1, green: 0.47, blue: 0.79)

enum RibbonTab: String, CaseIterable {
    case home = "Home", share = "Share", view = "View"
}

struct ExplorerView: View {
    @State private var model = Explorer()
    @State private var tab = RibbonTab.home
    @State private var showNavigationPane = true
    @State private var showPreviewPane = false
    @State private var showExtensions = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            addressRow
            Divider()
            HSplitView {
                if showNavigationPane {
                    NavigationPane(model: model)
                        .frame(minWidth: 200, idealWidth: 220, maxWidth: 320)
                }
                fileTable
                    .frame(minWidth: 380)
                    .layoutPriority(1)
                if showPreviewPane {
                    PreviewPane(url: model.selection.count == 1 ? model.selection.first.map { URL(fileURLWithPath: $0) } : nil)
                        .frame(minWidth: 220, idealWidth: 300)
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 450)
        .navigationTitle(displayName(model.current))
        .focusedSceneValue(\.explorer, model)
        .sheet(item: $model.properties) { PropertiesView(item: $0) }
        .alert("Rename", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }), presenting: model.renaming) { id in
            TextField("Name", text: $model.newName)
            Button("Rename") { model.rename(id, to: model.newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }), presenting: model.errorMessage) { _ in
        } message: { message in
            Text(message)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }

    // MARK: Ribbon

    private var ribbon: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Menu {
                    Button("Open new window") { openWindow(id: "explorer") }
                    Button("Open Terminal here") {
                        NSWorkspace.shared.open([model.current], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
                    }
                    Divider()
                    Button("Close") { NSApp.keyWindow?.performClose(nil) }
                } label: {
                    Text("File")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .background(windowsBlue)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                ForEach(RibbonTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(tab == item ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .overlay { if tab == item { Rectangle().strokeBorder(.separator) } }
                            .contentShape(Rectangle())
                    }
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.leading, 8)
            .padding(.top, 4)
            Group {
                switch tab {
                case .home: homeTab
                case .share: shareTab
                case .view: viewTab
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            Divider()
        }
    }

    private var homeTab: some View {
        let none = model.selection.isEmpty
        return HStack(alignment: .top, spacing: 0) {
            RibbonGroup(title: "Clipboard") {
                RibbonButton(title: "Pin to Quick\naccess", icon: "pin.fill", large: true) { model.pin(model.selection) }
                RibbonButton(title: "Copy", icon: "doc.on.doc", large: true) { model.copy(model.selection, cut: false) }
                    .disabled(none)
                RibbonButton(title: "Paste", icon: "doc.on.clipboard", color: .brown, large: true, action: model.paste)
                VStack(alignment: .leading, spacing: 5) {
                    RibbonButton(title: "Cut", icon: "scissors") { model.copy(model.selection, cut: true) }
                    RibbonButton(title: "Copy path", icon: "link") { model.copyPaths(model.selection) }
                }
                .disabled(none)
            }
            RibbonGroup(title: "Organize") {
                RibbonButton(title: "Move\nto", icon: "arrowshape.turn.up.right", large: true) { model.transfer(model.selection, move: true) }
                RibbonButton(title: "Copy\nto", icon: "plus.square.on.square", large: true) { model.transfer(model.selection, move: false) }
                RibbonButton(title: "Delete", icon: "xmark", color: .red, large: true) { model.trash(model.selection) }
                RibbonButton(title: "Rename", icon: "pencil", large: true, action: model.renameSelection)
                    .disabled(model.selection.count != 1)
            }
            .disabled(none)
            RibbonGroup(title: "New") {
                RibbonButton(title: "New\nfolder", icon: "folder.fill.badge.plus", color: .orange, large: true, action: model.newFolder)
            }
            RibbonGroup(title: "Open") {
                RibbonButton(title: "Properties", icon: "info.circle", large: true) { model.showProperties(model.selection) }
                RibbonButton(title: "Open", icon: "arrow.up.right.square") { model.open(model.selection) }
                    .disabled(none)
            }
            RibbonGroup(title: "Select") {
                VStack(alignment: .leading, spacing: 5) {
                    RibbonButton(title: "Select all", icon: "checkmark.square") { model.selection = Set(model.visible.map(\.id)) }
                    RibbonButton(title: "Select none", icon: "square") { model.selection = [] }
                    RibbonButton(title: "Invert selection", icon: "arrow.triangle.2.circlepath") {
                        model.selection = Set(model.visible.map(\.id)).subtracting(model.selection)
                    }
                }
            }
        }
    }

    private var shareTab: some View {
        let urls = model.selection.sorted().map { URL(fileURLWithPath: $0) }
        return RibbonGroup(title: "Send") {
            ShareLink(items: urls) { RibbonLabel(title: "Share", icon: "square.and.arrow.up", large: true) }
            RibbonButton(title: "Email", icon: "envelope", large: true) { NSSharingService(named: .composeEmail)?.perform(withItems: urls) }
            RibbonButton(title: "Zip", icon: "archivebox", color: .orange, large: true) { model.zip(model.selection) }
        }
        .disabled(urls.isEmpty)
    }

    private var viewTab: some View {
        HStack(alignment: .top, spacing: 0) {
            RibbonGroup(title: "Panes") {
                RibbonButton(title: "Navigation\npane", icon: "sidebar.left", large: true) { showNavigationPane.toggle() }
                    .background(showNavigationPane ? windowsBlue.opacity(0.15) : .clear)
                RibbonButton(title: "Preview\npane", icon: "sidebar.right", large: true) { showPreviewPane.toggle() }
                    .background(showPreviewPane ? windowsBlue.opacity(0.15) : .clear)
            }
            RibbonGroup(title: "Show/hide") {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("File name extensions", isOn: $showExtensions)
                    Toggle("Hidden items", isOn: $model.showHidden)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Address bar, file list, status bar

    private var addressRow: some View {
        HStack(spacing: 8) {
            Button("Back", systemImage: "arrow.left", action: model.goBack)
                .keyboardShortcut("[")
                .disabled(model.back.isEmpty)
            Button("Forward", systemImage: "arrow.right", action: model.goForward)
                .keyboardShortcut("]")
                .disabled(model.forward.isEmpty)
            Button("Up", systemImage: "arrow.up", action: model.goUp)
                .keyboardShortcut(.upArrow)
                .disabled(model.current.path == "/")
            AddressBar(model: model)
            HStack(spacing: 4) {
                TextField("Search \(displayName(model.current))", text: $model.search)
                    .textFieldStyle(.plain)
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(width: 230, height: 24)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().strokeBorder(Color.gray.opacity(0.5)))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var fileTable: some View {
        Table(model.visible, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Label {
                    Text(showExtensions || item.isFolder ? item.name : (item.name as NSString).deletingPathExtension)
                } icon: {
                    FileIcon(url: item.url)
                }
                .opacity(model.cut.contains(item.id) ? 0.5 : 1)
            }
            .width(min: 180, ideal: 300)
            TableColumn("Date modified", value: \.modified) { item in
                Text(item.modified.formatted(date: .numeric, time: .shortened))
            }
            .width(ideal: 140)
            TableColumn("Type", value: \.kind)
                .width(ideal: 140)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "" : item.size.formatted(.byteCount(style: .file)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(ideal: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            if ids.isEmpty {
                Button("New folder", action: model.newFolder)
                Button("Paste", action: model.paste)
            } else {
                Button("Open") { model.open(ids) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) }) }
                if model.items.contains(where: { ids.contains($0.id) && $0.isFolder }) {
                    Button("Pin to Quick access") { model.pin(ids) }
                }
                Divider()
                Button("Cut") { model.copy(ids, cut: true) }
                Button("Copy") { model.copy(ids, cut: false) }
                Button("Copy as path") { model.copyPaths(ids) }
                Divider()
                if ids.count == 1, let id = ids.first {
                    Button("Rename") { model.startRename(id) }
                }
                Button("Move to Trash", role: .destructive) { model.trash(ids) }
            }
            Divider()
            Button("Properties") { model.showProperties(ids) }
        } primaryAction: { ids in
            model.open(ids)
        }
        .onCommand(#selector(NSText.cut(_:))) { model.copy(model.selection, cut: true) }
        .onCommand(#selector(NSText.copy(_:))) { model.copy(model.selection, cut: false) }
        .onCommand(#selector(NSText.paste(_:))) { model.paste() }
        .onDeleteCommand { model.trash(model.selection) }
    }

    private var statusBar: some View {
        let selected = model.items.filter { model.selection.contains($0.id) }
        let bytes = selected.filter { !$0.isFolder }.map(\.size).reduce(0, +)
        return HStack(spacing: 16) {
            Text(itemCount(model.visible.count))
            if !selected.isEmpty { Text("\(itemCount(selected.count)) selected") }
            if bytes > 0 { Text(bytes.formatted(.byteCount(style: .file))) }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) { content }
                .frame(maxHeight: .infinity, alignment: .top)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.separator).frame(width: 1).padding(.vertical, 8)
        }
    }
}

struct RibbonButton: View {
    let title: String
    let icon: String
    var color = windowsBlue
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { RibbonLabel(title: title, icon: icon, color: color, large: large) }
    }
}

struct RibbonLabel: View {
    let title: String
    let icon: String
    var color = windowsBlue
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let image = Image(systemName: icon).foregroundStyle(isEnabled ? color : Color.secondary)
        if large {
            VStack(spacing: 3) {
                image.font(.system(size: 22)).frame(height: 28)
                Text(title).multilineTextAlignment(.center).fixedSize()
            }
            .frame(minWidth: 46)
            .contentShape(Rectangle())
        } else {
            Label { Text(title) } icon: { image }
                .contentShape(Rectangle())
        }
    }
}

struct NavigationPane: View {
    let model: Explorer
    @State private var quickAccessExpanded = true
    @State private var thisPCExpanded = true

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let iCloudDrive = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    private static let places = [home]
        + ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies"].map { home.appending(path: $0) }
        + [URL(fileURLWithPath: "/Applications")]

    var body: some View {
        List(selection: Binding<String?>(get: { model.current.path }, set: { if let path = $0 { model.go(to: URL(fileURLWithPath: path)) } })) {
            DisclosureGroup(isExpanded: $quickAccessExpanded) {
                ForEach(model.pinned, id: \.self) { path in
                    row(URL(fileURLWithPath: path))
                        .contextMenu {
                            Button("Unpin from Quick access") { model.pinned.removeAll { $0 == path } }
                        }
                }
            } label: {
                Label { Text("Quick access") } icon: { Image(systemName: "star.fill").foregroundStyle(windowsBlue) }
            }
            if FileManager.default.fileExists(atPath: Self.iCloudDrive.path) {
                row(Self.iCloudDrive)
            }
            DisclosureGroup(isExpanded: $thisPCExpanded) {
                ForEach(Self.places + (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? []), id: \.self) {
                    row($0)
                }
            } label: {
                Label { Text("This PC") } icon: { Image(systemName: "desktopcomputer").foregroundStyle(windowsBlue) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ url: URL) -> some View {
        Label { Text(displayName(url)) } icon: { FileIcon(url: url) }
            .tag(url.path)
    }
}

struct AddressBar: View {
    let model: Explorer
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 4) {
            FileIcon(url: model.current)
            // The field stays mounted and opaque (only its text is hidden) under the breadcrumbs so a click on empty space
            // focuses it natively: SwiftUI on macOS won't focus a field inserted on click, and never hit-tests transparent views.
            ZStack(alignment: .leading) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(editing ? Color.primary : Color.clear)
                    .focused($editing)
                    .accessibilityLabel("Address")
                    .onChange(of: editing) { _, isEditing in
                        if isEditing { text = model.current.path }
                    }
                    .onSubmit {
                        model.open(path: text)
                        editing = false
                    }
                    .onExitCommand { editing = false }
                if !editing {
                    HStack(spacing: 2) {
                        let parts = model.current.pathComponents
                        ForEach(parts.indices, id: \.self) { i in
                            let url = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...i])))
                            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
                            Button(displayName(url)) { model.go(to: url) }
                        }
                    }
                }
            }
            Button("Refresh", systemImage: "arrow.clockwise", action: model.reload)
                .keyboardShortcut("r")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(Rectangle().strokeBorder(Color.gray.opacity(0.5)))
    }
}

struct PreviewPane: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL? }
    }
}

struct PropertiesView: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text(item.name).font(.title3) } icon: { FileIcon(url: item.url, size: 32) }
            Form {
                LabeledContent("Type", value: item.kind)
                LabeledContent("Location", value: item.url.deletingLastPathComponent().path)
                if !item.isFolder {
                    LabeledContent("Size", value: item.size.formatted(.byteCount(style: .file)))
                }
                LabeledContent("Modified", value: item.modified.formatted(date: .long, time: .shortened))
            }
            .textSelection(.enabled)
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 16

    var body: some View {
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isVolumeKey])
        let folder = values?.isDirectory == true && values?.isPackage != true && values?.isVolume != true
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
            // macOS folder icons are blue; this shifts them to Windows yellow and keeps glyphs like Downloads' arrow.
            .hueRotation(.degrees(folder ? 210 : 0))
            .brightness(folder ? 0.2 : 0)
            .saturation(folder ? 1.2 : 1)
    }
}
