import AppKit
import SwiftUI

/// Notes as a graph: a node per note (and per #tag if asked), an edge per [[link]] (and per tag used). Laid out by
/// a small force simulation: nodes push apart, links pull together, everything drifts to the middle; it stops
/// once still.
// ponytail: all-pairs repulsion (O(n²) a frame); fine for hundreds of notes, use a quadtree (Barnes-Hut) past that.
final class GraphModel {
    struct Node {
        let id: String   // a note's UUID, or "#tag"
        let title: String
        let note: UUID?
        let color: NoteColor
        var group = ""   // its folder, or its first tag: what "Color by" groups it by
        var p: CGPoint
        var v = CGVector.zero
        var degree = 0
        var held = false // being dragged: the simulation leaves it alone
    }

    private(set) var nodes: [Node] = []
    private(set) var edges: [(Int, Int)] = []
    private(set) var neighbors: [Set<Int>] = []
    private(set) var settled = false
    private var calm = 0
    var edits = 0 // counts note edits, so a burst of typing rebuilds once, after it

    /// From the notes. Nodes already there keep their place, so the picture doesn't jump after an edit
    /// (and an edit that changes no link leaves it resting).
    func rebuild(_ store: Store, tags: Bool, unlinked: Bool, around: UUID?, depth: Int = 2, groupBy: GraphState.ColorBy = .note) {
        let old = Dictionary(nodes.map { ($0.id, $0.p) }) { a, _ in a }
        let oldLinks = Set(edges.map { [nodes[$0.0].id, nodes[$0.1].id].sorted() })
        let notes = store.liveFolders.flatMap { f in f.notes.filter { !$0.archived }.map { (f.id, $0) } }
        // [[Title]] means the newest note with that title (or alias); [[Title#Heading]] that note too.
        var byTitle: [String: Note] = [:]
        for (_, n) in notes {
            let key = n.title.lowercased()
            if byTitle[key].map({ $0.modified < n.modified }) ?? true { byTitle[key] = n }
        }
        for (_, n) in notes { for a in MD.aliases(n.text) where byTitle[a.lowercased()] == nil { byTitle[a.lowercased()] = n } } // titles first
        func target(_ t: String) -> Note? { byTitle[t.lowercased()] ?? (t.contains("#") ? byTitle[MD.splitLink(t).title.lowercased()] : nil) }
        var list = notes.map { f, n in
            Node(id: n.id.uuidString, title: n.title, note: n.id, color: n.color,
                 group: groupBy == .folder ? store.folder(f)?.name ?? "" : groupBy == .tag ? (MD.tags(n.text).first.map { "#" + $0 } ?? "") : "", p: .zero)
        }
        var index = Dictionary(list.enumerated().map { ($0.element.id, $0.offset) }) { a, _ in a }
        var pairs = Set<[Int]>()
        func link(_ a: Int, _ b: Int) { if a != b { pairs.insert([min(a, b), max(a, b)]) } }
        for (_, n) in notes where n.lock == nil {
            guard let from = index[n.id.uuidString] else { continue }
            for title in MD.wikiLinks(n.text) {
                if let target = target(title), let to = index[target.id.uuidString] { link(from, to) }
            }
            guard tags else { continue }
            for t in MD.tags(n.text) {
                let id = "#" + t
                if index[id] == nil {
                    index[id] = list.count
                    list.append(Node(id: id, title: id, note: nil, color: .none, p: .zero))
                }
                link(from, index[id]!)
            }
        }
        var near = Array(repeating: Set<Int>(), count: list.count)
        for p in pairs { near[p[0]].insert(p[1]); near[p[1]].insert(p[0]) }

        // What to keep: everything, or what's within `depth` links of one note; with or without unlinked notes.
        var keep = Set(list.indices)
        if let around, let start = index[around.uuidString] {
            var seen: Set<Int> = [start], frontier: Set<Int> = [start]
            for _ in 0..<depth {
                frontier = Set(frontier.flatMap { near[$0] }).subtracting(seen)
                seen.formUnion(frontier)
            }
            keep = seen
        }
        if !unlinked { keep = keep.filter { !near[$0].isEmpty || list[$0].note == around } }

        let kept = list.indices.filter(keep.contains)
        let renumber = Dictionary(kept.enumerated().map { ($0.element, $0.offset) }) { a, _ in a }
        nodes = kept.enumerated().map { i, k in
            var n = list[k]
            n.degree = near[k].count
            // New nodes start on a spiral (golden angle), so they spread out evenly and the same way every time.
            let angle = Double(i) * 2.39996, radius = 18 * sqrt(Double(i + 1))
            n.p = old[n.id] ?? CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            return n
        }
        edges = pairs.compactMap { p in renumber[p[0]].flatMap { a in renumber[p[1]].map { (a, $0) } } }
        neighbors = Array(repeating: [], count: nodes.count)
        for (a, b) in edges { neighbors[a].insert(b); neighbors[b].insert(a) }
        if Set(nodes.map(\.id)) != Set(old.keys) || Set(edges.map { [nodes[$0.0].id, nodes[$0.1].id].sorted() }) != oldLinks { wake() }
    }

    func wake() { settled = false; calm = 0 }

    /// One frame of the simulation. Returns true once everything has come to rest.
    @discardableResult func step() -> Bool {
        guard !settled, !nodes.isEmpty else { settled = true; return true }
        let count = nodes.count
        var force = [CGVector](repeating: .zero, count: count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                var dx = nodes[i].p.x - nodes[j].p.x, dy = nodes[i].p.y - nodes[j].p.y
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 { dx = 0.1 * CGFloat(i - j); dy = 0.1; d2 = 0.02 } // on top of each other
                let d = sqrt(d2), push = 1800 / max(d2, 25)
                force[i].dx += dx / d * push; force[i].dy += dy / d * push
                force[j].dx -= dx / d * push; force[j].dy -= dy / d * push
            }
        }
        for (a, b) in edges {
            let dx = nodes[b].p.x - nodes[a].p.x, dy = nodes[b].p.y - nodes[a].p.y
            let d = max(sqrt(dx * dx + dy * dy), 0.1), pull = 0.03 * (d - 70)
            force[a].dx += dx / d * pull; force[a].dy += dy / d * pull
            force[b].dx -= dx / d * pull; force[b].dy -= dy / d * pull
        }
        var fastest: CGFloat = 0
        for i in 0..<count where !nodes[i].held {
            let f = CGVector(dx: force[i].dx - nodes[i].p.x * 0.012, dy: force[i].dy - nodes[i].p.y * 0.012) // and toward the middle
            var v = CGVector(dx: (nodes[i].v.dx + f.dx) * 0.8, dy: (nodes[i].v.dy + f.dy) * 0.8)
            let speed = sqrt(v.dx * v.dx + v.dy * v.dy)
            if speed > 30 { v = CGVector(dx: v.dx / speed * 30, dy: v.dy / speed * 30) }
            nodes[i].v = v
            nodes[i].p.x += v.dx
            nodes[i].p.y += v.dy
            fastest = max(fastest, speed)
        }
        calm = fastest < 0.08 ? calm + 1 : 0
        settled = calm > 40
        return settled
    }

    /// Settles the layout without drawing (tests, and a first look that isn't a jumble).
    func run(_ frames: Int) { for _ in 0..<frames where !step() {} }

    static func radius(_ n: Node) -> CGFloat { 4 + min(10, sqrt(CGFloat(n.degree)) * 2.2) }

    /// The node under a point (graph coordinates), allowing a little slack around small dots.
    func node(at p: CGPoint, scale: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, n) in nodes.enumerated() {
            let d = hypot(n.p.x - p.x, n.p.y - p.y)
            if d <= Self.radius(n) + 6 / scale, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }

    func hold(_ i: Int, at p: CGPoint) {
        guard nodes.indices.contains(i) else { return }
        nodes[i].held = true
        nodes[i].p = p
        nodes[i].v = .zero
        wake()
    }

    func release(_ i: Int) {
        guard nodes.indices.contains(i) else { return }
        nodes[i].held = false
        wake()
    }

    /// The box around every node (graph coordinates), for Fit.
    var bounds: CGRect {
        guard let first = nodes.first else { return .zero }
        return nodes.reduce(CGRect(origin: first.p, size: .zero)) { $0.union(CGRect(origin: $1.p, size: .zero)) }
    }
}

/// What the graph window shows and how it's framed; shared with the window so the scroll wheel can zoom.
@Observable final class GraphState {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var focus: UUID?   // the note "Around This Note" centres on
    var local = false
    var tags = false
    var unlinked = true
    enum ColorBy: String, CaseIterable { case note = "Note Color", folder = "Folder", tag = "First Tag" }
    var colorBy = ColorBy.note
    var hover: Int?
    var frame = 0      // bumped to redraw while the simulation is resting
    var size = CGSize.zero    // the canvas
    var pointer = CGSize.zero // where the pointer is, from the canvas's middle (the scroll wheel zooms around it)
    var shown = false         // the window is open: only then does it follow edits

    /// Zooms by `factor` keeping the point under `at` (view coordinates, from the middle) in place.
    func zoom(_ factor: CGFloat, at p: CGSize = .zero) {
        let next = min(4, max(0.15, scale * factor)), real = next / scale
        offset = CGSize(width: p.width - (p.width - offset.width) * real, height: p.height - (p.height - offset.height) * real)
        scale = next
        frame += 1
    }

    /// Frames every node.
    func fit(_ b: CGRect) {
        guard size.width > 0 else { return }
        scale = min(2, max(0.15, min((size.width - 80) / max(b.width, 1), (size.height - 80) / max(b.height, 1))))
        offset = CGSize(width: -b.midX * scale, height: -b.midY * scale)
        frame += 1
    }
}

/// The graph's own window: resizable, floating beside the panel, never in the way of typing.
final class GraphWindow: NSObject {
    static let shared = GraphWindow()
    let state = GraphState()
    private var window: NSPanel?

    func show(nav: Nav, around note: UUID? = nil) {
        state.focus = note ?? { if case .note(_, let n) = nav.route { n } else { nil } }()
        state.local = note != nil
        if window == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            w.title = "Graph"
            w.titlebarAppearsTransparent = true
            w.level = .floating
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.minSize = NSSize(width: 420, height: 320)
            w.contentView = FirstMouseHostingView(rootView: GraphView(nav: nav, state: state))
            // The scroll wheel (two fingers on a trackpad) zooms around the pointer.
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [state] e in
                guard e.window === w else { return e }
                state.zoom(exp(-e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08)), at: state.pointer)
                return nil
            }
            if !w.setFrameUsingName("cortexy.graph"), let card = PanelController.shared?.cardRect {
                w.setFrameTopLeftPoint(NSPoint(x: Prefs.isLeft ? card.maxX + 16 : card.minX - 776, y: card.maxY - 40))
            }
            w.setFrameAutosaveName("cortexy.graph")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [state] _ in state.shown = false }
            window = w
        }
        state.shown = true
        window?.makeKeyAndOrderFront(nil)
    }
}

struct GraphView: View {
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .yellow, .red, .indigo, .mint, .brown, .cyan, .teal]
    let nav: Nav
    @Bindable var state: GraphState
    @Local private var model = GraphModel()
    @Local private var running = true
    @Local private var drag: Drag?
    @Local private var pinchBase: CGFloat?

    private enum Drag { case node(String, grab: CGSize), pan(CGSize) } // a node by id: a rebuild mid-drag renumbers them

    var body: some View {
        let theme = Themes.shared.current
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                TimelineView(.animation(paused: !running)) { _ in
                    let _ = advance()
                    Canvas { ctx, size in draw(&ctx, size) }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(geo.size))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? state.scale
                        pinchBase = base
                        state.zoom(base * v.magnification / state.scale, at: state.pointer)
                    }
                    .onEnded { _ in pinchBase = nil })
                .onContinuousHover { phase in
                    if case .active(let p) = phase {
                        state.pointer = CGSize(width: p.x - geo.size.width / 2, height: p.y - geo.size.height / 2)
                        let hit = model.node(at: graphPoint(p, geo.size), scale: state.scale)
                        if hit != state.hover { state.hover = hit; state.frame += 1 }
                    } else if state.hover != nil {
                        state.hover = nil
                        state.frame += 1
                    }
                }
                .onChange(of: state.frame) { running = true } // redraw after zooms and hovers
            }
            .overlay(alignment: .bottomLeading) { if state.colorBy != .note { legend } }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { state.size = $0 }
            .background(theme.panelColor ?? .clear)
        }
        .tint(theme.accentColor)
        .onAppear { rebuild() }
        .onChange(of: nav.store.folders) { // half a second after typing stops (a rebuild takes ~40 ms per 300 notes)
            guard state.shown else { return }
            model.edits += 1
            let mine = model.edits
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if model.edits == mine { rebuild() } }
        }
        .onChange(of: state.shown) { if state.shown { rebuild() } } // catch up on edits made while it was closed
        .onChange(of: [state.tags, state.unlinked, state.local]) { rebuild(fit: true) }
        .onChange(of: state.colorBy) { rebuild() }
        .onChange(of: state.focus) { rebuild(fit: true) }
    }

    /// What each color stands for (the first dozen groups).
    private var legend: some View {
        let _ = state.frame
        let groups = Set(model.nodes.map(\.group)).filter { !$0.isEmpty }.sorted()
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(groups.prefix(12).enumerated()), id: \.offset) { i, g in
                Label { Text(g).lineLimit(1) } icon: { Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8) }
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private var toolbar: some View {
        let focusTitle = state.focus.flatMap { id in nav.store.folderOf(id).flatMap { nav.store.note($0.id, id)?.title } }
        return HStack(spacing: 10) {
            Picker("", selection: $state.local) {
                Text("All Notes").tag(false)
                Text("Around This Note").tag(true).help(focusTitle.map { "Notes within two links of “\($0)”" } ?? "Open a note first")
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(focusTitle == nil)
            Toggle("Tags", isOn: $state.tags).toggleStyle(.checkbox)
            Toggle("Unlinked notes", isOn: $state.unlinked).toggleStyle(.checkbox)
            Picker("Color by", selection: $state.colorBy) { ForEach(GraphState.ColorBy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .fixedSize()
            Spacer(minLength: 8)
            Text(MD.plural(model.nodes.count, "node") + " · " + MD.plural(model.edges.count, "link")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            MiniButton(symbol: "minus.magnifyingglass", help: "Zoom Out") { state.zoom(1 / 1.25) }
            MiniButton(symbol: "plus.magnifyingglass", help: "Zoom In") { state.zoom(1.25) }
            MiniButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Fit") { state.fit(model.bounds) }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.top, 30) // under the title bar
        .padding(.bottom, 8)
    }

    // MARK: Simulation

    private func rebuild(fit: Bool = false) {
        let fresh = model.nodes.isEmpty
        state.hover = nil // its index may not mean the same node any more
        model.rebuild(nav.store, tags: state.tags, unlinked: state.unlinked, around: state.local ? state.focus : nil, groupBy: state.colorBy)
        if fresh { model.run(400) } // the first look: already laid out
        if fresh || fit { DispatchQueue.main.async { state.fit(model.bounds) } }
        state.frame += 1 // titles and colors may have changed even if the links didn't
    }

    /// Steps the simulation for this frame; pauses the clock once it's resting (and nothing is held).
    private func advance() {
        let resting = model.step()
        if resting, drag == nil { DispatchQueue.main.async { running = false } }
    }

    // MARK: Coordinates

    private func screen(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + state.offset.width + p.x * state.scale, y: size.height / 2 + state.offset.height + p.y * state.scale)
    }

    private func graphPoint(_ s: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: (s.x - size.width / 2 - state.offset.width) / state.scale, y: (s.y - size.height / 2 - state.offset.height) / state.scale)
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let _ = state.frame
        let hover = state.hover, near = hover.map { model.neighbors[$0] } ?? []
        let open: UUID? = if case .note(_, let n) = nav.route { n } else { nil }
        func lit(_ i: Int) -> Bool { hover == nil || i == hover || near.contains(i) }
        let accent = Themes.shared.current.accentColor ?? Color(nsColor: .controlAccentColor) // not dimmed when the window isn't key
        let groups = Dictionary(uniqueKeysWithValues: Set(model.nodes.map(\.group)).filter { !$0.isEmpty }.sorted().enumerated().map { ($1, $0) })

        for (a, b) in model.edges {
            var line = Path()
            line.move(to: screen(model.nodes[a].p, size))
            line.addLine(to: screen(model.nodes[b].p, size))
            let on = hover.map { $0 == a || $0 == b } ?? false
            ctx.stroke(line, with: .color(on ? accent : Color.secondary.opacity(hover == nil ? 0.35 : 0.1)), lineWidth: on ? 1.6 : 1)
        }
        for (i, n) in model.nodes.enumerated() {
            let c = screen(n.p, size), r = GraphModel.radius(n) * max(0.6, min(1.6, state.scale))
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let fill: Color = n.note == nil ? .teal : state.colorBy == .note ? n.color.color ?? accent
                : n.group.isEmpty ? .gray : GraphView.palette[(groups[n.group] ?? 0) % GraphView.palette.count]
            ctx.opacity = lit(i) ? 1 : 0.25
            ctx.fill(dot, with: .color(fill))
            if n.note == open, open != nil { ctx.stroke(dot.insetBy(-3), with: .color(.primary), lineWidth: 1.5) }
            // Titles when zoomed in, or for what's hovered and what it links to.
            if state.scale >= 0.9 || i == hover || near.contains(i) || n.degree >= 4 {
                let title = n.title.count > 28 ? String(n.title.prefix(27)) + "…" : n.title
                ctx.draw(Text(title).font(.system(size: i == hover ? 12 : 10.5, weight: i == hover ? .semibold : .regular))
                    .foregroundStyle(i == hover ? Color.primary : Color.secondary),
                         at: CGPoint(x: c.x, y: c.y + r + 9))
            }
        }
        ctx.opacity = 1
    }

    // MARK: Dragging and clicking

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    let start = graphPoint(v.startLocation, size)
                    drag = model.node(at: start, scale: state.scale).map { i in
                        .node(model.nodes[i].id, grab: CGSize(width: model.nodes[i].p.x - start.x, height: model.nodes[i].p.y - start.y))
                    } ?? .pan(state.offset)
                }
                switch drag {
                case .node(let id, let grab):
                    let p = graphPoint(v.location, size)
                    if let i = model.index(of: id) { model.hold(i, at: CGPoint(x: p.x + grab.width, y: p.y + grab.height)) }
                case .pan(let start): state.offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                case nil: break
                }
                running = true
                state.frame += 1
            }
            .onEnded { v in
                if case .node(let id, _) = drag, let i = model.index(of: id) {
                    model.release(i)
                    if hypot(v.translation.width, v.translation.height) < 4 { open(i) } // a click, not a drag
                }
                drag = nil
                running = true
            }
    }

    /// Clicking a node opens its note (or a tag's notes) in the panel.
    private func open(_ i: Int) {
        guard model.nodes.indices.contains(i) else { return }
        let n = model.nodes[i]
        if let id = n.note { nav.openNote(id) } else { nav.openLink(Link.tag(String(n.id.dropFirst()))) }
        PanelController.shared?.show(byHover: false)
    }
}

private extension Path {
    func insetBy(_ d: CGFloat) -> Path { Path(ellipseIn: boundingRect.insetBy(dx: d, dy: d)) }
}
