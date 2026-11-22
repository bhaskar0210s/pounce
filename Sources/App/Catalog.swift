// What Pounce looks through: the apps added in Settings, the notes added from Notes and the pages of System Settings
// added. Also finds every installed app, for adding them.

import AppKit

struct AppEntry {
    let path: String
    let name: String
    let haystack: Haystack
}

struct NoteEntry {
    let note: Note
    let link: String  // applenotes:note/…, which opens it, and its key in the order of choices
    let haystack: Haystack

    var id: String { note.id }
    var title: String { note.title }
}

/// A page of System Settings, which Pounce opens straight on that page.
struct PaneEntry {
    let id: String     // the System Settings extension that shows it
    let title: String  // as System Settings names it, in the user's language
    let icon: String   // the file whose icon System Settings shows for it
    let haystack: Haystack

    var link: String { Catalog.paneLink(id) }
}

/// Where Notes keeps its notes.
let notesDatabasePath = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

@MainActor
final class Catalog {
    /// Notes, which opens the notes added to Pounce.
    static let notesApp = "/System/Applications/Notes.app"
    /// System Settings, which opens the pages added to Pounce.
    static let systemSettingsApp = "/System/Applications/System Settings.app"

    /// The added apps that exist, by name.
    private(set) var apps: [AppEntry] = []
    /// The added notes, by title.
    private(set) var notes: [NoteEntry] = []
    /// The added pages of System Settings, by title.
    private(set) var panes: [PaneEntry] = []
    /// The pages of System Settings Pounce offers: Displays. Made when first needed.
    private(set) lazy var offeredPanes = [Catalog.pane("com.apple.Displays-Settings.extension", file: "DisplaysExt.appex", name: "Displays")]
    /// Everything added, as saved: an app on a disk that isn't connected stays in the list for when it is.
    private var paths: [String] = []
    private var icons: [String: CGImage] = [:]  // by path
    private var installedCache: [AppEntry]?
    private var realPaths: [String: String] = [:]  // path → the path with symbolic links resolved
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved list, tidied: anything that isn't a path is skipped (an odd value never empties the list), and one
    /// app saved under two paths (/Applications/Safari.app is a link into the system) counts once.
    func load() {
        var seen = Set<String>()
        paths = []
        for case let path as String in defaults.array(forKey: Defaults.apps) ?? [] where path.hasPrefix("/") {
            let standard = (path as NSString).standardizingPath
            if seen.insert(realPath(standard)).inserted { paths.append(standard) }
        }
        rebuild()
        loadNotes()
        loadPanes()
    }

    /// Checks that the added apps are where they were: an app on a disk connected later appears, a deleted one goes.
    /// A file check per app, done each time the window opens.
    func refreshIfChanged() {
        let fileManager = FileManager.default
        let present = Set(paths.filter { fileManager.fileExists(atPath: $0) })
        if present != Set(apps.map(\.path)) { rebuild() }
    }

    private func realPath(_ path: String) -> String {
        if let real = realPaths[path] { return real }
        let real = (path as NSString).resolvingSymlinksInPath
        realPaths[path] = real
        return real
    }

    private func save() {
        defaults.set(paths, forKey: Defaults.apps)
    }

    private func rebuild() {
        let fileManager = FileManager.default
        apps = paths.compactMap { fileManager.fileExists(atPath: $0) ? entry($0) : nil }.sorted(by: Catalog.byName)
    }

    static func byName(_ a: AppEntry, _ b: AppEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private func entry(_ path: String) -> AppEntry {
        let name = Catalog.displayName(path)
        return AppEntry(path: path, name: name, haystack: prepare(name))
    }

    /// The name Finder shows, in the user's language, without ".app".
    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }

    func contains(_ path: String) -> Bool {
        let real = realPath((path as NSString).standardizingPath)
        return paths.contains { realPath($0) == real }
    }

    func add(_ path: String) {
        guard !contains(path) else { return }
        paths.append((path as NSString).standardizingPath)
        save()
        rebuild()
    }

    func remove(_ path: String) {
        let real = realPath((path as NSString).standardizingPath)
        paths.removeAll { realPath($0) == real }
        save()
        rebuild()
    }

    func isNotesApp(_ path: String) -> Bool {
        realPath((path as NSString).standardizingPath) == realPath(Catalog.notesApp)
    }

    func isSystemSettingsApp(_ path: String) -> Bool {
        realPath((path as NSString).standardizingPath) == realPath(Catalog.systemSettingsApp)
    }

    // MARK: Notes

    /// The saved notes, tidied like the apps: entries that aren't a note identifier and a title are skipped.
    private func loadNotes() {
        var seen = Set<String>()
        var loaded: [Note] = []
        for case let item as [String: String] in defaults.array(forKey: Defaults.notes) ?? [] {
            guard let id = item["id"], let title = item["title"].map(noteTitle), !title.isEmpty, noteLink(id) != nil,
                  seen.insert(id).inserted else { continue }
            loaded.append(Note(id: id, title: title))
        }
        setNotes(loaded)
    }

    private func setNotes(_ list: [Note]) {
        notes = list.compactMap { note in noteLink(note.id).map { NoteEntry(note: note, link: $0, haystack: prepare(note.title)) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func saveNotes() {
        defaults.set(notes.map { ["id": $0.id, "title": $0.title] }, forKey: Defaults.notes)
    }

    func containsNote(_ id: String) -> Bool {
        notes.contains { $0.id == id }
    }

    func addNote(_ note: Note) {
        guard !containsNote(note.id), noteLink(note.id) != nil else { return }
        setNotes(notes.map(\.note) + [note])
        saveNotes()
    }

    func removeNote(_ id: String) {
        setNotes(notes.map(\.note).filter { $0.id != id })
        saveNotes()
    }

    /// Takes the titles Notes has now, and drops the added notes it no longer has (deleted ones). Returns whether
    /// anything changed. An empty Notes (an account turned off for a moment) changes nothing.
    @discardableResult
    func updateNotes(from current: [Note]) -> Bool {
        guard !current.isEmpty else { return false }
        let updated = notes.compactMap { entry in current.first { $0.id == entry.id } }  // a handful of notes
        guard updated != notes.map(\.note) else { return false }
        setNotes(updated)
        saveNotes()
        return true
    }

    // MARK: System Settings

    /// The link that opens System Settings on a page.
    nonisolated static func paneLink(_ id: String) -> String {
        "x-apple.systempreferences:" + id
    }

    /// A page as System Settings shows it in its sidebar: the name and icon of the extension that makes it up.
    private static func pane(_ id: String, file: String, name: String) -> PaneEntry {
        let path = "/System/Library/ExtensionKit/Extensions/" + file
        let title = localizedName(of: path) ?? name
        let icon = FileManager.default.fileExists(atPath: path) ? path : systemSettingsApp
        return PaneEntry(id: id, title: title, icon: icon, haystack: prepare(title))
    }

    /// The name an extension's Info.plist gives it, in the user's language (System Settings' own pages keep their
    /// names in a table of every language). The languages are named: left to itself, Foundation would pick the one
    /// Pounce speaks, English.
    private static func localizedName(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Resources/InfoPlist.loctable"),
              let tables = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [String: Any]]
        else { return nil }
        for language in Bundle.preferredLocalizations(from: Array(tables.keys), forPreferences: Locale.preferredLanguages) + ["en"] {
            if let name = tables[language]?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// The saved pages that Pounce still offers. Nothing is read from System Settings unless some were added.
    private func loadPanes() {
        let saved = (defaults.array(forKey: Defaults.panes) ?? []).compactMap { $0 as? String }
        panes = saved.isEmpty ? [] : offeredPanes.filter { saved.contains($0.id) }
    }

    private func savePanes() {
        defaults.set(panes.map(\.id), forKey: Defaults.panes)
    }

    func containsPane(_ id: String) -> Bool {
        panes.contains { $0.id == id }
    }

    func addPane(_ id: String) {
        guard !containsPane(id), let pane = offeredPanes.first(where: { $0.id == id }) else { return }
        panes.append(pane)
        panes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        savePanes()
    }

    func removePane(_ id: String) {
        panes.removeAll { $0.id == id }
        savePanes()
    }

    // MARK: Icons

    /// An app's icon, drawn once at `points` × `scale` into an sRGB bitmap: drawn into the list from that bitmap, it
    /// needs no color conversion.
    func icon(_ path: String, points: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((points * scale).rounded())
        if let icon = icons[path], icon.width == pixels { return icon }
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.interpolationQuality = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let made = context.makeImage()
        icons[path] = made
        return made
    }

    /// Draws the icons of the added apps and pages ahead of time, so the first search after launch is as quick as any
    /// other.
    func prepareIcons(points: CGFloat, scale: CGFloat) {
        for path in apps.map(\.path) + panes.map(\.icon) { _ = icon(path, points: points, scale: scale) }
    }

    /// Keeps only the icons of added apps and pages (Settings may have drawn many more).
    func trimIcons() {
        let keep = Set(apps.map(\.path) + panes.map(\.icon))
        icons = icons.filter { keep.contains($0.key) }
    }

    // MARK: Installed apps

    /// Every app in the usual places, plus the added ones that live elsewhere, by name. Kept until `forgetInstalled`.
    func installed() -> [AppEntry] {
        if let installedCache { return installedCache }
        let fileManager = FileManager.default
        var seen = Set<String>()
        var found: [AppEntry] = []
        func add(_ path: String) {
            let real = (path as NSString).resolvingSymlinksInPath
            if seen.insert(real).inserted { found.append(entry(path)) }
        }
        func visit(_ directory: String, depth: Int) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = directory + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if depth > 0 {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { visit(path, depth: depth - 1) }
                }
            }
        }
        for root in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"] {
            visit(root, depth: 1)
        }
        let finder = "/System/Library/CoreServices/Finder.app"
        if fileManager.fileExists(atPath: finder) { add(finder) }
        for app in apps { add(app.path) }
        found.sort(by: Catalog.byName)
        installedCache = found
        return found
    }

    func forgetInstalled() {
        installedCache = nil
    }
}
