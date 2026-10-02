import AppKit
import CryptoKit
import Observation
import SwiftUI

enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, teal, blue, purple, pink, gray
    var id: Self { self }
    var name: String { self == .none ? "No Color" : rawValue.capitalized }
    var nsColor: NSColor? {
        switch self {
        case .none: nil
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .gray: .systemGray
        }
    }
    var color: Color? { nsColor.map(Color.init(nsColor:)) }
}

protocol Pinnable: Identifiable where ID == UUID {
    var pinned: Bool { get set }
}

struct Note: Codable, Identifiable, Hashable, Pinnable {
    var id = UUID()
    var text = ""
    var color = NoteColor.none
    var pinned = false
    var folded = false
    var snippet = false // clicking the card copies it instead of opening it
    var code = false    // monospaced, no spell check
    var modified = Date()
    var created = Date()
    var deleted: Date?  // set while in Recently Deleted
    var origin: UUID?   // the folder it was deleted from
    var archived = false // hidden from its folder and search; listed under Archive
    var lock: String?        // a locked note's sealed text (NoteLock); `text` is then empty
    var lockedTitle: String? // what a locked note is called (shown, like Apple Notes)
    var byFolder = false     // sealed because its folder was locked (taking the folder's lock off opens it; a note locked alone stays)

    var title: String { lock != nil ? (lockedTitle ?? "Locked Note") : MD.title(text) }
    /// Nothing in it (a locked note never counts as empty: its text is just out of sight).
    var isBlank: Bool { lock == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init() {}
    // Every field is optional on disk so adding fields later never breaks old files.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        color = (try? c.decodeIfPresent(NoteColor.self, forKey: .color)) ?? .none
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        folded = try c.decodeIfPresent(Bool.self, forKey: .folded) ?? false
        snippet = try c.decodeIfPresent(Bool.self, forKey: .snippet) ?? false
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? false
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? modified
        deleted = try c.decodeIfPresent(Date.self, forKey: .deleted)
        origin = try c.decodeIfPresent(UUID.self, forKey: .origin)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        lock = try c.decodeIfPresent(String.self, forKey: .lock)
        lockedTitle = try c.decodeIfPresent(String.self, forKey: .lockedTitle)
        byFolder = try c.decodeIfPresent(Bool.self, forKey: .byFolder) ?? false
    }
}

/// Folders are stored flat; `parent` nests them. Two built-in folders never show as anyone's child:
/// the root (the home screen, so it can hold notes too) and Recently Deleted.
struct Folder: Codable, Identifiable, Hashable, Pinnable {
    enum Sort: String, Codable, CaseIterable, Identifiable {
        case manual, modified, created, title
        var id: Self { self }
        var name: String { ["manual": "Manual", "modified": "Date Edited", "created": "Date Created", "title": "Title"][rawValue]! }
    }

    static let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let trashID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static func isBuiltIn(_ id: UUID) -> Bool { id == rootID || id == trashID }

    var id = UUID()
    var name: String
    var color = NoteColor.none
    var pinned = false
    var parent: UUID? // nil = top level (files from before nesting)
    var sort = Sort.manual
    var icon: String?  // an SF Symbol name or an emoji; nil = the folder symbol
    var query: String? // a smart folder: shows what this search finds, holds no notes itself
    var deleted: Date? // set on a folder moved to Recently Deleted
    var origin: UUID?  // where it was deleted from
    var locked = false // its notes are sealed, and it shows nothing until unlocked (Nav.lockFolder)
    var lockCheck: String? // a sealed known text: tells a right password from a wrong one even with no locked note in the folder
    var notes: [Note] = []

    /// Display order: pinned first, each group in the folder's sort order. Archived notes aren't shown.
    var shownNotes: [Note] {
        if id == Folder.trashID { return notes } // all of it, last deleted first; pins and archiving kept for Undo/Restore
        let live = notes.filter { !$0.archived }
        switch sort {
        case .manual: return live.pinnedFirst
        case .modified: return live.sorted { $0.modified > $1.modified }.pinnedFirst
        case .created: return live.sorted { $0.created > $1.created }.pinnedFirst
        case .title: return live.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.pinnedFirst
        }
    }

    init(name: String) { self.name = name }
    static func builtIn(_ id: UUID, _ name: String) -> Folder { var f = Folder(name: name); f.id = id; return f }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        color = (try? c.decodeIfPresent(NoteColor.self, forKey: .color)) ?? .none
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        sort = (try? c.decodeIfPresent(Sort.self, forKey: .sort)) ?? .manual
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        deleted = try c.decodeIfPresent(Date.self, forKey: .deleted)
        origin = try c.decodeIfPresent(UUID.self, forKey: .origin)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        lockCheck = try c.decodeIfPresent(String.self, forKey: .lockCheck)
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
    }
}

/// All notes live in one JSON file, written atomically, with one backup per day.
/// Put the folder in iCloud Drive/OneDrive to sync Macs: external changes are picked up, and if both sides
/// changed, the two are merged note by note (the other side's file is also kept as a conflict copy).
// ponytail: whole-file JSON rewrite on save (off the main thread); fine for thousands of notes, move to SQLite if it ever lags.
@Observable final class Store {
    var folders: [Folder] = [] { didSet { if !loading { edits += 1; scheduleSave() } } }

    let directory: URL
    let url: URL
    let isFirstRun: Bool
    /// The notes file couldn't be read (or a sync hasn't brought it down yet): the newest backup is showing
    /// and nothing is written until it reads again or you edit.
    private(set) var recovering = false
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private let io = DispatchQueue(label: "com.cortexy.save") // every file write, in order
    @ObservationIgnored private var lastWrite: Date? // only touched on `io`
    @ObservationIgnored private var loading = false
    @ObservationIgnored private(set) var edits = 0 // bumps on every change; caches compare against it
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored var onMerged: (() -> Void)? // another Mac's edits were combined with ours
    @ObservationIgnored private var savedEdits = 0
    @ObservationIgnored private var maintainedDay = ""
    var dirty: Bool { edits != savedEdits } // edits not yet on disk

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cortexy", isDirectory: true)
    }

    /// The folder chosen in Settings → Data, else Application Support.
    static var configuredDirectory: URL {
        UserDefaults.standard.string(forKey: Prefs.dataDirectory).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultDirectory
    }

    init(directory: URL = Store.defaultDirectory) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        url = directory.appendingPathComponent("cortexy.json")
        let missing = !fm.fileExists(atPath: url.path)
        // Only a truly new folder: an iCloud placeholder or backups mean the notes exist and just aren't here yet.
        isFirstRun = missing && !fm.fileExists(atPath: directory.appendingPathComponent(".cortexy.json.icloud").path)
            && Store.newestBackup(in: directory) == nil

        if isFirstRun {
            folders = Store.welcome()
            edits += 1
            save()
            return
        }
        do {
            loading = true
            defer { loading = false }
            if missing { throw CocoaError(.fileReadNoSuchFile) }
            folders = Store.withBuiltIns(try JSONDecoder().decode([Folder].self, from: Data(contentsOf: url)))
            lastWrite = fileDate
            maintain() // while loading: the clean-up isn't saved by itself, it simply happens again next time
        } catch {
            // Never write over a file we can't read (a sync may still be bringing it down): keep a copy, show the
            // newest backup without saving it, and let the sync poll load the file once it reads.
            if !missing { park(as: "unreadable", copy: true) }
            try? fm.startDownloadingUbiquitousItem(at: url)
            NSLog("Cortexy: could not read notes (\(error)); a copy is kept as cortexy-unreadable-*.json")
            loading = true
            folders = Store.withBuiltIns(Store.newestBackup(in: directory).flatMap { try? JSONDecoder().decode([Folder].self, from: Data(contentsOf: $0)) }
                ?? Store.welcome())
            loading = false
            lastWrite = .distantPast // whatever the file says next is newer
            recovering = true
        }
    }

    static func newestBackup(in directory: URL) -> URL? {
        let dir = directory.appendingPathComponent("Backups", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("cortexy-") }.sorted().last
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: Persistence

    private var fileDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// After a pause in editing, encodes and writes on `io` so typing never waits for the disk.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dirty else { return }
            self.mergeExternalChanges()
            let snapshot = self.folders, n = self.edits
            self.io.async { [weak self] in
                guard let self, self.write(snapshot) else { return }
                DispatchQueue.main.async { self.savedEdits = max(self.savedEdits, n); self.recovering = false; self.onSaved?() }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes pending edits right now (hiding the panel, quitting, switching data folders).
    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard dirty else { return }
        mergeExternalChanges()
        let snapshot = folders, n = edits
        if io.sync(execute: { write(snapshot) }) { savedEdits = max(savedEdits, n); recovering = false; onSaved?() }
    }

    /// Another Mac wrote the file since we last did, while we have edits of our own: fold its notes into ours
    /// before writing (its file is kept as a conflict copy too, just in case).
    private func mergeExternalChanges() {
        let changed: Date? = io.sync {
            guard let d = fileDate, let last = lastWrite, d != last else { return nil }
            return d
        }
        guard let d = changed, let data = try? Data(contentsOf: url), let theirs = try? JSONDecoder().decode([Folder].self, from: data) else { return }
        io.sync { park(as: "conflict", copy: true); lastWrite = d }
        folders = Store.withBuiltIns(Store.merge(folders, theirs))
        onMerged?()
    }

    /// Both sides' folders and notes; where both have a note, the one edited last wins (in the folder that side
    /// put it). Folder names and order stay ours.
    // ponytail: a note deleted here comes back if the other Mac's file still has it; tombstones would stop that.
    static func merge(_ ours: [Folder], _ theirs: [Folder]) -> [Folder] {
        var out = ours
        for f in theirs where !out.contains(where: { $0.id == f.id }) {
            var empty = f
            empty.notes = []
            out.append(empty)
        }
        for f in theirs {
            for n in f.notes {
                if let at = out.firstIndex(where: { $0.notes.contains { $0.id == n.id } }), let i = out[at].notes.firstIndex(where: { $0.id == n.id }) {
                    guard n.modified > out[at].notes[i].modified else { continue }
                    if out[at].id == f.id { out[at].notes[i] = n; continue }
                    out[at].notes.remove(at: i)
                }
                if let fi = out.firstIndex(where: { $0.id == f.id }) { out[fi].notes.insert(n, at: 0) }
            }
        }
        return out
    }

    /// Runs on `io`. If another Mac changed the file since our last write, theirs is kept as a conflict copy first.
    private func write(_ snapshot: [Folder]) -> Bool {
        if let d = fileDate, let last = lastWrite, d != last { park(as: "conflict", copy: true) }
        do {
            try JSONEncoder.cortexy.encode(snapshot).write(to: url, options: .atomic)
            lastWrite = fileDate
            return true
        } catch {
            NSLog("Cortexy: save failed: \(error)") // data stays in memory; next edit retries
            return false
        }
    }

    /// Picks up edits another Mac synced into the data folder. Returns true if notes were reloaded.
    @discardableResult func reloadIfChangedExternally() -> Bool {
        let changed: Date? = io.sync {
            guard let d = fileDate, let last = lastWrite, d != last else { return nil }
            return d
        }
        guard let d = changed else { return false }
        if dirty {
            save() // both sides changed: save() merges theirs into ours, then writes
            return true
        }
        guard let data = try? Data(contentsOf: url), let new = try? JSONDecoder().decode([Folder].self, from: data) else { return false }
        loading = true
        folders = Store.withBuiltIns(new)
        loading = false
        recovering = false
        edits += 1          // caches (tags) see the change,
        savedEdits = edits  // which is already on disk,
        onSaved?()          // and synced due dates get their reminders
        io.sync { lastWrite = d }
        return true
    }

    private func park(as label: String, copy: Bool = false) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = directory.appendingPathComponent("cortexy-\(label)-\(stamp).json")
        if copy { try? FileManager.default.copyItem(at: url, to: dest) } else { try? FileManager.default.moveItem(at: url, to: dest) }
    }

    var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    /// Once a day, at launch and when the day turns while the app keeps running: today's backup, emptying old
    /// Recently Deleted items and trimming version history.
    func maintain() {
        let day = Date().formatted(.iso8601.year().month().day())
        guard day != maintainedDay, !recovering else { return }
        maintainedDay = day
        backup()
        if Prefs.number(Prefs.trashDays) > 0 { purgeTrash(olderThan: Prefs.number(Prefs.trashDays)) }
        pruneHistory()
    }

    /// Copies today's starting state to Backups/ and keeps the newest few (Settings → Data).
    private func backup() {
        let fm = FileManager.default
        let dir = backupsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = Date().formatted(.iso8601.year().month().day())
        let target = dir.appendingPathComponent("cortexy-\(day).json")
        if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: url, to: target) }
        let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("cortexy-") }.sorted().dropLast(max(1, Int(Prefs.number(Prefs.backupsKept))))
        for name in old { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        // Conflict copies are only a safety net (edits are merged): keep the newest few.
        let conflicts = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("cortexy-conflict-") }.sorted()
        for name in conflicts.dropLast(max(1, Int(Prefs.number(Prefs.backupsKept)))) { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
    }

    // MARK: Version history (History/<note id>.json beside the notes file, so it syncs along)

    struct Version: Codable, Equatable {
        var date: Date
        var text: String
    }

    var historyDirectory: URL { directory.appendingPathComponent("History", isDirectory: true) }
    private func historyFile(_ nid: UUID) -> URL { historyDirectory.appendingPathComponent(nid.uuidString + ".json") }

    /// A note's kept versions, oldest first.
    func history(_ nid: UUID) -> [Version] {
        let file = historyFile(nid)
        return io.sync { (try? JSONDecoder().decode([Version].self, from: Data(contentsOf: file))) ?? [] }
    }

    /// Keeps the note's text as a version, unless it's empty (or locked) or the same as the last one kept.
    func snapshot(_ nid: UUID) {
        guard let f = folderOf(nid), let n = note(f.id, nid), !n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = n.text, file = historyFile(nid), dir = historyDirectory, keep = max(1, Int(Prefs.number(Prefs.versionsKept)))
        io.async {
            var versions = (try? JSONDecoder().decode([Version].self, from: Data(contentsOf: file))) ?? []
            guard versions.last?.text != text else { return }
            versions.append(Version(date: Date(), text: text))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(Array(versions.suffix(keep))).write(to: file, options: .atomic)
        }
    }

    /// After locking a note: its copies in backups and conflict files become the locked version too.
    func scrubCopies(of locked: Note) {
        let fm = FileManager.default
        let backups = ((try? fm.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []).map { backupsDirectory.appendingPathComponent($0) }
        let conflicts = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("cortexy-conflict-") }
            .map { directory.appendingPathComponent($0) }
        io.async {
            for file in backups + conflicts where file.pathExtension == "json" {
                guard var copy = try? JSONDecoder().decode([Folder].self, from: Data(contentsOf: file)) else { continue }
                var changed = false
                for i in copy.indices {
                    for j in copy[i].notes.indices where copy[i].notes[j].id == locked.id {
                        copy[i].notes[j].text = ""
                        copy[i].notes[j].lock = locked.lock
                        copy[i].notes[j].lockedTitle = locked.lockedTitle
                        changed = true
                    }
                }
                if changed { try? JSONEncoder.cortexy.encode(copy).write(to: file, options: .atomic) }
            }
        }
    }

    func removeHistory(_ nid: UUID) {
        let file = historyFile(nid)
        io.async { try? FileManager.default.removeItem(at: file) }
    }

    /// History of notes deleted for good.
    private func pruneHistory() {
        let known = Set(folders.flatMap(\.notes).map(\.id.uuidString)), dir = historyDirectory
        io.async {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.hasSuffix(".json") && !known.contains(String(name.dropLast(5))) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: Attachments (images and files dropped into notes live next to the notes file)

    var attachmentsDirectory: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    /// Saves data as a new attachment and returns its note-relative path, e.g. `attachments/…png`.
    func addAttachment(_ data: Data, ext: String) -> String? {
        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext.lowercased())"
        do {
            try data.write(to: attachmentsDirectory.appendingPathComponent(name), options: .atomic)
            return "attachments/\(name)"
        } catch {
            NSLog("Cortexy: attachment save failed: \(error)")
            return nil
        }
    }

    /// Where a locked note's attachments open while it's unlocked (they're sealed in `attachments/` as `<name>.locked`).
    static let unlockedAttachments = FileManager.default.temporaryDirectory.appendingPathComponent("cortexy-unlocked", isDirectory: true)

    /// Resolves an image/link path from a note: relative `attachments/…`, `file://…` or an absolute path.
    func resolve(_ path: String) -> URL? {
        if path.hasPrefix("attachments/") {
            let plain = directory.appendingPathComponent(path)
            let opened = Store.unlockedAttachments.appendingPathComponent(String(path.dropFirst("attachments/".count)))
            return !FileManager.default.fileExists(atPath: plain.path) && FileManager.default.fileExists(atPath: opened.path) ? opened : plain
        }
        if let u = URL(string: path), u.scheme != nil { return u }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    /// Markdown for something dropped or pasted in: images are copied in, other files are linked.
    func markdown(forFile file: URL) -> String {
        let imageTypes = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp"]
        if imageTypes.contains(file.pathExtension.lowercased()), let data = try? Data(contentsOf: file),
           let path = addAttachment(data, ext: file.pathExtension) {
            return "![\(MD.escape(file.deletingPathExtension().lastPathComponent))](\(path))"
        }
        // Parentheses are legal in file URLs but would end the Markdown link early.
        let link = file.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(MD.escape(file.lastPathComponent))](\(link))"
    }

    func markdown(forImage image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let path = addAttachment(png, ext: "png") else { return nil }
        return "![image](\(path))"
    }

    // MARK: Lookup

    func folderIndex(_ id: UUID) -> Int? { folders.firstIndex { $0.id == id } }
    func folder(_ id: UUID) -> Folder? { folderIndex(id).map { folders[$0] } }
    func note(_ fid: UUID, _ nid: UUID) -> Note? { folder(fid)?.notes.first { $0.id == nid } }
    func folderOf(_ nid: UUID) -> Folder? { folders.first { $0.notes.contains { $0.id == nid } } }

    // ponytail: parent lookups scan the flat list (O(n²) for a tree walk); index by parent if folders reach the thousands.
    /// Where a folder sits. Top-level folders, and any whose parent went missing, belong to the root.
    func parentID(_ f: Folder) -> UUID? {
        guard !Folder.isBuiltIn(f.id) else { return nil }
        guard let p = f.parent, p != f.id, folderIndex(p) != nil else { return Folder.rootID }
        return p
    }

    func subfolders(_ id: UUID) -> [Folder] { folders.filter { parentID($0) == id } }

    /// The folder and everything inside it, depth first in display order.
    func subtree(_ id: UUID) -> [Folder] {
        (folder(id).map { [$0] } ?? []) + subfolders(id).pinnedFirst.flatMap { subtree($0.id) }
    }

    func noteCount(_ id: UUID, archived: Bool = false) -> Int {
        subtree(id).reduce(0) { $0 + $1.notes.count { archived || !$0.archived } }
    }

    /// From the top (root or Recently Deleted) down to `id`, for the breadcrumb.
    func chain(_ id: UUID) -> [Folder] {
        var out: [Folder] = [], f = folder(id)
        while let cur = f, !out.contains(where: { $0.id == cur.id }) {
            out.insert(cur, at: 0)
            f = parentID(cur).flatMap(folder)
        }
        return out
    }

    /// Everything not in Recently Deleted: what search and scripting see.
    /// Locked folders unlocked this session (never saved).
    var openFolders: Set<UUID> = []

    /// In a locked folder (or below one) that isn't unlocked: what's inside stays out of every list and search.
    func lockedAway(_ id: UUID) -> Bool { chain(id).contains { $0.locked && !openFolders.contains($0.id) } }

    var liveFolders: [Folder] { subtree(Folder.rootID).filter { !lockedAway($0.id) } }

    /// Where notes and folders can be moved: live folders that aren't smart folders.
    var moveTargets: [Folder] { liveFolders.filter { $0.query == nil } }

    func inTrash(_ id: UUID) -> Bool {
        var f = folder(id)
        while let cur = f {
            if cur.id == Folder.trashID { return true }
            f = parentID(cur).flatMap(folder)
        }
        return false
    }

    /// "Work › Projects", for Move to menus. The root shows as its name, "Cortexy".
    func path(_ id: UUID) -> String {
        guard let f = folder(id) else { return "" }
        guard let p = parentID(f), p != Folder.rootID else { return f.name }
        return path(p) + " › " + f.name
    }

    func updateFolder(_ id: UUID, _ change: (inout Folder) -> Void) {
        guard let i = folderIndex(id) else { return }
        change(&folders[i])
    }

    func updateNote(_ fid: UUID, _ nid: UUID, _ change: (inout Note) -> Void) {
        guard let fi = folderIndex(fid), let ni = folders[fi].notes.firstIndex(where: { $0.id == nid }) else { return }
        change(&folders[fi].notes[ni])
    }

    /// Typing in an editor: the note changes at once (saving, search, anything reading it sees it), but views
    /// hear of it only once the typing pauses: re-rendering the panel for every keystroke cost frames.
    func type(_ fid: UUID, _ nid: UUID, _ change: (inout Note) -> Void) {
        guard let fi = folderIndex(fid), let ni = folders[fi].notes.firstIndex(where: { $0.id == nid }) else { return }
        change(&_folders[fi].notes[ni]) // the storage under `folders`: no views told, its didSet still saves
        typing?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.withMutation(keyPath: \.folders) {} }
        typing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    @ObservationIgnored private var typing: DispatchWorkItem?

    // MARK: Editing

    @discardableResult func addFolder(_ name: String, in parent: UUID = Folder.rootID) -> UUID {
        var f = Folder(name: name)
        f.parent = parent
        folders.append(f)
        return f.id
    }

    /// Permanently deletes the folder with its subfolders and notes. Built-in folders can't be deleted.
    func deleteFolder(_ id: UUID) {
        guard !Folder.isBuiltIn(id) else { return }
        let doomed = Set(subtree(id).map(\.id))
        folders.removeAll { doomed.contains($0.id) }
    }

    /// Nests a folder (and everything in it) inside another; never inside itself or its own subfolders.
    func moveFolder(_ id: UUID, into target: UUID) {
        guard !Folder.isBuiltIn(id), folder(target) != nil, !subtree(id).contains(where: { $0.id == target }) else { return }
        updateFolder(id) { $0.parent = target }
    }

    /// Inserts a note before `before` (as displayed), or at the top of the unpinned notes.
    @discardableResult func addNote(to fid: UUID, text: String = "", before: UUID? = nil) -> UUID? {
        guard let i = folderIndex(fid) else { return nil }
        var n = Note()
        n.text = text
        var notes = folders[i].notes.pinnedFirst
        if let before, let at = notes.firstIndex(where: { $0.id == before }) {
            n.pinned = notes[at].pinned
            notes.insert(n, at: at)
        } else {
            notes.insert(n, at: notes.firstIndex { !$0.pinned } ?? notes.count)
        }
        folders[i].notes = notes
        return n.id
    }

    func deleteNote(_ fid: UUID, _ nid: UUID) {
        guard let i = folderIndex(fid) else { return }
        folders[i].notes.removeAll { $0.id == nid }
    }

    /// A copy right below the original.
    @discardableResult func duplicateNote(_ fid: UUID, _ nid: UUID) -> UUID? {
        guard let fi = folderIndex(fid), let ni = folders[fi].notes.firstIndex(where: { $0.id == nid }) else { return nil }
        var n = folders[fi].notes[ni]
        n.id = UUID()
        n.created = Date()
        n.modified = Date()
        folders[fi].notes.insert(n, at: ni + 1)
        return n.id
    }

    func deleteIfEmpty(_ fid: UUID, _ nid: UUID) {
        if let n = note(fid, nid), n.isBlank {
            deleteNote(fid, nid)
        }
    }

    func moveNote(_ nid: UUID, from: UUID, to: UUID) {
        guard from != to, var n = note(from, nid), let ti = folderIndex(to) else { return }
        deleteNote(from, nid)
        n.pinned = false
        folders[ti].notes.insert(n, at: 0)
    }

    func moveFolder(_ id: UUID, onto target: UUID) { folders.move(id, onto: target) }

    // MARK: Recently Deleted

    func trashNote(_ fid: UUID, _ nid: UUID) {
        guard !inTrash(fid), var n = note(fid, nid), let ti = folderIndex(Folder.trashID) else { return }
        deleteNote(fid, nid)
        n.origin = fid
        n.deleted = Date()
        folders[ti].notes.insert(n, at: 0)
    }

    /// The folder goes with everything in it; restoring brings it all back.
    func trashFolder(_ id: UUID) {
        guard !Folder.isBuiltIn(id), let f = folder(id), !inTrash(id) else { return }
        let from = parentID(f)
        updateFolder(id) { $0.origin = from; $0.parent = Folder.trashID; $0.deleted = Date(); $0.pinned = false }
    }

    /// Puts a deleted note or folder back where it came from, or at the top level if that folder is gone too.
    // ponytail: a restored note goes to the top of its folder, not its old slot.
    /// Back from Recently Deleted, from any depth: to where it was deleted from if that's still there, else the
    /// top level (also for things inside a deleted folder, which have no place of their own). Returns where it went.
    @discardableResult func restore(_ id: UUID) -> UUID? {
        func home(_ origin: UUID?) -> UUID { origin.flatMap { folder($0) != nil && !inTrash($0) ? $0 : nil } ?? Folder.rootID }
        if id != Folder.trashID, let f = folder(id), inTrash(id) {
            let to = home(f.origin)
            updateFolder(id) { $0.parent = to; $0.origin = nil; $0.deleted = nil }
            return to
        } else if let from = folderOf(id), inTrash(from.id), var n = note(from.id, id), let ti = folderIndex(home(n.origin)) {
            deleteNote(from.id, id)
            n.origin = nil
            n.deleted = nil
            folders[ti].notes.insert(n, at: 0)
            return folders[ti].id
        }
        return nil
    }

    /// Permanently removes what was deleted more than `days` ago (everything with 0).
    func purgeTrash(olderThan days: Double) {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        guard let ti = folderIndex(Folder.trashID) else { return }
        if folders[ti].notes.contains(where: { ($0.deleted ?? .distantPast) <= cutoff }) {
            folders[ti].notes.removeAll { ($0.deleted ?? .distantPast) <= cutoff }
        }
        for f in subfolders(Folder.trashID) where (f.deleted ?? .distantPast) <= cutoff { deleteFolder(f.id) }
    }
    func moveNote(_ nid: UUID, onto target: UUID, in fid: UUID) { updateFolder(fid) { $0.notes.move(nid, onto: target) } }

    /// Copies everything to another data folder: attachments, version history and backups (merged into folders
    /// already there), then the notes file last, so a copy cut short never looks like a finished library.
    func copyLibrary(to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for sub in ["attachments", "History", "Backups"] {
            let from = directory.appendingPathComponent(sub), to = target.appendingPathComponent(sub)
            guard let names = try? fm.contentsOfDirectory(atPath: from.path) else { continue }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for name in names where !fm.fileExists(atPath: to.appendingPathComponent(name).path) {
                try fm.copyItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
            }
        }
        try fm.copyItem(at: url, to: target.appendingPathComponent("cortexy.json"))
    }

    // MARK: Export

    /// Writes every note as a .md file (folders become nested directories) plus the attachments. Returns the export folder.
    func exportMarkdown(to parent: URL) throws -> URL {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("Cortexy Export \(Date().formatted(.iso8601.year().month().day()))")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: attachmentsDirectory.path) {
            try? fm.copyItem(at: attachmentsDirectory, to: root.appendingPathComponent("attachments"))
        }
        func unique(_ base: String, in used: inout Set<String>) -> String {
            var name = base, k = 2
            while used.contains(name.lowercased()) { name = "\(base) \(k)"; k += 1 }
            used.insert(name.lowercased())
            return name
        }
        func write(_ fid: UUID, to dir: URL, depth: Int, usedDirs: Set<String> = []) throws {
            guard let f = folder(fid) else { return }
            var used = Set<String>(), usedDirs = usedDirs
            let up = String(repeating: "../", count: depth)
            for n in f.notes {
                let name = unique(Store.fileName(n.title), in: &used)
                let text = n.lock != nil ? "🔒 This note is locked in Cortexy.\n"
                    : n.text.replacingOccurrences(of: "](attachments/", with: "](\(up)attachments/")
                try text.write(to: dir.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
            }
            for sub in subfolders(fid) {
                let d = dir.appendingPathComponent(unique(Store.fileName(sub.name), in: &usedDirs))
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try write(sub.id, to: d, depth: depth + 1)
            }
        }
        try write(Folder.rootID, to: root, depth: 0, usedDirs: ["attachments"])
        return root
    }

    static func fileName(_ s: String) -> String {
        var clean = s.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() } // "..", "." would leave the export folder; ".x" would hide
        return String((clean.isEmpty ? "Untitled" : clean).prefix(80))
    }

    /// Adds the built-in folders older files don't have: the root (notes used to live only in folders) and Recently Deleted.
    static func withBuiltIns(_ folders: [Folder]) -> [Folder] {
        var out = folders
        if !out.contains(where: { $0.id == Folder.rootID }) { out.insert(.builtIn(Folder.rootID, "Cortexy"), at: 0) }
        if !out.contains(where: { $0.id == Folder.trashID }) { out.append(.builtIn(Folder.trashID, "Recently Deleted")) }
        return out
    }

    /// First-run content: a note on the home screen that teaches the basics.
    static func welcome() -> [Folder] {
        var f = Folder.builtIn(Folder.rootID, "Cortexy")
        var n = Note()
        n.text = """
        # Welcome to Cortexy
        Push the pointer against the right edge of the screen, or press ⌃⌥N.

        - [ ] Click a checkbox to tick it
        - [x] **Bold**, *italic*, `code` and [links](https://apple.com) render as you type
        - Drag notes to reorder them, or drop files and images in
        - Right-click a note for colors, pins, snippets and folders
        - Esc hides the panel, ⌘, opens Settings
        """
        n.color = .blue
        f.notes = [n]
        return withBuiltIns([f])
    }
}

extension Array where Element: Pinnable {
    /// Display order: pinned first, otherwise stored order.
    var pinnedFirst: [Element] { filter(\.pinned) + filter { !$0.pinned } }

    /// Live drag-reorder: moves `id` to `target`'s place as displayed. It joins the target's group,
    /// so dragging into the pinned group pins it (and out of it unpins).
    mutating func move(_ id: UUID, onto target: UUID) {
        var shown = pinnedFirst
        guard id != target, let from = shown.firstIndex(where: { $0.id == id }),
              let to = shown.firstIndex(where: { $0.id == target }) else { return }
        shown[from].pinned = shown[to].pinned
        shown.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        self = shown
    }
}

extension JSONEncoder {
    static let cortexy: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

/// Images from the web for `![](https://…)`: fetched in the background once, kept in Caches, shown when they
/// arrive (editors reload, cards redraw). Settings → General can turn fetching off.
@Observable final class WebImages {
    static let shared = WebImages()
    static let arrived = Notification.Name("CortexyWebImageArrived")
    private(set) var arrivals = 0 // bumps on each arrival, so views showing images redraw
    @ObservationIgnored private let memory = NSCache<NSURL, NSImage>()
    @ObservationIgnored private var loading = Set<URL>()
    @ObservationIgnored private var failed = Set<URL>()

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cortexy/Web", isDirectory: true)
    }

    /// Fetching an image tells its server the note was opened (a tracking pixel can do just that), so it's done only
    /// with Settings' "every note" on, or for a note whose images were loaded with its "Load" button.
    func allows(_ note: UUID?) -> Bool {
        (UserDefaults.standard.object(forKey: Prefs.webImages) as? Bool ?? false) || note.map(allowedNotes.contains) == true
    }

    /// A note's "Load Images": its web images, now and from then on.
    func allow(_ note: UUID) {
        allowedNotes.insert(note)
        UserDefaults.standard.set(allowedNotes.map(\.uuidString), forKey: Self.allowedKey)
        arrivals += 1 // cards look again
        NotificationCenter.default.post(name: Self.allowed, object: note)
    }
    static let allowed = Notification.Name("CortexyWebImagesAllowed")
    private static let allowedKey = "webImageNotes"
    @ObservationIgnored private var allowedNotes = Set((UserDefaults.standard.stringArray(forKey: "webImageNotes") ?? []).compactMap(UUID.init(uuidString:)))

    /// Whether it may still show up: fetching is allowed for its note and hasn't failed.
    func coming(_ url: URL, note: UUID?) -> Bool { allows(note) && !failed.contains(url) }

    /// The image if it's here (fetched before: showing it asks no server); otherwise nil, and it's fetched (once)
    /// for next time if its note allows that.
    func image(_ url: URL, note: UUID?) -> NSImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        let file = directory.appendingPathComponent(SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
        if let img = NSImage(contentsOf: file) {
            memory.setObject(img, forKey: url as NSURL)
            return img
        }
        if allows(note) { fetch(url, to: file) }
        return nil
    }

    private func fetch(_ url: URL, to file: URL) {
        guard !loading.contains(url), !failed.contains(url) else { return }
        loading.insert(url)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 20)) { data, _, _ in
            DispatchQueue.main.async { [self] in
                loading.remove(url)
                guard let data, data.count < 25_000_000, let img = NSImage(data: data) else {
                    failed.insert(url)
                    arrivals += 1 // redraw: what was waiting for it shows the link instead
                    return
                }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                memory.setObject(img, forKey: url as NSURL)
                arrivals += 1
                NotificationCenter.default.post(name: Self.arrived, object: url)
            }
        }.resume()
    }
}
