import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drag-to-reorder without the system drag session (which floating non-activating panels don't
/// receive reliably). While dragging, the row's slot shows as a dashed placeholder that slides between
/// the other rows, and a lifted copy (`reorderGhost`) follows the pointer. The copy never depends on
/// layout, so it can't stutter when rows swap. Held over a folder row, it drops into that folder instead.
struct Reorderable: ViewModifier {
    let id: UUID
    let nav: Nav
    let cornerRadius: CGFloat
    var enabled = true
    let move: (UUID, UUID) -> Void // (dragged, onto)
    var drop: ((UUID, UUID) -> Void)? // (dragged, folder row)

    func body(content: Content) -> some View {
        let active = nav.dragging == id
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Reorderable.space)) } action: { nav.rowFrames[id] = $0 }
            .opacity(active ? 0 : 1)
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Reorderable.space))
                    .onChanged { v in
                        guard let me = nav.rowFrames[id] else { return }
                        if nav.dragging != id {
                            nav.grabY = v.startLocation.y - me.minY
                            nav.dragY = v.location.y
                            nav.dragging = id
                            return
                        }
                        nav.dragY = v.location.y
                        let center = v.location.y - nav.grabY + me.height / 2
                        // Over a folder row: drop into it. A dragged folder has to be over the row's middle half,
                        // so its top and bottom quarters still reorder.
                        if drop != nil {
                            let isFolder = nav.store.folder(id) != nil, into = nav.dropIDs
                            let target = nav.rowFrames.first { other, f in
                                let inset = isFolder ? f.height / 4 : 0
                                // Side by side tiles (Archive, Recently Deleted) share a row: the pointer has to be over this one.
                                return other != id && into.contains(other) && f.minY + inset <= center && center <= f.maxY - inset
                                    && f.minX <= v.location.x && v.location.x <= f.maxX
                            }?.key
                            if nav.dropTarget != target { nav.dropTarget = target }
                            if target != nil { return }
                        }
                        // Swap once the dragged copy's center crosses the middle of a neighbour.
                        let ids = nav.reorderIDs
                        let target = nav.rowFrames.first { other, f in
                            other != id && ids.contains(other) && f.minY <= center && center <= f.maxY
                                && (f.minY > me.minY ? center > f.midY : center < f.midY)
                        }?.key
                        if let target { withAnimation(Motion.standard) { move(id, target) } }
                    }
                    .onEnded { _ in
                        if let target = nav.dropTarget, let drop {
                            nav.dropTarget = nil
                            nav.dragging = nil
                            withAnimation(Motion.standard) { drop(id, target) }
                            return
                        }
                        // Let the copy glide into its slot, then swap back to the real row.
                        let slot = nav.rowFrames[id]?.minY ?? 0
                        withAnimation(Motion.standard) { nav.dragY = nav.grabY + slot } completion: {
                            if nav.dragging == id { nav.dragging = nil }
                        }
                    },
                including: enabled ? .all : .subviews
            )
    }

    static let space = "reorder"
}

extension View {
    func reorderable(_ id: UUID, nav: Nav, cornerRadius: CGFloat, enabled: Bool = true, move: @escaping (UUID, UUID) -> Void,
                     drop: ((UUID, UUID) -> Void)? = nil) -> some View {
        modifier(Reorderable(id: id, nav: nav, cornerRadius: cornerRadius, enabled: enabled, move: move, drop: drop))
    }

    /// Records a row's frame so drags can find it (reorderable rows do this themselves).
    func trackFrame(_ id: UUID, nav: Nav) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Reorderable.space)) } action: { nav.rowFrames[id] = $0 }
            .onDisappear { nav.rowFrames[id] = nil } // a tile that's gone (trash emptied) is no drop target
    }

    /// The lifted copy of the row being dragged, drawn over the list and pinned to the pointer.
    func reorderGhost<Ghost: View>(_ nav: Nav, cornerRadius: CGFloat, @ViewBuilder ghost: @escaping (UUID) -> Ghost) -> some View {
        overlay(alignment: .topLeading) { ReorderGhost(nav: nav, cornerRadius: cornerRadius, ghost: ghost) }
    }
}

/// Its own view so only it redraws as the pointer moves; reading `dragY` in the list's body
/// would rebuild every card on every frame of the drag.
private struct ReorderGhost<Ghost: View>: View {
    let nav: Nav
    let cornerRadius: CGFloat
    let ghost: (UUID) -> Ghost

    var body: some View {
        if let d = nav.dragging, nav.reorderIDs.contains(d), let f = nav.rowFrames[d] {
            let into = nav.dropTarget != nil
            ghost(d)
                .frame(width: f.width, height: f.height)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if nav.marked.contains(d), nav.marked.count > 1 {
                        Text("\(nav.marked.count)").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.cortexyAccent, in: .capsule).offset(x: 6, y: -6)
                    }
                }
                .scaleEffect(into ? 0.85 : 1.03, anchor: .leading)
                .opacity(into ? 0.85 : 1)
                .animation(Motion.quick, value: into)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                .offset(x: f.minX, y: nav.dragY - nav.grabY)
                .allowsHitTesting(false)
        }
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.vertical, 4)
    }
}

// MARK: Folder (subfolders, then notes; the home screen is the root folder)

struct FolderView: View {
    @Bindable var nav: Nav
    let folder: Folder
    @AppStorage(Prefs.showTags) private var showTags = true
    @AppStorage(Prefs.trashDays) private var trashDays = 30

    private var keepText: String { trashDays > 0 ? "for \(trashDays) days, then go for good" : "until you empty it" }

    var body: some View {
        let all = nav.folderRows(folder.id)
        // Top-level smart folders get their own section; folders opened in place keep theirs inline.
        let rows = all.filter { $0.depth > 0 || $0.folder.query == nil }
        let smart = all.filter { $0.depth == 0 && $0.folder.query != nil }
        let notes = folder.shownNotes
        let home = folder.id == Folder.rootID
        let trash = home ? nav.store.folder(Folder.trashID).flatMap { t in
            t.notes.isEmpty && nav.store.subfolders(t.id).isEmpty ? nil : t
        } : nil
        let archived = home ? nav.archivedNotes.count : 0
        let due = home ? nav.dueTasks.filter { !$0.done }.count : 0
        let tags = home && showTags ? nav.allTags : []
        let others = !rows.isEmpty || !smart.isEmpty || trash != nil || archived > 0 || due > 0 || !tags.isEmpty
        Group {
            if nav.store.lockedAway(folder.id) {
                ContentUnavailableView {
                    Label("Locked", systemImage: "lock.fill")
                } description: {
                    Text(folder.name)
                } actions: {
                    Button("Unlock") { nav.unlockFolder(folder.id) }
                }.fitsPanel(nav, height: 300)
            } else if !others && notes.isEmpty {
                if folder.id == Folder.trashID {
                    ContentUnavailableView("Nothing Deleted", systemImage: "trash",
                                           description: Text("Deleted notes and folders stay here \(keepText).")).fitsPanel(nav, height: 320)
                } else {
                    ContentUnavailableView("No Notes", systemImage: "note.text",
                                           description: Text("Press ⌘N for a note or ⇧⌘N for a folder, or drop files, images or text here.")).fitsPanel(nav, height: 320)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Themes.shared.look.density.spacing) {
                            if folder.id == Folder.trashID {
                                PageNote(symbol: "trash", text: "Deleted notes and folders stay here \(keepText). Right-click one to restore it.",
                                         action: ("Empty", { nav.requestDelete(.trash) }))
                            }
                            if !rows.isEmpty {
                                SectionHeader(folder.id == Folder.trashID ? "Deleted Folders" : "Folders")
                                FolderGroup(ids: rows.map(\.folder.id)) { id in row(rows.first { $0.folder.id == id }!.folder, depth: rows.first { $0.folder.id == id }!.depth) }
                            }
                            if !smart.isEmpty {
                                SectionHeader("Smart Folders").padding(.top, rows.isEmpty ? 0 : 6)
                                FolderGroup(ids: smart.map(\.folder.id)) { id in row(smart.first { $0.folder.id == id }!.folder, depth: 0) }
                            }
                            if trash != nil || archived > 0 || due > 0 {
                                SectionHeader("Library").padding(.top, 6)
                                HStack(spacing: 8) {
                                    if due > 0 {
                                        LibraryTile(title: "Upcoming", symbol: "calendar", count: due)
                                            .onTapGesture { nav.route = .upcoming }
                                            .previewOnHover(.upcoming)
                                    }
                                    if archived > 0 {
                                        LibraryTile(title: "Archive", symbol: "archivebox", count: archived)
                                            .onTapGesture { nav.route = .archive }
                                            .previewOnHover(.archive)
                                    }
                                    if let trash {
                                        LibraryTile(title: "Recently Deleted", symbol: "trash", count: trash.notes.count + nav.store.subfolders(trash.id).count,
                                                    dropping: nav.dropTarget == trash.id)
                                            .onTapGesture { nav.route = .folder(trash.id) }
                                            .contextMenu { Button("Empty Recently Deleted…", role: .destructive) { nav.requestDelete(.trash) } }
                                            .trackFrame(trash.id, nav: nav)
                                            .previewOnHover(.folder(trash.id))
                                    }
                                }
                            }
                            if !tags.isEmpty { tagStrip(tags) }
                            if !notes.isEmpty && others {
                                SectionHeader(folder.id == Folder.trashID ? "Deleted Notes" : "Notes").padding(.top, 6)
                            }
                            ForEach(notes) { card($0) }
                        }
                        .animation(Motion.standard, value: notes.map(\.id) + all.map(\.folder.id)) // added, deleted, moved
                        .reorderGhost(nav, cornerRadius: nav.dragging.flatMap(nav.store.folder) != nil ? FolderRow.radius : NoteCard.radius) { id in
                            if let f = nav.store.folder(id) { FolderRow(folder: f, nav: nav) }
                            else if let n = notes.first(where: { $0.id == id }) { NoteCard(note: n, store: nav.store) }
                        }
                        .coordinateSpace(.named(Reorderable.space))
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 12)
                    }
                    .fitsPanel(nav)
                    .onChange(of: nav.selection, initial: true) { if let s = nav.selection { withAnimation(Motion.standard) { proxy.scrollTo(s) } } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func tagStrip(_ tags: [(name: String, count: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader("Tags").padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.name) { t in
                        Button { nav.openLink(Link.tag(t.name)) } label: {
                            HStack(spacing: 3) {
                                Text("#" + t.name).foregroundStyle(Color.cortexyAccentText)
                                Text("\(t.count)").foregroundStyle(.secondary)
                            }
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(.primary.opacity(0.07), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func row(_ f: Folder, depth: Int) -> some View {
        VStack(spacing: 4) {
            rowView(f, depth: depth)
            if nav.iconPicking == f.id { IconPicker(nav: nav, folder: f).padding(.leading, 18 + CGFloat(depth) * 16).padding(.bottom, 4) }
        }
    }

    @ViewBuilder private func rowView(_ f: Folder, depth: Int) -> some View {
        let r = FolderRow(folder: f, nav: nav, selected: nav.selection == f.id, marked: nav.marked.contains(f.id),
                          dropping: nav.dropTarget == f.id, depth: depth, count: f.query.map { nav.hits(Query($0)).count })
            .onTapGesture { if nav.renaming != f.id { nav.click(f.id) { nav.route = .folder(f.id) } } }
            .previewOnHover(.folder(f.id))
            .contextMenu {
                if folder.id == Folder.trashID {
                    Button("Restore") { nav.restore(f.id) }
                    Divider()
                    Button("Delete Permanently…", role: .destructive) { nav.requestDelete(.folder(f)) }
                } else {
                    menu(f)
                }
            }
            .id(f.id)
        // Rows expanded in place drop things in but don't reorder: their siblings aren't all on screen.
        if depth == 0 && folder.id != Folder.trashID {
            r.reorderable(f.id, nav: nav, cornerRadius: FolderRow.radius, move: { nav.store.moveFolder($0, onto: $1) },
                          drop: { nav.drop($0, into: $1) })
        } else {
            r.trackFrame(f.id, nav: nav)
        }
    }

    @ViewBuilder private func menu(_ f: Folder) -> some View {
        Button("Rename") { nav.renaming = f.id }
        ColorMenu(selection: f.color) { c in nav.store.updateFolder(f.id) { $0.color = c } }
        Button("Icon…") { withAnimation(Motion.standard) { nav.iconPicking = f.id } }
        Button(f.pinned ? "Unpin" : "Pin to Top") { nav.store.updateFolder(f.id) { $0.pinned.toggle() } }
        if f.query == nil { FolderLockMenu(nav: nav, folder: f) }
        Menu("Move to") {
            let inside = Set(nav.store.subtree(f.id).map(\.id)), parent = nav.store.parentID(f)
            ForEach(nav.store.moveTargets.filter { !inside.contains($0.id) && $0.id != parent }) { t in
                Button(nav.store.path(t.id)) { nav.store.moveFolder(f.id, into: t.id) }
            }
        }
        Divider()
        Button("Delete Folder", role: .destructive) { nav.requestDelete(.folder(f)) }
    }

    private func card(_ n: Note) -> some View {
        let fid = folder.id
        return NoteCard(note: n, store: nav.store, selected: nav.selection == n.id, marked: nav.marked.contains(n.id),
                        toggle: { nav.toggleTask(fid, n.id, line: $0) }, onCopy: { nav.copy(n) }, onPreview: NoteCard.preview(n.id))
            .equatable()
            .onTapGesture { nav.click(n.id) { nav.activate(fid, n) } }
            .contextMenu { NoteMenu(nav: nav, fid: fid, note: n) }
            // Sorted folders still drag (into other folders); only manual order reorders.
            .reorderable(n.id, nav: nav, cornerRadius: NoteCard.radius,
                         move: { a, b in if folder.sort == .manual { nav.store.moveNote(a, onto: b, in: fid) } },
                         drop: { nav.drop($0, into: $1) })
            .id(n.id)
    }
}

/// A folder's icon: its SF Symbol or emoji, in its color.
struct FolderIcon: View {
    let folder: Folder

    var body: some View {
        let tint = folder.color.harmonized(with: Themes.shared.current) ?? .accentColor
        if folder.id == Folder.trashID { Image(systemName: "trash").foregroundStyle(.secondary) }
        else if folder.query != nil && folder.icon == nil { Image(systemName: "sparkle.magnifyingglass").foregroundStyle(tint) }
        else if let i = folder.icon, NSImage(systemSymbolName: i, accessibilityDescription: nil) != nil { Image(systemName: i).foregroundStyle(tint) }
        else if let i = folder.icon, !i.isEmpty { Text(i) }
        else { Image(systemName: "folder.fill").foregroundStyle(tint) }
    }
}

/// Rest the pointer on this to preview `column` (a folder's contents, a note) beside the panel.
struct PreviewOnHover: ViewModifier {
    let column: PreviewModel.Column
    @Local private var frame = NoteCard.FrameBox() // a box, so scrolling doesn't redraw

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
            .onHover { PanelController.shared?.preview.hover(column, inside: $0, rect: frame.rect) }
    }
}

/// Tells the panel how much taller (or shorter) this page is than its room; again whenever the card comes to
/// rest. Only while it's the page on show: one fading out has nothing more to say.
struct FitsPanel: ViewModifier {
    let nav: Nav
    let screen: String // as it was when this page was made
    let fixed: CGFloat?
    struct Size: Equatable { var content: CGFloat = 0, container: CGFloat = 0 }
    final class Box { var size = Size() }
    @Local private var box = Box()

    func body(content: Content) -> some View {
        Group {
            if let fixed {
                content.frame(maxWidth: .infinity, maxHeight: .infinity) // the room, not the view
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.size = Size(content: fixed, container: $0); report() }
            } else {
                content.onScrollGeometryChange(for: Size.self) { Size(content: $0.contentSize.height, container: $0.containerSize.height) } action: { _, s in
                    box.size = s
                    report()
                }
            }
        }
        .onChange(of: nav.measureTick) { report() }
    }

    private func report() { if nav.screenKey == screen { nav.panel?.grow(content: box.size.content, container: box.size.container) } }
}

extension View {
    /// The panel fits its height to this list's content (up to the screen's), like Dynamic Island.
    func fitsPanel(_ nav: Nav) -> some View { modifier(FitsPanel(nav: nav, screen: nav.screenKey, fixed: nil)) }

    /// A page with nothing to scroll (an empty one, a lock): the panel gives it `height`.
    func fitsPanel(_ nav: Nav, height: CGFloat) -> some View { modifier(FitsPanel(nav: nav, screen: nav.screenKey, fixed: height)) }

    func previewOnHover(_ column: PreviewModel.Column) -> some View { modifier(PreviewOnHover(column: column)) }
}

/// Folder icons, shown as they'll look: SF Symbols in the folder's color, common emoji, or any emoji typed in.
struct IconPicker: View {
    let nav: Nav
    let folder: Folder
    @Local private var emoji = ""
    static let symbols = ["folder", "star", "heart", "bookmark", "flag", "tag", "briefcase", "house", "book",
                          "graduationcap", "lightbulb", "cart", "creditcard", "airplane", "car", "gift", "music.note", "camera",
                          "gamecontroller", "paintpalette", "hammer", "chart.bar", "person", "doc.text", "tray", "leaf", "bolt"]
    static let emojis = ["📁", "⭐️", "❤️", "🏠", "💼", "📚", "💡", "🛒", "✈️", "🎮", "🎵", "📷", "🌱", "⚡️", "🔥", "🎯", "📌", "✅",
                         "🧠", "💰", "🍳", "🏃", "🎨", "🔧", "🐶", "☕️", "🎁"]

    var body: some View {
        let tint = folder.color.harmonized(with: Themes.shared.current) ?? .accentColor
        VStack(alignment: .leading, spacing: 8) {
            grid(Self.symbols) { Image(systemName: $0).foregroundStyle(tint) }
            grid(Self.emojis) { Text($0) }
            HStack(spacing: 8) {
                TextField("Other emoji (⌃⌘Space)", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { if let c = emoji.first { set(String(c)) } }
                Button("Default") { set(nil) }
                Spacer(minLength: 0)
                Button("Done") { withAnimation(Motion.standard) { nav.iconPicking = nil } }
            }
            .font(.system(size: 12))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: FolderRow.radius + 2, style: .continuous).fill(.primary.opacity(0.06)))
    }

    private func grid<Cell: View>(_ items: [String], @ViewBuilder cell: @escaping (String) -> Cell) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: 3)], alignment: .leading, spacing: 3) {
            ForEach(items, id: \.self) { item in
                Button { set(item) } label: {
                    cell(item)
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(folder.icon == item ? Color.cortexyAccent.opacity(0.25) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item)
            }
        }
    }

    private func set(_ icon: String?) {
        nav.store.updateFolder(folder.id) { $0.icon = icon }
        withAnimation(Motion.standard) { nav.iconPicking = nil }
    }
}

/// Archive and Recently Deleted on the home screen: tiles, so they read as places, not folders.
struct LibraryTile: View {
    let title: String
    let symbol: String
    let count: Int
    var dropping = false
    @Local private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer()
                Text("\(count)").font(.system(size: 16, weight: .semibold)).monospacedDigit()
            }
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75) // "Recently Deleted" fits
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: FolderRow.radius + 2, style: .continuous)
            .fill(dropping ? Color.cortexyAccent.opacity(0.22) : .primary.opacity(hover ? 0.1 : 0.06)))
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: FolderRow.radius + 2, style: .continuous).strokeBorder(Color.cortexyAccent, lineWidth: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A line at the top of a special page saying what it is.
struct PageNote: View {
    let symbol: String
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action.0, action: action.1).buttonStyle(.plain).foregroundStyle(Color.cortexyAccentText).fontWeight(.semibold) }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: FolderRow.radius + 2, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

/// Folders sit together in one grouped, grey panel with hairlines between them (as in Settings), while notes
/// are separate light cards: one look for "go inside", another for "read this".
struct FolderGroup<Row: View>: View {
    let ids: [UUID]
    @ViewBuilder let row: (UUID) -> Row

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NoteCard.radius, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                row(id)
                if i < ids.count - 1 { Divider().opacity(0.6).padding(.leading, 40).padding(.trailing, 10) }
            }
        }
        .padding(3)
        .background(shape.fill(.primary.opacity(0.055)))
        .overlay(shape.strokeBorder(.primary.opacity(0.07), lineWidth: 1))
    }
}

struct FolderRow: View {
    let folder: Folder
    @Bindable var nav: Nav
    var selected = false  // the keyboard cursor: an outline
    var marked = false    // ⌘/⇧-clicked: a tint and a tick
    var dropping = false // a dragged row would drop in here
    var depth = 0
    var count: Int?
    @Local private var hover = false
    @FocusState private var editing: Bool

    var body: some View {
        let expandable = !Folder.isBuiltIn(folder.id) && !nav.store.subfolders(folder.id).isEmpty
        let open = nav.expanded.contains(folder.id)
        HStack(spacing: 8) {
            Group {
                if expandable {
                    Button { withAnimation(Motion.standard) { nav.toggleExpanded(folder.id) } } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 14, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(open ? "Collapse" : "Expand")
                } else {
                    Color.clear.frame(width: 14)
                }
            }
            FolderIcon(folder: folder).font(.system(size: 15)).frame(width: 20)
            if nav.renaming == folder.id {
                TextField("Folder Name", text: $nav.renameDraft)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onSubmit(commit)
                    .onAppear { nav.renameDraft = folder.name; editing = true }
                    .onChange(of: editing) { if !editing { commit() } }
            } else {
                Text(folder.name).lineLimit(1)
            }
            Spacer(minLength: 4)
            if folder.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary) }
            if folder.locked { Image(systemName: nav.store.lockedAway(folder.id) ? "lock.fill" : "lock.open").font(.caption2).foregroundStyle(.secondary) }
            Text("\(count ?? nav.store.noteCount(folder.id))").foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 13.5))
        .padding(.leading, 2 + CGFloat(depth) * 16)
        .padding(.trailing, 10)
        .frame(height: Themes.shared.look.density.rowHeight)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(dropping ? Color.cortexyAccent.opacity(0.22) : marked ? Color.cortexyAccent.opacity(0.16) : .primary.opacity(hover || selected ? 0.08 : 0)))
        .overlay {
            if selected || dropping { RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.cortexyAccent, lineWidth: 2) }
        }
        .overlay(alignment: .leading) { if marked { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.cortexyAccent).offset(x: -4) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    static var radius: CGFloat { max(4, Themes.shared.look.cornerRadius - 4) }

    private func commit() {
        guard nav.renaming == folder.id else { return }
        nav.commitRename()
    }
}

// MARK: Upcoming

/// Every open task with a date, by when it's due. Tick them off here; click one to go to it.
struct UpcomingView: View {
    @Bindable var nav: Nav

    var body: some View {
        let tasks = nav.dueTasks.filter { !$0.done }
        let cal = Calendar.current
        let groups: [(String, [Nav.DueTask])] = [
            ("Overdue", tasks.filter { $0.due == .overdue }),
            ("Today", tasks.filter { $0.due == .today }),
            ("Tomorrow", tasks.filter { $0.due == .later && cal.isDateInTomorrow($0.date) }),
            ("Later", tasks.filter { $0.due == .later && !cal.isDateInTomorrow($0.date) }),
        ].filter { !$0.1.isEmpty }
        if tasks.isEmpty {
            ContentUnavailableView("Nothing Due", systemImage: "calendar",
                                   description: Text("Give a task a date — “- [ ] Call Ann 📅 2026-10-05 14:30”, or the calendar button under the editor — and it shows here and reminds you.")).fitsPanel(nav, height: 320)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    PageNote(symbol: "calendar", text: "Tasks with a date, from every note. Reminders come as notifications (Settings → General).")
                    ForEach(groups, id: \.0) { name, items in
                        SectionHeader(name).padding(.top, 6)
                        ForEach(items) { row($0) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .fitsPanel(nav)
        }
    }

    private func row(_ t: Nav.DueTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { nav.toggleTask(t.fid, t.nid, line: t.line) } label: { Image(systemName: "square").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark as done")
            VStack(alignment: .leading, spacing: 2) {
                Text(t.text.isEmpty ? "Untitled task" : t.text).font(.system(size: 13.5)).lineLimit(2)
                Text(nav.store.note(t.fid, t.nid)?.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Nav.show(t.date, time: t.hasTime))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(nsColor: t.due.color))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: FolderRow.radius, style: .continuous).fill(.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { nav.openNote(t.nid, line: t.line) }
        .previewOnHover(.note(t.nid))
    }
}

// MARK: Archive

struct ArchiveView: View {
    @Bindable var nav: Nav

    var body: some View {
        let notes = nav.archivedNotes
        if notes.isEmpty {
            ContentUnavailableView("Nothing Archived", systemImage: "archivebox",
                                   description: Text("Archived notes leave their folder and search, and wait here.")).fitsPanel(nav, height: 300)
        } else {
            ScrollView {
                LazyVStack(spacing: Themes.shared.look.density.spacing) {
                    PageNote(symbol: "archivebox", text: "Archived notes stay out of their folders and search. Right-click one to unarchive it.")
                    ForEach(notes, id: \.1.id) { f, n in
                        NoteCard(note: n, store: nav.store, folderName: nav.store.path(f.id),
                                 selected: nav.selection == n.id, marked: nav.marked.contains(n.id),
                                 toggle: { nav.toggleTask(f.id, n.id, line: $0) }, onCopy: { nav.copy(n) }, onPreview: NoteCard.preview(n.id))
                            .onTapGesture { nav.click(n.id) { nav.activate(f.id, n) } }
                            .contextMenu { NoteMenu(nav: nav, fid: f.id, note: n) }
                            .id(n.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .fitsPanel(nav)
        }
    }
}

/// What the search box finds, or what a smart folder's saved search finds. Matches are highlighted.
struct SearchResults: View {
    @Bindable var nav: Nav
    var smart: Folder?

    var body: some View {
        let text = smart?.query ?? nav.search
        let q = Query(text)
        let hits = smart == nil ? nav.searchHits : nav.hits(q)
        VStack(spacing: 0) {
            if let smart {
                SmartQueryBar(nav: nav, folder: smart)
                PageNote(symbol: "sparkle.magnifyingglass",
                         text: "Smart folder: every note matching this search, wherever it lives (\(hits.count) now). Notes stay in their own folders.")
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if hits.isEmpty {
                if q.isEmpty {
                    ContentUnavailableView("Smart Folder", systemImage: "sparkle.magnifyingglass",
                                           description: Text("Type a search above, e.g. #work is:todo, and matching notes show here.")).fitsPanel(nav, height: 300)
                } else {
                    ContentUnavailableView.search(text: text).fitsPanel(nav, height: 300)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Themes.shared.look.density.spacing) {
                            if smart == nil {
                                HStack {
                                    Text("\(hits.count) note\(hits.count == 1 ? "" : "s")")
                                    Spacer()
                                    Button("Save as Smart Folder") { nav.saveSearch() }.buttonStyle(.plain).foregroundStyle(Color.cortexyAccentText)
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                            }
                            ForEach(hits, id: \.1.id) { f, n in
                                NoteCard(note: n, store: nav.store, folderName: f.id == Folder.rootID ? nil : nav.store.path(f.id),
                                         selected: nav.selection == n.id, marked: nav.marked.contains(n.id), highlight: q.words, showMatch: q.words.first,
                                         toggle: { nav.toggleTask(f.id, n.id, line: $0) }, onCopy: { nav.copy(n) }, onPreview: NoteCard.preview(n.id))
                                    .equatable()
                                    .onTapGesture { nav.click(n.id) { nav.activate(f.id, n, find: q.words.first) } }
                                    .contextMenu { NoteMenu(nav: nav, fid: f.id, note: n) }
                                    .id(n.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }
                    .fitsPanel(nav)
                    .onChange(of: nav.selection, initial: true) { if let s = nav.selection { withAnimation(Motion.standard) { proxy.scrollTo(s) } } }
                }
            }
        }
    }
}

/// A smart folder's search, editable in place.
struct SmartQueryBar: View {
    let nav: Nav
    let folder: Folder
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            TextField("#tag, words, is:todo, path:Work…", text: Binding(get: { folder.query ?? "" },
                                                                        set: { q in nav.store.updateFolder(folder.id) { $0.query = q } }))
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: nav.searchFocus) { focused = true } // ⌘F here edits the smart folder's search
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.primary.opacity(0.06), in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

// MARK: Note card

/// A card draws from these alone (the closures only act on the note they were made for), so one that is the same
/// as before isn't evaluated again: typing in the search box re-made every card in the list.
extension NoteCard: Equatable {
    static func == (a: NoteCard, b: NoteCard) -> Bool {
        a.note == b.note && a.folderName == b.folderName && a.selected == b.selected && a.marked == b.marked
            && a.exporting == b.exporting && a.highlight == b.highlight && a.showMatch == b.showMatch
    }
}

struct NoteCard: View {
    let note: Note
    let store: Store
    var folderName: String?
    var selected = false
    var marked = false
    var exporting = false
    var highlight: [String] = [] // search words to mark
    var showMatch: String?       // also show the first line with this word (search results)
    var toggle: (Int) -> Void = { _ in }
    var onCopy: (() -> Void)?
    var onPreview: ((Bool, CGRect) -> Void)? // hover in/out, with the card's frame in the window
    @Local private var hover = false
    @Local private var frame = FrameBox() // a box, so scrolling doesn't redraw the card

    final class FrameBox { var rect = CGRect.zero }

    static var radius: CGFloat { Themes.shared.look.cornerRadius }

    /// Shows the note beside the panel while the pointer rests on its card.
    static func preview(_ id: UUID) -> (Bool, CGRect) -> Void {
        { inside, rect in PanelController.shared?.preview.hover(id, inside: inside, rect: rect) }
    }

    /// The editor's fonts and spacing, so a card reads like the open note.
    private var style: TextStyle {
        var st = Themes.shared.textStyle
        st.code = note.code
        return st
    }

    /// The text up to its `lines`-th line break.
    static func head(_ s: String, lines: Int) -> String {
        var seen = 0
        for i in s.indices where s[i] == "\n" {
            seen += 1
            if seen == lines { return String(s[..<i]) }
        }
        return s
    }

    /// The first `limit` lines, plus (for a search result showing only its title) the first one with `match`.
    private static func lines(_ content: [(offset: Int, element: MD.Line)], limit: Int, match: String?, raw: [String]) -> [(offset: Int, element: MD.Line)] {
        let first = Array(content.prefix(limit))
        guard let match, let hit = content.dropFirst(limit).first(where: { raw.indices.contains($0.offset) && MD.finds(match, in: raw[$0.offset]) }) else { return first }
        return first + [hit]
    }

    /// Lines as the card draws them: a run of code lines is one block (in the fence's language), a table one grid.
    private enum Piece { case line(Int, MD.Line), code(String, [String]), table([String]) }
    private static func pieces(_ lines: [(offset: Int, element: MD.Line)], raw: [String]) -> [(id: Int, piece: Piece)] {
        let tables = MD.tables(raw)
        var out: [(id: Int, piece: Piece)] = []
        for (i, line) in lines {
            if let t = tables.first(where: { $0.contains(i) }) {
                if case .table? = out.last?.piece, t.contains(out.last!.id) { continue } // the rest of a table already added
                out.append((i, .table(Array(raw[i..<min(t.upperBound, (lines.last?.offset ?? i) + 1)]))))
            } else if case .code(let s) = line {
                if case .code(let lang, let run)? = out.last?.piece { out[out.count - 1].piece = .code(lang, run + [s]); continue }
                let fence = i > 0 ? raw[i - 1].trimmingCharacters(in: .whitespaces) : ""
                out.append((i, .code(fence.hasPrefix("```") ? String(fence.dropFirst(3).split(separator: " ").first ?? "") : "", [s])))
            } else {
                out.append((i, .line(i, line)))
            }
        }
        return out
    }

    var body: some View {
        let look = Themes.shared.look
        let style = style
        let brief = !exporting && (look.titleOnly || note.folded) // just the title: the preview shows the rest
        // Showing just the title (and no search line to find): only the top of the note needs reading.
        let text = brief && showMatch == nil ? Self.head(note.text, lines: 12) : note.text
        let raw = text.components(separatedBy: "\n") // for list nesting, which MD.Line leaves out
        let all = Array(MD.lines(text).enumerated()).filter { $0.element != .fence }
        let content = Array(all.drop { $0.element == .blank }.reversed().drop { $0.element == .blank }.reversed())
        let limit = exporting ? Int.max : brief ? 1 : look.cardLines
        let shown = Self.lines(content, limit: limit, match: brief ? showMatch : nil, raw: raw)
        VStack(alignment: .leading, spacing: style.paragraphSpacing) {
            if let folderName {
                Text(folderName).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            if note.lock != nil { // just its title: the text is sealed
                Label(note.title, systemImage: "lock.fill").font(style.swiftUI(weight: .semibold))
            } else if shown.isEmpty {
                Text("Empty Note").foregroundStyle(.tertiary)
            }
            if note.lock != nil {
            } else if note.code { // code mode: the whole note is code, colored, without Markdown
                CodeBlock(lines: Array(raw.prefix(limit)), lang: "", style: style, boxed: false)
            } else {
                ForEach(Self.pieces(shown, raw: raw), id: \.id) { _, piece in
                    switch piece {
                    case .line(let i, let line):
                        LineView(line: line, store: store, style: style, highlight: highlight, level: raw.indices.contains(i) ? MD.indentLevel(raw[i]) : 0) { toggle(i) }
                    case .code(let lang, let lines): CodeBlock(lines: lines, lang: lang, style: style)
                    case .table(let rows): TableBlock(rows: rows, style: style)
                    }
                }
            }
            if !brief && content.count > limit {
                Text("…").foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(style.swiftUI())
        .fontDesign(nil) // the panel's design would override these explicit fonts (a chosen family, code mode)
        .lineSpacing(style.lineSpacing)
        .padding(.vertical, look.density.cardPadding)
        .padding(.leading, look.density.cardPadding + 2)
        .padding(.trailing, 26)
        .overlay(alignment: .topTrailing) { badges }
        .background { CardBackground(color: note.color, hover: hover, opaque: exporting) }
        .overlay {
            if marked { RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color.cortexyAccent.opacity(0.14)) }
            if selected {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.cortexyAccent, lineWidth: 2)
            }
        }
        .overlay(alignment: .topLeading) {
            if marked { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.cortexyAccent).background(Circle().fill(.background)).offset(x: -3, y: -3) }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
        .onHover { inside in
            hover = inside
            onPreview?(inside, frame.rect)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title)
    }

    @ViewBuilder private var badges: some View {
        if hover && !exporting {
            if let onCopy { MiniButton(symbol: "doc.on.doc", help: "Copy Text", action: onCopy).padding(5) }
        } else {
            VStack(spacing: 6) {
                if note.pinned { Image(systemName: "pin.fill") }
                if note.snippet { Image(systemName: "doc.on.clipboard").help("Snippet: click to copy") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 11)
            .padding(.trailing, 9)
        }
    }

    /// The card as an image, for Copy/Export as Image.
    @MainActor static func snapshot(_ n: Note, store: Store) -> NSImage? {
        let theme = Themes.shared.current
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let view = NoteCard(note: n, store: store, exporting: true)
            .frame(width: max(280, CGFloat(UserDefaults.standard.double(forKey: Prefs.width)) - 20))
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(theme.accentColor)
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: view)
        r.scale = 2
        return r.nsImage
    }
}

/// A run of code lines on a card, boxed like the editor's code.
struct CodeBlock: View {
    let lines: [String]
    var lang = ""
    let style: TextStyle
    var boxed = true

    var body: some View {
        let code = lines.joined(separator: "\n")
        var a = AttributedString(code)
        for (r, kind) in Syntax.tokens(code, lang: lang) {
            if let sr = Range(r, in: code), let ar = Range(sr, in: a) { a[ar].foregroundColor = Color(nsColor: kind.color) }
        }
        return Text(a)
            .font(style.swiftUIMono(style.size - 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, boxed ? 8 : 0)
            .padding(.vertical, boxed ? 6 : 0)
            .background(boxed ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A Markdown table on a card: a real grid, header bold, columns aligned as the `| :-: |` row says.
struct TableBlock: View {
    let rows: [String] // header, rule, body rows
    let style: TextStyle

    var body: some View {
        let header = MD.cells(rows[0])
        let aligns = rows.count > 1 ? MD.alignments(rows[1]) : []
        let body = rows.dropFirst(2).map(MD.cells)
        let columns = max(header.count, body.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow { ForEach(0..<columns, id: \.self) { c in cell(header, c, aligns).fontWeight(.semibold) } }
            Divider()
            ForEach(body.indices, id: \.self) { r in
                GridRow { ForEach(0..<columns, id: \.self) { c in cell(body[r], c, aligns) } }
            }
        }
        .padding(8)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func cell(_ row: [String], _ c: Int, _ aligns: [MD.Align]) -> some View {
        let text = c < row.count ? row[c] : ""
        let a = (try? AttributedString(markdown: MD.linkify(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let align: HorizontalAlignment = switch c < aligns.count ? aligns[c] : .left { case .left: .leading; case .center: .center; case .right: .trailing }
        return Text(a).gridColumnAlignment(align)
    }
}

struct MiniButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct CardBackground: View {
    let color: NoteColor
    var hover = false
    var opaque = false
    @AppStorage("colorStyle") private var colorStyle = "tint"

    var body: some View {
        let theme = Themes.shared.current
        let shape = RoundedRectangle(cornerRadius: NoteCard.radius, style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(Color(nsColor: .textBackgroundColor).opacity(opaque ? 1 : theme.cardOpacity + (hover ? 0.15 : 0)))
            if let t = theme.cardTint.flatMap(Color.init(hex:)) { shape.fill(t.opacity(0.12)) }
            if let c = color.color {
                if colorStyle == "bar" {
                    Capsule().fill(c).frame(width: 4).padding(.vertical, 10).padding(.leading, 4)
                } else {
                    shape.fill(c.opacity(hover ? 0.22 : 0.16))
                }
            }
        }
    }
}

struct LineView: View {
    let line: MD.Line
    let store: Store
    let style: TextStyle
    var highlight: [String] = []
    var level = 0 // list nesting, as in the editor
    let toggle: () -> Void

    private var size: CGFloat { style.size }
    private var indent: CGFloat { CGFloat(level) * style.indentWidth }

    var body: some View {
        switch line {
        case .blank: Color.clear.frame(height: max(0, style.lineHeight - style.paragraphSpacing))
        case .fence: EmptyView()
        case .heading(_, let s):
            inline(s).font(style.swiftUI(weight: .bold)) // cards keep headings at text size; the editor shows them big
        case .task(let done, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button(action: toggle) {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Color.cortexyAccent : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
                inline(s, done: done).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.leading, indent)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text(["•", "◦", "▪"][level % 3]).foregroundStyle(.secondary); inline(s) }
                .padding(.leading, indent)
        case .numbered(let m, let s):
            HStack(alignment: .firstTextBaseline, spacing: 4) { Text(m).foregroundStyle(.secondary).monospacedDigit(); inline(s) }
                .padding(.leading, indent)
        case .quote(let s):
            inline(s).foregroundStyle(.secondary).padding(.leading, 8)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 2) }
        case .code(let s):
            Text(s).font(style.swiftUIMono(size - 1)).foregroundStyle(.secondary)
        case .image(let alt, let path):
            let _ = (WebImages.shared.arrivals, Attachments.loads.count) // redraw when an image is ready
            let url = store.resolve(path)
            if let url, let img = Attachments.imageSoon(at: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320) // as in the editor
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            } else if let url, url.isFileURL ? FileManager.default.fileExists(atPath: url.path) : WebImages.shared.coming(url) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)).frame(height: 90) // on its way
            } else if let url, !url.isFileURL { // web images off, or it couldn't be fetched: a link, as in the editor
                SwiftUI.Link(destination: url) { Label(alt.isEmpty ? url.host ?? "Image" : alt, systemImage: "photo") }
            } else {
                Label(alt.isEmpty ? "Missing image" : alt, systemImage: "photo").foregroundStyle(.secondary)
            }
        case .file(let name, let link):
            let url = URL(string: link)
            Button { if let url { NSWorkspace.shared.open(url) } } label: {
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url?.path ?? "")).resizable().frame(width: 16, height: 16)
                    Text(name).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(url?.path ?? name)
        case .text(let s):
            inline(s)
        }
    }

    /// Inline Markdown, with #tags and [[links]] clickable, `#ff8800` shown in its color and search words marked.
    private func inline(_ s: String, done: Bool = false) -> Text {
        var a = (try? AttributedString(markdown: MD.linkify(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        func each(_ term: String, _ apply: (inout AttributedString, Range<AttributedString.Index>) -> Void) {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: term, options: MD.searchOptions(term)) {
                apply(&a, r)
                from = r.upperBound
            }
        }
        let plain = String(a.characters)
        for m in Styler.hex.matches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)) {
            let hex = (plain as NSString).substring(with: m.range)
            guard let c = NSColor(hex: hex) else { continue }
            let light = c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114 > 0.6
            each(hex) { a, r in
                a[r].backgroundColor = Color(nsColor: c)
                a[r].foregroundColor = light ? .black : .white
                a[r].font = style.swiftUIMono(size - 1)
            }
        }
        // ==marked== text and footnotes: the parser leaves these as plain text, so rework them here, last to first
        // (so earlier positions stay put). `apply` gets the whole match and its first group.
        func rework(_ re: NSRegularExpression, _ apply: (inout AttributedString, Range<AttributedString.Index>, Range<AttributedString.Index>) -> Void) {
            let plain = String(a.characters)
            for m in re.matches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)).reversed() {
                func range(_ r: NSRange) -> Range<AttributedString.Index>? {
                    guard let sr = Range(r, in: plain) else { return nil }
                    let lo = a.characters.index(a.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: sr.lowerBound))
                    return lo..<a.characters.index(lo, offsetBy: plain.distance(from: sr.lowerBound, to: sr.upperBound))
                }
                guard let whole = range(m.range), let inner = range(m.range(at: 1)) else { continue }
                apply(&a, whole, inner)
            }
        }
        let raised = style.swiftUI(round(size * 0.72)), lift = round(size * 0.35)
        // One replaceSubrange per match: indices don't survive a second mutation.
        func raisedLabel(_ a: AttributedString, _ label: Range<AttributedString.Index>) -> AttributedString {
            var piece = AttributedString(a[label])
            piece.font = raised
            piece.baselineOffset = lift
            piece.foregroundColor = .accentColor
            return piece
        }
        rework(Styler.mark) { a, whole, inner in
            var piece = AttributedString(a[inner])
            piece.backgroundColor = Color.yellow.opacity(0.4)
            a.replaceSubrange(whole, with: piece)
        }
        rework(Styler.footnoteDef) { a, whole, label in // "[^1]: text" → a raised 1, then the text
            a.replaceSubrange(whole, with: raisedLabel(a, label) + AttributedString(" "))
        }
        rework(Styler.footnoteRef) { a, whole, label in a.replaceSubrange(whole, with: raisedLabel(a, label)) }
        rework(MD.dueRegex) { a, whole, _ in // due dates in their urgency's color
            guard let d = MD.due(String(a[whole].characters)) else { return }
            a[whole].foregroundColor = Color(nsColor: Due.of(d.date, hasTime: d.hasTime, done: done).color)
        }
        for term in highlight where !term.isEmpty { each(term) { a, r in a[r].backgroundColor = Color.yellow.opacity(0.45) } }
        return Text(a)
    }
}

