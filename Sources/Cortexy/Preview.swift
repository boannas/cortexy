import AppKit
import SwiftUI

/// What the preview shows: a path, its last level on show. A folder lists what's inside; clicking a subfolder
/// goes into it, so any depth is reachable in the one card. A note shows in full, laid out like the editor.
@Observable final class PreviewModel {
    enum Item: Hashable {
        case folder(UUID), archive, upcoming, note(UUID)
        case version(UUID, Int) // a note's kept version, by its place in the history
        case web(URL)           // a link in a note: its page's title, summary and picture
        case day(Date)          // a day in the calendar: its daily note and the tasks due then

        var isText: Bool { switch self { case .note, .version: true; default: false } }
    }
    var path: [Item] = []       // the hovered thing, then each subfolder gone into; the last one shows
    var peek: UUID?             // a note in the folder on show, rested on: its text in a second card beside
    var card: CGRect = .zero    // the card, in its clear window (top-left origin); its size never changes
    var peekCard: CGRect = .zero // where the second card goes (.zero: no room for it)
    var shown = false           // faded in
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
        window.hasShadow = false // the card draws its own; a window shadow would outline the whole clear strip
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.sharingType = Prefs.sharing
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
        if let was { hovered = was; arm(was.item, after: 0.15) }
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
    func hover(_ item: PreviewModel.Item, inside: Bool, rect: CGRect) {
        guard inside else {
            if hovered?.item == item { hovered = nil } // (never one that came after: exits can arrive late)
            return
        }
        guard let panel = PanelController.shared?.panel, let content = panel.contentView else { return }
        let at = panel.convertToScreen(NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height))
        hovered = (item, at)
        if model.shown, model.path.first == item { // already on show (or fading out: shown again)
            source = at
            pending?.cancel()
            pending = nil
            return
        }
        arm(item)
    }

    /// What the pointer is resting on now, on screen.
    private var hovered: (item: PreviewModel.Item, rect: NSRect)?

    /// Where the pointer is (tests say where, so they don't depend on a real hand).
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }

    /// A short rest before the first one, so passing over rows doesn't flash windows. One showing switches
    /// after a rest too: on the way to it the pointer crosses other rows (a folder's subfolders under it),
    /// and switching to each one it passed made the card jump and show the wrong folder.
    private func arm(_ item: PreviewModel.Item, after wait: Double? = nil) {
        pending?.cancel()
        let delay = Prefs.number(Prefs.previewDelay)
        let work = DispatchWorkItem { [weak self] in self?.attempt(item) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wait ?? (isShowing ? min(0.3, delay) : delay)), execute: work)
    }

    /// The rest is over: show it if the pointer is still on it; while the list is being scrolled or an item
    /// dragged, look again soon instead of giving up.
    private func attempt(_ item: PreviewModel.Item) {
        pending = nil
        guard let h = hovered, h.item == item, UserDefaults.standard.bool(forKey: Prefs.hoverPreview),
              let c = PanelController.shared, c.shown, NSMouseInRect(pointer(), h.rect, false) else { return }
        if model.shown, model.path.first == item { return }
        if nav.dragging != nil || Date() < quietUntil { return arm(item, after: 0.15) }
        show(item, from: h.rect)
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
            model.path = []
            window.orderOut(nil)
            return
        }
        withAnimation(Motion.card) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in // once it has faded
            guard let self, !self.model.shown else { return }
            self.model.path = []
            self.model.peek = nil
            self.window.orderOut(nil)
        }
    }

    private func show(_ item: PreviewModel.Item, from at: NSRect) {
        guard let c = PanelController.shared, c.shown, nav.dragging == nil, Date() >= quietUntil, NSMouseInRect(pointer(), at, false) else { return }
        source = at
        let first = !model.shown
        place(animated: !first) // level with what was hovered; its size never changes
        go(to: [item])
        window.orderFrontRegardless()
        if first { DispatchQueue.main.async { [self] in
            guard !model.path.isEmpty else { return } // hidden again before it got to show
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

    /// Goes into `item` (a subfolder clicked) from level `index` of the path: the path's last level is what shows.
    func push(_ item: PreviewModel.Item, after index: Int) {
        guard model.path.indices.contains(index) else { return }
        go(to: Array(model.path.prefix(index + 1)) + [item])
    }

    /// Back up to level `index` (from the path bar).
    func pop(to index: Int) {
        guard model.path.indices.contains(index) else { return }
        go(to: Array(model.path.prefix(index + 1)))
    }

    /// Somewhere else in the card: the note beside it (of the old place) goes.
    private func go(to path: [PreviewModel.Item]) {
        peekPending?.cancel()
        model.peek = nil
        model.path = path
    }

    /// A note row in the folder on show: resting on it shows the note in the card beside (passing over doesn't).
    func hoverNote(_ item: PreviewModel.Item, inside: Bool) {
        peekPending?.cancel()
        guard inside, case .note(let id) = item, model.peekCard != .zero else { return }
        let work = DispatchWorkItem { [weak self] in self?.model.peek = id }
        peekPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func openInPanel(_ item: PreviewModel.Item) {
        hide()
        nav.search = ""
        switch item {
        case .folder(let f): nav.route = .folder(f)
        case .archive: nav.route = .archive
        case .upcoming: nav.route = .upcoming
        case .note(let id), .version(let id, _): if let f = nav.store.folderOf(id) { nav.route = .note(f.id, id) }
        case .web(let url): NSWorkspace.shared.open(url); return
        case .day(let d): nav.calendarShown = false; nav.openPeriodic(.day, date: d)
        }
        PanelController.shared?.panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Contents

    struct Row: Identifiable {
        let id: String
        let item: PreviewModel.Item
        let title: String
        var detail = ""
        var folder: Folder?
        var count: Int?
        var symbol = "note.text"
        var isFolder: Bool { if case .note = item { false } else { true } }
    }

    func title(_ c: PreviewModel.Item) -> String {
        switch c {
        case .archive: "Archive"
        case .upcoming: "Upcoming"
        case .folder(let f): nav.store.folder(f)?.name ?? ""
        case .note(let id): nav.store.folderOf(id).flatMap { nav.store.note($0.id, id)?.title } ?? ""
        case .version(_, _): "Earlier version"
        case .web(let url): url.host ?? url.absoluteString
        case .day(let d): Nav.show(d, time: false)
        }
    }

    /// What a note page shows: the note, or one of its kept versions.
    func content(_ c: PreviewModel.Item) -> Note? {
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

    /// A folder page's rows: subfolders, then notes (a smart folder's matches; Archive's archived notes).
    func rows(_ c: PreviewModel.Item) -> [Row] {
        func note(_ n: Note) -> Row {
            let rest = MD.lines(MD.head(n.text, lines: 16).text).filter { !$0.isMeta }.drop { $0 == .blank }.dropFirst().first { $0 != .blank && $0 != .fence }
            let detail = (rest.map(Self.plain) ?? "").replacingOccurrences(of: #"[*_`~]|==|\[\[|\]\]"#, with: "", options: .regularExpression)
            return Row(id: n.id.uuidString, item: .note(n.id), title: n.title, detail: detail)
        }
        switch c {
        case .note, .version, .web: return []
        case .archive: return nav.archivedNotes.map { note($0.1) }
        case .day(let d): // the day's note, then its tasks (with their time); resting on one shows its note beside
            let cal = Calendar.current
            let daily = nav.dailyNotes()[Nav.periodTitle(.day, d)].map { id in
                [Row(id: id.uuidString, item: .note(id), title: nav.store.folderOf(id).flatMap { nav.store.note($0.id, id)?.title } ?? "", detail: "This day's note", symbol: "doc.text")]
            } ?? []
            let tasks = nav.dueTasks.filter { !$0.done && cal.isDate($0.date, inSameDayAs: d) }.map { t in
                Row(id: t.id, item: .note(t.nid), title: t.text.isEmpty ? "Untitled task" : t.text,
                    detail: (t.hasTime ? t.date.formatted(date: .omitted, time: .shortened) + " · " : "") + (nav.store.note(t.fid, t.nid)?.title ?? ""),
                    symbol: t.due == .overdue ? "exclamationmark.circle" : "circle")
            }
            return daily + tasks
        case .upcoming: // each task with a date; resting on one previews its note
            return nav.dueTasks.filter { !$0.done }.map { t in
                Row(id: t.id, item: .note(t.nid), title: t.text.isEmpty ? "Untitled task" : t.text,
                    detail: Nav.show(t.date, time: t.hasTime) + " · " + (nav.store.note(t.fid, t.nid)?.title ?? ""), symbol: "calendar")
            }
        case .folder(let fid):
            guard let f = nav.store.folder(fid), !nav.store.lockedAway(fid) else { return [] } // a locked folder shows nothing
            if let q = f.query { return nav.hits(Query(q)).map { note($0.1) } }
            let folders = nav.store.subfolders(fid).pinnedFirst.map { s in
                Row(id: s.id.uuidString, item: .folder(s.id), title: s.name, folder: s,
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
        case .blank, .fence, .meta: ""
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
        text.store = store
        text.noteID = n.id
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
                NotePage(controller: controller, item: .note(id))
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
        let path = controller.model.path
        VStack(spacing: 0) {
            if path.count > 1 { PathBar(controller: controller, path: path) }
            ZStack {
                // The path's last level fills the card; going elsewhere fades it over, the card stays put.
                if let item = path.last {
                    Group {
                        if case .version(let id, let i) = item { DiffPage(controller: controller, nid: id, index: i) }
                        else if item.isText { NotePage(controller: controller, item: item) }
                        else if case .web(let url) = item { WebPage(controller: controller, url: url) }
                        else { FolderPage(controller: controller, index: path.count - 1, item: item) }
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
struct FolderPage: View {
    let controller: PreviewController
    let index: Int
    let item: PreviewModel.Item

    var body: some View {
        let rows = controller.rows(item)
        let peek = controller.model.peek.map(PreviewModel.Item.note) // the note shown beside: its row is marked
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(controller.title(item)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(rows.count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                MiniButton(symbol: "arrow.up.forward.app", help: "Open in the Panel") { controller.openInPanel(item) }
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
                        PreviewRowView(row: row, selected: row.item == peek)
                            // A folder opens in this card, a note in the panel; resting on a note shows it beside.
                            .onTapGesture { row.isFolder ? controller.push(row.item, after: index) : controller.openInPanel(row.item) }
                            .onHover { if !row.isFolder { controller.hoverNote(row.item, inside: $0) } }
                    }
                }
                .padding(6)
            }
        }
    }
}

struct PreviewRowView: View {
    static let height: CGFloat = 42
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

/// A kept version against the note now: lines since added in green, lines since removed in red, the rest plain.
struct DiffPage: View {
    let controller: PreviewController
    let nid: UUID
    let index: Int

    var body: some View {
        let versions = controller.nav.store.history(nid)
        let old = versions.indices.contains(index) ? versions[index].text : ""
        let now = controller.nav.store.folderOf(nid).flatMap { controller.nav.store.note($0.id, nid)?.text } ?? ""
        let lines = Array(MD.diffLines(old, now).enumerated())
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(lines, id: \.offset) { _, l in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(l.0 == .added ? "+" : l.0 == .removed ? "−" : " ").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(l.1.isEmpty ? " " : l.1).font(.system(size: 12)).strikethrough(l.0 == .removed).textSelection(.enabled)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(l.0 == .added ? Color.green.opacity(0.16) : l.0 == .removed ? Color.red.opacity(0.14) : .clear)
                }
            }
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            Text("vs. now").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2).background(.thinMaterial, in: Capsule()).padding(8)
        }
    }
}

/// A web link's page: its picture, title and summary (asked for once; nothing is shown from the page itself).
/// Click to open it in the browser.
struct WebPage: View {
    let controller: PreviewController
    let url: URL

    var body: some View {
        let info = LinkPreviews.shared.found[url]
        VStack(alignment: .leading, spacing: 10) {
            if let image = info?.image {
                AsyncImage(url: image) { $0.resizable().scaledToFill() } placeholder: { Color.primary.opacity(0.05) }
                    .frame(maxWidth: .infinity).frame(height: 150).clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(info?.title.isEmpty == false ? info!.title : url.host ?? url.absoluteString)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(3)
                if let s = info?.summary, !s.isEmpty { Text(s).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(6) }
                if info == nil { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Label(url.host ?? url.absoluteString, systemImage: "safari").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.top, info?.image == nil ? 14 : 0)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { controller.openInPanel(.web(url)) }
        .help(url.absoluteString)
        .task(id: url) { _ = await LinkPreviews.shared.info(url) }
    }
}

/// Inside a subfolder: the folders above it, to step back to.
struct PathBar: View {
    let controller: PreviewController
    let path: [PreviewModel.Item] // as drawn: the live one empties as the card fades out (0..<-1 crashed)

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
struct NotePage: NSViewRepresentable {
    let controller: PreviewController
    let item: PreviewModel.Item

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
        guard let text = scroll.documentView as? MarkdownTextView, context.coordinator.shown != item,
              let n = controller.content(item) else { return }
        context.coordinator.shown = item
        PreviewController.configure(text, n, store: controller.nav.store)
        text.onPreviewClick = { [controller, item] in controller.openInPanel(item) }
        text.frame = NSRect(x: 0, y: 0, width: controller.cardWidth, height: 1)
        let head = MD.head(n.text, lines: PreviewController.shownLines)
        text.load(head.whole ? head.text : head.text + "\n…")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.sizeToFit()
        text.scroll(.zero)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: PreviewController
        var shown: PreviewModel.Item?
        init(controller: PreviewController) { self.controller = controller }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "cortexy" else { return false }
            controller.hide()
            return controller.nav.openLink(url)
        }
    }
}
