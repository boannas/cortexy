import AppKit
import CoreSpotlight
import CryptoKit
import UniformTypeIdentifiers

// The notes outside the app: a Markdown copy kept up to date, Markdown folders brought in, and Spotlight.

extension Store {
    /// What a Markdown mirror holds: each note's file (folder path + title + ".md"), its note, and its text with
    /// attachment links made relative to it. Not Recently Deleted, not a locked note, and nothing under a locked
    /// folder (a note written there is plain for a moment before it's sealed). Names come out the same each time,
    /// so files don't churn: a clash gets " 2" in the order the notes were made.
    func mirrorFiles() -> [String: (id: UUID, text: String)] {
        var out: [String: (id: UUID, text: String)] = [:]
        func walk(_ fid: UUID, _ dir: String, depth: Int) {
            guard let f = folder(fid), !chain(fid).contains(where: \.locked) else { return }
            var used = Set<String>()
            func unique(_ base: String) -> String {
                var name = base, k = 2
                while used.contains(name.lowercased()) { name = "\(base) \(k)"; k += 1 }
                used.insert(name.lowercased())
                return name
            }
            let up = String(repeating: "../", count: depth)
            for n in f.notes.sorted(by: { $0.created < $1.created }) where n.lock == nil && !n.isBlank {
                out[dir + unique(Store.fileName(n.title)) + ".md"] = (n.id, n.text.replacingOccurrences(of: "](attachments/", with: "](\(up)attachments/"))
            }
            for sub in subfolders(fid) where !Folder.isBuiltIn(sub.id) { walk(sub.id, dir + unique(Store.fileName(sub.name)) + "/", depth: depth + 1) }
        }
        walk(Folder.rootID, "", depth: 0)
        return out
    }
    func mirrorPlan() -> [String: String] { mirrorFiles().mapValues(\.text) }

    static let mirrorManifest = ".cortexy-mirror.json"

    /// What the copy last wrote at a path: its content's hash, its note, and the file's date then (a later date
    /// means it was edited outside). Attachments have the hash "file".
    struct MirrorEntry: Codable, Equatable {
        var hash: String
        var id: UUID?
        var mtime: Double?
    }

    static func readManifest(_ dir: URL) -> [String: MirrorEntry] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(mirrorManifest)) else { return [:] }
        if let v2 = try? JSONDecoder().decode([String: MirrorEntry].self, from: data) { return v2 }
        if let v1 = try? JSONDecoder().decode([String: String].self, from: data) { return v1.mapValues { MirrorEntry(hash: $0) } } // before two-way
        return [:]
    }

    static func mirrorHash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
    static func fileDate(_ url: URL) -> Double? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
    }

    /// A folder the copy may write into: empty (hidden files aside), missing, or a Cortexy copy already.
    static func canMirror(into dir: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return true }
        return items.allSatisfy { $0.hasPrefix(".") } || items.contains(mirrorManifest)
    }

    /// Brings `dir` in line with `plan`: writes what changed, deletes files of notes gone (and folders left
    /// empty) and the files in `drop` (brought in under another name), copies the attachments the notes use. A
    /// manifest remembers what it wrote, so nothing else there is touched.
    static func syncMirror(_ plan: [String: String], ids: [String: UUID] = [:], drop: [String] = [], attachments: URL, to dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent(mirrorManifest)
        let old = readManifest(dir)
        if !fm.fileExists(atPath: manifestURL.path) { try? Data("{}".utf8).write(to: manifestURL) } // claimed before anything is written
        let inside = dir.standardizedFileURL.path + "/"
        var now: [String: MirrorEntry] = [:]
        for (path, text) in plan {
            let h = mirrorHash(text), file = dir.appendingPathComponent(path)
            if old[path]?.hash != h || !fm.fileExists(atPath: file.path) {
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: file, atomically: true, encoding: .utf8)
            }
            now[path] = MirrorEntry(hash: h, id: ids[path], mtime: fileDate(file))
        }
        // Attachments the notes show: copied once; ones no longer used go.
        for name in Set(plan.values.flatMap(MD.attachmentNames)) {
            let key = "attachments/" + name, dest = dir.appendingPathComponent(key)
            now[key] = MirrorEntry(hash: "file")
            if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: attachments.appendingPathComponent(name).path) {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: attachments.appendingPathComponent(name), to: dest)
            }
        }
        for path in Array(old.keys.filter { now[$0] == nil }) + drop.filter({ now[$0] == nil }) {
            let file = dir.appendingPathComponent(path)
            guard file.standardizedFileURL.path.hasPrefix(inside) else { continue } // never anything outside the copy
            try? fm.removeItem(at: file)
            var parent = file.deletingLastPathComponent() // folders it leaves empty
            while parent.path.count > dir.path.count, (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }
        if now != old, let data = try? JSONEncoder().encode(now) { try? data.write(to: manifestURL, options: .atomic) }
        let about = dir.appendingPathComponent("About this folder (Cortexy).txt")
        if !fm.fileExists(atPath: about.path) {
            try? "Cortexy keeps a Markdown copy of your notes here (Settings → Data). With “Bring edits back” on, edits, new .md files and deletions made here come back into Cortexy (a deleted file's note goes to Recently Deleted). Locked notes are never copied here.\n"
                .write(to: about, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Edits made in the copy

    /// What changed in the copy since it was last written: files edited (with the hash Cortexy last wrote there),
    /// .md files added, files deleted (an iCloud placeholder, a file only moved off this Mac, isn't a deletion).
    struct MirrorChanges {
        var changed: [(id: UUID, path: String, text: String, wrote: String)] = []
        var added: [(path: String, text: String)] = []
        var removed: [UUID] = []
        var isEmpty: Bool { changed.isEmpty && added.isEmpty && removed.isEmpty }
    }

    static func scanMirror(_ dir: URL) -> MirrorChanges {
        let fm = FileManager.default, manifest = readManifest(dir)
        var out = MirrorChanges()
        guard !manifest.isEmpty else { return out } // never written: nothing to bring back
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for (path, e) in manifest where e.hash != "file" {
            let file = dir.appendingPathComponent(path)
            guard file.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else { continue }
            if !fm.fileExists(atPath: file.path) {
                let placeholder = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud")
                if let id = e.id, !fm.fileExists(atPath: placeholder.path) { out.removed.append(id) }
                continue
            }
            guard let id = e.id, fileDate(file) != e.mtime, let text = try? String(contentsOf: file, encoding: .utf8), mirrorHash(text) != e.hash else { continue }
            out.changed.append((id, path, text, e.hash))
        }
        if let walk = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walk where url.pathExtension.lowercased() == "md" {
                let full = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard full.hasPrefix(root) else { continue }
                let rel = String(full.dropFirst(root.count))
                guard manifest[rel] == nil, !rel.hasPrefix("attachments/"), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.added.append((rel, text))
            }
        }
        return out
    }

    /// Brings the copy's changes in. An edit replaces its note's text, unless the note changed here too since the
    /// copy was written: then the copy's version comes in as a note of its own beside it, so nothing is lost. A
    /// new file becomes a note in the matching folder (titled by its file name); a deleted file's note goes to
    /// Recently Deleted. Locked notes and folders are left alone. Returns how many notes changed, and the files
    /// brought in by id (the copy may write them under another name).
    func applyMirror(_ c: MirrorChanges, from dir: URL) -> (count: Int, adopted: [UUID: String]) {
        let current = Dictionary(mirrorFiles().map { ($0.value.id, Store.mirrorHash($0.value.text)) }) { a, _ in a }
        func open(_ fid: UUID) -> Bool { !inTrash(fid) && !chain(fid).contains(where: \.locked) }
        func fromCopy(_ text: String, path: String) -> String {
            let depth = path.components(separatedBy: "/").count - 1
            let back = text.replacingOccurrences(of: "](" + String(repeating: "../", count: depth) + "attachments/", with: "](attachments/")
            return rehome(back.replacingOccurrences(of: "\r\n", with: "\n"), base: dir.appendingPathComponent(path).deletingLastPathComponent(), byName: [:])
        }
        var count = 0, adopted: [UUID: String] = [:]
        for ch in c.changed {
            guard let f = folderOf(ch.id), let n = note(f.id, ch.id), n.lock == nil, open(f.id) else { continue }
            let text = fromCopy(ch.text, path: ch.path)
            if current[ch.id].map({ $0 != ch.wrote }) ?? true { // edited on both sides: keep both
                if let id = addNote(to: f.id, text: "# \(n.title) (edited in the Markdown copy)\n" + text) { adopted[id] = ch.path }
            } else {
                updateNote(f.id, ch.id) { $0.text = text; $0.modified = Date() }
            }
            count += 1
        }
        for a in c.added {
            var fid = Folder.rootID, ok = true
            for name in a.path.components(separatedBy: "/").dropLast() {
                if let sub = subfolders(fid).first(where: { Store.fileName($0.name) == name || $0.name == name }) { fid = sub.id } else { fid = addFolder(name, in: fid) }
                if !open(fid) { ok = false; break }
            }
            guard ok else { continue }
            var text = fromCopy(a.text, path: a.path)
            let title = ((a.path as NSString).lastPathComponent as NSString).deletingPathExtension
            if MD.title(text) != title { // its file name is how it's found (and named again)
                let cut = MD.frontmatter(text)?.length ?? 0
                text = (text as NSString).replacingCharacters(in: NSRange(location: cut, length: 0), with: "# \(title)\n")
            }
            if let id = addNote(to: fid, text: text) { adopted[id] = a.path; count += 1 }
        }
        for id in c.removed {
            guard let f = folderOf(id), note(f.id, id)?.lock == nil, open(f.id) else { continue }
            trashNote(f.id, id)
            count += 1
        }
        return (count, adopted)
    }

    /// Takes a copy away (turned off, or moved elsewhere): the files it wrote, its manifest and note, and the
    /// folders that leaves empty. Nothing else in the folder is touched. A copy left behind would keep notes
    /// locked later in plain text.
    static func removeMirror(at dir: URL) {
        let fm = FileManager.default, manifestURL = dir.appendingPathComponent(mirrorManifest)
        let old = readManifest(dir)
        guard fm.fileExists(atPath: manifestURL.path) else { return }
        let inside = dir.standardizedFileURL.path + "/"
        for path in old.keys {
            let file = dir.appendingPathComponent(path)
            guard file.standardizedFileURL.path.hasPrefix(inside) else { continue }
            try? fm.removeItem(at: file)
            var parent = file.deletingLastPathComponent()
            while parent.path.count > dir.path.count, (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }
        try? fm.removeItem(at: manifestURL)
        try? fm.removeItem(at: dir.appendingPathComponent("About this folder (Cortexy).txt"))
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
    }

    /// Where the mirror goes: the folder chosen in Settings, else "Markdown" in the data folder.
    var mirrorDirectory: URL {
        let chosen = Prefs.text(Prefs.mirrorDirectory)
        return chosen.isEmpty ? directory.appendingPathComponent("Markdown", isDirectory: true) : URL(fileURLWithPath: chosen, isDirectory: true)
    }

    private static let mirrorQueue = DispatchQueue(label: "cortexy.mirror", qos: .utility)
    private static var mirrorBusy = false, mirrorAgain = false // only touched on the main thread

    /// After a save, and every few seconds when edits come back: the copy's changes read in the background and
    /// brought in here first (so writing never covers an edit made outside), then the notes written out. One
    /// pass at a time; asked again meanwhile, it runs once more after.
    func updateMirror() {
        guard UserDefaults.standard.bool(forKey: Prefs.mirror), Store.canMirror(into: mirrorDirectory) || Prefs.text(Prefs.mirrorDirectory).isEmpty else { return }
        if Store.mirrorBusy { Store.mirrorAgain = true; return }
        Store.mirrorBusy = true
        let dir = mirrorDirectory, attachments = attachmentsDirectory, twoWay = UserDefaults.standard.bool(forKey: Prefs.mirrorTwoWay)
        Store.mirrorQueue.async { [weak self] in
            let changes = twoWay ? Store.scanMirror(dir) : MirrorChanges()
            DispatchQueue.main.async {
                guard let self else { Store.mirrorBusy = false; return }
                let (count, adopted) = changes.isEmpty ? (0, [:]) : self.applyMirror(changes, from: dir)
                if count > 0 { self.onMirrorPulled?(count) }
                let files = self.mirrorFiles()
                let byID = Dictionary(files.map { ($0.value.id, $0.key) }) { a, _ in a }
                let drop = adopted.compactMap { id, path in byID[id] == path ? nil : path } // brought in, now written under its note's name
                Store.mirrorQueue.async {
                    Store.syncMirror(files.mapValues(\.text), ids: files.mapValues(\.id), drop: drop, attachments: attachments, to: dir)
                    DispatchQueue.main.async {
                        Store.mirrorBusy = false
                        if Store.mirrorAgain { Store.mirrorAgain = false; self.updateMirror() }
                    }
                }
            }
        }
    }

    // MARK: Import

    /// Notes from a folder of Markdown (an Obsidian vault, Bear's or Apple Notes' Markdown export, a folder of
    /// .md/.txt files, TextBundles) into a new folder named after it. Subfolders become folders; images they show
    /// (`![](rel/path.png)`, `![[pic.png]]`) are copied in; other linked files are linked where they are. A note
    /// whose first line isn't its file name gets it as its title, so `[[links]]` to it keep working. Returns the
    /// new folder and how many notes came in.
    @discardableResult func importMarkdown(from root: URL, into parent: UUID = Folder.rootID) -> (UUID, Int) {
        let fm = FileManager.default
        // Every file by name, for `![[name]]` (Obsidian finds those anywhere in the vault).
        var byName: [String: URL] = [:]
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where byName[u.lastPathComponent.lowercased()] == nil { byName[u.lastPathComponent.lowercased()] = u }
        }
        let top = addFolder(root.lastPathComponent, in: parent)
        var count = 0
        func note(from file: URL, base: URL, title: String, into fid: UUID) {
            guard var text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else { return }
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            text = rehome(text, base: base, byName: byName)
            if MD.title(text) != title { // the file name is how links reach it
                let cut = MD.frontmatter(text)?.length ?? 0
                text = (text as NSString).replacingCharacters(in: NSRange(location: cut, length: 0), with: "# \(title)\n")
            }
            guard let id = addNote(to: fid, text: text) else { return }
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            updateNote(fid, id) { n in
                if let c = attrs?[.creationDate] as? Date { n.created = c }
                if let m = attrs?[.modificationDate] as? Date { n.modified = m }
            }
            count += 1
        }
        func walk(_ dir: URL, into fid: UUID) {
            let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for u in items {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if u.pathExtension.lowercased() == "textbundle" {
                    if let text = ["text.md", "text.markdown", "text.txt"].map(u.appendingPathComponent).first(where: { fm.fileExists(atPath: $0.path) }) {
                        note(from: text, base: u, title: u.deletingPathExtension().lastPathComponent, into: fid)
                    }
                } else if isDir {
                    let hasNotes = (fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? [])
                        .contains { ["md", "markdown", "txt", "textbundle"].contains($0.pathExtension.lowercased()) }
                    if hasNotes { walk(u, into: addFolder(u.lastPathComponent, in: fid)) } // an images-only folder isn't a folder of notes
                } else if ["md", "markdown", "txt"].contains(u.pathExtension.lowercased()) {
                    note(from: u, base: dir, title: u.deletingPathExtension().lastPathComponent, into: fid)
                }
            }
        }
        walk(root, into: top)
        return (top, count)
    }

    /// Links to files beside the note, made to work here: images copied into attachments, other files linked by
    /// `file://` where they are. `![[x.png]]` (Obsidian) becomes `![x](attachments/…)`.
    private func rehome(_ text: String, base: URL, byName: [String: URL]) -> String {
        let images: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp", "svg"]
        func local(_ ref: String) -> URL? {
            let clean = (ref.removingPercentEncoding ?? ref).trimmingCharacters(in: .whitespaces)
            guard !clean.contains("://"), !clean.hasPrefix("attachments/") else { return nil }
            let direct = clean.hasPrefix("/") ? URL(fileURLWithPath: clean) : base.appendingPathComponent(clean)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            return byName[(clean as NSString).lastPathComponent.lowercased()]
        }
        func replacement(_ file: URL, alt: String, image: Bool) -> String {
            if image, images.contains(file.pathExtension.lowercased()), let data = try? Data(contentsOf: file), let path = addAttachment(data, ext: file.pathExtension) {
                return "![\(MD.escape(alt))](\(path))"
            }
            return markdown(forFile: file)
        }
        var out = text
        // ![[name.png|300]] and ![[name.pdf]]
        let embed = try! NSRegularExpression(pattern: #"!\[\[([^\]|#\n]+\.[A-Za-z0-9]{2,5})(?:\|([^\]\n]*))?\]\]"#)
        for m in embed.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed() {
            let ns = out as NSString, ref = ns.substring(with: m.range(at: 1))
            guard let file = local(ref) else { continue }
            let size = m.range(at: 2).location == NSNotFound ? "" : "|" + ns.substring(with: m.range(at: 2))
            var md = replacement(file, alt: file.deletingPathExtension().lastPathComponent, image: true)
            if !size.isEmpty, md.hasPrefix("!["), let close = md.range(of: "](") { md.insert(contentsOf: size, at: close.lowerBound) }
            out = ns.replacingCharacters(in: m.range, with: md)
        }
        // ![alt](relative/path) and [name](relative/path.pdf)
        let link = try! NSRegularExpression(pattern: #"(!?)\[((?:\\.|[^\]\\\n])*)\]\(<?([^)>\n]+?)>?\)"#)
        for m in link.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed() {
            let ns = out as NSString, ref = ns.substring(with: m.range(at: 3))
            guard !ref.hasPrefix("#"), (ref as NSString).pathExtension.count > 0, let file = local(ref) else { continue }
            if ["md", "markdown"].contains(file.pathExtension.lowercased()) { // a link to another note: [[its name]]
                out = ns.replacingCharacters(in: m.range, with: "[[\(file.deletingPathExtension().lastPathComponent)|\(ns.substring(with: m.range(at: 2)))]]")
                continue
            }
            out = ns.replacingCharacters(in: m.range, with: replacement(file, alt: MD.unescape(ns.substring(with: m.range(at: 2))), image: ns.substring(with: m.range(at: 1)) == "!"))
        }
        return out
    }

    // MARK: Spotlight

    /// Notes Spotlight may show: not locked, not under a locked folder, not deleted.
    func spotlightNotes() -> [(Folder, Note)] {
        subtree(Folder.rootID).filter { f in !chain(f.id).contains(where: \.locked) }.flatMap { f in f.notes.filter { $0.lock == nil && !$0.isBlank }.map { (f, $0) } }
    }
}

/// Puts notes in Spotlight (titles and text; locked ones never) and keeps it up to date; choosing one there
/// opens it in the panel. Only notes changed since the last pass are sent again.
enum SpotlightIndex {
    private static var sent: [UUID: Date] = [:]
    private static var pending: DispatchWorkItem?
    static let domain = "com.cortexy.notes"

    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.spotlight) as? Bool ?? true }

    /// A little after the last change (typing makes many); at once when a note it holds was locked.
    static func update(_ store: Store) {
        let live = Set(store.spotlightNotes().map(\.1.id))
        if sent.keys.contains(where: { !live.contains($0) }) { return sync(store) }
        pending?.cancel()
        let work = DispatchWorkItem { [weak store] in if let store { sync(store) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    static func sync(_ store: Store) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return } // not from `swift test` / `swift run`
        let index = CSSearchableIndex.default()
        guard enabled else { // off: everything out, whatever an earlier run put in
            index.deleteSearchableItems(withDomainIdentifiers: [domain])
            sent = [:]
            return
        }
        let notes = store.spotlightNotes()
        let changed = notes.filter { sent[$0.1.id] != $0.1.modified }
        let items = changed.map { f, n -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: .text)
            a.title = n.title
            a.textContent = String(n.text.prefix(20_000))
            a.contentDescription = f.id == Folder.rootID ? nil : store.path(f.id)
            a.contentModificationDate = n.modified
            a.keywords = MD.tags(n.text)
            return CSSearchableItem(uniqueIdentifier: n.id.uuidString, domainIdentifier: domain, attributeSet: a)
        }
        let live = Set(notes.map(\.1.id)), gone = sent.keys.filter { !live.contains($0) }
        if !items.isEmpty { index.indexSearchableItems(items) }
        if !gone.isEmpty { index.deleteSearchableItems(withIdentifiers: gone.map(\.uuidString)) }
        for (_, n) in changed { sent[n.id] = n.modified }
        for g in gone { sent[g] = nil }
    }

    /// At launch: what earlier runs indexed is cleared (it may hold notes locked or deleted since, here or on
    /// another Mac), then everything that may be shown goes in again.
    static func start(_ store: Store) {
        reset()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak store] in if let store { sync(store) } }
    }

    /// Everything out (a lock, a moved library): the next pass sends what may be shown.
    static func reset() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        sent = [:]
    }
}
