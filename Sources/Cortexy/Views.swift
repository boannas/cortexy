import AppKit
import SwiftUI

// MARK: Root

/// One set of animation timings for the whole app; with Reduce Motion on, they're all off.
enum Motion {
    static var off: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    // One family of springs everywhere, so everything moves alike.
    static var quick: Animation? { off ? nil : .spring(response: 0.25, dampingFraction: 0.9) }     // hover, small changes
    static var standard: Animation? { off ? nil : .spring(response: 0.35, dampingFraction: 0.88) } // rows, pages, bars
    /// The panel's and the preview's card: sliding in, out, and changing size (as Notification Center does).
    static var card: Animation { off ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86) }
    static let settle = 0.5 // seconds until a card spring has come to rest
}

struct RootView: View {
    @Bindable var nav: Nav
    @FocusState private var searchFocused: Bool

    private var isEditing: Bool { if case .note = nav.route { true } else { false } }
    private var isSmart: Bool { if case .folder(let f) = nav.route { nav.store.folder(f)?.query != nil } else { false } }

    /// The open folder, offered as a search scope (not at the top level).
    private var scopeName: String? {
        guard case .folder(let f) = nav.route, f != Folder.rootID else { return nil }
        return nav.store.folder(f)?.name
    }

    var body: some View {
        let theme = Themes.shared.current
        let radius = Themes.shared.look.cornerRadius + 8
        VStack(spacing: 0) {
            Header(nav: nav)
            if !isEditing && !isSmart {
                SearchField(text: $nav.search, focused: $searchFocused, scope: scopeName, inFolder: $nav.searchInFolder)
                if searchFocused, case let hints = nav.searchHints(nav.search), !hints.isEmpty {
                    SearchHints(nav: nav, hints: hints).transition(.opacity)
                }
            }
            content
                .id(nav.search.isEmpty ? nav.route : .home)
                .transition(.opacity) // a scale too re-placed every scroll view in both pages each frame (~4× the cost)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !nav.marked.isEmpty && !isEditing {
                BulkBar(nav: nav).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let t = nav.toast {
                HStack(spacing: 10) {
                    Text(t)
                    if nav.undoAction != nil {
                        Button("Undo") { nav.undoLast() }.buttonStyle(.plain).foregroundStyle(Color.cortexyAccentText)
                    }
                }
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 320)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { if nav.palette != nil { PaletteView(nav: nav).transition(.opacity) } }
        .overlay { if let n = nav.historyNote { HistoryView(nav: nav, nid: n).transition(.opacity) } }
        .animation(Motion.quick, value: nav.palette != nil)
        .animation(Motion.quick, value: nav.historyNote)
        .clipped() // nothing shows past the card while it springs (a page fading out, ⌘O); a rounded clip cost frames
        .environment(\.openURL, OpenURLAction { url in nav.openLink(url) ? .handled : .systemAction })
        .background(theme.panelColor ?? .clear, in: .rect(cornerRadius: radius))
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
        .tint(theme.accentColor)
        .fontDesign((Themes.shared.design ?? .standard).swiftUI)
        .environment(\.controlActiveState, .key) // keep accent-colored controls lit in a hover-opened (non-key) panel
        .animation(Motion.standard, value: nav.route)
        .animation(Motion.standard, value: nav.toast)
        .animation(Motion.standard, value: nav.marked.isEmpty)
        .animation(Motion.quick, value: searchFocused && !nav.searchHints(nav.search).isEmpty) // the hint list fades in and out
        // ⌘O / ⌘P and Version History float over the page: room for them even over a short one.
        .onChange(of: nav.palette != nil || nav.historyNote != nil) { _, open in nav.panel?.needs(atLeast: open ? 480 : 0) }
        .onChange(of: nav.searchFocus) {
            // From a note (⇧⌘F): out to its folder, where the search box is. Not Back, which went to wherever the
            // note was reached from (another note, say: the search box still wasn't there).
            if case .note(let f, _) = nav.route { nav.route = .folder(f) }
            searchFocused = true
        }
        .confirmationDialog(deleteTitle, isPresented: $nav.confirming, presenting: nav.pendingDelete) { d in
            Button("Delete", role: .destructive) { nav.perform(d) }
        } message: { _ in
            Text("Daily backups are kept in the Cortexy data folder.")
        }
    }

    private var deleteTitle: String {
        switch nav.pendingDelete {
        case .folder(let f): "Permanently delete “\(f.name)” and its \(MD.plural(nav.store.noteCount(f.id, archived: true), "note"))?"
        case .note(_, let n): "Permanently delete “\(n.title)”?"
        case .trash: "Permanently delete everything in Recently Deleted?"
        case .items(let ids): "Permanently delete \(ids.count == 1 ? "this item" : "\(ids.count) items")?"
        case nil: ""
        }
    }

    @ViewBuilder private var content: some View {
        if !nav.search.isEmpty {
            SearchResults(nav: nav)
        } else {
            switch nav.route {
            case .folder(let fid):
                if let f = nav.store.folder(fid) {
                    if f.query != nil { SearchResults(nav: nav, smart: f) } else { FolderView(nav: nav, folder: f) }
                } else {
                    Color.clear.onAppear { nav.route = .home }
                }
            case .note(let fid, let nid):
                if let n = nav.store.note(fid, nid) { EditorView(nav: nav, fid: fid, note: n) } else { Color.clear.onAppear { nav.route = .folder(fid) } }
            case .archive:
                ArchiveView(nav: nav)
            case .upcoming:
                UpcomingView(nav: nav)
            }
        }
    }
}

// MARK: Header

struct Header: View {
    @Bindable var nav: Nav

    var body: some View {
        let showsBack = nav.route != .home || !nav.search.isEmpty
        HStack(spacing: 2) {
            if showsBack { ChromeButton(symbol: "chevron.left", help: "Back (⌘[)") { nav.back() } }
            titleView
                .font(.system(size: 15, weight: .semibold))
                .padding(.leading, showsBack ? 2 : 8)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var title: String {
        if !nav.search.isEmpty { return "Search" }
        if nav.route == .archive { return "Archive" }
        if nav.route == .upcoming { return "Upcoming" }
        return nav.store.folder(nav.currentFolder)?.name ?? "Cortexy"
    }

    /// The title, as a menu of the folders above it (in the editor, the note's folder too).
    @ViewBuilder private var titleView: some View {
        let crumbs: [Folder] = switch nav.route {
        case _ where !nav.search.isEmpty: []
        case .folder(let f): Array(nav.store.chain(f).dropLast())
        case .note(let f, _): nav.store.chain(f)
        case .archive, .upcoming: []
        }
        if crumbs.isEmpty {
            Text(title).lineLimit(1)
        } else {
            Menu {
                ForEach(crumbs.reversed()) { f in
                    Button { nav.route = .folder(f.id) } label: { Label(f.name, systemImage: f.id == Folder.rootID ? "house" : "folder") }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Go to a folder above")
        }
    }

    @ViewBuilder private var trailing: some View {
        switch nav.route {
        case .note(let fid, let nid):
            if let n = nav.store.note(fid, nid) {
                let heads = MD.headings(nav.unlocked[nid] ?? n.text)
                if !heads.isEmpty {
                    ChromeMenu(symbol: "list.bullet.indent", help: "Outline") {
                        ForEach(heads, id: \.line) { h in
                            Button(String(repeating: "\u{2003}", count: h.level - 1) + h.title) { MarkdownTextView.active?.reveal(line: h.line) }
                        }
                    }
                }
                ChromeButton(symbol: n.pinned ? "pin.fill" : "pin", help: n.pinned ? "Unpin" : "Pin to Top") {
                    nav.store.updateNote(fid, nid) { $0.pinned.toggle() }
                }
                ChromeMenu(symbol: "ellipsis", help: "Note Actions") {
                    NoteMenu(nav: nav, fid: fid, note: n)
                }
            }
            ChromeButton(symbol: "square.and.pencil", help: "New Note (⌘N)") { nav.newNote() }
        default:
            ChromeButton(symbol: "folder.badge.plus", help: "New Folder (⇧⌘N)") { nav.newFolder() }
            ChromeButton(symbol: "square.and.pencil", help: "New Note (⌘N)") { nav.newNote() }
            ChromeMenu(symbol: "ellipsis", help: "More") {
                if case .folder(let fid) = nav.route {
                    FolderMenu(nav: nav, fid: fid)
                    Divider()
                }
                QuickSettingsMenu()
            }
        }
    }
}

/// Counted off the main thread once typing pauses: dictionary word breaks (what makes Thai count right)
/// take a third of a second on a 5,000-line note.
struct WordCount: View {
    let text: String
    @Local private var count: Int?

    var body: some View {
        Text(count.map { MD.plural($0, "word") } ?? "…")
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(count == nil ? 0 : 500))
                guard !Task.isCancelled else { return }
                let t = text
                count = await Task.detached { MD.wordCount(t) }.value
            }
    }
}

struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false) // keep the caret in the editor when clicking toolbar buttons
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ChromeMenu<Content: View>: View {
    let symbol: String
    let help: String
    @ViewBuilder let content: Content

    @Local private var hover = false

    var body: some View {
        // The frame and hit shape go inside the label (outside, only the 13 pt glyph was clickable), and the
        // hover highlight stays outside the Menu: changing the label as the pointer arrives swallowed the click.
        Menu { content } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Circle().fill(.primary.opacity(hover ? 0.1 : 0)))
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var scope: String?         // the open folder's name, when searching only it is possible
    @Binding var inFolder: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain).focused(focused) // the ways to search show on click
            if !text.isEmpty, let scope {
                Button { inFolder.toggle() } label: {
                    Text(inFolder ? scope : "All Notes")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.primary.opacity(0.1), in: .capsule)
                }
                .buttonStyle(.plain)
                .help(inFolder ? "Searching only this folder — click to search all notes" : "Searching all notes — click to search only this folder")
            }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Clear Search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.primary.opacity(0.06), in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// What can be typed in the search box, while it has the focus: with nothing typed, one quiet row of chips
/// (the kinds of search); after `#`, `is:` or `path:`, a short list of what fits. A click (or Tab) puts it in.
struct SearchHints: View {
    let nav: Nav
    let hints: [Nav.SearchHint]

    var body: some View {
        Group {
            if nav.search.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(hints) { h in
                            pick(h) {
                                Text(h.label)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 22)
                                    .background(.primary.opacity(0.06), in: .capsule)
                            }
                            .help(h.detail)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(hints.prefix(5).enumerated()), id: \.element.id) { i, h in
                        pick(h) {
                            HStack(spacing: 8) {
                                Text(h.label).font(.system(size: 12.5)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(h.detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.cortexyAccent.opacity(nav.hintIndex == i ? 0.22 : 0)))
                            .contentShape(Rectangle())
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 6)
    }

    private func pick(_ h: Nav.SearchHint, @ViewBuilder _ label: () -> some View) -> some View {
        Button { nav.apply(h) } label: { label() }
            .buttonStyle(.plain)
            .focusable(false) // the search box keeps the focus, to go on typing
    }
}

// MARK: Editor screen

struct EditorView: View {
    let nav: Nav
    let fid: UUID
    let note: Note

    var body: some View {
        let nid = note.id
        let look = Themes.shared.look
        var style = Themes.shared.textStyle
        style.code = note.code
        return VStack(spacing: 0) {
            if note.lock != nil, nav.unlocked[nid] == nil {
                ContentUnavailableView {
                    Label("Locked", systemImage: "lock.fill")
                } description: {
                    Text(note.title)
                } actions: {
                    Button("Unlock") { nav.unlock(nid) }
                }
                .frame(maxHeight: .infinity)
                .fitsPanel(nav, height: 300)
            } else if NoteWindows.shared.state.open.contains(nid) {
                ContentUnavailableView {
                    Label("Open in Its Own Window", systemImage: "macwindow.on.rectangle")
                } description: {
                    Text("Edit it there, or bring it back here.")
                } actions: {
                    Button("Show Window") { NoteWindows.shared.show(nid, nav: nav) }
                    Button("Bring It Back Here") { NoteWindows.shared.close(nid) }
                }
                .frame(maxHeight: .infinity)
                .fitsPanel(nav, height: 320)
            } else {
            MarkdownEditor(text: Binding(
                get: { note.lock != nil ? nav.unlocked[nid] ?? "" : nav.store.note(fid, nid)?.text ?? "" },
                set: { t in
                    if nav.store.note(fid, nid)?.lock != nil { return nav.updateLocked(nid, t) } // sealed, never stored plain
                    nav.store.type(fid, nid) { $0.text = t; $0.modified = Date() }
                    nav.edited(nid)
                }
            ), style: style, store: nav.store, onLink: { nav.openLink($0) },
               complete: { kind, partial in nav.suggestions(kind, partial, excluding: nid) }, caretKey: nid,
               onFit: { [screen = nav.screenKey] content, room in if nav.screenKey == screen { nav.panel?.grow(content: content, container: room) } },
               measureTick: nav.measureTick)
            .background { CardBackground(color: note.color) }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            if look.noteInfo || !links.isEmpty {
                HStack(spacing: 4) {
                    if look.noteInfo {
                        Text(note.modified, format: .relative(presentation: .named))
                        Text("·")
                        WordCount(text: nav.unlocked[note.id] ?? note.text)
                    }
                    if !links.isEmpty {
                        if look.noteInfo { Text("·") }
                        Menu {
                            ForEach(links, id: \.1.id) { f, n in Button(n.title) { nav.route = .note(f.id, n.id) } }
                        } label: {
                            Label("\(links.count) linked here", systemImage: "arrow.uturn.left").labelStyle(.titleAndIcon)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Notes with a [[link]] to this one")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            if look.formatBar { FormatBar(nav: nav) } else { Spacer().frame(height: 10) }
            }
        }
        // Backlinks only change when this note's title does (other notes aren't edited meanwhile).
        .task(id: note.title) { links = nav.backlinks(to: note.title, excluding: nid) }
    }

    @Local private var links: [(Folder, Note)] = []
}

/// A note's kept versions, newest first. Rest on one to read it beside the panel; Restore puts it back.
struct HistoryView: View {
    let nav: Nav
    let nid: UUID
    @Local private var versions: [Store.Version] = []

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).onTapGesture { nav.historyNote = nil }
            VStack(spacing: 0) {
                HStack {
                    Text("Version History").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(versions.count) kept").font(.system(size: 11)).foregroundStyle(.secondary)
                    MiniButton(symbol: "xmark", help: "Close (Esc)") { nav.historyNote = nil }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                Divider()
                if versions.isEmpty {
                    Text("No earlier versions yet. One is kept when you open a note, every few minutes while you edit it, and when you leave it.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(versions.enumerated().reversed()), id: \.offset) { i, v in row(i, v) }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(.horizontal, 12)
            .padding(.top, 46)
        }
        .onAppear { versions = nav.store.history(nid) }
    }

    private func row(_ i: Int, _ v: Store.Version) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(v.date, format: .relative(presentation: .named))  ·  \(Nav.show(v.date, time: true))")
                    .font(.system(size: 12.5, weight: .medium))
                Text(MD.title(v.text) + "  ·  " + MD.plural(v.text.count, "character")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Restore") { nav.restoreVersion(nid, v) }.buttonStyle(.plain).foregroundStyle(Color.cortexyAccentText).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .previewOnHover(.version(nid, i))
    }
}

/// ⌘O: jump to a note, folder or #tag. ⌘P (or ">" in ⌘O): run a command.
struct PaletteView: View {
    @Bindable var nav: Nav
    @FocusState private var focused: Bool

    var body: some View {
        let items = nav.paletteItems
        let commands = nav.palette == .commands || nav.paletteQuery.hasPrefix(">")
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).onTapGesture { nav.palette = nil }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: commands ? "command" : "magnifyingglass").foregroundStyle(.secondary)
                    TextField(commands ? "Type a command" : "Notes, folders, #tags — or > for commands", text: $nav.paletteQuery)
                        .textFieldStyle(.plain)
                        .focused($focused)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 40)
                Divider()
                if items.isEmpty {
                    Text("No matches").foregroundStyle(.secondary).font(.system(size: 13)).padding(14)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                    row(item, selected: i == nav.paletteIndex)
                                        .id(i)
                                        .onTapGesture { nav.paletteIndex = i; nav.runPalette() }
                                }
                            }
                            .padding(4)
                        }
                        .frame(height: min(330, CGFloat(items.count) * 30 + 8))
                        .onChange(of: nav.paletteIndex) { proxy.scrollTo(nav.paletteIndex) }
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(.horizontal, 12)
            .padding(.top, 46)
        }
        .onAppear { focused = true }
        .onChange(of: nav.palette) { focused = true }
    }

    private func row(_ item: Nav.PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(item.title).lineLimit(1)
            Spacer(minLength: 6)
            Text(item.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.cortexyAccent.opacity(0.25) : .clear))
        .contentShape(Rectangle())
    }
}

struct FormatBar: View {
    let nav: Nav

    /// The bar when it fits the panel; at the narrowest widths it scrolls sideways instead of losing its end buttons.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar
            ScrollView(.horizontal, showsIndicators: false) { bar.padding(.horizontal, 2) }
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            item("checklist", "Checklist (⌘L)", "cxTask:")
            item("textformat.size", "Heading", "cxHeading:")
            item("bold", "Bold (⌘B)", "cxBold:")
            item("italic", "Italic (⌘I)", "cxItalic:")
            item("strikethrough", "Strikethrough (⇧⌘X)", "cxStrike:")
            item("chevron.left.forwardslash.chevron.right", "Code (⌘E)", "cxCode:")
            item("link", "Link (⌘K)", "cxLink:")
            ChromeMenu(symbol: "textformat", help: "More Formatting") {
                Button("Bullet List  ⇧⌘8") { send("cxBullet:") }
                Button("Numbered List  ⇧⌘7") { send("cxNumbered:") }
                Button("Quote  ⇧⌘9") { send("cxQuote:") }
                Button("Highlight  ⇧⌘H") { send("cxHighlight:") }
                Button("Code Block") { send("cxCodeBlock:") }
                Button("Divider") { send("cxDivider:") }
            }
            item("tablecells", "Table", "cxTable:")
            item("calendar.badge.plus", "Due Date", "cxDue:")
            ChromeButton(symbol: "photo", help: "Insert Image…") { nav.insertImageFile() }
            ChromeButton(symbol: "camera.viewfinder", help: "Insert Screenshot") { nav.insertScreenshot() }
        }
        .padding(.horizontal, 4)
        .background(.primary.opacity(0.06), in: .capsule)
    }

    private func item(_ symbol: String, _ help: String, _ action: String) -> some View {
        ChromeButton(symbol: symbol, help: help) { send(action) }
    }

    private func send(_ action: String) { NSApp.sendAction(Selector(action), to: nil, from: nil) }
}

// MARK: Menus

/// Lock, unlock or unlock-for-good a folder.
struct FolderLockMenu: View {
    let nav: Nav
    let folder: Folder

    var body: some View {
        if !folder.locked {
            Button("Lock Folder…") { nav.lockFolder(folder.id) }
        } else if nav.store.lockedAway(folder.id) {
            Button("Unlock Folder…") { nav.unlockFolder(folder.id) }
        } else {
            Button("Lock All Locked Notes and Folders") { nav.lockAll() }
            Button("Remove Folder Lock") { nav.removeFolderLock(folder.id) }
        }
    }
}

struct NoteMenu: View {
    let nav: Nav
    let fid: UUID
    let note: Note

    var body: some View {
        let store = nav.store
        if store.inTrash(fid) {
            Button("Restore") { nav.restore(note.id) }
            Button("Copy Text") { nav.copy(note) }
            Divider()
            Button("Delete Permanently…", role: .destructive) { nav.requestDelete(.note(fid, note)) }
        } else {
            menu(store)
        }
    }

    @ViewBuilder private func menu(_ store: Store) -> some View {
        if note.snippet && !isOpen {
            Button("Edit") { nav.search = ""; nav.route = .note(fid, note.id) }
            Divider()
        }
        Button(note.pinned ? "Unpin" : "Pin to Top") { store.updateNote(fid, note.id) { $0.pinned.toggle() } }
        ColorMenu(selection: note.color) { c in store.updateNote(fid, note.id) { $0.color = c } }
        if !Themes.shared.look.titleOnly { Button(note.folded ? "Unfold" : "Fold") { store.updateNote(fid, note.id) { $0.folded.toggle() } } }
        Toggle("Snippet (Click Copies)", isOn: Binding(get: { note.snippet }, set: { v in store.updateNote(fid, note.id) { $0.snippet = v } }))
        Toggle("Code Mode", isOn: Binding(get: { note.code }, set: { v in store.updateNote(fid, note.id) { $0.code = v } }))
        Button("Duplicate") { store.duplicateNote(fid, note.id); nav.flash("Duplicated") }
        Button(note.archived ? "Unarchive" : "Archive") { nav.archive(fid, note.id, !note.archived) }
        Menu("Move to") {
            ForEach(store.moveTargets.filter { $0.id != fid }) { f in
                Button(store.path(f.id)) {
                    store.moveNote(note.id, from: fid, to: f.id)
                    if isOpen { nav.route = .note(f.id, note.id) }
                }
            }
        }
        Divider()
        if note.lock == nil {
            Button("Open in Window") { NoteWindows.shared.show(note.id, nav: nav) }
            Button("Lock Note…") { nav.lockNote(fid, note.id) }
        } else if nav.unlocked[note.id] != nil {
            Button("Lock All Locked Notes") { nav.lockAll() }
            Button("Remove Lock") { nav.removeLock(fid, note.id) }
        } else {
            Button("Unlock…") { nav.unlock(note.id) }
        }
        Button("Version History…") { nav.historyNote = note.id }
        Button("Show in Graph") { GraphWindow.shared.show(nav: nav, around: note.id) }
        Divider()
        Button("Copy Text") { nav.copy(note) }
        Button("Copy as Image") { nav.copyImage(note) }
        Button("Export as Image…") { nav.exportImage(note) }
        Divider()
        Button("Delete Note", role: .destructive) { nav.requestDelete(.note(fid, note)) }
    }

    private var isOpen: Bool { if case .note(_, let open) = nav.route { open == note.id } else { false } }
}

/// Acts on the ⌘/⇧-clicked rows.
struct BulkBar: View {
    let nav: Nav

    var body: some View {
        let trash = nav.markedInTrash
        HStack(spacing: 0) {
            Text("\(nav.marked.count) selected").font(.system(size: 12, weight: .semibold)).padding(.leading, 10)
            Spacer(minLength: 4)
            if trash {
                ChromeButton(symbol: "arrow.uturn.backward", help: "Restore") { nav.restoreMarked() }
                ChromeButton(symbol: "trash", help: "Delete Permanently…") { nav.deleteMarked() }
            } else {
                ChromeMenu(symbol: "folder", help: "Move to") {
                    ForEach(nav.store.moveTargets) { f in Button(nav.store.path(f.id)) { nav.moveMarked(to: f.id) } }
                }
                ChromeMenu(symbol: "paintpalette", help: "Color") {
                    ForEach(NoteColor.allCases) { c in
                        Button { nav.colorMarked(c) } label: { Label { Text(c.name) } icon: { Image(nsImage: ColorMenu.swatch(c.nsColor)) } }
                    }
                }
                ChromeButton(symbol: "pin", help: "Pin or Unpin") { nav.pinMarked() }
                if nav.route == .archive {
                    ChromeButton(symbol: "tray.and.arrow.up", help: "Unarchive") { nav.archiveMarked(false) }
                } else {
                    ChromeButton(symbol: "archivebox", help: "Archive") { nav.archiveMarked() }
                }
                ChromeButton(symbol: "trash", help: "Delete (⌘⌫)") { nav.deleteMarked() }
            }
            ChromeButton(symbol: "xmark", help: "Done (Esc)") { nav.marked = [] }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

/// The ⋯ menu's folder part: how notes are sorted, or emptying Recently Deleted.
struct FolderMenu: View {
    let nav: Nav
    let fid: UUID

    var body: some View {
        if fid == Folder.trashID {
            Button("Empty Recently Deleted…", role: .destructive) { nav.requestDelete(.trash) }
                .disabled(nav.store.subtree(fid).allSatisfy { $0.notes.isEmpty } && nav.store.subfolders(fid).isEmpty)
        } else if let f = nav.store.folder(fid) {
            Button("Open Today's Note") { nav.openToday() }.keyboardShortcut("d")
            Button("Show Graph") { GraphWindow.shared.show(nav: nav) }.keyboardShortcut("g")
            Menu("New from Template") {
                let templates = nav.templates
                if templates.isEmpty { Text("Put notes in a folder named “\(Prefs.text(Prefs.templatesFolder))”") }
                ForEach(templates) { t in Button(t.title) { nav.newNote(from: t) } }
                Divider()
                Button("Show Templates Folder") {
                    let name = Prefs.text(Prefs.templatesFolder)
                    nav.route = .folder(nav.templatesFolder?.id ?? nav.store.addFolder(name))
                }
            }
            if f.query == nil, !Folder.isBuiltIn(fid) { FolderLockMenu(nav: nav, folder: f) }
            if f.query == nil { // a smart folder lists its matches newest first; sorting it does nothing
                Divider()
                Picker("Sort Notes By", selection: Binding(get: { f.sort }, set: { v in nav.store.updateFolder(fid) { $0.sort = v } })) {
                    ForEach(Folder.Sort.allCases) { Text($0.name).tag($0) }
                }
            }
        }
    }
}

struct ColorMenu: View {
    let selection: NoteColor
    let pick: (NoteColor) -> Void

    var body: some View {
        Menu("Color") {
            ForEach(NoteColor.allCases) { c in
                Toggle(isOn: Binding(get: { c == selection }, set: { _ in pick(c) })) {
                    Label { Text(c.name) } icon: { Image(nsImage: Self.swatch(c.nsColor)) }
                }
            }
        }
    }

    /// Menus render SF Symbols as monochrome templates, so draw colored dots ourselves.
    static func swatch(_ color: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let dot = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            if let color {
                color.setFill()
                dot.fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                dot.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// The ⋯ menu in the panel and the menu bar menu: the settings people flip most, plus Settings….
struct QuickSettingsMenu: View {
    @AppStorage(Prefs.hotSide) private var hotSide = true
    @AppStorage(Prefs.side) private var side = "right"

    var body: some View {
        Toggle("Open at Screen Edge", isOn: $hotSide)
        Picker("Screen Edge", selection: $side) {
            Text("Right").tag("right")
            Text("Left").tag("left")
        }
        Menu("Theme") {
            ForEach(Themes.shared.all) { t in
                Toggle(isOn: Binding(get: { Themes.shared.currentID == t.id }, set: { _ in Themes.shared.currentID = t.id })) {
                    Label { Text(t.name) } icon: { Image(nsImage: ColorMenu.swatch(t.panelTint.flatMap(NSColor.init(hex:)) ?? .windowBackgroundColor)) }
                }
            }
        }
        Divider()
        Button("Settings…") { SettingsWindow.show() }
            .keyboardShortcut(",")
        Button("Open Data Folder") { NSWorkspace.shared.open(PanelController.shared?.store.directory ?? Store.configuredDirectory) }
        Button("Restart Cortexy") {
            // Relaunch once this process is gone (open would just reactivate the running one).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
            try? p.run()
            NSApp.terminate(nil)
        }
        Button("Quit Cortexy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// `@State` without the `@State` macro: the macOS 27 SDK implements `@State` as a macro whose plugin
/// ships only with Xcode, so Command Line Tools builds fail. Wrapping `State` keeps both working.
// ponytail: switch back to @State once Command Line Tools ships SwiftUIMacros.
@propertyWrapper struct Local<Value>: DynamicProperty {
    private let state: State<Value>
    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { state.projectedValue }
}
