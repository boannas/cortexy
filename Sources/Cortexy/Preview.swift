import AppKit
import SwiftUI

/// What the preview shows: a path, its last level on show. A folder lists what's inside; clicking a subfolder
/// goes into it, so any depth is reachable in the one card. A note shows in full, laid out like the editor.
@Observable final class PreviewModel {
    enum Column: Hashable {
        case folder(UUID), archive, upcoming, note(UUID)
        case version(UUID, Int) // a note's kept version, by its place in the history

        var isText: Bool { switch self { case .note, .version: true; default: false } }
    }
    var columns: [Column] = []
    var peek: UUID?            // a note in the folder on show, rested on: its text in a second card beside
    var peekCard: CGRect = .zero
    var card: CGRect = .zero // the card, in its clear window (top-left origin): springs between places and sizes
    var shown = false        // faded in
}

/// The preview beside the panel: one card of one size, level with what was hovered. Only what it shows changes;
/// a folder's subfolders open inside it (the path bar goes back), and resting on one of its notes shows that
/// note in a second card of the same size beside it. It goes once the pointer has left what was hovered and
/// the cards. Clicking a note's text (or ↗) opens it in the panel.
/// (Sized to what it showed, with a column per level, it grew and shrank about under the pointer.)
final class PreviewController: NSObject {
    let nav: Nav
    let model = PreviewModel()
    private let window: NSPanel
    private var pending: DispatchWorkItem?
    private var peekPending: DispatchWorkItem?
    private var source: NSRect = .zero // what was hovered, on screen
    private var timer: Timer?
    private var outside = 0            // timer ticks with the pointer away

    static let height: CGFloat = 380 // every card's, whatever it shows
    static let pathBar: CGFloat = 30

    init(nav: Nav) {
        self.nav = nav
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false // the card draws its own; a window shadow wouldn't follow it as it springs
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        // The window never becomes key (the panel keeps focus), so every click is a "first" click: it must act.
        let host = FirstMouseHostingView(rootView: PreviewCard(controller: self))
        host.sizingOptions = [] // we size the window
        window.contentView = NSView.container(for: host) // SwiftUI must not manage the window's size
        self.host = host
        window.ignoresMouseEvents = true // clear until the pointer is over the card (updateHitTesting)
    }

    private var host: NSView?
    private var quietUntil = Date.distantPast

    var acceptsFirstClick: Bool { host?.acceptsFirstMouse(for: nil) == true }

    /// The list is being scrolled or swiped: no preview while it is, and one showing goes.
    func scrolled() {
        quietUntil = Date().addingTimeInterval(0.7)
        peekPending?.cancel()
        let was = hovered
        if isShowing { hide() }
        pending?.cancel()
        // The pointer may rest on a row when the scrolling stops, with no new hover event to say so.
        if let was { hovered = was; arm(was.column, after: 0.15) }
    }

    /// Only the card takes clicks; the rest of the strip beside the panel lets them through to what's under it.
    func updateHitTesting(_ p: NSPoint) {
        window.ignoresMouseEvents = !(model.shown && cards.contains { $0.insetBy(dx: -2, dy: -2).contains(p) })
    }

    var isShowing: Bool { model.shown }
    func contains(_ p: NSPoint) -> Bool { isShowing && cards.contains { NSMouseInRect(p, $0.insetBy(dx: -8, dy: -8), false) } }

    /// Where the card is on screen. The window around it is a clear strip beside the panel that never moves
    /// or resizes while it shows; the card moves inside it.
    var cardRect: NSRect { onScreen(model.card) }
    var peekRect: NSRect? { model.peek == nil ? nil : onScreen(model.peekCard) }
    private var cards: [NSRect] { [cardRect] + (peekRect.map { [$0] } ?? []) }
    private func onScreen(_ c: CGRect) -> NSRect {
        let w = window.frame
        return NSRect(x: w.minX + c.minX, y: w.maxY - c.maxY, width: c.width, height: c.height)
    }

    // MARK: From the panel

    /// A note card or folder row was hovered (`rect`: it in the panel's top-left coordinates).
    /// Where the pointer rests is remembered, and the preview is tried for it until it shows or the pointer
    /// leaves (see `attempt`). Hover events used to be acted on once and dropped: one that came while the list
    /// had just been scrolled, or a row's exit arriving after the next row's entry, left a row with no preview
    /// until the pointer went off it and back.
    func hover(_ column: PreviewModel.Column, inside: Bool, rect: CGRect) {
        guard inside else {
            if hovered?.column == column { hovered = nil } // (never one that came after: exits can arrive late)
            return
        }
        guard let panel = PanelController.shared?.panel, let content = panel.contentView else { return }
        let at = panel.convertToScreen(NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height))
        hovered = (column, at)
        if model.shown, model.columns.first == column { // already on show (or fading out: shown again)
            source = at
            pending?.cancel()
            pending = nil
            return
        }
        arm(column)
    }

    /// What the pointer is resting on now, on screen.
    private var hovered: (column: PreviewModel.Column, rect: NSRect)?

    /// Where the pointer is (tests say where, so they don't depend on a real hand).
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }

    /// A short rest before the first one, so passing over rows doesn't flash windows. One showing switches
    /// after a rest too: on the way to it the pointer crosses other rows (a folder's subfolders under it),
    /// and switching to each one it passed made the card jump and show the wrong folder.
    private func arm(_ column: PreviewModel.Column, after wait: Double? = nil) {
        pending?.cancel()
        let delay = Prefs.number(Prefs.previewDelay)
        let work = DispatchWorkItem { [weak self] in self?.attempt(column) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wait ?? (isShowing ? min(0.3, delay) : delay)), execute: work)
    }

    /// The rest is over: show it if the pointer is still on it; while the list is being scrolled or an item
    /// dragged, look again soon instead of giving up.
    private func attempt(_ column: PreviewModel.Column) {
        pending = nil
        guard let h = hovered, h.column == column, UserDefaults.standard.bool(forKey: Prefs.hoverPreview),
              let c = PanelController.shared, c.shown, NSMouseInRect(pointer(), h.rect, false) else { return }
        if model.shown, model.columns.first == column { return }
        if nav.dragging != nil || Date() < quietUntil { return arm(column, after: 0.15) }
        show(column, from: h.rect)
    }

    func hover(_ id: UUID, inside: Bool, rect: CGRect) { hover(.note(id), inside: inside, rect: rect) }

    func hide(keepingHover: Bool = false) {
        if !keepingHover {
            pending?.cancel()
            pending = nil
            hovered = nil
        }
        peekPending?.cancel()
        timer?.invalidate()
        timer = nil
        guard model.shown else {
            model.columns = []
            window.orderOut(nil)
            return
        }
        withAnimation(Motion.card) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in // once it has faded
            guard let self, !self.model.shown else { return }
            self.model.columns = []
            self.model.peek = nil
            self.window.orderOut(nil)
        }
    }

    private func show(_ column: PreviewModel.Column, from at: NSRect) {
        guard let c = PanelController.shared, c.shown, nav.dragging == nil, Date() >= quietUntil, NSMouseInRect(pointer(), at, false) else { return }
        source = at
        let first = !model.shown
        place(animated: !first) // level with what was hovered; its size never changes
        peekPending?.cancel()
        model.peek = nil
        model.columns = [column]
        window.orderFrontRegardless()
        if first { DispatchQueue.main.async { [self] in
            guard !model.columns.isEmpty else { return } // hidden again before it got to show
            withAnimation(Motion.card) { model.shown = true }
        } }
        outside = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Hides once the pointer has been away from the hovered row, the cards, and the stretch between them (the
    /// card can sit higher than the row near the screen's bottom) for a moment.
    private func tick() {
        let p = pointer()
        // On the way to another row (about to take over) it stays until that does.
        let onNext = hovered.map { NSMouseInRect(p, $0.rect, false) } ?? false
        let near = onNext || cards.reduce(source) { $0.union($1) }.insetBy(dx: -6, dy: -6).contains(p)
        let away = !near || nav.dragging != nil || PanelController.shared?.shown != true
        outside = away ? outside + 1 : 0
        // Only the card goes: the row the pointer has moved to keeps its turn (hiding everything dropped it, and
        // moving fast to a row far from the last one never brought its preview).
        if Double(outside) * 0.1 >= max(0.1, Prefs.number(Prefs.previewHideDelay)) { hide(keepingHover: true) }
    }

    // MARK: Inside the window

    /// Goes into `column` (a subfolder clicked) from level `index`: what's shown is the path's last level.
    func push(_ column: PreviewModel.Column, after index: Int) {
        guard model.columns.indices.contains(index) else { return }
        peekPending?.cancel()
        model.peek = nil
        model.columns = Array(model.columns.prefix(index + 1)) + [column]
    }

    /// Back up to level `index` (from the path bar).
    func pop(to index: Int) {
        guard model.columns.indices.contains(index) else { return }
        peekPending?.cancel()
        model.peek = nil
        model.columns = Array(model.columns.prefix(index + 1))
    }

    /// A note row in the folder on show: resting on it shows the note in the card beside (passing over doesn't).
    func hoverNote(_ column: PreviewModel.Column, inside: Bool) {
        peekPending?.cancel()
        guard inside, case .note(let id) = column, model.peekCard != .zero else { return }
        let work = DispatchWorkItem { [weak self] in self?.model.peek = id }
        peekPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func openInPanel(_ column: PreviewModel.Column) {
        hide()
        nav.search = ""
        switch column {
        case .folder(let f): nav.route = .folder(f)
        case .archive: nav.route = .archive
        case .upcoming: nav.route = .upcoming
        case .note(let id), .version(let id, _): if let f = nav.store.folderOf(id) { nav.route = .note(f.id, id) }
        }
        PanelController.shared?.panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Contents and size

    struct Row: Identifiable {
        let id: String
        let column: PreviewModel.Column
        let title: String
        var detail = ""
        var folder: Folder?
        var count: Int?
        var symbol = "note.text"
        var isFolder: Bool { if case .note = column { false } else { true } }
    }

    func title(_ c: PreviewModel.Column) -> String {
        switch c {
        case .archive: "Archive"
        case .upcoming: "Upcoming"
        case .folder(let f): nav.store.folder(f)?.name ?? ""
        case .note(let id): nav.store.folderOf(id).flatMap { nav.store.note($0.id, id)?.title } ?? ""
        case .version(_, _): "Earlier version"
        }
    }

    /// What a text column shows: the note, or one of its kept versions.
    func content(_ c: PreviewModel.Column) -> Note? {
        switch c {
        case .note(let id):
            guard var n = nav.store.folderOf(id).flatMap({ nav.store.note($0.id, id) }) else { return nil }
            if n.lock != nil { n.text = "🔒 **\(n.title)** is locked." } // never previewed, even while unlocked
            return n
        case .version(let id, let i):
            let versions = nav.store.history(id)
            guard versions.indices.contains(i), var n = content(.note(id)) else { return nil }
            n.text = versions[i].text
            return n
        default: return nil
        }
    }

    /// A folder column's rows: subfolders, then notes (a smart folder's matches; Archive's archived notes).
    func rows(_ c: PreviewModel.Column) -> [Row] {
        func note(_ n: Note) -> Row {
            let rest = MD.lines(Self.head(n.text, lines: 16).text).drop { $0 == .blank }.dropFirst().first { $0 != .blank && $0 != .fence }
            let detail = (rest.map(Self.plain) ?? "").replacingOccurrences(of: #"[*_`~]|==|\[\[|\]\]"#, with: "", options: .regularExpression)
            return Row(id: n.id.uuidString, column: .note(n.id), title: n.title, detail: detail)
        }
        switch c {
        case .note, .version: return []
        case .archive: return nav.archivedNotes.map { note($0.1) }
        case .upcoming: // each task with a date; resting on one previews its note
            return nav.dueTasks.filter { !$0.done }.map { t in
                Row(id: t.id, column: .note(t.nid), title: t.text.isEmpty ? "Untitled task" : t.text,
                    detail: Nav.show(t.date, time: t.hasTime) + " · " + (nav.store.note(t.fid, t.nid)?.title ?? ""), symbol: "calendar")
            }
        case .folder(let fid):
            guard let f = nav.store.folder(fid), !nav.store.lockedAway(fid) else { return [] } // a locked folder shows nothing
            if let q = f.query { return nav.hits(Query(q)).map { note($0.1) } }
            let folders = nav.store.subfolders(fid).pinnedFirst.map { s in
                Row(id: s.id.uuidString, column: .folder(s.id), title: s.name, folder: s,
                    count: s.query.map { nav.hits(Query($0)).count } ?? nav.store.noteCount(s.id))
            }
            return folders + f.shownNotes.map(note)
        }
    }

    private static func plain(_ line: MD.Line) -> String {
        switch line {
        case .heading(_, let s), .task(_, let s), .bullet(let s), .numbered(_, let s), .quote(let s), .text(let s), .code(let s): s
        case .image(let alt, _): alt.isEmpty ? "Image" : alt
        case .file(let name, _): name
        case .blank, .fence: ""
        }
    }

    /// One width whatever it shows: 300 pt unless set in Settings.
    var cardWidth: CGFloat {
        let chosen = Prefs.number(Prefs.previewWidth)
        let wanted = chosen > 0 ? chosen : 300
        return min(wanted, max(300, room)) // never wider than the space beside the panel, or its text is cut off
    }

    /// The screen's width beside the panel, where the preview goes.
    private var room: CGFloat {
        guard let c = PanelController.shared, let screen = c.panel.screen else { return .infinity }
        let visible = c.visible(screen).insetBy(dx: 8, dy: 8)
        return Prefs.isLeft ? visible.maxX - c.panel.frame.maxX - 8 : c.panel.frame.minX - 8 - visible.minX
    }

    /// The first `lines` lines of `text`, and whether that's all of it.
    static func head(_ text: String, lines: Int) -> (text: String, whole: Bool) {
        let ns = text as NSString
        var end = 0
        for _ in 0..<lines {
            let nl = ns.range(of: "\n", options: .literal, range: NSRange(location: end, length: ns.length - end))
            guard nl.location != NSNotFound else { return (text, true) }
            end = nl.location + 1
        }
        return end >= ns.length ? (text, true) : (ns.substring(to: end), false)
    }
    static let shownLines = 200 // a preview shows this much of a long note (opening it shows the rest)

    /// Beside the panel, its top level with what was hovered (moved up only as far as the screen's bottom needs),
    /// `cardWidth` × `height` whatever it shows. The note card beside goes on its far side, when there's room.
    private func place(animated: Bool) {
        guard let c = PanelController.shared, let screen = c.panel.screen else { return }
        let visible = c.visible(screen).insetBy(dx: 8, dy: 8)
        let width = cardWidth, height = min(visible.height, Self.height)
        let x = Prefs.isLeft ? c.panel.frame.maxX + 8 : c.panel.frame.minX - 8 - width
        let card = NSRect(x: x, y: max(visible.minY, min(source.maxY, visible.maxY) - height), width: width, height: height)
        // The clear window: the whole strip beside the panel; only the cards in it take clicks.
        let strip = Prefs.isLeft ? NSRect(x: c.panel.frame.maxX + 8, y: visible.minY, width: visible.maxX - c.panel.frame.maxX - 8, height: visible.height)
                                 : NSRect(x: visible.minX, y: visible.minY, width: c.panel.frame.minX - 8 - visible.minX, height: visible.height)
        if window.frame != strip { window.setFrame(strip, display: false) }
        let local = CGRect(x: card.minX - strip.minX, y: strip.maxY - card.maxY, width: card.width, height: card.height)
        let beside = local.offsetBy(dx: Prefs.isLeft ? width + 8 : -(width + 8), dy: 0)
        let peek = CGRect(origin: .zero, size: strip.size).contains(beside) ? beside : .zero
        if animated { withAnimation(Motion.standard) { model.card = local; model.peekCard = peek } } else { model.card = local; model.peekCard = peek }
    }

    // MARK: Note text

    static func makeText() -> MarkdownTextView {
        let text = MarkdownTextView(usingTextLayoutManager: false) // TextKit 1, like the editor
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.previewing = true
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        text.minSize = .zero // without these the text view stays 0 pt tall and the preview looks empty
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        return text
    }

    static func configure(_ text: MarkdownTextView, _ n: Note, store: Store) {
        var style = Themes.shared.textStyle
        style.code = n.code
        text.style = style
        text.resolve = { [store] in store.resolve($0) }
    }
}

// MARK: Views

/// The preview's cards in their clear window, fading in and out beside the panel.
struct PreviewCard: View {
    let controller: PreviewController

    var body: some View {
        let m = controller.model
        ZStack(alignment: .topLeading) {
            PreviewBrowser(controller: controller)
                .frame(width: m.card.width, height: m.card.height)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                .offset(x: m.card.minX, y: m.card.minY)
            if let id = m.peek {
                NoteColumn(controller: controller, column: .note(id))
                    .id(id)
                    .previewCard()
                    .frame(width: m.peekCard.width, height: m.peekCard.height)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                    .offset(x: m.peekCard.minX, y: m.peekCard.minY)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: m.peek)
        .opacity(m.shown ? 1 : 0) // a fade only: scaling re-placed its text view every frame
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(Rectangle()) // nothing of it outside the strip
    }
}

extension View {
    /// A preview card's glass, in the panel's look.
    func previewCard() -> some View {
        let theme = Themes.shared.current, radius = Themes.shared.look.cornerRadius + 8
        return background(theme.panelColor ?? .clear, in: .rect(cornerRadius: radius))
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
            .tint(theme.accentColor)
            .fontDesign((Themes.shared.design ?? .standard).swiftUI)
            .environment(\.controlActiveState, .key)
    }
}

struct PreviewBrowser: View {
    let controller: PreviewController

    var body: some View {
        let path = controller.model.columns
        VStack(spacing: 0) {
            if path.count > 1 { PathBar(controller: controller, path: path) }
            ZStack {
                // The path's last level fills the card; going elsewhere fades it over, the card stays put.
                if let column = path.last {
                    Group {
                        if column.isText { NoteColumn(controller: controller, column: column) }
                        else { FolderColumn(controller: controller, index: path.count - 1, column: column) }
                    }
                    .id(path)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Motion.quick, value: path)
        }
        .previewCard()
    }
}

/// A folder's contents. Click a folder to look inside (in the same card); click a note to open it in the panel.
struct FolderColumn: View {
    let controller: PreviewController
    let index: Int
    let column: PreviewModel.Column

    var body: some View {
        let rows = controller.rows(column)
        let model = controller.model
        let next = model.columns.indices.contains(index + 1) ? model.columns[index + 1] : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(controller.title(column)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(rows.count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                MiniButton(symbol: "arrow.up.forward.app", help: "Open in the Panel") { controller.openInPanel(column) }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            if rows.isEmpty {
                Text("Empty").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        PreviewRowView(row: row, selected: next == row.column || (model.peek.map { .note($0) == row.column } ?? false))
                            // A folder opens in this card, a note in the panel; resting on a note shows it beside.
                            .onTapGesture { row.isFolder ? controller.push(row.column, after: index) : controller.openInPanel(row.column) }
                            .onHover { if !row.isFolder { controller.hoverNote(row.column, inside: $0) } }
                    }
                }
                .padding(6)
            }
        }
    }
}

struct PreviewRowView: View {
    static let height: CGFloat = 42 // fixed, so the card can be sized to its rows exactly
    let row: PreviewController.Row
    let selected: Bool
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let f = row.folder { FolderIcon(folder: f) } else { Image(systemName: row.symbol).foregroundStyle(.secondary) }
            }
            .font(.system(size: 14))
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 13)).lineLimit(1)
                if !row.detail.isEmpty { Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let count = row.count { Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            if row.isFolder {
                Image(systemName: Prefs.isLeft ? "chevron.right" : "chevron.left").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.cortexyAccent.opacity(0.22) : .primary.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(row.isFolder ? "Click to look inside" : "Rest here to read it, click to open it")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(row.isFolder ? "Looks inside" : "Opens the note")
    }
}

/// Inside a subfolder: the folders above it, to step back to.
struct PathBar: View {
    let controller: PreviewController
    let path: [PreviewModel.Column] // as drawn: the live one empties as the card fades out (0..<-1 crashed)

    var body: some View {
        let above = max(0, path.count - 1)
        HStack(spacing: 4) {
            MiniButton(symbol: "chevron.left", help: "Up one level") { controller.pop(to: above - 1) }
            ForEach(0..<above, id: \.self) { i in
                if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                Button(controller.title(path[i])) { controller.pop(to: i) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: PreviewController.pathBar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A note in full, read-only and laid out like the editor. Clicking its text opens it in the panel.
struct NoteColumn: NSViewRepresentable {
    let controller: PreviewController
    let column: PreviewModel.Column

    func makeNSView(context: Context) -> NSScrollView {
        let text = PreviewController.makeText()
        text.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? MarkdownTextView, context.coordinator.shown != column,
              let n = controller.content(column) else { return }
        context.coordinator.shown = column
        PreviewController.configure(text, n, store: controller.nav.store)
        text.onPreviewClick = { [controller, column] in controller.openInPanel(column) }
        text.frame = NSRect(x: 0, y: 0, width: controller.cardWidth, height: 1)
        let head = PreviewController.head(n.text, lines: PreviewController.shownLines)
        text.load(head.whole ? head.text : head.text + "\n…")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.sizeToFit()
        text.scroll(.zero)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: PreviewController
        var shown: PreviewModel.Column?
        init(controller: PreviewController) { self.controller = controller }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "cortexy" else { return false }
            controller.hide()
            return controller.nav.openLink(url)
        }
    }
}
