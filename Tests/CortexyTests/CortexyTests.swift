import AppKit
import Foundation
import SwiftUI
import Carbon
import Testing
@testable import Cortexy

@Test func tasksToggleAndConvert() {
    #expect(MD.toggleTask("- [ ] milk") == "- [x] milk")
    #expect(MD.toggleTask("  - [x] milk") == "  - [ ] milk")
    #expect(MD.toggleTask("milk") == "milk")
    #expect(MD.toggleTask(in: "a\n- [ ] b\nc", line: 1) == "a\n- [x] b\nc")
    #expect(MD.toggleChecklist("milk") == "- [ ] milk")
    #expect(MD.toggleChecklist("- milk") == "- [ ] milk")
    #expect(MD.toggleChecklist("- [x] milk") == "milk")
}

@Test func listContinuation() {
    #expect(MD.listMarker("- [x] done") == "- [x] ")
    #expect(MD.nextMarker("- [x] ") == "- [ ] ")
    #expect(MD.nextMarker("  9. ") == "  10. ")
    #expect(MD.nextMarker("* ") == "* ")
    #expect(MD.listMarker("plain") == nil)
}

@Test func headingsCycle() {
    #expect(MD.cycleHeading("Title") == "# Title")
    #expect(MD.cycleHeading("## Title") == "### Title")
    #expect(MD.cycleHeading("### Title") == "Title")
}

@Test func parsingLinesAndTitle() {
    let lines = MD.lines("# Hi\n- [x] a\n\n```\n# not heading\n```\n> q\n![cat](attachments/c.png)\n[a \\[1\\].pdf](file:///tmp/a%20%281%29.pdf)")
    #expect(lines == [.heading(1, "Hi"), .task(true, "a"), .blank, .fence, .code("# not heading"), .fence, .quote("q"),
                      .image(alt: "cat", path: "attachments/c.png"), .file(name: "a [1].pdf", url: "file:///tmp/a%20%281%29.pdf")])
    #expect(MD.title("\n\n## **Groceries**\nmilk") == "Groceries")
    #expect(MD.title("   ") == "Empty Note")
    #expect(MD.title("# snake_case and 2*3") == "snake_case and 2*3")
    #expect(MD.title("**ตัวหนา** `code` [[แผนงาน]] [[T|ไตรมาส]] [a](https://x.y) ==m==") == "ตัวหนา code แผนงาน ไตรมาส a m")
    #expect(MD.unescape(MD.escape(#"a[b]\c"#)) == #"a[b]\c"#)
}

private struct Item: Pinnable, Equatable {
    let id = UUID()
    let name: String
    var pinned: Bool
}

@Test func dragReorderAcrossPinnedGroups() {
    let a = Item(name: "a", pinned: true), b = Item(name: "b", pinned: false), c = Item(name: "c", pinned: false)
    var xs = [b, a, c] // stored order; shown as a, b, c
    #expect(xs.pinnedFirst.map(\.name) == ["a", "b", "c"])

    xs.move(c.id, onto: b.id) // drag c up over b
    #expect(xs.pinnedFirst.map(\.name) == ["a", "c", "b"])

    xs.move(b.id, onto: a.id) // drag b into the pinned group: it gets pinned
    #expect(xs.pinnedFirst.map(\.name) == ["b", "a", "c"])
    #expect(xs.first { $0.name == "b" }!.pinned)

    xs.move(a.id, onto: c.id) // drag a down out of it: it gets unpinned
    #expect(xs.pinnedFirst.map(\.name) == ["b", "c", "a"])
    #expect(!xs.first { $0.name == "a" }!.pinned)
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test func storeRoundTripsAndToleratesOldFiles() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = Store(directory: dir)
    #expect(a.isFirstRun)
    let fid = a.addFolder("Work")
    let nid = a.addNote(to: fid, text: "- [ ] ship it")!
    a.updateNote(fid, nid) { $0.snippet = true; $0.code = true }
    a.save()

    let b = Store(directory: dir)
    #expect(!b.isFirstRun)
    #expect(b.folders == a.folders)

    // A file from an older version with missing fields must still load.
    try Data(#"[{"name":"Old","notes":[{"text":"hi"}]}]"#.utf8).write(to: b.url)
    let c = Store(directory: dir)
    #expect(c.folder(Folder.rootID) != nil) // home is added to files from before nesting
    #expect(c.subfolders(Folder.rootID).first?.name == "Old")
    #expect(c.subfolders(Folder.rootID).first?.notes.first?.text == "hi")

    // Garbage (say, a file a sync is still writing) is never written over: a copy is kept, the newest backup
    // shows, nothing is saved, and the file loads once it reads again.
    try FileManager.default.createDirectory(at: c.backupsDirectory, withIntermediateDirectories: true)
    try Data(contentsOf: c.url).write(to: c.backupsDirectory.appendingPathComponent("cortexy-2099-01-01.json"))
    try Data("not json".utf8).write(to: c.url)
    let d = Store(directory: dir)
    let parked = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("cortexy-unreadable-") }
    #expect(parked.count == 1 && d.recovering && !d.isFirstRun && !d.dirty)
    #expect(d.subfolders(Folder.rootID).first?.name == "Old")      // from the backup
    #expect(try String(contentsOf: d.url, encoding: .utf8) == "not json") // untouched
    try Data(contentsOf: c.backupsDirectory.appendingPathComponent("cortexy-2099-01-01.json")).write(to: d.url)
    #expect(d.reloadIfChangedExternally() && !d.recovering)

    // No file at all but backups exist (iCloud hasn't downloaded it yet): not a first run, nothing written.
    try FileManager.default.removeItem(at: d.url)
    let e = Store(directory: dir)
    #expect(!e.isFirstRun && e.recovering && !FileManager.default.fileExists(atPath: e.url.path))
}

@Test func externalChangesReloadAndConflictsAreKept() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mine = Store(directory: dir)
    let fid = mine.folders[0].id

    // Another Mac writes the synced file.
    Thread.sleep(forTimeInterval: 1.1) // file dates have 1 s resolution on some volumes
    var theirs = mine.folders
    theirs[0].name = "From iPad"
    try JSONEncoder().encode(theirs).write(to: mine.url)
    #expect(mine.reloadIfChangedExternally())
    #expect(mine.folders[0].name == "From iPad")

    // Both sides change: folder names stay ours, notes merge (newest edit of each wins), theirs is kept as a copy too.
    Thread.sleep(forTimeInterval: 1.1)
    theirs[0].name = "Other Mac"
    var theirNote = Note()
    theirNote.text = "# Written on the other Mac"
    theirs[0].notes.append(theirNote)
    try JSONEncoder().encode(theirs).write(to: mine.url)
    mine.updateFolder(fid) { $0.name = "Mine" } // unsaved edit
    let myNote = mine.addNote(to: fid, text: "# Written here")!
    #expect(mine.reloadIfChangedExternally())
    let onDisk = try JSONDecoder().decode([Folder].self, from: Data(contentsOf: mine.url))
    #expect(onDisk[0].name == "Mine")
    #expect(Set(onDisk[0].notes.map(\.id)).isSuperset(of: [theirNote.id, myNote]))
    let conflicts = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("cortexy-conflict-") }
    #expect(conflicts.count == 1)
}

@Test func attachmentsAndExport() throws {
    let dir = tempDir(), out = tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let s = Store(directory: dir)
    let fid = s.addFolder("Notes")

    let path = try #require(s.addAttachment(Data([1, 2, 3]), ext: "PNG"))
    #expect(path.hasPrefix("attachments/") && path.hasSuffix(".png"))
    #expect(s.resolve(path) == dir.appendingPathComponent(path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path))

    let doc = dir.appendingPathComponent("Report (final).pdf")
    try Data().write(to: doc)
    let link = s.markdown(forFile: doc)
    #expect(MD.lines(link) == [.file(name: "Report (final).pdf", url: doc.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29"))])

    s.addNote(to: fid, text: "# Plan\n![](\(path))")
    s.addNote(to: fid, text: "# Plan") // same title → second file gets a suffix
    let root = try s.exportMarkdown(to: out)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Notes").path).sorted()
    #expect(files.contains("Plan.md") && files.contains("Plan 2.md"))
    let exported = try ["Plan.md", "Plan 2.md"].map { try String(contentsOf: root.appendingPathComponent("Notes/\($0)"), encoding: .utf8) }
    #expect(exported.filter { $0.contains("](../attachments/") }.count == 1)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
}

@Test func foldersNestAndHomeHoldsNotes() throws {
    let dir = tempDir(), out = tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let s = Store(directory: dir)
    #expect(s.note(Folder.rootID, s.folder(Folder.rootID)!.notes[0].id) != nil) // welcome note is on the home screen

    let work = s.addFolder("Work"), proj = s.addFolder("Projects", in: work), home = s.addFolder("Home")
    s.addNote(to: proj, text: "# Plan\n![](attachments/x.png)")
    #expect(s.subfolders(Folder.rootID).map(\.name) == ["Work", "Home"])
    #expect(s.subfolders(work).map(\.id) == [proj])
    #expect(s.path(proj) == "Work › Projects")
    #expect(s.noteCount(work) == 1)

    s.moveFolder(work, into: proj) // into its own subfolder: refused
    s.moveFolder(work, into: work)
    #expect(s.parentID(s.folder(work)!) == Folder.rootID)

    let root = try s.exportMarkdown(to: out)
    let nested = try String(contentsOf: root.appendingPathComponent("Work/Projects/Plan.md"), encoding: .utf8)
    #expect(nested == "# Plan\n![](../../attachments/x.png)")

    s.moveFolder(work, into: home)
    #expect(s.path(proj) == "Home › Work › Projects")
    s.deleteFolder(work) // takes its subfolders along
    #expect(s.folder(proj) == nil && s.folder(home) != nil)
    s.deleteFolder(Folder.rootID)
    #expect(s.folder(Folder.rootID) != nil)
}

@Test func recentlyDeletedRestoresAndPurges() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let work = s.addFolder("Work"), proj = s.addFolder("Projects", in: work)
    let n = s.addNote(to: proj, text: "keep me")!
    let m = s.addNote(to: work, text: "me too")!

    s.trashNote(work, m)
    #expect(s.note(Folder.trashID, m)?.origin == work)
    #expect(!s.liveFolders.flatMap(\.notes).contains { $0.id == m }) // hidden from search and Move to
    s.trashFolder(work) // takes Projects and its note along
    #expect(s.inTrash(proj) && s.subfolders(Folder.rootID).isEmpty)
    #expect(!s.liveFolders.contains { $0.id == proj })

    s.restore(m) // its folder is still deleted, so it comes back at the top level
    #expect(s.note(Folder.rootID, m) != nil)
    s.restore(work)
    #expect(s.note(proj, n) != nil && s.parentID(s.folder(work)!) == Folder.rootID)

    s.trashNote(proj, n)
    s.updateNote(Folder.trashID, n) { $0.deleted = Date().addingTimeInterval(-31 * 86_400) }
    s.purgeTrash(olderThan: 30)
    #expect(s.note(Folder.trashID, n) == nil)
    s.trashFolder(work)
    s.purgeTrash(olderThan: 0) // Empty Recently Deleted
    #expect(s.folder(work) == nil && s.folder(proj) == nil && s.folder(Folder.trashID) != nil)
}

@Test func notesSortWithinPinnedGroups() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let f = s.addFolder("F")
    let b = s.addNote(to: f, text: "banana")!, a = s.addNote(to: f, text: "apple")!, c = s.addNote(to: f, text: "cherry")!
    s.updateNote(f, b) { $0.modified = Date().addingTimeInterval(60); $0.created = Date().addingTimeInterval(-60) }
    s.updateNote(f, c) { $0.pinned = true }
    func order(_ sort: Folder.Sort) -> [UUID] { s.updateFolder(f) { $0.sort = sort }; return s.folder(f)!.shownNotes.map(\.id) }
    #expect(order(.manual) == [c, a, b])  // newest added on top, pinned first
    #expect(order(.title) == [c, a, b])
    #expect(order(.modified) == [c, b, a])
    #expect(order(.created).suffix(1) == [b])
    // Older files have no creation date: it falls back to the edit date.
    let old = try! JSONDecoder().decode(Note.self, from: Data(#"{"text":"x","modified":0}"#.utf8))
    #expect(old.created == old.modified)
}

@Test func dropMarkArchiveAndTree() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    nav.route = .home
    let work = s.addFolder("Work"), proj = s.addFolder("Projects", in: work), home = s.addFolder("Home")
    let a = s.addNote(to: Folder.rootID, text: "a")!, b = s.addNote(to: Folder.rootID, text: "b")!

    // Tree: subfolders show in place only when expanded; breadcrumb runs from the top.
    nav.expanded = []
    #expect(nav.folderRows(Folder.rootID).map(\.folder.id) == [work, home])
    nav.toggleExpanded(work)
    #expect(nav.folderRows(Folder.rootID).map { "\($0.folder.name)\($0.depth)" } == ["Work0", "Projects1", "Home0"])
    #expect(nav.dropIDs.contains(proj))
    #expect(s.chain(proj).map(\.name) == ["Cortexy", "Work", "Projects"])

    // Dropping: a note into a folder; a folder never into its own subfolder; onto Recently Deleted = delete.
    nav.drop(a, into: proj)
    #expect(s.note(proj, a) != nil)
    nav.drop(work, into: proj)
    #expect(s.parentID(s.folder(work)!) == Folder.rootID)
    nav.drop(b, into: Folder.trashID)
    #expect(s.note(Folder.trashID, b) != nil)
    nav.undoLast()
    #expect(s.note(Folder.rootID, b) != nil)

    // Marked rows act together; a marked folder takes its contents, and one Undo brings everything back.
    nav.marked = [b, work, proj]
    nav.deleteMarked()
    #expect(s.inTrash(work) && s.note(Folder.trashID, b) != nil && nav.marked.isEmpty)
    nav.undoLast()
    #expect(!s.inTrash(work) && s.note(proj, a) != nil && s.note(Folder.rootID, b) != nil)
    nav.marked = [b, home]
    nav.moveMarked(to: work)
    #expect(s.note(work, b) != nil && s.parentID(s.folder(home)!) == work)

    // Archive: out of the folder and search, listed under Archive; deleted, it leaves Archive but keeps the flag for Restore.
    nav.archive(work, b, true)
    #expect(!s.folder(work)!.shownNotes.contains { $0.id == b } && nav.archivedNotes.map(\.1.id) == [b])
    nav.search = "b"
    #expect(!nav.searchHits.contains { $0.1.id == b })
    nav.search = ""
    s.trashNote(work, b)
    #expect(s.note(Folder.trashID, b)?.archived == true && nav.archivedNotes.isEmpty)

    // Duplicate lands right below the original.
    let copy = s.duplicateNote(proj, a)!
    #expect(s.folder(proj)!.notes.map(\.id) == [a, copy] && s.note(proj, copy)?.text == "a")
    #expect(MD.headings("# One\ntext\n## **Two**\n```\n# not\n```").map { "\($0.line)\($0.level)\($0.title)" } == ["01One", "22Two"])
}

@Test func tagsLinksAndQueries() {
    let text = "# Heading\nBuy #milk and #นม·ไทย (#work/q3) #ff8800 #123 #decade\nsee [[Plan]] and [[Road map|the map]]\n`#nottag [[nolink]]`\n```\n#code [[x]]\n```"
    #expect(MD.tags(text) == ["milk", "นม", "work/q3"])
    #expect(MD.wikiLinks(text) == ["Plan", "Road map"])
    #expect(MD.linkify("go [[A b|see]] #t `#x`") == "go [see](cortexy://open?title=A%20b) [#t](cortexy://tag/t) `#x`")
    #expect(MD.fuzzy("pln", "Plan")! < MD.fuzzy("pla", "Plan")!)
    #expect(MD.fuzzy("xyz", "Plan") == nil)

    let q = Query(#"milk "oat milk" -soy #shop tag:Home path:Work is:todo"#)
    #expect(q.words == ["milk", "oat milk"] && q.excluded == ["soy"] && q.tags == ["shop", "home"] && q.paths == ["Work"] && q.flags == ["todo"])
    var n = Note()
    n.text = "oat milk #shop #home/kitchen\n- [ ] buy"
    #expect(q.matches(n, path: "Work › Errands"))
    #expect(!q.matches(n, path: "Home"))       // wrong folder
    n.text += " soy"
    #expect(!q.matches(n, path: "Work"))       // excluded word
    n.text = "oat milk #shop #home\n- [x] buy"
    #expect(!q.matches(n, path: "Work"))       // nothing left to do
    n.archived = true
    #expect(!Query("milk").matches(n, path: "") && Query("milk is:archived").matches(n, path: ""))
}

@Test func searchSmartFoldersLinksAndPalette() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    let work = s.addFolder("Work"), home = s.addFolder("Home")
    let plan = s.addNote(to: work, text: "# Plan\nmilk #shop")!
    let list = s.addNote(to: home, text: "# Groceries\nmilk #shop\nsee [[plan]]")!

    // Search everywhere, or only in the open folder.
    nav.route = .folder(work)
    nav.search = "milk"
    #expect(Set(nav.searchHits.map(\.1.id)) == [plan, list])
    nav.searchInFolder = true
    #expect(nav.searchHits.map(\.1.id) == [plan])
    nav.searchInFolder = false

    // A saved search becomes a smart folder: it lists matches, holds no notes, and takes no drops.
    nav.search = "#shop"
    nav.saveSearch()
    guard case .folder(let smart) = nav.route else { Issue.record("no smart folder"); return }
    #expect(s.folder(smart)?.query == "#shop" && nav.search.isEmpty)
    nav.route = .folder(work)
    nav.searchInFolder = true
    nav.search = "milk"
    nav.saveSearch()
    if case .folder(let scoped) = nav.route { #expect(Set(nav.hits(Query(s.folder(scoped)!.query!)).map(\.1.id)) == [plan]) }
    nav.searchInFolder = false
    nav.route = .folder(smart)
    #expect(Set(nav.visibleIDs) == [plan, list])
    #expect(!s.moveTargets.contains { $0.id == smart })
    nav.newNote(text: "x")
    #expect(s.folder(smart)!.notes.isEmpty && s.folder(work)!.notes.count == 2) // went next to the smart folder

    // [[links]]: the open folder's note wins; a missing one is created; tags search.
    #expect(nav.resolve(title: "PLAN")?.1.id == plan)
    #expect(nav.backlinks(to: "Plan", excluding: plan).map(\.1.id) == [list])
    #expect(nav.suggestions(.link, "gro", excluding: plan) == ["Groceries"])
    #expect(nav.suggestions(.tag, "sh") == ["shop"])
    nav.openLink(Link.note("Brand New"))
    guard case .note(let nf, let nn) = nav.route else { Issue.record("not opened"); return }
    #expect(s.note(nf, nn)?.text == "# Brand New\n")
    nav.route = .home                                     // left untouched: the stub goes
    #expect(s.folderOf(nn) == nil)
    nav.openLink(Link.note("Brand New"))
    guard case .note(let nf2, let nn2) = nav.route else { Issue.record("not opened"); return }
    s.updateNote(nf2, nn2) { $0.text += "kept" }
    nav.route = .folder(nf2)                              // written in: it stays
    #expect(s.note(nf2, nn2) != nil)
    nav.openLink(Link.tag("shop"))
    #expect(nav.search == "#shop" && nav.route == .folder(nf2))
    nav.search = ""

    // Renaming a note (its first line) updates [[links]] to it when you leave it; Undo puts them back.
    nav.route = .note(work, plan)
    s.updateNote(work, plan) { $0.text = "# Master Plan\nmilk" }
    nav.route = .folder(work)
    #expect(s.note(home, list)!.text.hasSuffix("see [[Master Plan]]"))
    nav.undoLast()
    #expect(s.note(home, list)!.text.hasSuffix("see [[plan]]"))

    // Palette: fuzzy note titles; ">" switches to commands.
    nav.palette = .open
    nav.paletteQuery = "groc"
    #expect(nav.paletteItems.first?.title == "Groceries")
    nav.runPalette()
    #expect(nav.route == .note(home, list) && nav.palette == nil)
    nav.palette = .open
    nav.paletteQuery = "> go home"
    #expect(nav.paletteItems.first?.title == "Go Home")
}

@Test func backFromBuiltInPagesGoesHome() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nav = Nav(store: Store(directory: dir))
    nav.route = .folder(Folder.trashID)
    nav.back()
    #expect(nav.route == .home)
    nav.route = .archive
    nav.back()
    #expect(nav.route == .home)
}

/// Previews hide all markup, even where the caret would be; the editor shows it on the caret's line.
@MainActor @Test func previewHidesAllMarkup() {
    let h = EditorHarness(dir: tempDir())
    func hidden(_ previewing: Bool) -> Bool {
        h.tv.previewing = previewing
        h.tv.load("**bold**")
        h.tv.setSelectedRange(NSRange(location: 3, length: 0))
        h.tv.restyle(force: true)
        return (h.tv.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)!.pointSize < 1
    }
    #expect(hidden(true))
    #expect(!hidden(false))
}

/// The preview's folder pages list subfolders, then notes; clicking a subfolder goes a level deeper along the
/// path, a crumb goes back up, and a note row opens the note in the panel.
@MainActor @Test func previewBrowsesFoldersAlongAPath() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    let p = PreviewController(nav: nav)
    let work = s.addFolder("Work"), proj = s.addFolder("Projects", in: work), deep = s.addFolder("Q3", in: proj)
    let plan = s.addNote(to: deep, text: "# Plan\nship it")!
    let memo = s.addNote(to: work, text: "Memo\n\nsecond line")!
    let smart = s.addFolder("Todo", in: work)
    s.updateFolder(smart) { $0.query = "ship" }

    #expect(p.rows(.folder(work)).map(\.title) == ["Projects", "Todo", "Memo"])
    #expect(p.rows(.folder(work)).last?.detail == "second line")
    #expect(p.rows(.folder(smart)).map(\.id) == [plan.uuidString]) // a smart folder lists its matches
    // Upcoming lists each dated task (two in one note are two rows); resting on one previews its note.
    let due = s.addNote(to: work, text: "# Bills\n- [ ] rent 📅 2099-01-02\n- [ ] water 📅 2099-01-03\n- [x] old 📅 2099-01-01")!
    #expect(p.rows(.upcoming).map(\.title) == ["rent", "water"] && p.rows(.upcoming).allSatisfy { $0.item == .note(due) && !$0.isFolder })
    #expect(Set(p.rows(.upcoming).map(\.id)).count == 2)
    s.deleteNote(work, due)
    p.model.path = [.folder(work)]
    p.push(.folder(proj), after: 0)
    p.push(.folder(deep), after: 1)
    p.push(.note(plan), after: 2)
    #expect(p.model.path == [.folder(work), .folder(proj), .folder(deep), .note(plan)])
    p.push(.note(memo), after: 0)                                   // from a level higher up: the deeper ones go
    #expect(p.model.path == [.folder(work), .note(memo)])
    #expect(p.acceptsFirstClick) // it's never the key window, so a first click that only "focuses" would do nothing

    // However deep it goes, the card shows the last level; the ones above wait in the path bar.
    let d4 = s.addFolder("Week 1", in: deep)
    p.model.path = [.folder(work), .folder(proj), .folder(deep)]
    p.push(.folder(d4), after: 2)
    #expect(p.model.path.last == .folder(d4) && p.model.path.count == 4)
    p.pop(to: 1)                                                    // a crumb: back to Projects
    #expect(p.model.path == [.folder(work), .folder(proj)])
    p.openInPanel(.note(memo))                                      // clicking a note row opens it
    #expect(nav.route == .note(work, memo) && p.model.path.isEmpty)

    // A long note shows its start (opening it shows the rest).
    let long = (1...500).map { "line \($0)" }.joined(separator: "\n")
    #expect(MD.head(long, lines: 200).text.components(separatedBy: "\n").count == 200)
    #expect(!MD.head(long, lines: 200).whole && MD.head("short", lines: 200) == ("short", true) && MD.head("a\n", lines: 1) == ("a", true))
}

/// Tab nests a list item by one clear level; wrapped lines line up with the item's text.
@MainActor @Test func listsIndentByLevels() {
    #expect(MD.indentLevel("- a") == 0 && MD.indentLevel("  - a") == 1 && MD.indentLevel("\t  - a") == 2 && MD.indentLevel("   - a") == 1)
    let h = EditorHarness(dir: tempDir())
    h.tv.load("- one\n- two")
    let w = h.tv.style.indentWidth
    func para(_ i: Int) -> NSParagraphStyle { h.tv.textStorage!.attribute(.paragraphStyle, at: i, effectiveRange: nil) as! NSParagraphStyle }
    #expect(para(6).firstLineHeadIndent == 0 && para(6).headIndent > 0) // hanging indent after the bullet
    h.tv.setSelectedRange(NSRange(location: 8, length: 0))
    h.tv.insertTab(nil)
    #expect(h.tv.markdown() == "- one\n  - two")
    #expect(para(8).firstLineHeadIndent == w)
    h.tv.insertTab(nil)
    #expect(para(8).firstLineHeadIndent == 2 * w)
    #expect(h.tv.textStorage!.attribute(.cxMarker, at: 10, effectiveRange: nil) as? String == "bullet2")
    h.tv.insertBacktab(nil)
    #expect(h.tv.markdown() == "- one\n  - two" && para(8).firstLineHeadIndent == w)
}

/// Settings fall back to their defaults, and changed ones take effect.
@MainActor @Test func settingsApply() {
    let d = UserDefaults.standard
    defer { d.removeObject(forKey: Prefs.codeTab) }
    d.removeObject(forKey: Prefs.codeTab)
    #expect(Prefs.number(Prefs.previewDelay) == 0.45 && Prefs.number(Prefs.trashDays) == 30 && Prefs.number(Prefs.codeTab) == 4)
    d.set(2, forKey: Prefs.codeTab)
    let h = EditorHarness(dir: tempDir())
    h.tv.style.code = true
    h.tv.load("x")
    h.tv.setSelectedRange(NSRange(location: 1, length: 0))
    h.tv.insertTab(nil)
    #expect(h.tv.markdown() == "x  ")
    #expect(TextStyle(size: 10, indentScale: 3).indentWidth == 30)
}

@MainActor @Test func templatesAndDailyNotes() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    let day = ISO8601DateFormatter().date(from: "2026-03-05T09:30:00Z")!
    let (text, caret) = Nav.expand("# {{date}} {{date:yyyy}}\nin {{folder}}: {{cursor}}!", date: day, folder: "Work")
    #expect(text.hasPrefix("# 2026-03-05 2026\nin Work: !") && caret == (text as NSString).range(of: "!").location)

    let templates = s.addFolder("Templates")
    let t = s.addNote(to: templates, text: "# Meeting {{date}}\n- {{cursor}}")!
    nav.route = .folder(templates)
    nav.newNote(from: s.note(templates, t)!)
    #expect(s.folder(templates)!.notes.count == 1)          // not into the Templates folder itself
    #expect(s.folder(Folder.rootID)!.notes.contains { $0.text.hasPrefix("# Meeting ") && $0.text.hasSuffix("- ") })

    nav.openToday()
    let today = Nav.expand("{{date}}").text
    let daily = s.folders.first { $0.name == "Daily" }!
    #expect(daily.notes.map(\.title) == [today])
    nav.route = .home
    nav.openToday()                                         // the same note again, not a second one
    #expect(s.folder(daily.id)!.notes.count == 1 && nav.route == .note(daily.id, daily.notes[0].id))
}

@MainActor @Test func tablesCodeAndFootnotesInTheEditor() {
    let h = EditorHarness(dir: tempDir())
    let text = "| Name | Qty |\n| --- | ---: |\n| Milk | 2 |\n\nafter ==hi== and[^1]\n```swift\nlet x = 1\n```\n[^1]: the note"
    h.tv.load(text)
    h.tv.setSelectedRange(NSRange(location: (text as NSString).range(of: "after").location, length: 0))
    h.tv.restyle(force: true)
    let st = h.tv.textStorage!, ns = text as NSString
    func attr(_ k: NSAttributedString.Key, at needle: String, _ offset: Int = 0) -> Any? { st.attribute(k, at: ns.range(of: needle).location + offset, effectiveRange: nil) }
    #expect(attr(.cxMarker, at: "| ---") as? String != nil)                                   // the rule row draws a line
    #expect((attr(.kern, at: "| Milk") as? CGFloat ?? 0) > 0)                                 // cells padded to their column
    #expect((attr(.font, at: "Name") as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(attr(.backgroundColor, at: "hi") != nil)
    #expect(attr(.link, at: "[^1]", 2) as? URL == Link.footnote("1"))
    #expect(attr(.foregroundColor, at: "let") as? NSColor == Syntax.Kind.keyword.color)

    // Caret in the table: plain monospaced source to edit; Tab walks the cells, then adds a row.
    h.tv.setSelectedRange(NSRange(location: 2, length: 0))
    h.tv.restyle()
    #expect((attr(.font, at: "Milk") as? NSFont)?.isFixedPitch == true)
    h.tv.insertTab(nil)
    #expect(h.tv.selectedRange().location == ns.range(of: "Qty").location)
    h.tv.setSelectedRange(NSRange(location: ns.range(of: "2 |").location, length: 0))
    h.tv.insertTab(nil)
    #expect(h.tv.markdown().hasPrefix("| Name | Qty |\n| --- | ---: |\n| Milk | 2 |\n|  |  |"))
}

/// Restyling only what changed must still match a full restyle around tables and code blocks.
@MainActor @Test func incrementalRestyleHandlesBlocks() {
    let h = EditorHarness(dir: tempDir())
    h.tv.load("| a | b |\n| - | - |\n| x | y |\ntext\n```swift\nlet a = 1 // c\n```\nend")
    func check(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        h.tv.restyle()
        let incremental = NSAttributedString(attributedString: h.tv.textStorage!)
        h.tv.restyle(force: true)
        #expect(incremental.isEqual(to: h.tv.textStorage!), "\(what)", sourceLocation: sourceLocation)
    }
    let ns = { h.tv.string as NSString }
    h.tv.setSelectedRange(NSRange(location: ns().range(of: "text").location, length: 0)); check("caret below the table")
    h.tv.setSelectedRange(NSRange(location: ns().range(of: "x").location, length: 0)); check("caret into the table")
    h.tv.insertText("wide cell", replacementRange: h.tv.selectedRange()); check("a wider cell")
    h.tv.setSelectedRange(NSRange(location: ns().range(of: "end").location, length: 0)); check("caret out again")
    h.tv.setSelectedRange(NSRange(location: ns().range(of: "1 //").location, length: 0))
    h.tv.insertText("/* ", replacementRange: h.tv.selectedRange()); check("an open comment recolors the block")
}

/// Serves a red PNG for any https://cortexy.test/… request, so web images can be tested offline.
private final class StubImages: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cortexy.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let img = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func webImagesArriveAndShowInPlace() async throws {
    URLProtocol.registerClass(StubImages.self)
    defer { URLProtocol.unregisterClass(StubImages.self) }
    let url = URL(string: "https://cortexy.test/\(UUID().uuidString).png")!
    let h = EditorHarness(dir: tempDir())
    let note = UUID()
    h.tv.noteID = note
    h.tv.load("see ![pic](\(url.absoluteString)) here")
    try await Task.sleep(for: .milliseconds(300))
    #expect(!h.tv.string.contains("\u{FFFC}") && WebImages.shared.image(url, note: note) == nil) // not fetched: its note hasn't allowed it
    WebImages.shared.allow(note)                           // the note's Load
    for _ in 0..<50 where WebImages.shared.image(url, note: note) == nil { try await Task.sleep(for: .milliseconds(50)) }
    #expect(WebImages.shared.image(url, note: note) != nil)
    #expect(h.tv.string.contains("\u{FFFC}"))             // arrived: shown as an image
    #expect(h.tv.markdown() == "see ![pic](\(url.absoluteString)) here")
}

/// A note in its own window: one editor per note, the panel stands aside, and an empty note isn't dropped
/// from under its window when the panel leaves it.
@MainActor @Test func noteWindowsKeepOneEditorPerNote() {
    let dir = tempDir()
    let keep = UserDefaults.standard.stringArray(forKey: "noteWindows")
    defer { try? FileManager.default.removeItem(at: dir); UserDefaults.standard.set(keep, forKey: "noteWindows") }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    let n = s.addNote(to: Folder.rootID, text: "")!
    nav.route = .note(Folder.rootID, n)
    NoteWindows.shared.show(n, nav: nav)
    #expect(NoteWindows.shared.isOpen(n))
    nav.route = .home
    #expect(s.note(Folder.rootID, n) != nil)       // still there for the window
    NoteWindows.shared.close(n)
    #expect(!NoteWindows.shared.isOpen(n))
}

/// Images are decoded at the size they're shown: big photos shrink to 1600 px, Retina screenshots keep their
/// point size, and cards get theirs from the background without waiting.
@MainActor @Test func imagesDecodeSmallAndOffTheMainThread() async throws {
    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func png(_ name: String, pixels: Int, points: Int) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels / 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: points, height: points / 2) // sets the DPI written to the file
        let url = dir.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
    let photo = try #require(Attachments.decode(try png("photo.png", pixels: 4000, points: 4000)))
    #expect(photo.size.width == 4000 && photo.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 1600)
    let retina = try #require(Attachments.decode(try png("shot.png", pixels: 400, points: 200)))
    #expect(retina.size == NSSize(width: 200, height: 100))

    let url = try png("card.png", pixels: 300, points: 300)
    #expect(Attachments.imageSoon(at: url) == nil)               // not ready yet: the card shows a placeholder
    for _ in 0..<100 where Attachments.imageSoon(at: url) == nil { try await Task.sleep(for: .milliseconds(50)) } // up to 5 s under load
    #expect(Attachments.imageSoon(at: url)?.size.width == 300)

    #expect(MD.head("a\nb\nc\nd", lines: 2) == ("a\nb", false) && MD.head("a\nb", lines: 5) == ("a\nb", true))
}

@MainActor private func editorIn(_ v: NSView) -> MarkdownTextView? {
    if let t = v as? MarkdownTextView { return t }
    for s in v.subviews { if let t = editorIn(s) { return t } }
    return nil
}

/// Editing an existing note once looked impossible: the first click on a panel opened by the pointer only
/// focused it (the caret stayed at the end, out of sight) and typing landed there. Now the first click counts,
/// the caret is in view on opening, and each note reopens where you left it.
@MainActor @Test func editingStartsWhereYouClickAndYouSeeIt() async throws {
    await PanelGate.enter() // its page transitions and focus are timed: not alongside tests that show the panel
    defer { PanelGate.leave() }
    Prefs.register()
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    let long = s.addNote(to: Folder.rootID, text: (1...80).map { "line \($0)" }.joined(separator: "\n"))!
    let host = NSHostingView(rootView: RootView(nav: nav).frame(width: 360, height: 500))
    host.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
    let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = host
    win.makeKeyAndOrderFront(nil)
    func caretInView(_ tv: MarkdownTextView) -> Bool {
        let g = tv.layoutManager!.glyphIndexForCharacter(at: max(0, tv.selectedRange().location - 1))
        let r = tv.layoutManager!.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tv.textContainer!)
        return tv.visibleRect.intersects(r.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y))
    }
    /// The note's new editor once it's on screen with its caret shown (the old page fades out meanwhile, and a
    /// busy machine can take longer than any fixed wait).
    func open(_ n: UUID) async throws -> MarkdownTextView {
        let before = editorIn(host)
        nav.route = .note(Folder.rootID, n)
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            if let tv = editorIn(host), tv !== before, tv.window != nil, caretInView(tv) { return tv }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(editorIn(host))
    }
    var tv = try await open(long)
    #expect(tv.acceptsFirstMouse(for: nil))
    #expect(caretInView(tv))
    tv.setSelectedRange(NSRange(location: 20, length: 0))
    tv.insertText("x", replacementRange: tv.selectedRange())
    tv.deleteBackward(nil)
    let firstUndo = tv.undoManager
    #expect(firstUndo?.canUndo == true)
    nav.route = .home
    // Until the note's page has faded out: come back within that and SwiftUI revives the same editor (its own history still).
    for _ in 0..<100 where editorIn(host) != nil { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    tv = try await open(long)
    #expect(tv.selectedRange().location == 20 && caretInView(tv))
    for _ in 0..<100 where tv.undoManager === firstUndo || tv.undoManager?.canUndo != false { // the page transition keeps the old editor around for a moment
        try await Task.sleep(for: .milliseconds(50))
        tv = try #require(editorIn(host))
    }
    #expect(tv.undoManager !== firstUndo && tv.undoManager?.canUndo == false) // its own history, not the last note's
    tv.find(.showFindInterface)                    // ⌘F: find in this note
    #expect(tv.findBarShown)
    tv.find(.hideFindInterface)
    #expect(!tv.findBarShown)
}

@MainActor @Test func completionKnowsWhatIsBeingTyped() {
    let h = EditorHarness(dir: tempDir())
    func context(_ text: String) -> String? {
        h.tv.load(text)
        h.tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        guard let (kind, r) = h.tv.completionContext() else { return nil }
        return "\(kind):" + (text as NSString).substring(with: r)
    }
    #expect(context("see [[Pla") == "link:Pla")
    #expect(context("see [[Plan]] and #wo") == "tag:wo")
    #expect(context("ไทย #งาน") == "tag:งาน")
    #expect(context("done [[Plan]]") == nil)
    #expect(context("a#b") == nil)              // not a tag: no space before #
    h.tv.completionSource = { _, _ in ["homework"] }
    h.tv.load("#home")
    h.tv.setSelectedRange(NSRange(location: 5, length: 0))
    var index = 0
    _ = h.tv.completions(forPartialWordRange: NSRange(location: 1, length: 4), indexOfSelectedItem: &index)
    #expect(index == -1)                         // nothing preselected: Return doesn't swap in a guess
    #expect(context("```\n#code") == nil)     // inside a code block
    h.tv.load("#work and [[Plan]]")
    #expect(h.tv.textStorage!.attribute(.link, at: 1, effectiveRange: nil) as? URL == Link.tag("work"))
    #expect(h.tv.textStorage!.attribute(.link, at: 12, effectiveRange: nil) as? URL == Link.note("Plan"))
}

@Test func tablesAndCodeTokens() {
    let lines = ["intro", "| Name | Qty |", "|:---|---:|", "| Milk | 2 |", "| a \\| b |  |", "after", "| not | a table |"]
    #expect(MD.tables(lines) == [1..<5])
    #expect(MD.cells("| Milk | 2 |") == ["Milk", "2"])
    #expect(MD.cells("| a \\| b |  |") == ["a \\| b", ""])   // escaped pipe, empty last cell
    #expect(MD.cells("|x|y") == ["x", "y"])
    #expect(MD.alignments("|:---|:--:|---:|") == [.left, .center, .right])
    #expect(!MD.isTableRule("---"))                              // a horizontal rule, not a table

    func kinds(_ code: String, _ lang: String) -> [String] {
        Syntax.tokens(code, lang: lang).map { "\(String(describing: $0.1)):" + (code as NSString).substring(with: $0.0) }
    }
    #expect(kinds("let x = 42 // hi", "swift") == ["keyword:let", "number:42", "comment:// hi"])
    #expect(kinds("s = \"if\" # c", "py") == ["string:\"if\"", "comment:# c"]) // keywords inside strings stay strings
    #expect(kinds("SELECT name FROM t", "sql") == ["keyword:SELECT", "keyword:FROM"])
    #expect(kinds("/* a\nb */ View", "swift") == ["comment:/* a\nb */", "type:View"])
}

@Test func versionHistoryKeepsAndRestores() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    let n = s.addNote(to: Folder.rootID, text: "first")!
    nav.route = .note(Folder.rootID, n)                       // opening keeps how it was
    s.updateNote(Folder.rootID, n) { $0.text = "second" }
    nav.route = .home                                         // leaving keeps how it is now
    nav.route = .note(Folder.rootID, n)                       // unchanged since: not kept twice
    #expect(s.history(n).map(\.text) == ["first", "second"])

    nav.restoreVersion(n, s.history(n)[0])
    #expect(s.note(Folder.rootID, n)?.text == "first")
    nav.undoLast()
    #expect(s.note(Folder.rootID, n)?.text == "second")

    UserDefaults.standard.set(2, forKey: Prefs.versionsKept)
    defer { UserDefaults.standard.removeObject(forKey: Prefs.versionsKept) }
    s.updateNote(Folder.rootID, n) { $0.text = "third" }
    s.snapshot(n)
    #expect(s.history(n).map(\.text) == ["second", "third"]) // only the newest few

    // A note deleted for good loses its history at the next launch.
    s.deleteNote(Folder.rootID, n)
    s.save()
    let reopened = Store(directory: dir)
    _ = reopened.history(n) // reads on the same queue as its clean-up, so after it
    #expect(!FileManager.default.fileExists(atPath: s.historyDirectory.appendingPathComponent(n.uuidString + ".json").path))
}

@MainActor @Test func dueDatesAndUpcoming() {
    let cal = Calendar.current
    let d = MD.due("- [ ] call 📅 2026-10-05 14:30")!
    #expect(d.hasTime && cal.component(.hour, from: d.date) == 14 && MD.dayString(d.date) == "2026-10-05")
    #expect(MD.due("pay @2026-10-05")?.hasTime == false)
    #expect(MD.due("mail ann@2026-10-05.com") == nil)          // not a date: part of an address

    let now = Date()
    #expect(Due.of(cal.date(byAdding: .day, value: -1, to: now)!, hasTime: false, done: false) == .overdue)
    #expect(Due.of(cal.startOfDay(for: now), hasTime: false, done: false) == .today) // all day: not late until tomorrow
    #expect(Due.of(now.addingTimeInterval(-60), hasTime: true, done: false) == .overdue)
    #expect(Due.of(now.addingTimeInterval(-60), hasTime: true, done: true) == .done)

    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    s.addNote(to: Folder.rootID, text: "# Errands\n- [ ] call bank 📅 2026-10-05 14:30\n- [x] paid @2026-10-01\nplain 📅 2026-10-09")
    #expect(nav.dueTasks.map { "\($0.text)|\($0.done)|\($0.line)" } == ["paid|true|2", "call bank|false|1"])
    let t = nav.dueTasks.first { !$0.done }!
    UserDefaults.standard.removeObject(forKey: Prefs.remindAt)
    #expect(Reminders.fireDate(t) == t.date)                   // a time given: then
    #expect(cal.component(.hour, from: Reminders.fireDate(nav.dueTasks[0])) == 9) // just a day: at 9 by default

    let h = EditorHarness(dir: tempDir())
    h.tv.load("buy milk")
    h.tv.setSelectedRange(NSRange(location: 3, length: 0))
    h.tv.cxDue(nil)
    let tomorrow = MD.dayString(cal.date(byAdding: .day, value: 1, to: now)!)
    #expect(h.tv.markdown() == "- [ ] buy milk 📅 " + tomorrow)
    #expect((h.tv.string as NSString).substring(with: h.tv.selectedRange()) == tomorrow) // ready to type over
}

@Test func lockedNotesNeverWritePlaintext() throws {
    Nav.passwordAnswer = .some(nil) // never a real password prompt or alert (a test would wait on it forever)
    defer { Nav.passwordAnswer = nil }
    let salt = NoteLock.newSalt()
    let box = try #require(NoteLock.seal("secret", key: NoteLock.key("pw", salt: salt), salt: salt))
    #expect(NoteLock.open(box, key: NoteLock.key("pw", salt: NoteLock.salt(box)!)) == "secret")
    #expect(NoteLock.open(box, key: NoteLock.key("nope", salt: salt)) == nil)

    let dir = tempDir(), out = tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let s = Store(directory: dir)
    let nav = Nav(store: s)
    let pic = s.addAttachment(Data("SECRET-PIXELS".utf8), ext: "png")!
    let n = s.addNote(to: Folder.rootID, text: "# Bank\nPIN 4321\n![](\(pic))")!
    s.snapshot(n)
    s.save()
    // An older backup with the note still readable in it.
    try FileManager.default.createDirectory(at: s.backupsDirectory, withIntermediateDirectories: true)
    let backup = s.backupsDirectory.appendingPathComponent("cortexy-2026-01-01.json")
    try FileManager.default.copyItem(at: s.url, to: backup)

    nav.password = "pw" // as if just typed
    nav.lockNote(Folder.rootID, n)
    _ = s.history(n) // after the queued clean-ups
    s.save()
    let locked = s.note(Folder.rootID, n)!
    #expect(locked.text.isEmpty && locked.lock != nil && locked.title == "Bank" && !locked.isBlank)
    #expect(!(try String(contentsOf: s.url, encoding: .utf8)).contains("4321"))
    #expect(!(try String(contentsOf: backup, encoding: .utf8)).contains("4321"))
    #expect(s.history(n).isEmpty)
    // Its attachment is sealed too: only ciphertext in attachments/, the plain copy only while unlocked, in temp.
    let plain = s.directory.appendingPathComponent(pic), sealed = plain.appendingPathExtension("locked")
    #expect(!FileManager.default.fileExists(atPath: plain.path))
    #expect(!(try Data(contentsOf: sealed)).contains(Data("SECRET-PIXELS".utf8)))
    #expect(try Data(contentsOf: s.resolve(pic)!) == Data("SECRET-PIXELS".utf8))

    // Edits while unlocked are sealed at once; search, export and "empty note" clean-up never see the text.
    nav.updateLocked(n, "# Bank\nPIN 9999\n![](\(pic))")
    s.save()
    #expect(!(try String(contentsOf: s.url, encoding: .utf8)).contains("9999"))
    nav.search = "9999"
    #expect(nav.searchHits.isEmpty)
    nav.search = ""
    #expect(!s.note(Folder.rootID, n)!.isBlank) // its text is sealed, not empty: leaving it never drops it
    let exported = try s.exportMarkdown(to: out)
    #expect(!(try String(contentsOf: exported.appendingPathComponent("Bank.md"), encoding: .utf8)).contains("9999"))

    nav.lockAll()
    #expect(nav.unlocked.isEmpty && nav.password == nil)
    #expect(!FileManager.default.fileExists(atPath: Store.unlockedAttachments.path))
    nav.password = "wrong"
    nav.unlock(n)
    #expect(nav.unlocked[n] == nil && nav.password == nil) // forgotten: the next try asks again
    #expect(Query("Bank").matches(s.note(Folder.rootID, n)!, path: ""))  // found by its visible title
    nav.copy(s.note(Folder.rootID, n)!)
    #expect(nav.toast == "Unlock the note to copy it")
    nav.password = "pw"
    nav.unlock(n)
    #expect(nav.unlocked[n] == "# Bank\nPIN 9999\n![](\(pic))")
    #expect(try Data(contentsOf: s.resolve(pic)!) == Data("SECRET-PIXELS".utf8)) // opened again

    // Another Mac re-locks it with a new salt while it's open here: edits still seal so the password opens them.
    s.updateNote(Folder.rootID, n) { $0.lock = NoteLock.seal("other", key: NoteLock.key("pw", salt: NoteLock.newSalt()), salt: NoteLock.newSalt()) }
    nav.updateLocked(n, "# Bank\nPIN 9999\n![](\(pic))")
    let resealed = s.note(Folder.rootID, n)!.lock!
    #expect(NoteLock.open(resealed, key: NoteLock.key("pw", salt: NoteLock.salt(resealed)!)) == "# Bank\nPIN 9999\n![](\(pic))")

    // Removing the lock gives the note its text back, and forgets the key.
    nav.removeLock(Folder.rootID, n)
    let open = s.note(Folder.rootID, n)!
    #expect(try Data(contentsOf: plain) == Data("SECRET-PIXELS".utf8) && !FileManager.default.fileExists(atPath: sealed.path))
    #expect(open.text == "# Bank\nPIN 9999\n![](\(pic))" && open.lock == nil && open.lockedTitle == nil && open.title == "Bank")
    #expect(nav.unlocked[n] == nil && nav.keys[n] == nil)
}

@Test func routesSurviveRelaunch() {
    let f = UUID(), n = UUID()
    for r in [Nav.Route.home, .folder(f), .note(f, n), .archive, .upcoming] {
        #expect(Nav.Route(encoded: r.encoded) == r)
    }
    #expect(Nav.Route(encoded: "note:garbage") == nil)
}

@Test func hotKeySpecsRoundTrip() {
    let s = HotKeySpec(keyCode: 45, modifiers: 6144, display: "⌃⌥N")
    #expect(HotKeySpec(encoded: s.encoded) == s)
    #expect(HotKeySpec(encoded: "") == nil)
    let optionOnly = HotKeySpec(keyCode: 45, modifiers: UInt32(optionKey), display: "⌥N")
    let copy = HotKeySpec(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), display: "⌘C")
    #expect(HotKeys.problem(optionOnly, others: []) != nil && HotKeys.problem(copy, others: []) != nil)
    #expect(HotKeys.problem(s, others: [s]) != nil && HotKeys.problem(s, others: []) == nil)
}

@Test func themesDecodeWithMissingFields() throws {
    let t = try JSONDecoder().decode(Theme.self, from: Data(#"{"id":"x","name":"Mine"}"#.utf8))
    #expect(t.fontSize == 14 && t.isCustom && t.design == .standard)
    #expect(Set(Theme.builtIn.map(\.id)).count == Theme.builtIn.count) // no duplicate ids
    #expect(Theme.builtIn.count >= 40)
    #expect(NSColor(hex: "3B82F6")?.hex == "3B82F6")
}

@Test func lookToleratesMissingFieldsAndResolvesFonts() throws {
    // Saved settings survive fields being added later; unknown or missing ones fall back to defaults.
    let look = try #require(Look.decode(Data(#"{"fontSize":18,"density":"roomy","future":1}"#.utf8)))
    #expect(look.fontSize == 18 && look.density == .roomy && look.cardLines == 14 && look.useThemeFont)
    #expect(Look.decode(nil) == nil)

    let helvetica = TextStyle(size: 15, family: "Helvetica")
    #expect(helvetica.body.familyName == "Helvetica" && helvetica.body.pointSize == 15)
    #expect(helvetica.font(weight: .bold).fontDescriptor.symbolicTraits.contains(.bold))
    var code = helvetica
    code.code = true // code mode wins over the family
    #expect(code.body.isFixedPitch)
    #expect(TextStyle(family: "No Such Font").body.familyName != nil) // missing family: system font, no crash
    #expect(TextStyle(size: 14, headingScale: 0.5).headingSize(1) == 18)
}

// MARK: Regression tests from code review

/// A text view wired like the real editor, with images resolved from `dir` and a working undo manager.
@MainActor private final class EditorHarness: NSObject, NSTextViewDelegate {
    let tv = MarkdownTextView(usingTextLayoutManager: false)
    let undo = UndoManager()
    init(dir: URL) {
        super.init()
        tv.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.delegate = self
        tv.resolve = { $0.hasPrefix("attachments/") ? dir.appendingPathComponent($0) : URL(string: $0) }
    }
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
    func textDidChange(_ n: Notification) { tv.convertTypedAttachments() } // as the real Coordinator does
}

private func pngFile(in dir: URL) throws -> String {
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
    let img = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
    let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try png.write(to: dir.appendingPathComponent("attachments/x.png"))
    return "attachments/x.png"
}

@MainActor @Test func editorKeepsAttachmentsThroughFormatting() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = try pngFile(in: dir)
    let h = EditorHarness(dir: dir)
    let md = "- see ![](\(path)) here"
    h.tv.load(md)
    #expect(h.tv.string.contains("\u{FFFC}"))           // shown as an attachment
    #expect(h.tv.markdown() == md)                      // and saved back unchanged

    h.tv.setSelectedRange(NSRange(location: 3, length: 0))
    h.tv.insertTab(nil)                                 // indent the list item
    #expect(h.tv.markdown() == "  " + md)
    h.tv.cxTask(nil)                                    // bullet → task
    #expect(h.tv.markdown() == "  - [ ] see ![](\(path)) here")
    h.tv.setSelectedRange(NSRange(location: 0, length: (h.tv.string as NSString).length))
    h.tv.cxBold(nil)
    #expect(h.tv.markdown().contains("![](\(path))"))
}

@MainActor @Test func undoAfterInsertingAnImageDoesNotCrash() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = try pngFile(in: dir)
    let h = EditorHarness(dir: dir)
    h.tv.load("abc")
    h.tv.setSelectedRange(NSRange(location: 3, length: 0))
    h.undo.beginUndoGrouping()
    h.tv.insertBlock("![](\(path))")
    h.undo.endUndoGrouping()
    #expect(h.tv.string.contains("\u{FFFC}"))
    #expect(h.tv.selectedRange().location == (h.tv.string as NSString).length) // caret right after the image
    h.undo.undo()
    #expect(h.tv.markdown() == "abc")
}

@MainActor @Test func draggingASelectionCarriesMarkdown() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = try pngFile(in: dir)
    let h = EditorHarness(dir: dir)
    h.tv.load("x ![](\(path)) y")
    h.tv.setSelectedRange(NSRange(location: 0, length: (h.tv.string as NSString).length))
    let pb = NSPasteboard(name: NSPasteboard.Name("cortexy-test-\(UUID())"))
    pb.clearContents()
    #expect(h.tv.writeSelection(to: pb, type: .string))
    #expect(pb.string(forType: .string) == "x ![](\(path)) y")
}

@Test func savingNeverOverwritesAnotherMacsEdit() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mine = Store(directory: dir)
    #expect(!mine.dirty)

    // Their edit lands; we have nothing new, so saving (e.g. hiding the panel) must leave it alone.
    Thread.sleep(forTimeInterval: 1.1)
    var theirs = mine.folders
    theirs[0].name = "Theirs"
    try JSONEncoder().encode(theirs).write(to: mine.url)
    mine.save()
    #expect(try JSONDecoder().decode([Folder].self, from: Data(contentsOf: mine.url))[0].name == "Theirs")

    // We edit before the poll picks theirs up: ours is written, theirs is kept as a conflict copy.
    mine.updateFolder(mine.folders[0].id) { $0.name = "Mine" }
    mine.save()
    #expect(try JSONDecoder().decode([Folder].self, from: Data(contentsOf: mine.url))[0].name == "Mine")
    let conflicts = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("cortexy-conflict-") }
    #expect(conflicts.count == 1)

    // Reopening only reads.
    #expect(!Store(directory: dir).dirty)
}

@Test func exportKeepsSameNamedFoldersAndNotesApart() throws {
    let dir = tempDir(), out = tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let s = Store(directory: dir)
    let a = s.addFolder("Work"), b = s.addFolder("work")
    s.addNote(to: a, text: "Todo")
    s.addNote(to: a, text: "todo")
    s.addNote(to: b, text: "Todo")
    let root = try s.exportMarkdown(to: out)
    let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.lowercased().hasPrefix("work") }
    #expect(dirs.count == 2)
    let notes = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Work").path)
    #expect(notes.count == 2)
}

/// Restyling only what changed must look exactly like restyling everything.
@MainActor @Test func incrementalRestyleMatchesFullRestyle() {
    let h = EditorHarness(dir: tempDir())
    h.tv.load("# Title\n- [ ] task **bold**\nplain `code` #ff8800\n```\nlet x = 1 // *not italic*\n```\n> quote\nend")
    func check(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        h.tv.restyle()
        let incremental = NSAttributedString(attributedString: h.tv.textStorage!)
        h.tv.restyle(force: true)
        #expect(incremental.isEqual(to: h.tv.textStorage!), "\(what)", sourceLocation: sourceLocation)
    }
    func type(_ s: String, at i: Int) {
        h.tv.setSelectedRange(NSRange(location: i, length: 0))
        h.tv.insertText(s, replacementRange: h.tv.selectedRange())
    }
    let ns = { h.tv.string as NSString }
    h.tv.setSelectedRange(NSRange(location: 3, length: 0)); check("caret into the heading")
    type("x", at: ns().range(of: "task").location); check("typing in a task")
    type("**", at: ns().range(of: "plain").location); check("half a bold marker")
    h.tv.setSelectedRange(NSRange(location: ns().length, length: 0)); check("caret to the end")
    type("```\n", at: ns().range(of: "> quote").location); check("opening a fence shifts everything below")
    h.tv.setSelectedRange(NSRange(location: ns().range(of: "```\n> quote").location, length: 4))
    h.tv.insertText("", replacementRange: h.tv.selectedRange()); check("deleting it again")
    type("\nnew line", at: ns().range(of: "let x").location); check("new line inside code")
    h.tv.setSelectedRange(NSRange(location: 0, length: 0)); check("caret back to the top")
}

@MainActor @Test func formattingShortcutsToggle() {
    let h = EditorHarness(dir: tempDir())
    h.tv.load("a ")
    h.tv.setSelectedRange(NSRange(location: 2, length: 0))
    h.tv.cxBold(nil)                               // "a **|**"
    #expect(h.tv.markdown() == "a ****")
    h.tv.cxBold(nil)                               // pressing again undoes the empty pair
    #expect(h.tv.markdown() == "a ")
    h.tv.cxBold(nil)
    h.tv.insertText("bold", replacementRange: h.tv.selectedRange())
    h.tv.cxBold(nil)                               // steps out: "a **bold**|"
    h.tv.insertText("!", replacementRange: h.tv.selectedRange())
    #expect(h.tv.markdown() == "a **bold**!")
    h.tv.setSelectedRange(NSRange(location: 4, length: 4)) // select "bold"
    h.tv.cxBold(nil)                               // unwraps a selection that is already bold
    #expect(h.tv.markdown() == "a bold!")
    h.tv.load("**คำ**")
    h.tv.setSelectedRange(NSRange(location: 2, length: 2))
    h.tv.cxItalic(nil)                             // bold and italic, not italic instead
    #expect(h.tv.markdown() == "***คำ***")
    h.tv.cxItalic(nil)
    #expect(h.tv.markdown() == "**คำ**")
    h.tv.load("word and more")
    h.tv.setSelectedRange(NSRange(location: 0, length: 5)) // "word " with its space
    h.tv.cxBold(nil)
    #expect(h.tv.markdown() == "**word** and more")
}

@MainActor @Test func graphLinksTagsAndNeighborhood() {
    let s = Store(directory: tempDir())
    let seeded = s.liveFolders.flatMap(\.notes).count // the welcome note
    let work = s.addFolder("Work")
    let a = s.addNote(to: Folder.rootID, text: "# A\nsee [[b]] and [[Missing]] #plan")!
    let b = s.addNote(to: work, text: "# B\nback to [[A]] #plan")!
    let c = s.addNote(to: work, text: "# C\nonly [[B]]")!
    let d = s.addNote(to: work, text: "# D\nnext to [[C]]")!
    _ = s.addNote(to: work, text: "# Alone\nno links")!
    let g = GraphModel()
    func ids() -> Set<String> { Set(g.nodes.map(\.id)) }

    g.rebuild(s, tags: false, unlinked: true, around: nil)
    #expect(g.nodes.count == 5 + seeded)
    #expect(g.edges.count == 3) // A–B once (both ways), B–C, C–D; [[Missing]] goes nowhere
    g.rebuild(s, tags: false, unlinked: false, around: nil)
    #expect(!g.nodes.contains { $0.title == "Alone" })
    g.rebuild(s, tags: true, unlinked: false, around: nil)
    #expect(ids().contains("#plan"))
    #expect(g.edges.count == 5)
    // Two links out from A: B and C, not D.
    g.rebuild(s, tags: false, unlinked: true, around: a)
    #expect(ids() == Set([a, b, c].map(\.uuidString)))
    _ = d

    // It comes to rest, nothing overlaps, and a click finds the node under it.
    g.rebuild(s, tags: true, unlinked: true, around: nil)
    g.run(3000)
    #expect(g.settled)
    for i in g.nodes.indices { for j in g.nodes.indices where j > i {
        #expect(hypot(g.nodes[i].p.x - g.nodes[j].p.x, g.nodes[i].p.y - g.nodes[j].p.y) > 15)
    } }
    let first = g.nodes[0]
    #expect(g.node(at: CGPoint(x: first.p.x + 2, y: first.p.y), scale: 1) == 0)
    #expect(g.node(at: CGPoint(x: 1e5, y: 1e5), scale: 1) == nil)
    // Rebuilding after an edit keeps everyone where they were.
    let before = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.p) })
    s.updateNote(work, c) { $0.text += " more" }
    g.rebuild(s, tags: true, unlinked: true, around: nil)
    #expect(g.nodes.allSatisfy { before[$0.id] == $0.p })
    #expect(g.settled) // typing that changes no link doesn't set it moving
    s.updateNote(work, c) { $0.text += " [[D]] [[A]]" }
    g.rebuild(s, tags: true, unlinked: true, around: nil)
    #expect(!g.settled)
}

/// Deleting for good only ever happens to what's already in Recently Deleted, and only when asked.
@Test func nothingIsLostForGoodByAccident() {
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    // A search from Recently Deleted lists live notes too: deleting marked hits sends live ones to the trash.
    let live = s.addNote(to: Folder.rootID, text: "# Budget\n2026")!
    let old = s.addNote(to: Folder.rootID, text: "# Old budget")!
    s.trashNote(Folder.rootID, old)
    nav.route = .folder(Folder.trashID)
    nav.search = "budget"
    nav.marked = [live]
    #expect(!nav.markedInTrash)
    nav.deleteMarked()
    #expect(nav.pendingDelete == nil && s.folderOf(live).map { s.inTrash($0.id) } == true)
    nav.marked = [old]
    #expect(nav.markedInTrash)
    nav.deleteMarked()
    #expect(nav.pendingDelete != nil) // asks first
    nav.pendingDelete = nil
    nav.search = ""

    // A note emptied with ⌘A ⌫ and left goes to Recently Deleted with its text, and Undo brings it back.
    let n = s.addNote(to: Folder.rootID, text: "# Plan\nkeep this")!
    nav.route = .note(Folder.rootID, n)
    s.updateNote(Folder.rootID, n) { $0.text = "" }
    nav.route = .home
    #expect(s.note(Folder.trashID, n)?.text == "# Plan\nkeep this")
    nav.undoLast()
    #expect(s.note(Folder.rootID, n)?.text == "# Plan\nkeep this")
    // Undo after deleting an archived, pinned note puts it back as it was.
    let kept = s.addNote(to: Folder.rootID, text: "# Kept")!
    s.updateNote(Folder.rootID, kept) { $0.archived = true; $0.pinned = true }
    nav.requestDelete(.note(Folder.rootID, s.note(Folder.rootID, kept)!))
    #expect(s.folder(Folder.trashID)!.shownNotes.contains { $0.id == kept })
    nav.undoLast()
    #expect(s.note(Folder.rootID, kept).map { $0.archived && $0.pinned } == true)
    // One that never had text still just goes.
    let blank = s.addNote(to: Folder.rootID, text: "")!
    nav.route = .note(Folder.rootID, blank)
    nav.route = .home
    #expect(s.folderOf(blank) == nil)
}

@Test func mergingKeepsTheNewestEditOfEachNote() {
    let a = Folder(name: "A"), b = Folder(name: "B")
    var n = Note()
    n.text = "old"; n.modified = Date(timeIntervalSince1970: 100)
    var ours = [a, b]
    ours[0].notes = [n]
    var theirs = ours
    theirs[0].notes = []
    var newer = n
    newer.text = "new"; newer.modified = Date(timeIntervalSince1970: 200)
    theirs[1].notes = [newer]                         // edited and moved to b on the other Mac
    var m = Store.merge(ours, theirs)
    #expect(m[0].notes.isEmpty && m[1].notes.map(\.text) == ["new"])
    ours[0].notes[0].modified = Date(timeIntervalSince1970: 300) // ours is newer: it stays
    m = Store.merge(ours, theirs)
    #expect(m[0].notes.map(\.text) == ["old"] && m[1].notes.isEmpty)
}

@Test func exportNamesStayInsideTheExportFolder() {
    #expect(Store.fileName("..") == "Untitled" && Store.fileName(".") == "Untitled" && Store.fileName(".hidden") == "hidden")
    #expect(Store.fileName("a/b") == "a-b" && Store.fileName("บันทึก: วันนี้") == "บันทึก- วันนี้")
}

@Test func changingTheDataFolderTakesEverything() throws {
    let s = Store(directory: tempDir())
    let n = s.addNote(to: Folder.rootID, text: "# Plan\nv1")!
    _ = s.addAttachment(Data("img".utf8), ext: "png")
    s.snapshot(n)
    s.save()
    let target = tempDir()
    try FileManager.default.createDirectory(at: target.appendingPathComponent("attachments"), withIntermediateDirectories: true) // already there
    try s.copyLibrary(to: target)
    let t = Store(directory: target)
    #expect(t.note(Folder.rootID, n)?.text == "# Plan\nv1" && t.history(n).count == 1)
    #expect((try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("attachments").path)).count == 1)
}

/// Thai is matched as it's typed: a consonant before its vowel or tone mark still matches, and the marks that
/// change a word's meaning aren't ignored.
@Test func thaiMatchesWhileTypingAndKeepsItsMarks() {
    for (q, t) in [("บ", "บันทึก"), ("สว", "สวัสดี"), ("ประช", "บันทึกประชุม"), ("ปชม", "ประชุม"), ("นำ", "น้ำมัน"), ("ไม", "ไม่ใช่"), ("meet", "Meeting ทีม")] {
        #expect(MD.fuzzy(q, t) != nil, "\(q) ~ \(t)")
    }
    #expect(MD.fuzzy("ประชุม", "ประชุมทีม")! > MD.fuzzy("ประชุม", "บันทึกประชุม")!) // a prefix ranks first
    var n = Note()
    n.text = "ข่าวเช้า เสือ ใช้งาน Café"
    #expect(!Query("ข้าว").matches(n, path: "") && !Query("เสื้อ").matches(n, path: ""))
    #expect(Query("ข่าว").matches(n, path: "") && Query("ใช").matches(n, path: "") && Query("cafe").matches(n, path: ""))
    n.text = "งาน ขาวสะอาด"
    #expect(Query("งาน -ข่าว").matches(n, path: ""))
}

/// Table padding sits on the space after a cell's text, so Thai ending in ำ (and emoji) keep their shape.
@MainActor @Test func tablePaddingNeverSplitsThai() {
    let h = EditorHarness(dir: tempDir())
    h.tv.load("| งาน | สถานะ |\n|--|--|\n| ทำ | 👍 |\n\nafter")
    h.tv.setSelectedRange(NSRange(location: (h.tv.string as NSString).length, length: 0)) // caret out of the table
    let ns = h.tv.string as NSString
    let am = ns.range(of: "ทำ").location + 1, thumb = ns.range(of: "👍")
    #expect(h.tv.textStorage!.attribute(.kern, at: am, effectiveRange: nil) == nil)
    #expect(h.tv.textStorage!.attribute(.kern, at: NSMaxRange(thumb) - 1, effectiveRange: nil) == nil)
    #expect(h.tv.textStorage!.attribute(.kern, at: am + 1, effectiveRange: nil) != nil) // on the space after it
}

/// Italic works inside a Thai sentence (no spaces), and leans Thai letters since Thai fonts have no italic.
/// Inside `code` nothing is styled.
@MainActor @Test func italicInThaiAndPlainCode() {
    let h = EditorHarness(dir: tempDir())
    func attr(_ key: NSAttributedString.Key, at s: String, offset: Int = 0) -> Any? {
        h.tv.textStorage!.attribute(key, at: (h.tv.string as NSString).range(of: s).location + offset, effectiveRange: nil)
    }
    h.tv.load("นี่คือ*สำคัญ*มาก\n\nx")
    h.tv.setSelectedRange(NSRange(location: (h.tv.string as NSString).length, length: 0))
    #expect((attr(.font, at: "*") as? NSFont).map { $0.pointSize < 1 } == true) // markers hidden
    #expect(attr(.obliqueness, at: "สำคัญ") as? Double == 0.2)
    h.tv.load("`__init__` and `[a](b)`\n\nx")
    h.tv.setSelectedRange(NSRange(location: (h.tv.string as NSString).length, length: 0))
    #expect((attr(.font, at: "init") as? NSFont).map { !$0.fontDescriptor.symbolicTraits.contains(.bold) } == true)
    #expect(attr(.link, at: "a](") == nil)
    h.tv.load("[Foo](https://en.wikipedia.org/wiki/Foo_(bar))\n\nx")
    h.tv.setSelectedRange(NSRange(location: (h.tv.string as NSString).length, length: 0))
    #expect((attr(.link, at: "Foo") as? URL)?.absoluteString == "https://en.wikipedia.org/wiki/Foo_(bar)")
    h.tv.load("snake_case_name and 2*3")
    #expect(h.tv.markdown() == "snake_case_name and 2*3")
}

/// ⇧⌘M on the Thai layout arrives as "?": the shortcut still reads as M.
@MainActor @Test func shortcutsWorkOnTheThaiLayout() {
    func ev(_ chars: String, _ code: Int) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }
    #expect(PanelController.key(ev("?", kVK_ANSI_M)) == "m")
    #expect(PanelController.key(ev(")", kVK_ANSI_X)) == "x")
    #expect(PanelController.key(ev("ท", kVK_ANSI_M)) == "m")
}

@MainActor @Test func thaiDatesAndNumbers() { // (sets global date settings: not alongside templatesAndDailyNotes)
    let ad = MD.due("- [ ] ส่งรายงาน 📅 2026-10-05")!.date
    #expect(MD.due("- [ ] ส่งรายงาน 📅 2569-10-05")?.date == ad)   // พ.ศ.
    #expect(MD.due("- [ ] ส่งรายงาน 📅 ๒๕๖๙-๑๐-๐๕")?.date == ad)   // Thai digits
    #expect(MD.due("- [ ] โทร 📅 2569-10-05 ๑๔:๓๐")?.hasTime == true)
    #expect(MD.wordCount("ภาษาไทยง่ายนิดเดียว and English") > 4 && MD.plural(1, "word") == "1 word" && MD.plural(3, "word") == "3 words")
    UserDefaults.standard.set("th", forKey: Prefs.dateLanguage)
    let day = ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")!
    #expect(Nav.expand("{{date:d MMMM yyyy}}", date: day).text == "1 ตุลาคม 2026")
    UserDefaults.standard.set(true, forKey: Prefs.systemCalendar)
    if Calendar.current.identifier == .buddhist { #expect(Nav.expand("{{date:yyyy}}", date: day).text == "2569") }
    UserDefaults.standard.removeObject(forKey: Prefs.systemCalendar)
    UserDefaults.standard.removeObject(forKey: Prefs.dateLanguage)
    #expect(MD.nextMarker("๑. ") == "๒. " && MD.nextMarker("  ๙. ") == "  ๑๐. " && MD.nextMarker("9. ") == "10. ")
}

@Test func aTagInsideALinkIsPartOfTheTitle() {
    let text = "ดู [[ประชุม #ทีม]] #งาน"
    #expect(MD.tags(text) == ["งาน"])
    #expect(MD.tags("ส่งงาน#ด่วน “#ลูกค้า” page#section a#b") == ["ด่วน", "ลูกค้า"])
    #expect(MD.linkify(text) == "ดู [ประชุม #ทีม](\(Link.note("ประชุม #ทีม").absoluteString)) [#งาน](\(Link.tag("งาน").absoluteString))")
}

/// Tab lands on a cell with its text selected (typing replaces a placeholder); Return on the header row adds
/// a row under the |---| rule, not above it.
@MainActor @Test func tablesTabAndReturnFromTheHeader() {
    let h = EditorHarness(dir: tempDir())
    h.tv.load("")
    h.tv.cxTable(nil)
    h.tv.insertText("ชื่อ", replacementRange: h.tv.selectedRange())
    h.tv.insertTab(nil)
    h.tv.insertText("สถานะ", replacementRange: h.tv.selectedRange())
    #expect(h.tv.markdown() == "| ชื่อ | สถานะ |\n| --- | --- |\n|  |  |")
    h.tv.insertBacktab(nil)
    #expect((h.tv.string as NSString).substring(with: h.tv.selectedRange()) == "ชื่อ")
    h.tv.setSelectedRange(NSRange(location: ("| ชื่อ | สถานะ |" as NSString).length, length: 0))
    #expect(h.tv.continueList())
    #expect(h.tv.markdown() == "| ชื่อ | สถานะ |\n| --- | --- |\n|  |  |\n|  |  |")
}

/// Around a bullet's or task's hidden marker: the caret can't get inside it, ⌫ removes it (or steps out a
/// level), Return at the text start opens an item above. Numbered runs renumber; quotes continue; nothing of
/// this happens inside a code block.
@MainActor @Test func listsBehaveAroundTheirMarkers() {
    let h = EditorHarness(dir: tempDir())
    func at(_ text: String, _ caret: Int, _ act: () -> Void) -> String {
        h.tv.load(text)
        h.tv.setSelectedRange(NSRange(location: caret, length: 0))
        act()
        return h.tv.markdown()
    }
    h.tv.load("- [ ] ซื้อนม")
    h.tv.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(h.tv.selectedRange().location == 6)                                   // ⌘← or a click at the edge
    #expect(at("- [ ] ซื้อนม", 6) { h.tv.deleteBackward(nil) } == "ซื้อนม")
    #expect(at("- a\n  - b", 8) { h.tv.deleteBackward(nil) } == "- a\n- b")
    #expect(at("- [x] Buy", 6) { _ = h.tv.continueList() } == "- [ ] \n- [x] Buy")
    #expect(h.tv.selectedRange().location == 13)
    #expect(at("1. a\n2. b", 4) { _ = h.tv.continueList() } == "1. a\n2. \n3. b")
    #expect(at("1. a", 3) { _ = h.tv.continueList() } == "1. \n2. a")
    #expect(at("- a\n  - ", 9) { _ = h.tv.continueList() } == "- a\n- ")
    #expect(at("> hi", 4) { _ = h.tv.continueList() } == "> hi\n> ")
    #expect(at("> hi\n> ", 7) { _ = h.tv.continueList() } == "> hi\n")
    h.tv.load("```\n- old")
    h.tv.setSelectedRange(NSRange(location: 9, length: 0))
    #expect(!h.tv.continueList())
    #expect(at("one\n- two", 6) { h.tv.moveLeft(nil) } == "one\n- two" && h.tv.selectedRange().location == 3)
}

/// Code Mode is code all the way: `# comment` is no heading, `- item` no bullet, Return no list.
@MainActor @Test func codeModeShowsNoMarkdown() {
    let h = EditorHarness(dir: tempDir())
    h.tv.style.code = true
    h.tv.load("# install deps\n- item\n\nx")
    h.tv.setSelectedRange(NSRange(location: (h.tv.string as NSString).length, length: 0))
    #expect((h.tv.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { $0.pointSize > 1 } == true) // "#" not hidden
    #expect(h.tv.textStorage!.attribute(.cxMarker, at: 15, effectiveRange: nil) == nil)
    h.tv.setSelectedRange(NSRange(location: 21, length: 0))
    #expect(!h.tv.continueList())
}

@MainActor @Test func moreFormatting() {
    let h = EditorHarness(dir: tempDir())
    func run(_ text: String, _ sel: NSRange, _ act: () -> Void) -> String {
        h.tv.load(text); h.tv.setSelectedRange(sel); act(); return h.tv.markdown()
    }
    let all = NSRange(location: 0, length: 9)
    #expect(run("นม\nไข่\nขนม", all) { h.tv.cxBullet(nil) } == "- นม\n- ไข่\n- ขนม")
    #expect(run("- นม\n- ไข่", NSRange(location: 0, length: 9)) { h.tv.cxBullet(nil) } == "นม\nไข่")
    #expect(run("นม\nไข่\nขนม", all) { h.tv.cxNumbered(nil) } == "1. นม\n2. ไข่\n3. ขนม")
    #expect(run("1. a\n2. b", NSRange(location: 0, length: 9)) { h.tv.cxNumbered(nil) } == "a\nb")
    #expect(run("คำพูด", NSRange(location: 0, length: 0)) { h.tv.cxQuote(nil) } == "> คำพูด")
    #expect(run("let x\nlet y", NSRange(location: 0, length: 11)) { h.tv.cxCodeBlock(nil) } == "```\nlet x\nlet y\n```")
    #expect(run("ก ข ค", NSRange(location: 2, length: 1)) { h.tv.cxHighlight(nil) } == "ก ==ข== ค")
}

/// Anything in Recently Deleted can come back, even from inside a deleted folder.
@Test func restoreFromInsideADeletedFolder() {
    let s = Store(directory: tempDir())
    let work = s.addFolder("Work"), sub = s.addFolder("Sub", in: work)
    let n = s.addNote(to: work, text: "# N")!
    s.trashFolder(work)
    #expect(s.restore(n) == Folder.rootID && s.note(Folder.rootID, n) != nil)
    #expect(s.restore(sub) == Folder.rootID && !s.inTrash(sub))
    #expect(s.restore(work) == Folder.rootID && !s.inTrash(work))
}

/// Back goes where you came from: the search a hit was opened from, the note a link was followed from; only
/// with nowhere left does it go up a level. The note you left is selected in the list you return to.
@MainActor @Test func backRetracesYourSteps() {
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    let work = s.addFolder("Work")
    let a = s.addNote(to: work, text: "# A\nsee [[B]] budget")!
    let b = s.addNote(to: Folder.rootID, text: "# B")!
    nav.search = "budget"
    nav.search = ""                    // opening a hit clears the search…
    nav.route = .note(work, a)         // …and opens it
    nav.openLink(Link.note("B"))
    #expect(nav.route == .note(Folder.rootID, b))
    nav.back()
    #expect(nav.route == .note(work, a))
    nav.back()
    #expect(nav.route == .home && nav.search == "budget")
    nav.back()
    #expect(nav.search.isEmpty)
    nav.route = .note(work, a)
    nav.back()
    #expect(nav.route == .home && nav.selection == a) // the note you left, selected
    nav.back()
    #expect(nav.route == .home)
}

/// A locked folder: its notes are sealed and out of every list until it's unlocked; notes written in it while
/// open are sealed when it locks again; removing the lock gives everything back.
@MainActor @Test func lockedFolders() {
    Nav.passwordAnswer = .some(nil) // never a real password prompt or alert (a test would wait on it forever)
    defer { Nav.passwordAnswer = nil }
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    let work = s.addFolder("Work"), sub = s.addFolder("Deep", in: work)
    let a = s.addNote(to: work, text: "# Salary\n42000 #pay")!
    let b = s.addNote(to: sub, text: "# Contract\nsecret")!
    nav.password = "pw"
    nav.lockFolder(work)
    #expect(s.folder(work)!.locked && s.note(work, a)!.lock != nil && s.note(sub, b)!.lock != nil)
    #expect(s.note(work, a)!.text.isEmpty && !s.liveFolders.contains { $0.id == work || $0.id == sub })
    nav.search = "Salary"
    #expect(nav.searchHits.isEmpty && nav.allTags.isEmpty)
    nav.search = ""
    nav.lockAll()
    nav.password = "nope"
    nav.unlockFolder(work)
    #expect(s.lockedAway(work))                                  // wrong password: still locked
    nav.password = "pw"
    nav.unlockFolder(work)
    #expect(!s.lockedAway(work) && s.liveFolders.contains { $0.id == sub })
    let c = s.addNote(to: work, text: "# New plan\nwritten while open")!
    nav.lockAll()
    #expect(s.note(work, c)!.lock != nil && s.lockedAway(work))  // sealed on locking again
    nav.password = "pw"
    nav.removeFolderLock(work)
    #expect(!s.folder(work)!.locked && s.note(work, a)!.text == "# Salary\n42000 #pay" && s.note(sub, b)!.lock == nil)
}

@MainActor @Test func searchHintsFollowWhatsTyped() {
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    _ = s.addFolder("Work Projects")
    _ = s.addNote(to: Folder.rootID, text: "# A\n#งาน #home")!
    #expect(nav.searchHints("").map(\.label).contains("#tag"))
    #expect(nav.searchHints("milk is:t").map(\.label) == ["is:todo", "is:task"])
    #expect(Set(nav.searchHints("#").map(\.label)) == ["#งาน", "#home"] && nav.searchHints("#ง").map(\.label) == ["#งาน"])
    nav.search = "milk #ง"
    nav.apply(nav.searchHints(nav.search)[0])
    #expect(nav.search == "milk #งาน ")
    nav.search = "path:wor"
    nav.apply(nav.searchHints(nav.search)[0])
    #expect(nav.search == "\"path:Work Projects\" ")
    nav.search = "> go"
    #expect(nav.search.isEmpty && nav.palette == .commands && nav.paletteQuery == "go")
}

/// The panel is as tall as what it shows (up to the screen), hanging from the top: short pages make a short
/// panel, long ones grow it, and the top edge stays where it is.
@MainActor @Test func panelFitsItsContent() async throws {
    await PanelGate.enter()
    defer { PanelGate.leave() }
    Prefs.register()
    let s = Store(directory: tempDir())
    let c = PanelController(store: s)
    c.holdOpen += 1 // other tests open key windows meanwhile: that must not close this panel
    func settle(_ ok: () -> Bool) async throws { for _ in 0..<50 where !ok() { try await Task.sleep(for: .milliseconds(100)) } }
    let long = s.addFolder("Long")
    for i in 0..<60 { _ = s.addNote(to: long, text: "# Note \(i)") }
    c.nav.route = .folder(s.addFolder("Short"))
    c.show(byHover: false)
    let window = c.panel.frame
    let screen = c.panel.screen ?? NSScreen.main!
    let full = screen.visibleFrame.height - 16
    try await settle { c.cardRect.height < full - 40 }
    let short = c.cardRect
    c.nav.route = .folder(long)
    try await settle { c.cardRect.height > short.height + 100 }
    let tall = c.cardRect
    #expect(short.height < full - 40 && tall.height > short.height + 100)
    #expect(abs(short.maxY - tall.maxY) < 1 && abs(tall.maxY - (screen.visibleFrame.maxY - 8)) < 1 && tall.height <= full + 0.5)
    // A short note: a short panel; typing more lines grows it.
    let n = s.addNote(to: long, text: "# Short\nhi")!
    c.nav.route = .note(long, n)
    try await settle { c.cardRect.height < tall.height - 100 }
    let note = c.cardRect
    #expect(note.height < tall.height - 100)
    let tv = try #require(editorIn(c.panel.contentView!))
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    for _ in 0..<15 { tv.insertNewline(nil); tv.insertText("another line", replacementRange: tv.selectedRange()) }
    try await settle { c.cardRect.height > note.height + 100 }
    #expect(c.cardRect.height > note.height + 100 && abs(c.cardRect.maxY - note.maxY) < 1)
    #expect(c.panel.frame == window) // the card springs inside its clear window, which never resizes for it
    c.hide()
}

/// Holding Return in the editor grows the panel line after line. SwiftUI used to resize the window itself in
/// answer to each layout (a fight over the window's size that ended in AppKit's "too many layout passes"
/// exception, and the app quitting).
@MainActor @Test func holdingReturnInTheEditorDoesNotCrash() async throws {
    await PanelGate.enter()
    defer { PanelGate.leave() }
    Prefs.register()
    let s = Store(directory: tempDir())
    let c = PanelController(store: s)
    c.holdOpen += 1 // other tests open key windows meanwhile: that must not close this panel
    let n = s.addNote(to: Folder.rootID, text: "# Short\nhi")!
    c.nav.route = .note(Folder.rootID, n)
    c.show(byHover: false)
    for _ in 0..<60 where editorIn(c.panel.contentView!) == nil { try await Task.sleep(for: .milliseconds(50)) }
    let tv = try #require(editorIn(c.panel.contentView!))
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    for i in 0..<400 {
        tv.insertNewline(nil)
        if i % 4 == 0 { tv.insertText("บรรทัด \(i)", replacementRange: tv.selectedRange()) }
        if i % 3 == 0 { try await Task.sleep(for: .milliseconds(4)) } // layout passes happen between key repeats
    }
    try await Task.sleep(for: .milliseconds(1800))
    let screen = (c.panel.screen ?? NSScreen.main!).visibleFrame
    #expect(c.shown && c.cardRect.height > 300 && c.cardRect.height <= screen.height)
    c.hide()
}


/// Tests that show the one shared panel take turns (they would steal focus from each other, which hides it).
@MainActor enum PanelGate {
    private static var busy = false
    static func enter() async { while busy { try? await Task.sleep(for: .milliseconds(25)) }; busy = true }
    static func leave() { busy = false }
}

/// The preview card is one size whatever it shows, hangs level with what was hovered, and going into a subfolder
/// changes only what's inside; resting on a note in it shows the note in a second card beside, the first staying
/// put. (Sized to what it showed, with a column per level, it grew and shrank about under the pointer.)
@MainActor @Test func previewCardIsSteady() async throws {
    await PanelGate.enter()
    defer { PanelGate.leave() }
    Prefs.register()
    let s = Store(directory: tempDir())
    let big = s.addFolder("Big"), small = s.addFolder("Small")
    for i in 0..<12 { _ = s.addNote(to: big, text: "# Note \(i)") }
    let sub = s.addFolder("Sub", in: small)
    let note = s.addNote(to: small, text: "# Inside\ntext")!
    let c = PanelController(store: s)
    c.holdOpen += 1
    c.show(byHover: true)
    defer { c.hide() }
    try await Task.sleep(for: .milliseconds(600))
    // What was hovered is where the pointer is (show checks it's still there).
    let m = NSEvent.mouseLocation, f = c.panel.frame
    let rect = CGRect(x: m.x - f.minX - 10, y: f.height - (m.y - f.minY) - 10, width: 20, height: 20)
    let p = c.preview
    p.pointer = { m } // resting on the row, whatever the real pointer does meanwhile
    p.hover(.folder(big), inside: true, rect: rect)
    for _ in 0..<40 where !p.isShowing { try await Task.sleep(for: .milliseconds(50)) }
    try #require(p.isShowing)
    let card = p.model.card
    let visible = c.visible(c.panel.screen!).insetBy(dx: 8, dy: 8)
    #expect(card.height == min(visible.height, PreviewController.height) && card.width == p.cardWidth)
    #expect(abs(p.cardRect.maxY - min(m.y + 10, visible.maxY)) < 1 || p.cardRect.minY <= visible.minY + 1) // level with the row
    p.hover(.folder(small), inside: true, rect: rect)
    try await Task.sleep(for: .milliseconds(500))
    #expect(p.model.path == [.folder(small)] && p.model.card == card)
    p.push(.folder(sub), after: 0)
    #expect(p.model.path == [.folder(small), .folder(sub)] && p.model.card == card)
    p.pop(to: 0)
    p.pop(to: -1)                                                   // nothing above: stays (it used to empty, then crash)
    #expect(p.model.path == [.folder(small)])
    p.hoverNote(.note(note), inside: true)
    try await Task.sleep(for: .milliseconds(500))
    if let beside = p.peekRect {
        #expect(p.model.peek == note && p.model.card == card && !beside.intersects(p.cardRect) && beside.size == p.cardRect.size)
    }
}

/// Resting the pointer on a row always brings its preview, however the events came: during or just after a
/// scroll, a row's exit arriving after the next row's entry, or the scrolling stopping with the pointer on a
/// row. (Each of these used to drop the hover for good: no preview until the pointer left the row and returned.)
@MainActor @Test func previewAlwaysFollowsThePointer() async throws {
    await PanelGate.enter()
    defer { PanelGate.leave() }
    Prefs.register()
    let s = Store(directory: tempDir())
    let a = s.addFolder("A"), b = s.addFolder("B")
    _ = s.addNote(to: a, text: "# in A")
    _ = s.addNote(to: b, text: "# in B")
    let c = PanelController(store: s)
    c.holdOpen += 1
    c.show(byHover: true)
    defer { c.hide() }
    try await Task.sleep(for: .milliseconds(600))
    let m = NSEvent.mouseLocation, f = c.panel.frame
    let rect = CGRect(x: m.x - f.minX - 10, y: f.height - (m.y - f.minY) - 10, width: 20, height: 20)
    let p = c.preview
    p.pointer = { m } // resting on the row, whatever the real pointer does meanwhile
    func shows(_ item: PreviewModel.Item, within seconds: Double = 2.5) async throws -> Bool {
        for _ in 0..<Int(seconds * 20) where !(p.isShowing && p.model.path.first == item) { try await Task.sleep(for: .milliseconds(50)) }
        return p.isShowing && p.model.path.first == item
    }

    // The pointer lands on a row just as the list stopped scrolling: it shows once things are quiet.
    p.scrolled()
    p.hover(.folder(a), inside: true, rect: rect)
    #expect(try await shows(.folder(a)))

    // Moving to the next row, the old row's exit comes after the new row's entry.
    p.hover(.folder(b), inside: true, rect: rect)
    p.hover(.folder(a), inside: false, rect: rect)
    #expect(try await shows(.folder(b)))

    // Scrolling closes it; the pointer is still on the row when that stops, with no new event to say so.
    p.scrolled()
    #expect(!p.isShowing)
    #expect(try await shows(.folder(b)))

    // Off the row, nothing opens.
    p.hover(.folder(b), inside: false, rect: rect)
    p.hide()
    try await Task.sleep(for: .milliseconds(900))
    #expect(!p.isShowing)
}

/// Moving fast from one row to another that is far from it: the old preview goes, and the new row's own preview
/// still comes (the old one closing used to cancel it, leaving a highlighted row with no preview).
@MainActor @Test func previewComesForARowFarFromTheLastOne() async throws {
    await PanelGate.enter()
    defer { PanelGate.leave() }
    Prefs.register()
    let s = Store(directory: tempDir())
    let a = s.addFolder("A"), b = s.addFolder("B")
    _ = s.addNote(to: a, text: "# in A")
    _ = s.addNote(to: b, text: "# in B")
    let c = PanelController(store: s)
    c.holdOpen += 1
    c.show(byHover: true)
    defer { c.hide() }
    try await Task.sleep(for: .milliseconds(600))
    let f = c.panel.frame, p = c.preview
    // Two rows in the panel's top-left coordinates, the second well above the first (and above A's card).
    let rowA = CGRect(x: 40, y: 420, width: 280, height: 40), rowB = CGRect(x: 40, y: 60, width: 280, height: 40)
    func center(_ r: CGRect) -> NSPoint { NSPoint(x: f.minX + r.midX, y: f.maxY - r.midY) }
    func shows(_ item: PreviewModel.Item) async throws -> Bool {
        for _ in 0..<60 where !(p.isShowing && p.model.path.first == item) { try await Task.sleep(for: .milliseconds(50)) }
        return p.isShowing && p.model.path.first == item
    }
    p.pointer = { center(rowA) }
    p.hover(.folder(a), inside: true, rect: rowA)
    #expect(try await shows(.folder(a)))
    p.pointer = { center(rowB) }                       // a quick move up to a row far from the card
    p.hover(.folder(a), inside: false, rect: rowA)
    p.hover(.folder(b), inside: true, rect: rowB)
    #expect(try await shows(.folder(b)))
}

/// An editor wired as the real one is: every change and every caret move restyles.
@MainActor private final class RestylingHarness: NSObject, NSTextViewDelegate {
    let tv = MarkdownTextView(usingTextLayoutManager: false)
    let undo = UndoManager()
    override init() {
        super.init()
        tv.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.delegate = self
    }
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
    func textDidChange(_ n: Notification) { tv.convertTypedAttachments(); tv.restyle() }
    func textViewDidChangeSelection(_ n: Notification) { tv.restyle() }
}

/// The glyphs the editor's layout manager holds match those of a fresh layout of the same text.
@MainActor private func glyphsAreCurrent(_ tv: MarkdownTextView) -> Bool {
    guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage else { return false }
    lm.ensureLayout(for: tc)
    let fresh = NSTextStorage(attributedString: storage)
    let freshLM = NSLayoutManager(), freshTC = NSTextContainer(size: tc.size)
    freshTC.lineFragmentPadding = tc.lineFragmentPadding
    freshLM.addTextContainer(freshTC)
    fresh.addLayoutManager(freshLM)
    freshLM.ensureLayout(for: freshTC)
    guard lm.numberOfGlyphs == freshLM.numberOfGlyphs else { return false }
    return (0..<lm.numberOfGlyphs).allSatisfy { lm.cgGlyph(at: $0) == freshLM.cgGlyph(at: $0) }
}

/// A table typed out and left with Return (a new row, then Return on the empty one) was drawn as rubbish: the
/// caret moving out of it restyled the table (monospaced source → aligned) while TextKit was still handling the
/// edit, and TextKit kept the glyphs of the old fonts. Clicking elsewhere was fine, which is why it was random.
@MainActor @Test func tableLeftWithReturnKeepsItsGlyphs() async throws {
    Prefs.register()
    let h = RestylingHarness()
    h.tv.load("")
    for ch in "| ACB | AAA |\n| --- | --- |\n|sasd | dasd|" {
        if ch == "\n" { h.tv.insertNewline(nil) } else { h.tv.insertText(String(ch), replacementRange: h.tv.selectedRange()) }
    }
    #expect(h.tv.continueList())                                                         // Return: a new row
    h.tv.setSelectedRange(NSRange(location: (h.tv.string as NSString).length, length: 0))
    #expect(h.tv.continueList())                                                         // Return on the empty row: out
    try await Task.sleep(for: .milliseconds(100))                                        // the restyle after the edit
    #expect(h.tv.markdown() == "| ACB | AAA |\n| --- | --- |\n|sasd | dasd|\n")
    #expect(glyphsAreCurrent(h.tv))
}

/// What used to get past a locked folder: new notes and drops landing in it as plain text, ⌘A / Delete reaching
/// rows nobody can see, an empty one taking any password, the lock of single notes lost with the folder's,
/// [[links]] into it making copies, and the screen staying inside it after it locked.
@MainActor @Test func lockedFoldersKeepTheirSecrets() {
    Nav.passwordAnswer = .some(nil) // never a real password prompt or alert
    defer { Nav.passwordAnswer = nil }
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    let work = s.addFolder("Work"), sub = s.addFolder("Deep", in: work), other = s.addFolder("Other")
    let a = s.addNote(to: work, text: "# Salary\n42000")!, b = s.addNote(to: sub, text: "# Contract\nsecret")!
    let x = s.addNote(to: other, text: "# Loose")!
    nav.password = "pw"
    nav.lockFolder(work)
    nav.lockAll()                                                   // closed: password forgotten, folder locked away
    let notes = s.folders.flatMap(\.notes).count

    // Nothing new goes in; nothing is moved in.
    nav.route = .folder(work)
    #expect(nav.newNote() == nil && nav.newNote(folderName: "Work") == nil && s.folders.flatMap(\.notes).count == notes)
    nav.drop(x, into: work)
    #expect(s.folderOf(x)?.id == other)
    nav.marked = [x]
    nav.moveMarked(to: work)
    #expect(s.folderOf(x)?.id == other)
    nav.marked = []

    // Its rows are on no screen: ⌘A marks nothing, Delete / Return on a stale selection reach nothing.
    #expect(nav.visibleIDs.isEmpty)
    nav.markAll()
    #expect(nav.marked.isEmpty)
    nav.selection = a
    nav.deleteSelection()
    #expect(!nav.openSelection() && s.note(work, a) != nil && s.folderOf(a)?.id == work)
    nav.marked = [a, b]
    nav.deleteMarked()
    #expect(s.note(work, a) != nil && s.note(sub, b) != nil)
    nav.marked = []

    // A [[link]] to a note in it asks to open the folder; it doesn't make a note of the same name.
    nav.openLink(URL(string: "cortexy://open?title=Salary")!)
    #expect(s.folders.flatMap(\.notes).count == notes)

    // An empty locked folder still tells a wrong password from the right one.
    let empty = s.addFolder("Empty")
    nav.password = "pw"
    nav.lockFolder(empty)
    #expect(s.folder(empty)!.lockCheck != nil)
    nav.lockAll()
    nav.password = "wrong"
    nav.unlockFolder(empty)
    #expect(s.lockedAway(empty))
    nav.password = "pw"
    nav.unlockFolder(empty)
    #expect(!s.lockedAway(empty))
    nav.lockAll()

    // Taking the folder's lock off leaves a note that was locked on its own locked.
    let mixed = s.addFolder("Mixed")
    let own = s.addNote(to: mixed, text: "# Mine alone")!, plain = s.addNote(to: mixed, text: "# Plain")!
    nav.password = "pw"
    nav.lockNote(mixed, own)
    #expect(s.note(mixed, own)!.lock != nil && !s.note(mixed, own)!.byFolder)
    nav.lockFolder(mixed)
    #expect(s.note(mixed, plain)!.lock != nil && s.note(mixed, plain)!.byFolder)
    nav.removeFolderLock(mixed)
    #expect(!s.folder(mixed)!.locked && s.note(mixed, plain)!.lock == nil && s.note(mixed, own)!.lock != nil)

    // Locking while the screen is inside it takes the screen out.
    nav.password = "pw"
    nav.unlockFolder(work)
    nav.route = .folder(sub)
    nav.lockAll()
    #expect(s.lockedAway(work) && nav.route == .folder(work))
}

/// A folder locked by an earlier version (no check, no per-note mark) still gives all its notes back.
@MainActor @Test func olderLockedFoldersOpenFully() {
    Nav.passwordAnswer = .some(nil)
    defer { Nav.passwordAnswer = nil }
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    let f = s.addFolder("Old")
    let n = s.addNote(to: f, text: "# Kept\nbody")!
    nav.password = "pw"
    nav.lockFolder(f)
    s.updateFolder(f) { $0.lockCheck = nil }                      // as written before the check existed
    s.updateNote(f, n) { $0.byFolder = false }
    nav.lockAll()
    nav.password = "pw"
    nav.removeFolderLock(f)
    #expect(s.note(f, n)!.lock == nil && s.note(f, n)!.text == "# Kept\nbody")
}

/// The search box's hint list takes the arrow keys first (then the results do), and Return applies the hint
/// they're on; a rename left half typed is kept when you go elsewhere (Esc cancels it).
@MainActor @Test func hintKeysAndHalfTypedRenames() {
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    _ = s.addNote(to: Folder.rootID, text: "# A\n#alpha #beta #gamma")!
    nav.search = "#"
    let n = min(5, nav.searchHints("#").count)
    #expect(n >= 3 && nav.hintIndex == nil)
    #expect(nav.moveHint(1) && nav.hintIndex == 0)
    #expect(nav.moveHint(1) && nav.hintIndex == 1)
    #expect(nav.moveHint(-1) && nav.hintIndex == 0)
    #expect(nav.moveHint(-1) && nav.hintIndex == nil)               // off the first: back to the field
    #expect(!nav.moveHint(-1))                                      // nothing to go up in: not taken
    for _ in 0..<n { _ = nav.moveHint(1) }
    #expect(nav.hintIndex == n - 1)
    #expect(!nav.moveHint(1) && nav.hintIndex == nil)               // past the last: the results' turn
    _ = nav.moveHint(1); _ = nav.moveHint(1)
    let wanted = nav.searchHints("#")[1]
    #expect(nav.applyHighlightedHint() && nav.search == wanted.insert && nav.hintIndex == nil)
    nav.search = ""
    #expect(!nav.moveHint(1))                                       // no list while the box is empty

    let f = s.addFolder("Old name")
    nav.renaming = f
    nav.renameDraft = "  New name "
    nav.route = .folder(f)                                          // goes elsewhere before pressing Return
    #expect(s.folder(f)!.name == "New name" && nav.renaming == nil)
    nav.renaming = f
    nav.renameDraft = "   "
    nav.route = .home
    #expect(s.folder(f)!.name == "New name")                        // nothing typed keeps the name
    let smart = s.addFolder("Smart")
    s.updateFolder(smart) { $0.query = "#alpha" }
    nav.route = .folder(smart)
    #expect(nav.onSmartFolder)
    nav.route = .folder(f)
    #expect(!nav.onSmartFolder)
}

/// A note over 20,000 characters is laid out where it's looked at (it used to be laid out from the top down to
/// the caret first: half a second for the first key in its middle). It still scrolls to the caret, edits and reads back.
@MainActor @Test func longNotesAreLaidOutOnDemand() {
    Prefs.register()
    let text = (1...1500).map { "line \($0) with some words to fill the width of the editor a bit" }.joined(separator: "\n")
    #expect(text.count > 80_000)
    let h = EditorHarness(dir: tempDir())
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
    scroll.documentView = h.tv
    h.tv.load(text)
    #expect(h.tv.layoutManager?.allowsNonContiguousLayout == true)
    let middle = (text as NSString).range(of: "line 750 ").location
    h.tv.setSelectedRange(NSRange(location: middle, length: 0))
    h.tv.insertText("X", replacementRange: h.tv.selectedRange())
    h.tv.scrollRangeToVisible(h.tv.selectedRange())
    let lm = h.tv.layoutManager!, tc = h.tv.textContainer!
    let g = lm.glyphIndexForCharacter(at: h.tv.selectedRange().location - 1)
    let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).offsetBy(dx: h.tv.textContainerOrigin.x, dy: h.tv.textContainerOrigin.y)
    #expect(h.tv.visibleRect.intersects(r) && r.minY > 1000)       // scrolled down to it, not left at the top
    #expect(h.tv.markdown() == (text as NSString).replacingCharacters(in: NSRange(location: middle, length: 0), with: "X"))
    h.tv.load("short")                                              // a short note goes back to contiguous layout
    #expect(h.tv.layoutManager?.allowsNonContiguousLayout == false)
}

/// Thai typed into a paragraph showed nothing until the caret left it: the paragraph was restyled (system
/// font, no Thai) from inside the text storage's handling of the keystroke, where it doesn't swap in a font
/// that has the letters, so they were drawn as blank glyphs.
@MainActor @Test func thaiTypedInAParagraphIsDrawn() {
    Prefs.register()
    let h = RestylingHarness()
    h.tv.load("# หัวข้อ\n- [ ] งาน\n")
    func blank() -> [Int] {
        let lm = h.tv.layoutManager!, ns = h.tv.string as NSString
        lm.ensureLayout(for: h.tv.textContainer!)
        return (0..<ns.length).filter { i in
            let c = ns.character(at: i)
            guard c >= 0x0E00 && c <= 0x0E7F else { return false }
            let g = lm.glyphIndexForCharacter(at: i)
            return g < lm.numberOfGlyphs && lm.cgGlyph(at: g) == 0
        }
    }
    for at in [(h.tv.string as NSString).length, ("# หัวข้อ\n- [ ] งาน" as NSString).length] { // a new line; inside a task
        h.tv.setSelectedRange(NSRange(location: at, length: 0))
        for ch in ["ส", "ว", "ั", "ส", "ด", "ี"] { h.tv.insertText(ch, replacementRange: h.tv.selectedRange()) }
        #expect(blank().isEmpty)
    }
    h.tv.insertText(" and English", replacementRange: h.tv.selectedRange())
    #expect(blank().isEmpty && h.tv.markdown() == "# หัวข้อ\n- [ ] งานสวัสดี and English\nสวัสดี")
}

/// Shortcuts the user makes: a template's note in its chosen folder (home when none, or when it's gone), or a
/// note opened; keys that can't work are refused with a reason, and Cortexy's own ⌘ keys it takes over are named.
@MainActor @Test func customShortcuts() {
    Prefs.register()
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    let templates = s.addFolder("Templates")
    let meeting = s.addNote(to: templates, text: "# Meeting {{date}}\n- {{cursor}}")!
    let work = s.addFolder("Work"), plan = s.addNote(to: work, text: "# Plan")!
    nav.route = .folder(work)
    let cmdI = HotKeySpec(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(cmdKey), display: "⌘I")
    var t = CustomShortcut(keys: cmdI.encoded, action: .template, target: meeting)
    #expect(nav.run(t))
    #expect(s.folder(Folder.rootID)!.notes.contains { $0.text.hasPrefix("# Meeting ") }) // no folder chosen: home
    #expect(!s.folder(work)!.notes.contains { $0.text.hasPrefix("# Meeting ") })
    t.folder = work
    #expect(nav.run(t) && s.folder(work)!.notes.contains { $0.text.hasPrefix("# Meeting ") }) // its folder
    t.folder = UUID()                                                                   // since deleted: home
    let home = s.folder(Folder.rootID)!.notes.count
    #expect(nav.run(t) && s.folder(Folder.rootID)!.notes.count == home + 1)
    t.folder = nil
    #expect(t.replaces == "Replaces Italic (⌘I) in Cortexy.")
    #expect(nav.run(CustomShortcut(keys: cmdI.encoded, action: .note, target: plan)) && nav.route == .note(work, plan))
    #expect(!nav.run(CustomShortcut(keys: cmdI.encoded, action: .note, target: UUID())))  // gone: nothing done

    let cmdC = HotKeySpec(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), display: "⌘C")
    #expect(CustomShortcut.problem(cmdC, anywhere: false, others: []) != nil)          // Copy stays Copy
    #expect(CustomShortcut.problem(cmdI, anywhere: false, others: []) == nil)
    #expect(CustomShortcut.problem(cmdI, anywhere: false, others: [cmdI]) != nil)      // taken by another
    #expect(CustomShortcut.problem(cmdI, anywhere: true, others: []) != nil)           // any app: needs ⌃ or ⌥
    t.anywhere = true
    #expect(t.replaces == nil)
    let saved = CustomShortcut.all
    defer { CustomShortcut.all = saved }
    CustomShortcut.all = [t]
    #expect(CustomShortcut.all == [t])
}

/// Back to a list puts you where you were in it: on the note you left, or the folder you came out of (the list
/// scrolls to it), rather than at the top.
@MainActor @Test func backReturnsToWhereYouWereInTheList() {
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    let parent = s.addFolder("Parent")
    let kids = (0..<30).map { s.addFolder("Sub \($0)", in: parent) }
    let n = s.addNote(to: kids[25], text: "# deep")!
    nav.route = .folder(parent)
    nav.route = .folder(kids[25])
    nav.route = .note(kids[25], n)
    nav.back()
    #expect(nav.route == .folder(kids[25]) && nav.selection == n)
    nav.back()
    #expect(nav.route == .folder(parent) && nav.selection == kids[25])
}

/// A new password: every locked note and folder opens with it afterwards and not with the old one; a wrong
/// current password changes nothing.
@MainActor @Test func changingTheLockPassword() {
    Nav.passwordAnswer = .some(nil)
    defer { Nav.passwordAnswer = nil }
    let s = Store(directory: tempDir())
    let nav = Nav(store: s)
    let solo = s.addNote(to: Folder.rootID, text: "# Bank\nPIN 1234")!
    let f = s.addFolder("Vault"), inside = s.addNote(to: f, text: "# Deed")!
    let empty = s.addFolder("Empty")
    nav.password = "old"
    nav.lockNote(Folder.rootID, solo)
    nav.lockFolder(f)
    nav.lockFolder(empty)
    nav.lockAll()
    let before = s.note(Folder.rootID, solo)!.lock
    #expect(!nav.changePassword(from: "wrong", to: "new") && s.note(Folder.rootID, solo)!.lock == before)
    #expect(nav.changePassword(from: "old", to: "new"))
    func opens(_ box: String?, _ pw: String) -> Bool {
        guard let box, let salt = NoteLock.salt(box) else { return false }
        return NoteLock.open(box, key: NoteLock.key(pw, salt: salt)) != nil
    }
    for box in [s.note(Folder.rootID, solo)!.lock, s.note(f, inside)!.lock, s.folder(empty)!.lockCheck] {
        #expect(opens(box, "new") && !opens(box, "old"))
    }
    nav.password = "new"
    nav.removeLock(Folder.rootID, solo)
    #expect(s.note(Folder.rootID, solo)!.text == "# Bank\nPIN 1234")
}

/// Web images wait for a note's own Load (fetching one tells its server the note was opened), unless Settings
/// loads them everywhere; a note's Load is remembered.
@MainActor @Test func webImagesWaitForTheirNote() {
    let d = UserDefaults.standard
    let had = d.object(forKey: Prefs.webImages)
    defer { if let had { d.set(had, forKey: Prefs.webImages) } else { d.removeObject(forKey: Prefs.webImages) } }
    Prefs.register()
    d.removeObject(forKey: Prefs.webImages)
    #expect(Prefs.defaults[Prefs.webImages] as? Bool == false)
    #expect(MD.webImages("a ![x](https://e.com/p.png) b ![y](attachments/z.png) ![](http://t.co/1.gif)") == ["https://e.com/p.png", "http://t.co/1.gif"])
    let note = UUID(), other = UUID(), url = URL(string: "https://example.invalid/pixel.png")!
    #expect(!WebImages.shared.allows(note) && !WebImages.shared.coming(url, note: note))
    WebImages.shared.allow(note)
    #expect(WebImages.shared.allows(note) && !WebImages.shared.allows(other))
    d.set(true, forKey: Prefs.webImages)
    #expect(WebImages.shared.allows(other))                         // every note, from Settings
}
