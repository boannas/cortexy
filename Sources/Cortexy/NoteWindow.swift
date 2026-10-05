import AppKit
import Observation
import SwiftUI

/// Notes opened in their own small windows that float above every app, like sticky notes. Each note has one
/// editor at a time: while it's in a window, the panel shows a placeholder for it. Open windows come back
/// at the next launch, where they were.
final class NoteWindows: NSObject, NSWindowDelegate {
    static let shared = NoteWindows()
    @Observable final class State { var open: Set<UUID> = [] }
    let state = State()
    private var windows: [UUID: NSPanel] = [:]
    private var titles: [UUID: String?] = [:] // each note's title when its window opened, so links follow a rename
    private weak var nav: Nav?

    func isOpen(_ nid: UUID) -> Bool { state.open.contains(nid) }

    func show(_ nid: UUID, nav: Nav) {
        self.nav = nav
        if let w = windows[nid] { return w.makeKeyAndOrderFront(nil) }
        guard nav.store.folderOf(nid) != nil else { return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.level = .floating
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.minSize = NSSize(width: 220, height: 160)
        w.sharingType = Prefs.sharing
        w.delegate = self
        w.contentView = FirstMouseHostingView(rootView: NoteWindowView(nav: nav, nid: nid))
        // Where it was last time; else beside the panel, a little further along for each one open.
        if !w.setFrameUsingName(Self.frameName(nid)), let card = PanelController.shared?.cardRect {
            let step = CGFloat(windows.count % 6) * 24
            w.setFrameTopLeftPoint(NSPoint(x: Prefs.isLeft ? card.maxX + 16 + step : card.minX - 356 - step,
                                           y: card.maxY - 40 - step))
        }
        w.setFrameAutosaveName(Self.frameName(nid))
        windows[nid] = w
        titles[nid] = nav.store.folderOf(nid).flatMap { nav.store.note($0.id, nid)?.title }
        state.open.insert(nid)
        persist()
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ nid: UUID) { windows[nid]?.close() }

    func title(_ nid: UUID, _ title: String) { windows[nid]?.title = title }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSPanel, let nid = windows.first(where: { $0.value === w })?.key else { return }
        windows[nid] = nil
        if let old = titles.removeValue(forKey: nid) ?? nil { nav?.noteRenamed(nid, from: old) }
        state.open.remove(nid)
        persist()
    }

    /// Reopens what was open when Cortexy quit.
    func restore(nav: Nav) {
        for id in (UserDefaults.standard.stringArray(forKey: "noteWindows") ?? []).compactMap(UUID.init) { show(id, nav: nav) }
    }

    private func persist() {
        // Not while quitting: windows close then, and they should come back next time.
        guard !NoteWindows.quitting else { return }
        UserDefaults.standard.set(state.open.map(\.uuidString), forKey: "noteWindows")
    }

    static var quitting = false
    private static func frameName(_ nid: UUID) -> String { "cortexy.note.\(nid.uuidString)" }
}

/// A note's own window: the editor, by note ID (so moving the note between folders doesn't matter).
struct NoteWindowView: View {
    let nav: Nav
    let nid: UUID

    var body: some View {
        let store = nav.store
        let theme = Themes.shared.current
        if let f = store.folderOf(nid), let n = store.note(f.id, nid), !store.inTrash(f.id), n.lock == nil {
            MarkdownEditor(text: Binding(
                get: { store.folderOf(nid).flatMap { store.note($0.id, nid)?.text } ?? "" },
                set: { t in
                    guard let f = store.folderOf(nid) else { return }
                    store.type(f.id, nid) { $0.text = t; $0.modified = Date() }
                    nav.edited(nid)
                }
            ), style: Self.style(n), store: store, onLink: { nav.openLink($0, from: nid) },
               complete: { kind, partial in nav.suggestions(kind, partial, excluding: nid) }, caretKey: nid)
            .padding(.top, 26) // under the title bar
            .safeAreaInset(edge: .bottom) {
                if Themes.shared.look.formatBar { // scrolls sideways when the window is narrower than the bar
                    ScrollView(.horizontal, showsIndicators: false) { FormatBar(nav: nav).padding(.horizontal, 8) }.fixedSize(horizontal: false, vertical: true)
                }
            }
            .background { CardBackground(color: n.color, opaque: true) }
            .background(theme.panelColor ?? .clear)
            .tint(theme.accentColor)
            .onChange(of: n.title, initial: true) { NoteWindows.shared.title(nid, n.title) }
        } else {
            Color.clear.onAppear { NoteWindows.shared.close(nid) } // deleted, or moved to Recently Deleted
        }
    }

    private static func style(_ n: Note) -> TextStyle {
        var st = Themes.shared.textStyle
        st.code = n.code
        st.readOnly = n.readOnly
        return st
    }
}

/// The capture box (its own global shortcut): type, ↩ adds it to the end of the Inbox note or today's note
/// without opening the panel. Esc, or clicking elsewhere, puts it away keeping what's typed for next time.
final class CaptureWindow: NSObject, NSWindowDelegate {
    static let shared = CaptureWindow()
    private var window: NSPanel?

    func show(nav: Nav) {
        let w = window ?? {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = .floating
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.sharingType = Prefs.sharing
            w.delegate = self
            w.contentView = FirstMouseHostingView(rootView: CaptureView(nav: nav) { [weak self] in self?.close() })
            window = w
            return w
        }()
        // A third of the way down the screen the pointer is on.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame { w.setFrameTopLeftPoint(NSPoint(x: f.midX - w.frame.width / 2, y: f.maxY - f.height / 3 + w.frame.height)) }
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }
    func windowDidResignKey(_ n: Notification) { close() }
    var isShown: Bool { window?.isVisible == true }
}

struct CaptureView: View {
    let nav: Nav
    let done: () -> Void
    @AppStorage("captureDraft") private var draft = ""
    @AppStorage(Prefs.captureTarget) private var target = "inbox"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Jot something down…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(3...8)
                .focused($focused)
                .onSubmit(add)
            HStack {
                Picker("Add to", selection: $target) {
                    Text("Inbox").tag("inbox")
                    Text("Today's Note").tag("today")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                Spacer()
                Text("↩ adds · ⌥↩ new line · Esc").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(width: 440)
        .onExitCommand(perform: done)
        .onAppear { focused = true }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return done() }
        if nav.append(text, to: target) { draft = "" }
        done()
    }
}
