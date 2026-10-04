import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// What the panel is showing, plus the actions every screen shares.
@Observable final class Nav {
    enum Route: Hashable {
        case folder(UUID), note(UUID, UUID), archive, upcoming
        static let home = Route.folder(Folder.rootID)
    }
    /// trash = empty Recently Deleted; items = the marked rows, deleted for good
    enum Deletion { case folder(Folder), note(UUID, Note), trash, items([UUID]) }

    let store: Store
    var route: Route = .home {
        didSet {
            guard oldValue != route else { return }
            if search.isEmpty { page += 1 }
            if !goingBack { trail = Array((trail + [(oldValue, search.isEmpty ? clearedSearch ?? "" : search)]).suffix(50)) }
            if !goingBack && !goingForward { ahead = [] }
            clearedSearch = nil // it belonged to this step only
            // Leaving a note (not just following it to another folder): update links to it, drop it if empty.
            if case let .note(f, was) = oldValue, was != routeNote {
                if let old = openedTitle, let new = store.note(f, was)?.title { relink(old, to: new) }
                store.snapshot(was)
                if !NoteWindows.shared.isOpen(was) { dropIfEmpty(f, was) } // its window still has it
                if inLockedFolder(f), let password, store.note(f, was)?.lock == nil { seal(folder: f, password) } // a note just written there
                if let s = stub, s.id == was {
                    if store.note(f, was)?.text == s.text { store.deleteNote(f, was) }
                    stub = nil
                }
            }
            let oldNote: UUID? = if case .note(_, let n) = oldValue { n } else { nil }
            if case .note(let f, let n) = route, n != oldNote {
                openedTitle = store.note(f, n)?.title
                store.snapshot(n) // how it was before this visit
                lastSnapshot[n] = Date()
            }
            selection = nil
            marked = []
            markAnchor = nil
            iconPicking = nil
            commitRename()    // a rename left half done is kept as typed (Esc cancels), not left to grab focus later
            historyNote = nil // the Version History overlay belongs to the screen it was opened on
            dragging = nil    // a drag the panel closed under never ended
            dropTarget = nil
            rowFrames = [:]
            if let c = PanelController.shared, c.nav === self { c.preview.hide() } // (this panel's, not whichever was made last)
            UserDefaults.standard.set(route.encoded, forKey: "lastRoute")
        }
    }
    var search = "" {
        didSet {
            guard oldValue != search else { return }
            if oldValue.isEmpty != search.isEmpty { page += 1 }
            selection = nil
            hintIndex = nil
            marked = [] // marks on hits no longer shown would be deleted unseen
            // ">" in the search box is the command list, as in ⌘O.
            if search.hasPrefix(">") {
                let rest = String(search.dropFirst())
                search = ""
                palette = .commands
                paletteQuery = rest.trimmingCharacters(in: .whitespaces)
                return
            }
            // Opening a hit clears the search a moment before the route changes: Back should bring it back.
            if search.isEmpty, !oldValue.isEmpty {
                clearedSearch = oldValue
                DispatchQueue.main.async { [weak self] in self?.clearedSearch = nil }
            }
        }
    }
    /// Where you've been (and what you'd searched), for Back.
    @ObservationIgnored private var trail: [(route: Route, search: String)] = []
    /// Where Back came from, for Forward (⌘]); a new step elsewhere clears it.
    private(set) var ahead: [(route: Route, search: String)] = []
    @ObservationIgnored private var goingForward = false
    @ObservationIgnored private var goingBack = false
    @ObservationIgnored private var clearedSearch: String?
    var searchInFolder = false // search only the open folder (and what's inside it)
    @ObservationIgnored private var openedTitle: String? // the open note's title when it was opened, to follow renames
    @ObservationIgnored private var stub: (id: UUID, text: String)? // made by clicking a [[link]] to no note; dropped if left untouched
    @ObservationIgnored private var tagCache: (stamp: Int, tags: [(name: String, count: Int)])?
    var searchFocus = 0
    var historyNote: UUID? // showing this note's Version History
    var frontApp: (id: String, name: String)? // the app in front when the panel opened (its notes come first)
    var calendarShown = false    // the daily notes calendar (⇧⌘D)
    var attachmentsShown = false // every attached file, and which notes use it
    var unlocked: [UUID: String] = [:] // locked notes opened this session: their text, only ever in memory
    @ObservationIgnored var keys: [UUID: SymmetricKey] = [:]
    @ObservationIgnored var salts: [UUID: Data] = [:] // each key's own salt (the stored box may have changed under it)
    @ObservationIgnored var password: String?
    @ObservationIgnored private var lastSnapshot: [UUID: Date] = [:]
    var renaming: UUID?
    var renameDraft = ""

    /// Ends a rename with what was typed (a name of nothing keeps the old one).
    func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        let n = renameDraft.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, store.folder(id)?.name != n { store.updateFolder(id) { $0.name = n } }
    }

    /// On a smart folder's page (its query bar is on screen, not the search box).
    var onSmartFolder: Bool { if case .folder(let f) = route { store.folder(f)?.query != nil } else { false } }

    /// The hint the arrow keys are on in the search box's list (nil: none, the keys go to the results).
    var hintIndex: Int?

    /// ↓ / ↑ in the search box walk its hint list first, then on to the results. True when it took the key.
    func moveHint(_ delta: Int) -> Bool {
        let shown = search.isEmpty ? 0 : min(5, searchHints(search).count)
        guard shown > 0 else { return false }
        if delta > 0 {
            let next = (hintIndex ?? -1) + 1
            if next < shown { hintIndex = next; return true }
            hintIndex = nil // past the last one: on to the results
            return false
        }
        guard let i = hintIndex else { return false }
        hintIndex = i > 0 ? i - 1 : nil // ↑ off the first: back to the field
        return true
    }

    /// Return on a hint the arrows are on.
    func applyHighlightedHint() -> Bool {
        guard let i = hintIndex, !search.isEmpty else { return false }
        let hints = searchHints(search)
        hintIndex = nil
        guard hints.indices.contains(i) else { return false }
        apply(hints[i])
        return true
    }
    var iconPicking: UUID? // folder row showing the icon picker under it
    var selection: UUID?   // keyboard selection in the current list
    var marked: Set<UUID> = [] // ⌘/⇧-clicked rows the bulk bar acts on
    @ObservationIgnored private var markAnchor: UUID?
    var expanded: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "expandedFolders") ?? []).compactMap(UUID.init)) {
        didSet { UserDefaults.standard.set(expanded.map(\.uuidString), forKey: "expandedFolders") }
    }
    var dropTarget: UUID?  // folder row a dragged row would drop into
    var dragging: UUID?    // row being dragged for reordering
    var dragY: CGFloat = 0 // pointer, in the list's coordinates
    var grabY: CGFloat = 0 // where in the row it was grabbed
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
    var toast: String?
    @ObservationIgnored private var toasts = 0
    var undoAction: (() -> Void)? // offered as "Undo" in the toast; ⌘Z outside text fields runs it too
    var pendingDelete: Deletion?
    var confirming: Bool {
        get { pendingDelete != nil }
        set { if !newValue { pendingDelete = nil } }
    }

    init(store: Store) {
        self.store = store
        // Reopen where the user left off.
        if let saved = UserDefaults.standard.string(forKey: "lastRoute").flatMap(Route.init(encoded:)), exists(saved) {
            route = saved
        }
    }

    func exists(_ r: Route) -> Bool {
        switch r {
        case .folder(let f): store.folder(f) != nil
        case .note(let f, let n): store.note(f, n) != nil
        case .archive, .upcoming: true
        }
    }

    var currentFolder: UUID {
        switch route {
        case .folder(let f), .note(let f, _): f
        case .archive, .upcoming: Folder.rootID
        }
    }

    /// Back where you came from (a search, Upcoming, the note before a [[link]]…); with nowhere left, up a level.
    /// The list you return to has the note you left selected, and scrolled to.
    func back() {
        if !search.isEmpty { search = ""; return }
        // The page's list comes back scrolled to (and on) what you left: the note, or the folder you were in.
        let left: UUID? = if case .folder(let f) = route, !Folder.isBuiltIn(f) { f } else { routeNote }
        while let last = trail.popLast() {
            guard exists(last.route), last.route != route else { continue }
            ahead.append((route, ""))
            goingBack = true
            route = last.route
            goingBack = false
            if !last.search.isEmpty { search = last.search }
            if let left, case .folder = route { selection = left }
            return
        }
        if route != .home { ahead.append((route, "")) }
        goingBack = true // going up isn't a step to come back to
        defer { goingBack = false; if let left, case .folder = route { selection = left } }
        switch route {
        case .note(let f, _): route = store.note(f, routeNote ?? UUID())?.archived == true ? .archive : .folder(f)
        // Built-in folders (Recently Deleted) have no parent: they go back home.
        case .folder(let f): if f != Folder.rootID { route = .folder(store.folder(f).flatMap(store.parentID) ?? Folder.rootID) }
        case .archive, .upcoming: route = .home
        }
    }

    /// ⌘]: back to where Back left.
    func forward() {
        while let next = ahead.popLast() {
            guard exists(next.route), next.route != route else { continue }
            goingForward = true
            search = ""
            route = next.route
            goingForward = false
            if !next.search.isEmpty { search = next.search }
            return
        }
    }

    /// Any note at all (not archived, not locked), for rediscovering old ones.
    func openRandomNote() {
        let all = store.liveFolders.filter { !store.inTrash($0.id) }.flatMap { f in f.notes.filter { !$0.archived && $0.lock == nil }.map { (f.id, $0.id) } }
        guard let (f, n) = all.filter({ $0.1 != routeNote }).randomElement() ?? all.randomElement() else { return }
        search = ""
        route = .note(f, n)
    }

    private var routeNote: UUID? { if case .note(_, let n) = route { n } else { nil } }

    /// Which page is on show, one number per showing (search results count as one): a page still fading out,
    /// even the same folder's left and come straight back to, can't size the panel.
    @ObservationIgnored private(set) var page = 0
    /// Bumped when the panel's card comes to rest: pages say again how tall they are.
    var measureTick = 0
    /// The side panel showing this Nav (none for one only used in a note window or a test).
    var panel: PanelController? { PanelController.shared?.nav === self ? PanelController.shared : nil }

    // MARK: Creating

    /// The folder new notes go to: a named one (created at the top level if missing), else the open one (home included).
    /// A smart folder holds no notes, so they go next to it.
    private func targetFolder(named name: String?) -> UUID {
        if let name, !name.isEmpty {
            func named(_ f: Folder) -> Bool { f.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            // One locked away counts too (found, then refused): it mustn't be matched by a second folder of its name.
            return store.moveTargets.first(where: named)?.id ?? store.folders.first { named($0) && store.lockedAway($0.id) }?.id ?? store.addFolder(name)
        }
        guard let f = store.folder(currentFolder), !store.inTrash(f.id) else { return Folder.rootID }
        return f.query == nil ? f.id : store.parentID(f) ?? Folder.rootID
    }

    @discardableResult func newNote(text: String = "", folderName: String? = nil, open: Bool = true) -> UUID? {
        let fid = targetFolder(named: folderName)
        // Into a folder that's locked away it would sit there as plain text until the folder is next opened.
        guard !refuseLockedAway(fid), let n = store.addNote(to: fid, text: text) else { return nil }
        if open {
            search = ""
            route = .note(fid, n)
        }
        return n
    }

    /// Nothing is added to or moved into a folder that's locked away (it would be stored unsealed): says so, and true.
    private func refuseLockedAway(_ fid: UUID) -> Bool {
        guard store.lockedAway(fid) else { return false }
        flash("Unlock “\(store.folder(fid)?.name ?? "the folder")” first")
        return true
    }

    /// A row on no screen right now: inside a folder that's locked away.
    func isHidden(_ id: UUID) -> Bool {
        if let f = store.folderOf(id) { return store.lockedAway(f.id) }
        if let f = store.folder(id), let p = store.parentID(f) { return store.lockedAway(p) }
        return false
    }

    /// A new folder inside the open one.
    func newFolder() {
        search = ""
        let parent = targetFolder(named: nil)
        guard !refuseLockedAway(parent) else { return }
        route = .folder(parent)
        renaming = store.addFolder("New Folder", in: parent)
    }

    // MARK: Deleting

    /// Deleting moves things to Recently Deleted, with Undo. Empty notes just go;
    /// deleting for good (from Recently Deleted) asks first.
    /// Leaving a blank note: one that never had text just goes. One that had text (emptied with ⌘A ⌫, say)
    /// goes to Recently Deleted holding its last kept version, with Undo, instead of vanishing for good.
    private func dropIfEmpty(_ fid: UUID, _ nid: UUID) {
        guard let n = store.note(fid, nid), n.isBlank else { return }
        guard let last = store.history(nid).last?.text else { return store.deleteNote(fid, nid) }
        store.updateNote(fid, nid) { $0.text = last }
        store.trashNote(fid, nid)
        flash("Emptied note moved to Recently Deleted") { [weak self] in self?.store.restore(nid) }
    }

    func requestDelete(_ d: Deletion) {
        switch d {
        case .note(let fid, let n) where !store.inTrash(fid):
            if n.isBlank { return perform(d) }
            leave(note: n.id, in: fid)
            store.trashNote(fid, n.id)
            flash("Moved to Recently Deleted") { [weak self] in self?.store.restore(n.id) }
        case .folder(let f) where !store.inTrash(f.id):
            leave(folder: f)
            store.trashFolder(f.id)
            flash("Moved to Recently Deleted") { [weak self] in self?.store.restore(f.id) }
        default:
            pendingDelete = d
        }
    }

    /// Deletes for good.
    func perform(_ d: Deletion) {
        switch d {
        case .folder(let f):
            leave(folder: f)
            store.deleteFolder(f.id)
        case .note(let fid, let n):
            leave(note: n.id, in: fid)
            store.deleteNote(fid, n.id)
        case .trash:
            if store.inTrash(currentFolder) { route = .folder(Folder.trashID) }
            store.purgeTrash(olderThan: 0)
        case .items(let ids):
            for id in ids {
                if let f = store.folder(id) { leave(folder: f); store.deleteFolder(id) }
                else if let f = store.folderOf(id) { store.deleteNote(f.id, id) }
            }
            marked = []
        }
    }

    func restore(_ id: UUID) {
        if store.inTrash(currentFolder), store.subtree(id).contains(where: { $0.id == currentFolder }) { route = .folder(Folder.trashID) }
        if case .note(_, let open) = route, open == id { route = .folder(Folder.trashID) }
        flash(store.restore(id).map { "Restored to “\(store.folder($0)?.name ?? "")”" } ?? "Nothing to restore")
    }

    private func leave(note id: UUID, in fid: UUID) {
        if case .note(_, let open) = route, open == id { route = .folder(fid) }
    }

    private func leave(folder f: Folder) {
        if store.subtree(f.id).contains(where: { $0.id == currentFolder }) { route = .folder(store.parentID(f) ?? Folder.rootID) }
    }

    // MARK: Note actions

    func toggleTask(_ fid: UUID, _ nid: UUID, line: Int) {
        store.updateNote(fid, nid) { $0.text = MD.toggleTask(in: $0.text, line: line); $0.modified = Date() }
    }

    func copy(_ n: Note) {
        // A locked note's text only exists while it's unlocked; otherwise the clipboard is left alone.
        guard let text = n.lock == nil ? n.text : unlocked[n.id] else { return flash("Unlock the note to copy it") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied")
    }

    func flash(_ message: String, undo: (() -> Void)? = nil) {
        toast = message
        undoAction = undo
        toasts += 1
        if NSApp != nil { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: message]) } // VoiceOver says it
        let mine = toasts // a newer toast (even with the same words) outlives this one's timer
        let reading = max(1.2, Double(message.count) / 25) // long messages stay long enough to read
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo == nil ? reading : max(reading, Prefs.number(Prefs.undoSeconds)))) { [weak self] in
            guard let self, self.toasts == mine else { return }
            self.toast = nil
            self.undoAction = nil
        }
    }

    // MARK: Archive

    var archivedNotes: [(Folder, Note)] {
        store.liveFolders.flatMap { f in f.notes.filter(\.archived).map { (f, $0) } }.sorted { $0.1.modified > $1.1.modified }
    }

    func archive(_ fid: UUID, _ nid: UUID, _ on: Bool) {
        if on, case .note(_, nid) = route { route = .folder(fid) }
        store.updateNote(fid, nid) { $0.archived = on; $0.pinned = on ? false : $0.pinned }
        flash(on ? "Archived" : "Unarchived") { [weak self] in self?.store.updateNote(fid, nid) { $0.archived = !on } }
    }

    // MARK: Folder tree

    /// Folder rows shown in `fid`: its subfolders, each followed by its own when expanded in place.
    func folderRows(_ fid: UUID, depth: Int = 0) -> [(folder: Folder, depth: Int)] {
        store.subfolders(fid).pinnedFirst.flatMap { f in
            [(f, depth)] + (expanded.contains(f.id) && !store.lockedAway(f.id) ? folderRows(f.id, depth: depth + 1) : [])
        }
    }

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Marking several rows

    /// Clicking a row: ⌘ adds or removes it, ⇧ marks the run from the last click, a plain click opens it.
    func click(_ id: UUID, open: () -> Void) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if marked.isEmpty, let s = selection, s != id { marked.insert(s) }
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
            markAnchor = id
        } else if mods.contains(.shift) {
            let ids = visibleIDs
            // The last ⌘-click if it's on this screen (one from another folder would mark nothing).
            let anchor = [markAnchor, selection].compactMap { $0 }.first(where: ids.contains) ?? ids.first
            if let a = anchor.flatMap(ids.firstIndex), let b = ids.firstIndex(of: id) {
                marked.formUnion(ids[min(a, b)...max(a, b)])
            }
            markAnchor = anchor
        } else if !marked.isEmpty {
            marked = []
        } else {
            open()
        }
    }

    func markAll() { marked = Set(visibleIDs) }

    /// Notes and folders among the marked rows (folders inside other marked folders go with their parent).
    private var markedItems: (notes: [(UUID, Note)], folders: [Folder]) {
        let folders = marked.filter { !isHidden($0) }.compactMap(store.folder).filter { f in
            !store.chain(f.id).dropLast().contains { marked.contains($0.id) }
        }
        let notes = marked.filter { !isHidden($0) }.compactMap { id in store.folderOf(id).flatMap { f in store.note(f.id, id).map { (f.id, $0) } } }
            .filter { fid, _ in !store.chain(fid).contains { marked.contains($0.id) } }
        return (notes, folders)
    }

    /// The marked rows are all in Recently Deleted: the bulk bar offers Restore and Delete Permanently.
    /// Decided by the rows themselves, not the screen (a search from Recently Deleted lists live notes too).
    var markedInTrash: Bool {
        let (notes, folders) = markedItems
        return !(notes.isEmpty && folders.isEmpty) && notes.allSatisfy { store.inTrash($0.0) } && folders.allSatisfy { store.inTrash($0.id) }
    }

    func moveMarked(to target: UUID) {
        guard !refuseLockedAway(target) else { return }
        let (notes, folders) = markedItems
        for (fid, n) in notes { store.moveNote(n.id, from: fid, to: target) }
        for f in folders { store.moveFolder(f.id, into: target) }
        marked = []
        flash("Moved to \(store.folder(target)?.name ?? "")")
    }

    func colorMarked(_ c: NoteColor) {
        let (notes, folders) = markedItems
        for (fid, n) in notes { store.updateNote(fid, n.id) { $0.color = c } }
        for f in folders { store.updateFolder(f.id) { $0.color = c } }
    }

    func pinMarked() {
        let (notes, folders) = markedItems
        let pin = !(notes.allSatisfy(\.1.pinned) && folders.allSatisfy(\.pinned))
        for (fid, n) in notes { store.updateNote(fid, n.id) { $0.pinned = pin } }
        for f in folders { store.updateFolder(f.id) { $0.pinned = pin } }
    }

    /// To Recently Deleted with one Undo; from Recently Deleted, deletes for good after asking.
    func deleteMarked() {
        let (notes, folders) = markedItems
        guard !notes.isEmpty || !folders.isEmpty else { return }
        if markedInTrash { pendingDelete = .items(notes.map(\.1.id) + folders.map(\.id)); return }
        let live = notes.filter { !store.inTrash($0.0) }, liveFolders = folders.filter { !store.inTrash($0.id) } // already-deleted ones stay put
        for (fid, n) in live { store.trashNote(fid, n.id) }
        for f in liveFolders { leave(folder: f); store.trashFolder(f.id) }
        let ids = live.map(\.1.id) + liveFolders.map(\.id)
        marked = []
        flash("Moved \(ids.count) to Recently Deleted") { [weak self] in ids.forEach { self?.store.restore($0) } }
    }

    func restoreMarked() {
        let (notes, folders) = markedItems
        let places = Set((notes.map(\.1.id) + folders.map(\.id)).compactMap { store.restore($0) })
        marked = []
        flash(places.count == 1 ? "Restored to “\(store.folder(places.first!)?.name ?? "")”" : "Restored")
    }

    func archiveMarked(_ on: Bool = true) {
        let (notes, _) = markedItems
        for (fid, n) in notes { store.updateNote(fid, n.id) { $0.archived = on; $0.pinned = on ? false : $0.pinned } }
        marked = []
        flash(on ? "Archived" : "Unarchived") { [weak self] in for (fid, n) in notes { self?.store.updateNote(fid, n.id) { $0.archived = !on } } }
    }

    // MARK: Toast

    func undoLast() {
        let undo = undoAction
        toast = nil
        undoAction = nil
        undo?()
    }

    /// Clicking a card: snippets copy themselves, other notes open (at `find`, coming from a search).
    func activate(_ fid: UUID, _ n: Note, find: String? = nil) {
        if n.lock != nil, unlocked[n.id] == nil { return unlock(n.id) { [weak self] in self?.activate(fid, n, find: find) } }
        guard !n.snippet else { return copy(n) }
        search = ""
        route = .note(fid, n.id)
        if let find { whenOpen(n.id) { $0.reveal(text: find) } }
    }

    // MARK: Keyboard selection

    var searchHits: [(Folder, Note)] {
        let scoped = searchInFolder && currentFolder != Folder.rootID, q = Query(search)
        // Notes whose title has the words come first, then the newest.
        func inTitle(_ n: Note) -> Bool { !q.words.isEmpty && q.words.allSatisfy { MD.finds($0, in: n.title) } }
        return hits(q, in: scoped ? store.subtree(currentFolder) : store.liveFolders)
            .sorted { a, b in inTitle(a.1) != inTitle(b.1) ? inTitle(a.1) : a.1.modified > b.1.modified }
    }

    func hits(_ q: Query, in folders: [Folder]? = nil) -> [(Folder, Note)] {
        guard !q.isEmpty else { return [] }
        return (folders ?? store.liveFolders).flatMap { f in
            let path = f.id == Folder.rootID ? "" : store.path(f.id)
            return f.notes.filter { q.matches($0, path: path, seen: { [store] in ImageText.text(for: $0, in: store) }) }.map { (f, $0) }
        }
    }

    /// Searches typed text and turns the search into a smart folder in the open folder.
    func saveSearch() {
        let parent = targetFolder(named: nil)
        let id = store.addFolder(search, in: parent)
        // Searching only this folder: the smart folder keeps that scope.
        let scoped = searchInFolder && currentFolder != Folder.rootID ? "\"path:\(store.path(currentFolder))\" " + search : search
        store.updateFolder(id) { $0.query = scoped }
        search = ""
        route = .folder(id)
    }

    // MARK: Tags and links

    /// Every tag in live notes with how many notes use it, A–Z. Recounted only after edits.
    // MARK: Search hints

    struct SearchHint: Identifiable, Equatable {
        let insert: String, label: String, detail: String
        var id: String { insert + "|" + label }
    }

    /// What the search box offers for what's typed: its kinds of search when empty, then the tags after `#`,
    /// the filters after `is:`, the folders after `path:`.
    func searchHints(_ text: String) -> [SearchHint] {
        if text.isEmpty {
            return [
                SearchHint(insert: "#", label: "#tag", detail: "Notes with a tag"),
                SearchHint(insert: "is:", label: "is:", detail: "todo · done · pinned · archived…"),
                SearchHint(insert: "path:", label: "path:", detail: "Only in one folder"),
                SearchHint(insert: "\"", label: "\"exact phrase\"", detail: "These words together"),
                SearchHint(insert: "-", label: "-word", detail: "Leave out notes with a word"),
                SearchHint(insert: ">", label: "> command", detail: "Run a command (⌘P)"),
            ]
        }
        let token = text.components(separatedBy: " ").last ?? "", lower = token.lowercased()
        if lower.hasPrefix("is:") {
            let typed = lower.dropFirst(3)
            return Self.flags.filter { typed.isEmpty || $0.0.hasPrefix(typed) && $0.0 != typed }
                .map { SearchHint(insert: "is:\($0.0) ", label: "is:\($0.0)", detail: $0.1) }
        }
        if token.hasPrefix("#") || lower.hasPrefix("tag:") {
            let typed = token.hasPrefix("#") ? String(token.dropFirst()) : String(token.dropFirst(4))
            return allTags.filter { typed.isEmpty || MD.fuzzy(typed, $0.name) != nil && $0.name != typed.lowercased() }
                .prefix(12).map { SearchHint(insert: "#\($0.name) ", label: "#\($0.name)", detail: MD.plural($0.count, "note")) }
        }
        if lower.hasPrefix("path:") || lower.hasPrefix("in:") {
            let typed = String(token.drop { $0 != ":" }.dropFirst())
            return store.moveTargets.filter { $0.id != Folder.rootID }.map { store.path($0.id) }
                .filter { typed.isEmpty || MD.fuzzy(typed, $0) != nil }.prefix(10)
                .map { SearchHint(insert: $0.contains(" ") ? "\"path:\($0)\" " : "path:\($0) ", label: $0, detail: "Folder") }
        }
        return []
    }
    private static let flags = [("todo", "Notes with unfinished tasks"), ("done", "Notes whose tasks are all done"), ("task", "Notes with tasks"),
                                ("pinned", "Pinned notes"), ("archived", "Archived notes"), ("snippet", "Snippets"), ("code", "Code notes")]

    /// Puts a hint in place of the word being typed (or opens the command list).
    func apply(_ hint: SearchHint) {
        if hint.insert == ">" { search = ""; palette = .commands; return }
        var words = search.components(separatedBy: " ")
        words[words.count - 1] = hint.insert
        search = words.joined(separator: " ")
    }

    var allTags: [(name: String, count: Int)] {
        _ = store.folders.count // observe changes even when the cache answers
        if let c = tagCache, c.stamp == store.edits { return c.tags }
        var counts: [String: Int] = [:]
        for f in store.liveFolders { for n in f.notes where !n.archived { for t in MD.tags(n.text) { counts[t, default: 0] += 1 } } }
        let tags = counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { (name: $0.key, count: $0.value) }
        tagCache = (store.edits, tags)
        return tags
    }

    /// Completions for the editor: note titles after `[[`, tags after `#`.
    func suggestions(_ kind: MarkdownTextView.Completion, _ partial: String, excluding nid: UUID? = nil) -> [String] {
        var seen = Set<String>()
        if kind == .link, let hash = partial.firstIndex(of: "#") { // [[Note#  → that note's headings
            let name = String(partial[..<hash]), rest = String(partial[partial.index(after: hash)...])
            let n: Note? = name.isEmpty ? nid.flatMap { id in store.folderOf(id).flatMap { store.note($0.id, id) } } : resolve(title: name)?.1
            guard let n, !rest.hasPrefix("^") else { return [] }
            let heads = MD.headings(unlocked[n.id] ?? n.text).map(\.title).filter { seen.insert($0.lowercased()).inserted }
            return heads.compactMap { h in MD.fuzzy(rest, h).map { (name + "#" + h, $0) } }.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
        }
        let names: [String] = switch kind {
        case .tag: allTags.map(\.name)
        case .command: [] // the editor's own list
        case .link: store.liveFolders.flatMap(\.notes).filter { $0.id != nid && !$0.archived }.flatMap { [$0.title] + MD.aliases($0.text) }
            .filter { $0 != "Empty Note" && seen.insert($0.lowercased()).inserted }
        }
        return names.compactMap { n in MD.fuzzy(partial, n).map { (n, $0) } }.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
    }

    /// The note a `[[title]]` means: one in the open folder first, else the newest with that title.
    /// A title beats an alias (`aliases:` in a note's frontmatter).
    func resolve(title: String) -> (UUID, Note)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        func best(_ named: (Note) -> Bool) -> (UUID, Note)? {
            store.liveFolders.flatMap { f in f.notes.filter(named).map { (f.id, $0) } }
                .max { a, b in a.0 == currentFolder ? false : b.0 == currentFolder ? true : a.1.modified < b.1.modified }
        }
        return best { $0.title.localizedCaseInsensitiveCompare(t) == .orderedSame }
            ?? best { MD.aliases($0.text).contains { $0.localizedCaseInsensitiveCompare(t) == .orderedSame } }
    }

    /// The note a `[[title]]` means when it's in a folder that's locked away (its title stays readable).
    private func lockedAwayNote(titled title: String) -> (UUID, Note)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        for f in store.folders where store.lockedAway(f.id) {
            if let n = f.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(t) == .orderedSame }) { return (f.id, n) }
        }
        return nil
    }

    /// Notes with a `[[…]]` to one of these names (a note's title and aliases), or to a heading in it.
    func backlinks(to names: [String], excluding nid: UUID) -> [(Folder, Note)] {
        store.liveFolders.flatMap { f in
            f.notes.filter { n in n.id != nid && MD.wikiLinks(n.text).contains { t in names.contains { MD.links(t, to: $0) } } }.map { (f, $0) }
        }
    }

    /// Notes tied to the app the panel was opened from.
    var appNotes: [(UUID, Note)] {
        guard let app = frontApp?.id else { return [] }
        return store.liveFolders.filter { !store.inTrash($0.id) }.flatMap { f in f.notes.filter { $0.apps.contains(app) && !$0.archived }.map { (f.id, $0) } }
    }

    /// Ties a note to an app, or unties it.
    func toggleApp(_ fid: UUID, _ nid: UUID, _ bundle: String) {
        store.updateNote(fid, nid) { n in if n.apps.contains(bundle) { n.apps.removeAll { $0 == bundle } } else { n.apps.append(bundle) } }
    }

    /// Notes that name this note (its title or an alias) in their text without linking to it.
    func mentions(of names: [String], excluding nid: UUID) -> [(Folder, Note, String)] {
        store.liveFolders.filter { !store.inTrash($0.id) }.flatMap { f in
            f.notes.compactMap { n -> (Folder, Note, String)? in
                guard n.id != nid, n.lock == nil, !MD.wikiLinks(n.text).contains(where: { t in names.contains { MD.links(t, to: $0) } }),
                      let name = names.first(where: { !MD.mentionRanges($0, in: n.text).isEmpty }) else { return nil }
                return (f, n, name)
            }
        }
    }

    /// The first mention of `name` in that note becomes a `[[link]]` (Undo puts it back).
    func linkMention(_ fid: UUID, _ nid: UUID, name: String, title: String) {
        guard let n = store.note(fid, nid), let r = MD.mentionRanges(name, in: n.text).first else { return }
        let found = (n.text as NSString).substring(with: r)
        let link = found == title ? "[[\(title)]]" : "[[\(title)|\(found)]]"
        let before = n.text
        store.updateNote(fid, nid) { $0.text = ($0.text as NSString).replacingCharacters(in: r, with: link) }
        flash("Linked in “\(n.title)”") { [weak self] in self?.store.updateNote(fid, nid) { $0.text = before } }
    }

    /// `#old` (and `#old/…`) becomes `#new` in every note; a tag that exists already merges into it. Undo puts it back.
    func renameTag(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard let to = MD.tagName(new), to != old else { return }
        var before: [(UUID, UUID, String)] = []
        for f in store.liveFolders {
            for n in f.notes where n.lock == nil {
                let text = MD.renamedTag(n.text, from: old, to: to)
                guard text != n.text else { continue }
                before.append((f.id, n.id, n.text))
                store.updateNote(f.id, n.id) { $0.text = text }
            }
        }
        guard !before.isEmpty else { return }
        flash("#\(old) is now #\(to) in \(MD.plural(before.count, "note"))") { [weak self] in
            for (f, n, text) in before { self?.store.updateNote(f, n) { $0.text = text } }
        }
    }

    /// Asks for a tag's new name.
    func askRenameTag(_ old: String) {
        let answer: String? = PanelController.shared?.modal {
            let a = NSAlert()
            a.messageText = "Rename #\(old)"
            a.informativeText = "Every note with it changes. A name that's already a tag merges the two."
            let field = NSTextField(string: old)
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            a.accessoryView = field
            a.addButton(withTitle: "Rename")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = field
            return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        } ?? nil
        if let answer { renameTag(old, to: answer) }
    }

    /// Files in the attachments folder, with the notes that use each. A sealed one (`.locked`) belongs to a
    /// locked note whose text can't be read: it never counts as unused.
    struct Attachment: Identifiable { let url: URL; let notes: [(UUID, Note)]; let sealed: Bool; var id: URL { url } }

    func attachments() -> [Attachment] {
        let dir = store.directory.appendingPathComponent("attachments")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        let notes = store.folders.flatMap { f in f.notes.map { (f.id, $0) } } // Recently Deleted's too: they may come back
        return files.map { url in
            let sealed = url.pathExtension == "locked"
            return Attachment(url: url, notes: sealed ? [] : notes.filter { $0.1.text.contains("attachments/" + url.lastPathComponent) }, sealed: sealed)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// `cortexy://tag/x` searches the tag; `cortexy://open?title=T` opens that note, creating it if there's none.
    @discardableResult func openLink(_ url: URL) -> Bool {
        guard url.scheme == "cortexy" else { return false }
        switch url.host {
        case "footnote":
            MarkdownTextView.active?.revealFootnote(String(url.path.dropFirst()))
        case "tag":
            if case .note(let f, _) = route { route = .folder(f) }
            searchInFolder = false
            search = "#" + url.path.dropFirst()
        case "open":
            guard let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "title" })?.value,
                  !title.isEmpty else { return false }
            search = ""
            // What follows # is a heading or a block (^id), unless the whole is a note's title ("C# tips").
            var (name, heading, block) = (title, String?.none, String?.none)
            if title.contains("#"), resolve(title: title) == nil, lockedAwayNote(titled: title) == nil {
                (name, heading, block) = MD.splitLink(title)
            }
            func reveal(_ n: Note) {
                guard heading != nil || block != nil, let line = MD.line(heading: heading, block: block, in: unlocked[n.id] ?? n.text) else { return }
                whenOpen(n.id) { $0.reveal(line: line) }
            }
            if name.isEmpty { // [[#Heading]]: in this note
                if case .note(let fid, let id) = route, let n = store.note(fid, id) { reveal(n) }
            }
            else if let (fid, n) = resolve(title: name) { route = .note(fid, n.id); reveal(n) }
            else if let (fid, n) = lockedAwayNote(titled: name) { // there, behind its folder's lock: ask to open it, don't make a copy
                let door = store.chain(fid).first { $0.locked && !store.openFolders.contains($0.id) }?.id ?? fid
                unlockFolder(door) { [self] in activate(fid, n) }
            }
            else if !refuseLockedAway(targetFolder(named: nil)), let id = store.addNote(to: targetFolder(named: nil), text: "# \(name)\n") {
                stub = (id, "# \(name)\n")
                route = .note(targetFolder(named: nil), id)
            }
        default:
            return false
        }
        return true
    }

    /// A note's title changed: point `[[Old]]` links at the new one (Undo puts them back).
    /// A note edited in its own window: once it closes, [[links]] to its old title follow a rename.
    func noteRenamed(_ nid: UUID, from old: String) {
        if let new = store.folderOf(nid).flatMap({ store.note($0.id, nid)?.title }) { relink(old, to: new) }
    }

    private func relink(_ old: String, to new: String) {
        guard old != new, old != "Empty Note", new != "Empty Note" else { return }
        var before: [(UUID, UUID, String)] = []
        for f in store.liveFolders {
            for n in f.notes {
                let text = MD.relinked(n.text, from: old, to: new) { [self] in resolve(title: $0) != nil }
                guard text != n.text else { continue }
                before.append((f.id, n.id, n.text))
                store.updateNote(f.id, n.id) { $0.text = text }
            }
        }
        guard !before.isEmpty else { return }
        flash("Updated \(before.count) link\(before.count == 1 ? "" : "s") to “\(new)”") { [weak self] in
            for (f, n, text) in before { self?.store.updateNote(f, n) { $0.text = text } }
        }
    }

    // MARK: Due dates

    /// A date as the app shows it: the user's format, in the calendar chosen for templates (Gregorian unless the
    /// Mac's own is asked for), so it reads the same as the dates written in notes.
    static func show(_ date: Date, time: Bool) -> String {
        let f = dateFormatter()
        f.dateStyle = .medium
        f.timeStyle = time ? .short : .none
        return f.string(from: date)
    }

    /// Dates as Settings → General says: Gregorian unless this Mac's calendar is chosen, names in the chosen language.
    static func dateFormatter() -> DateFormatter {
        let f = DateFormatter()
        let language = UserDefaults.standard.string(forKey: Prefs.dateLanguage) ?? ""
        if !language.isEmpty { f.locale = Locale(identifier: language) }
        f.calendar = UserDefaults.standard.bool(forKey: Prefs.systemCalendar) ? Calendar.current : Calendar(identifier: .gregorian)
        f.calendar.locale = f.locale
        return f
    }

    struct DueTask: Identifiable {
        let id: String // note + line
        let fid: UUID, nid: UUID, line: Int
        let text: String // the task without its date
        let done: Bool
        let date: Date
        let hasTime: Bool
        var due: Due { Due.of(date, hasTime: hasTime, done: done) }
    }

    /// Every task with a date, soonest first.
    var dueTasks: [DueTask] {
        _ = store.folders.count // observe changes even when the cache answers
        let stamp = [store.edits, store.openFolders.count]
        if let c = dueCache, c.stamp == stamp { return c.tasks }
        let tasks = Self.dueTasks(in: store.liveFolders)
        dueCache = (stamp, tasks)
        return tasks
    }
    // Home asks on every render, and every ask read all notes with dates (and parsed each date): only when something changed now.
    @ObservationIgnored private var dueCache: (stamp: [Int], tasks: [DueTask])?

    static func dueTasks(in folders: [Folder]) -> [DueTask] {
        folders.flatMap { f in
            f.notes.filter { !$0.archived && ($0.text.contains("📅") || $0.text.contains("@")) }.flatMap { n in
                MD.lines(n.text).enumerated().compactMap { i, line -> DueTask? in
                    guard case .task(let done, let s) = line, let d = MD.due(s) else { return nil }
                    let text = (s as NSString).replacingCharacters(in: d.range, with: "").trimmingCharacters(in: .whitespaces)
                    return DueTask(id: "\(n.id.uuidString)-\(i)", fid: f.id, nid: n.id, line: i, text: text, done: done, date: d.date, hasTime: d.hasTime)
                }
            }
        }.sorted { $0.date < $1.date }
    }

    /// After every save: off the main thread, as reading every dated task out of a long note takes a while
    /// (in order, so an older pass never replaces a newer one).
    func scheduleReminders() {
        let folders = store.liveFolders
        Self.reminderQueue.async {
            let tasks = Self.dueTasks(in: folders), ids = Set(tasks.map(\.nid))
            var titles: [UUID: String] = [:]
            for f in folders { for n in f.notes where ids.contains(n.id) { titles[n.id] = n.title } }
            Reminders.shared.schedule(tasks, titles: titles)
        }
    }
    private static let reminderQueue = DispatchQueue(label: "cortexy.reminders", qos: .utility)

    /// From a reminder or a link: the note, wherever it is now.
    func openNote(_ id: UUID, line: Int? = nil) {
        guard let f = store.folderOf(id) else { return }
        search = ""
        route = .note(f.id, id)
        if let line { whenOpen(id) { $0.reveal(line: line) } }
    }

    // MARK: Version history

    /// While editing, a version is kept every few minutes too (besides on opening and leaving the note).
    func edited(_ nid: UUID) {
        guard Date().timeIntervalSince(lastSnapshot[nid] ?? .distantPast) > 300 else { return }
        lastSnapshot[nid] = Date()
        store.snapshot(nid)
    }

    /// Puts an old version back. The text it replaces is kept as a version as well, and Undo brings it back.
    func restoreVersion(_ nid: UUID, _ v: Store.Version) {
        guard let f = store.folderOf(nid), let current = store.note(f.id, nid)?.text else { return }
        store.snapshot(nid)
        store.updateNote(f.id, nid) { $0.text = v.text; $0.modified = Date() }
        historyNote = nil
        flash("Restored the version from \(Nav.show(v.date, time: true))") { [weak self] in
            self?.store.updateNote(f.id, nid) { $0.text = current; $0.modified = Date() }
        }
    }

    // MARK: Templates and daily notes

    /// Notes in the Templates folder (named in Settings → General).
    var templatesFolder: Folder? {
        store.moveTargets.first { $0.name.localizedCaseInsensitiveCompare(Prefs.text(Prefs.templatesFolder)) == .orderedSame }
    }
    var templates: [Note] { templatesFolder?.shownNotes ?? [] }

    /// Fills in a template: {{date}} {{time}} {{datetime}} {{weekday}} {{folder}}, and {{date:MMMM yyyy}} in any format.
    /// {{cursor}} marks where typing starts: it's removed, and its place returned.
    static func expand(_ text: String, date: Date = Date(), folder: String = "") -> (text: String, caret: Int?) {
        let f = dateFormatter()
        func format(_ pattern: String) -> String { f.dateFormat = pattern; return f.string(from: date) }
        let day = Prefs.text(Prefs.dateFormat)
        var out = text as NSString
        let custom = try! NSRegularExpression(pattern: #"\{\{date:([^}]+)\}\}"#)
        for m in custom.matches(in: out as String, range: NSRange(location: 0, length: out.length)).reversed() {
            out = out.replacingCharacters(in: m.range, with: format(out.substring(with: m.range(at: 1)))) as NSString
        }
        var s = out as String
        for (key, value) in [("{{date}}", format(day)), ("{{time}}", format("HH:mm")), ("{{datetime}}", format(day + " HH:mm")),
                             ("{{weekday}}", format("EEEE")), ("{{week}}", format("w")), ("{{folder}}", folder)] {
            s = s.replacingOccurrences(of: key, with: value)
        }
        let cursor = (s as NSString).range(of: "{{cursor}}")
        guard cursor.location != NSNotFound else { return (s, nil) }
        return ((s as NSString).replacingCharacters(in: cursor, with: ""), cursor.location)
    }

    /// What a shortcut made in Settings does. False (and said) when its template or note is gone.
    @discardableResult func run(_ s: CustomShortcut) -> Bool {
        guard let id = s.target, let f = store.folderOf(id), let n = store.note(f.id, id), !store.inTrash(f.id) else {
            flash(s.target == nil ? "Choose what the shortcut does in Settings → Shortcuts" : "That shortcut's \(s.action == .template ? "template" : "note") is gone")
            return false
        }
        switch s.action {
        case .template:
            // Into its folder, or home when it has none (one since deleted: home too, and said).
            let gone = s.folder.map { id in !store.moveTargets.contains { $0.id == id } } ?? false
            if gone { flash("That shortcut's folder is gone: the note is at home") }
            newNote(from: n, in: gone ? Folder.rootID : s.folder ?? Folder.rootID)
        case .note: activate(f.id, n)
        }
        return true
    }

    /// A new note made from `template`: in `folder`, else in the open one (not the Templates folder itself).
    func newNote(from template: Note, in folder: UUID? = nil) {
        var fid = folder ?? targetFolder(named: nil)
        if fid == templatesFolder?.id { fid = Folder.rootID }
        let (text, caret) = Nav.expand(template.text, folder: store.folder(fid)?.name ?? "")
        guard !refuseLockedAway(fid), let id = store.addNote(to: fid, text: text) else { return }
        store.updateNote(fid, id) { $0.color = template.color; $0.code = template.code }
        open(fid, id, caret: caret)
    }

    enum Period: String, CaseIterable { case day, week, month }

    /// The note's title for `period` around `date`: the date format for a day, a week's ("2026-W41") or a month's.
    static func periodTitle(_ period: Period, _ date: Date) -> String {
        switch period {
        case .day: return expand("{{date}}", date: date).text
        case .week:
            let f = dateFormatter()
            f.calendar = Calendar(identifier: .iso8601) // weeks start on Monday, week 1 holds the year's first Thursday
            f.calendar.locale = f.locale
            f.dateFormat = Prefs.text(Prefs.weekFormat)
            return f.string(from: date)
        case .month: return expand("{{date:\(Prefs.text(Prefs.monthFormat))}}", date: date).text
        }
    }

    /// The days that have a daily note (by title), for the calendar's dots.
    func dailyTitles() -> Set<String> {
        let name = Prefs.text(Prefs.dailyFolder)
        return Set(store.moveTargets.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }.map { store.folder($0.id)?.notes.map(\.title) ?? [] } ?? [])
    }

    /// ⌘D: today's note in the Daily folder, made from the daily template (Settings) the first time.
    func openToday() { openPeriodic(.day) }

    /// A day's, week's or month's note (made from its template the first time), all in the Daily folder.
    func openPeriodic(_ period: Period, date: Date = Date()) {
        guard let (fid, nid, caret) = periodicNote(period, date: date) else { return }
        open(fid, nid, caret: caret)
    }

    /// That note, made if it isn't there: its folder, its id, and (when just made) where the caret goes.
    func periodicNote(_ period: Period, date: Date = Date()) -> (UUID, UUID, Int?)? {
        let name = Prefs.text(Prefs.dailyFolder)
        let fid = store.moveTargets.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id ?? store.addFolder(name)
        let title = Nav.periodTitle(period, date)
        if let n = store.folder(fid)?.notes.first(where: { $0.title == title }) { return (fid, n.id, nil) }
        let wanted = Prefs.text([.day: Prefs.dailyTemplate, .week: Prefs.weeklyTemplate, .month: Prefs.monthlyTemplate][period]!)
        let template = wanted.isEmpty ? nil : templates.first { $0.title.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        var (text, caret) = template.map { Nav.expand($0.text, date: date, folder: name) } ?? ("# \(title)\n", nil)
        if MD.title(text) != title { // the date is how the note is found again
            let head = "# \(title)\n"
            text = head + text
            caret = caret.map { $0 + (head as NSString).length }
        }
        guard let id = store.addNote(to: fid, text: text) else { return nil }
        return (fid, id, caret ?? (text as NSString).length)
    }

    /// Text added to the end of a note without opening it: "inbox" (a note called Inbox at home, made if
    /// needed), "today" (today's note) or a note's title (made if there's none). A locked note says no.
    @discardableResult func append(_ text: String, to target: String? = nil) -> Bool {
        let t = (target ?? "inbox").trimmingCharacters(in: .whitespaces)
        let place: (UUID, UUID)?
        switch t.lowercased() {
        case "today": place = periodicNote(.day).map { ($0.0, $0.1) }
        case "", "inbox":
            place = store.folder(Folder.rootID)?.notes.first { $0.title.localizedCaseInsensitiveCompare("Inbox") == .orderedSame }.map { (Folder.rootID, $0.id) }
                ?? store.addNote(to: Folder.rootID, text: "# Inbox\n").map { (Folder.rootID, $0) }
        default:
            place = resolve(title: t).map { ($0.0, $0.1.id) } ?? store.addNote(to: targetFolder(named: nil), text: "# \(t)\n").map { (targetFolder(named: nil), $0) }
        }
        guard let (fid, nid) = place, let n = store.note(fid, nid) else { return false }
        if n.lock != nil {
            guard let open = unlocked[nid] else { flash("“\(n.title)” is locked"); return false }
            updateLocked(nid, open + (open.hasSuffix("\n") || open.isEmpty ? "" : "\n") + text) // sealed again, never written plain
            return true
        }
        store.updateNote(fid, nid) { $0.text += ($0.text.hasSuffix("\n") || $0.text.isEmpty ? "" : "\n") + text }
        return true
    }

    private func open(_ fid: UUID, _ nid: UUID, caret: Int?) {
        search = ""
        route = .note(fid, nid)
        guard let caret else { return }
        whenOpen(nid) { $0.setSelectedRange(NSRange(location: min(caret, ($0.string as NSString).length), length: 0)) }
    }

    /// `body` with the note's editor, once its page is up (a moment later). Only that note's: going elsewhere
    /// quickly meanwhile left another note's editor the active one, and its caret jumped.
    private func whenOpen(_ nid: UUID, _ body: @escaping (MarkdownTextView) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let tv = MarkdownTextView.active, tv.noteID == nid else { return }
            body(tv)
        }
    }

    // MARK: Quick open and commands

    enum PaletteMode { case open, commands }
    struct PaletteItem: Identifiable {
        let id: String
        let title: String
        var detail = ""
        let symbol: String
        let run: () -> Void
    }

    var palette: PaletteMode? {
        didSet {
            paletteQuery = ""
            paletteIndex = 0
            // Closed over a note: typing goes back into it (its field had the focus).
            if palette == nil, oldValue != nil, case .note = route {
                DispatchQueue.main.async { if let tv = MarkdownTextView.active { tv.window?.makeFirstResponder(tv) } }
            }
        }
    }
    var paletteQuery = "" { didSet { paletteIndex = 0 } }
    var paletteIndex = 0

    /// ⌘O finds notes, folders and #tags; ⌘P (or typing ">") runs commands.
    var paletteItems: [PaletteItem] {
        let commands = palette == .commands || paletteQuery.hasPrefix(">")
        let q = commands && paletteQuery.hasPrefix(">") ? String(paletteQuery.dropFirst()).trimmingCharacters(in: .whitespaces) : paletteQuery
        let pool = commands ? commandItems : openItems(q)
        guard !q.isEmpty else { return Array(pool.prefix(60)) }
        return pool.compactMap { item in MD.fuzzy(q, item.title).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
    }

    func movePalette(_ d: Int) { paletteIndex = max(0, min(paletteItems.count - 1, paletteIndex + d)) }

    func runPalette() {
        let items = paletteItems
        guard items.indices.contains(paletteIndex) else { return }
        let run = items[paletteIndex].run
        palette = nil
        run()
    }

    private func openItems(_ q: String) -> [PaletteItem] {
        if q.hasPrefix("#") {
            let t = String(q.dropFirst())
            return allTags.filter { t.isEmpty || MD.fuzzy(t, $0.name) != nil }.map { tag in
                PaletteItem(id: "tag:" + tag.name, title: "#" + tag.name, detail: "\(tag.count)", symbol: "number") { [weak self] in
                    self?.openLink(Link.tag(tag.name))
                }
            }
        }
        let notes = store.liveFolders.flatMap { f in f.notes.map { (f, $0) } }.sorted { $0.1.modified > $1.1.modified }
        let noteItems = notes.map { f, n in
            PaletteItem(id: n.id.uuidString, title: n.title, detail: (n.archived ? "Archived · " : "") + store.path(f.id),
                        symbol: n.snippet ? "doc.on.clipboard" : "note.text") { [weak self] in
                self?.search = ""
                self?.route = .note(f.id, n.id)
            }
        }
        let folderItems = store.liveFolders.filter { $0.id != Folder.rootID }.map { f in
            PaletteItem(id: f.id.uuidString, title: f.name, detail: store.parentID(f).map(store.path) ?? "",
                        symbol: f.query == nil ? "folder" : "sparkle.magnifyingglass") { [weak self] in
                self?.search = ""
                self?.route = .folder(f.id)
            }
        }
        return noteItems + folderItems
    }

    private var commandItems: [PaletteItem] {
        func cmd(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:" + title, title: title, symbol: symbol, run: run)
        }
        var items = [
            cmd("New Note", "square.and.pencil") { [weak self] in self?.newNote() },
            cmd("New Folder", "folder.badge.plus") { [weak self] in self?.newFolder() },
            cmd("Search", "magnifyingglass") { [weak self] in self?.searchFocus += 1 },
            cmd("Open Today's Note", "calendar") { [weak self] in self?.openToday() },
            cmd("Open This Week's Note", "calendar") { [weak self] in self?.openPeriodic(.week) },
            cmd("Open This Month's Note", "calendar") { [weak self] in self?.openPeriodic(.month) },
            cmd("Daily Notes Calendar", "calendar.badge.clock") { [weak self] in self?.calendarShown = true },
            cmd("Open a Random Note", "shuffle") { [weak self] in self?.openRandomNote() },
            cmd("Show Attachments", "paperclip") { [weak self] in self?.attachmentsShown = true },
            cmd("Import Markdown Folder…", "square.and.arrow.down") { [weak self] in self?.importMarkdownFolder() },
            cmd("Go Home", "house") { [weak self] in self?.search = ""; self?.route = .home },
            cmd("Show Archive", "archivebox") { [weak self] in self?.search = ""; self?.route = .archive },
            cmd("Show Upcoming", "calendar") { [weak self] in self?.search = ""; self?.route = .upcoming },
            cmd("Show Recently Deleted", "trash") { [weak self] in self?.search = ""; self?.route = .folder(Folder.trashID) },
            cmd("Show Graph", "point.3.connected.trianglepath.dotted") { [weak self] in self.map { GraphWindow.shared.show(nav: $0) } },
            cmd("Settings", "gearshape") { SettingsWindow.show() },
        ]
        if case let .note(fid, nid) = route, let n = store.note(fid, nid), store.inTrash(fid) {
            items += [ // deleted: it can only come back or go for good
                cmd("Restore Note", "arrow.uturn.backward") { [weak self] in self?.restore(nid) },
                cmd("Delete Note Permanently…", "trash") { [weak self] in self?.requestDelete(.note(fid, n)) },
            ]
        } else if case let .note(fid, nid) = route, let n = store.note(fid, nid) {
            items += [
                cmd(n.pinned ? "Unpin Note" : "Pin Note", "pin") { [weak self] in self?.store.updateNote(fid, nid) { $0.pinned.toggle() } },
                cmd("Duplicate Note", "plus.square.on.square") { [weak self] in self?.store.duplicateNote(fid, nid); self?.flash("Duplicated") },
                cmd(n.archived ? "Unarchive Note" : "Archive Note", "archivebox") { [weak self] in self?.archive(fid, nid, !n.archived) },
                cmd(n.code ? "Turn Off Code Mode" : "Turn On Code Mode", "chevron.left.forwardslash.chevron.right") { [weak self] in
                    self?.store.updateNote(fid, nid) { $0.code.toggle() }
                },
                cmd("Copy Note Text", "doc.on.doc") { [weak self] in self?.copy(n) },
                cmd("Insert Screenshot Text", "text.viewfinder") { [weak self] in self?.insertScreenshotText() },
            cmd("Version History", "clock.arrow.circlepath") { [weak self] in self?.historyNote = nid },
            cmd("Open Note in Window", "macwindow.on.rectangle") { [weak self] in self.map { NoteWindows.shared.show(nid, nav: $0) } },
                cmd("Show Note in Graph", "point.3.connected.trianglepath.dotted") { [weak self] in self.map { GraphWindow.shared.show(nav: $0, around: nid) } },
                cmd("Delete Note", "trash") { [weak self] in self?.requestDelete(.note(fid, n)) },
            ]
        }
        if case .folder(let fid) = route, store.folder(fid)?.query == nil, !store.inTrash(fid) {
            items += Folder.Sort.allCases.map { s in
                cmd(s == .manual ? "Sort Notes Manually" : "Sort Notes by \(s.name)", "arrow.up.arrow.down") { [weak self] in self?.store.updateFolder(fid) { $0.sort = s } }
            }
        }
        items += templates.map { t in cmd("New from Template: \(t.title)", "doc.badge.plus") { [weak self] in self?.newNote(from: t) } }
        items += ["system", "light", "dark"].map { mode in
            cmd("Appearance: \(mode.capitalized)", mode == "dark" ? "moon" : mode == "light" ? "sun.max" : "circle.lefthalf.filled") {
                Themes.shared.look.mode = mode
            }
        }
        items += Themes.shared.all.map { t in cmd("Theme: \(t.name)", "paintpalette") { Themes.shared.currentID = t.id } }
        return items
    }

    var visibleIDs: [UUID] {
        if !search.isEmpty { return searchHits.map(\.1.id) }
        switch route {
        case .folder(let f):
            if store.lockedAway(f) { return [] } // the screen shows only “Locked”
            if let q = store.folder(f)?.query { return hits(Query(q)).map(\.1.id) }
            // In the order the screen shows them: folders, then the Smart Folders section, then notes.
            let rows = folderRows(f), smart = { (r: (folder: Folder, depth: Int)) in r.depth == 0 && r.folder.query != nil }
            return rows.filter { !smart($0) }.map(\.folder.id) + rows.filter(smart).map(\.folder.id) + (store.folder(f)?.shownNotes.map(\.id) ?? [])
        case .archive: return archivedNotes.map(\.1.id)
        case .upcoming: return []
        case .note: return []
        }
    }

    func moveSelection(_ delta: Int) {
        let ids = visibleIDs
        guard !ids.isEmpty else { return }
        let i = selection.flatMap(ids.firstIndex) ?? (delta > 0 ? -1 : ids.count)
        selection = ids[max(0, min(ids.count - 1, i + delta))]
    }

    /// Return: open the selected row (or the first search hit).
    func openSelection() -> Bool {
        guard let id = selection ?? (search.isEmpty ? nil : visibleIDs.first), !isHidden(id) else { return false }
        if store.folder(id) != nil {
            route = .folder(id)
        } else if let f = store.folderOf(id), let n = store.note(f.id, id) {
            activate(f.id, n)
        }
        return true
    }

    func deleteSelection() {
        if !marked.isEmpty { return deleteMarked() }
        guard let id = selection, !isHidden(id) else { return }
        if let f = store.folder(id) { requestDelete(.folder(f)) }
        else if let f = store.folderOf(id), let n = store.note(f.id, id) { requestDelete(.note(f.id, n)) }
    }

    func foldSelection() {
        guard let id = selection, let f = store.folderOf(id) else { return }
        store.updateNote(f.id, id) { $0.folded.toggle() }
    }

    // MARK: Drag and drop

    /// Rows that can be reordered on the current screen (frames from other screens are stale).
    var reorderIDs: Set<UUID> {
        guard case .folder(let f) = route else { return [] }
        return Set(store.subfolders(f).map(\.id) + (store.folder(f)?.notes.map(\.id) ?? []))
    }

    /// Folder rows a dragged row can be dropped into: every one on screen, Recently Deleted included.
    var dropIDs: Set<UUID> {
        guard case .folder(let f) = route, !store.inTrash(f) else { return [] }
        return Set(folderRows(f).map(\.folder).filter { $0.query == nil }.map(\.id) + (f == Folder.rootID ? [Folder.trashID] : []))
    }

    /// A row dropped onto a folder row moves into it; onto Recently Deleted, it's deleted (with Undo).
    /// Dragging a marked row takes every marked row along.
    func drop(_ id: UUID, into target: UUID) {
        guard !isHidden(id), !refuseLockedAway(target) else { return }
        if marked.contains(id) {
            return target == Folder.trashID ? deleteMarked() : moveMarked(to: target)
        }
        if let f = store.folder(id) {
            guard f.id != target, !store.subtree(f.id).contains(where: { $0.id == target }) else { return }
            if target == Folder.trashID { return requestDelete(.folder(f)) }
            store.moveFolder(f.id, into: target)
        } else if let from = store.folderOf(id), let n = store.note(from.id, id) {
            if target == Folder.trashID { return requestDelete(.note(from.id, n)) }
            store.moveNote(id, from: from.id, to: target)
        } else { return }
        flash("Moved to \(store.folder(target)?.name ?? "")")
    }

    /// Something dropped on the panel from another app becomes a note in the open folder:
    /// files (images are copied in), an image, a web link, or text.
    func importPasteboard(_ pb: NSPasteboard) -> Bool {
        var text = ""
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            text = files.map(store.markdown(forFile:)).joined(separator: "\n")
        } else if pb.availableType(from: [.png, .tiff]) != nil, let img = NSImage(pasteboard: pb) {
            text = store.markdown(forImage: img) ?? ""
        } else if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme?.hasPrefix("http") == true {
            text = "[\(MD.escape(url.host ?? url.absoluteString))](\(url.absoluteString))"
        } else if let s = pb.string(forType: .string) {
            text = s
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let fid = targetFolder(named: nil)
        guard !refuseLockedAway(fid) else { return true } // taken (and told), not passed on to something else
        store.addNote(to: fid, text: text)
        flash("Added")
        return true
    }

    // MARK: Images, screenshots, export

    func insertImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        let urls = PanelController.shared?.modal { panel.runModal() == .OK ? panel.urls : [] } ?? []
        guard !urls.isEmpty else { return }
        MarkdownTextView.active?.insertBlock(urls.map(store.markdown(forFile:)).joined(separator: "\n"))
    }

    /// Hides the panel, lets the user drag out a region, and drops the capture into the open note.
    /// Asks for a folder of Markdown and brings its notes in (see `Store.importMarkdown`), then opens the new folder.
    func importMarkdownFolder() {
        let url: URL? = PanelController.shared?.modal {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.prompt = "Import"
            p.message = "Choose an Obsidian vault, a Bear or Apple Notes Markdown export, or any folder of .md files"
            return p.runModal() == .OK ? p.url : nil
        } ?? nil
        guard let url else { return }
        let (fid, count) = store.importMarkdown(from: url)
        search = ""
        route = .folder(fid)
        flash("Imported \(MD.plural(count, "note")) into “\(url.lastPathComponent)”")
    }

    /// A screenshot's text instead of the picture (read on this Mac).
    func insertScreenshotText() { insertScreenshot(asText: true) }

    func insertScreenshot(asText: Bool = false) {
        guard case let .note(fid, nid) = route, let c = PanelController.shared else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cortexy-\(UUID().uuidString).png")
        c.hide(lock: false) // the note it goes into stays open
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", tmp.path]
            p.terminationHandler = { _ in
                DispatchQueue.main.async { [self] in
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    c.show(byHover: false)
                    let md: String
                    if asText {
                        guard let text = ImageText.read(tmp), !text.isEmpty else { return flash("No text found in the screenshot") }
                        md = text
                    } else {
                        guard let data = try? Data(contentsOf: tmp), let path = store.addAttachment(data, ext: "png") else { return }
                        md = "![screenshot](\(path))"
                    }
                    if let tv = MarkdownTextView.active, tv.window != nil { tv.insertBlock(md) }
                    else if let open = unlocked[nid] { updateLocked(nid, open + "\n" + md) } // sealed, never into plain text
                    else if store.note(fid, nid)?.lock == nil { store.updateNote(fid, nid) { $0.text += "\n" + md } }
                }
            }
            do { try p.run() } catch { c.show(byHover: false) }
        }
    }

    @MainActor func copyImage(_ n: Note) {
        guard let img = NoteCard.snapshot(n, store: store) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        flash("Image Copied")
    }

    @MainActor func exportImage(_ n: Note) {
        guard let img = NoteCard.snapshot(n, store: store), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Store.fileName(n.title) + ".png"
        guard let url = PanelController.shared?.modal({ panel.runModal() == .OK ? panel.url : nil }) ?? nil else { return }
        do { try png.write(to: url) } catch { NSLog("Cortexy: export failed: \(error)") }
    }
}

extension Nav.Route {
    var encoded: String {
        switch self {
        case .archive: "archive"
        case .upcoming: "upcoming"
        case .folder(let f): "folder:\(f.uuidString)"
        case .note(let f, let n): "note:\(f.uuidString):\(n.uuidString)"
        }
    }

    init?(encoded: String) {
        let p = encoded.split(separator: ":").map(String.init)
        switch (p.first, p.count) {
        case ("archive", 1): self = .archive
        case ("upcoming", 1): self = .upcoming
        case ("folder", 2): guard let f = UUID(uuidString: p[1]) else { return nil }; self = .folder(f)
        case ("note", 3): guard let f = UUID(uuidString: p[1]), let n = UUID(uuidString: p[2]) else { return nil }; self = .note(f, n)
        default: return nil
        }
    }
}
