import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless floating panel that can take keyboard focus without activating the app,
/// so the app you were in stays frontmost (like Spotlight).
final class SidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The card's height and slide, animated by SwiftUI rather than by resizing or moving the window (that redoes
/// all layout in the window server every frame and stutters). The window is just a clear frame around it.
@Observable final class PanelLayout {
    var height: CGFloat = 400 // the card, springing to the content's size
    var out = true            // slid off the screen edge
    var drag: CGFloat = 0     // fingers pulling it toward the edge (two-finger swipe)
}

/// The card hanging from the top of the clear window, sliding in and out past the screen edge.
struct PanelFrame: View {
    let layout: PanelLayout
    let root: RootView

    var body: some View {
        GeometryReader { geo in
            // (No geometry watchers here: any one, even on a view beside the card, cost a frame per swipe step.)
            let m = PanelController.margin
            Slide(layout: layout, width: geo.size.width) {
                root
                    .frame(height: max(0, min(layout.height, geo.size.height - 2 * m)))
                    .padding(.top, m)
                    .padding(Prefs.isLeft ? .leading : .trailing, m)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The slide in and out and the fingers' pull, apart from the card: a swipe step re-renders just this. (Read
/// in the card's own body, every step rebuilt the card's modifiers and laid it all out again: a frame each.)
private struct Slide<Content: View>: View {
    let layout: PanelLayout
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let away = Motion.off ? 0 : width + 24
        content
            .offset(x: (layout.out ? away : 0) * (Prefs.isLeft ? -1 : 1) + layout.drag)
            .opacity(layout.out ? 0 : 1)
    }
}

extension NSView {
    /// A plain view to be a window's contentView with `host` inside it. A hosting view that IS the content view
    /// resizes its window itself (`updateAnimatedWindowSize`), which fights our own sizing: under quick edits
    /// that ended in AppKit's "too many layout passes" exception and the app quitting.
    static func container(for host: NSView) -> NSView {
        let box = NSView()
        host.frame = box.bounds
        host.autoresizingMask = [.width, .height]
        box.addSubview(host)
        return box
    }
}

/// Lets the first click on a not-yet-focused panel act right away (drag a card, tick a box)
/// instead of only focusing the panel, and takes drops from other apps at the AppKit level
/// (SwiftUI's onDrop never fires inside this non-activating panel).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var dropHandler: ((NSPasteboard) -> Bool)? {
        didSet { dropHandler == nil ? unregisterDraggedTypes() : registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff]) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler == nil ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropHandler?(sender.draggingPasteboard) ?? false }
}

/// Settings kept in UserDefaults (Settings window); text and layout live in `Look`, themes in `Themes`.
enum Prefs {
    static let hotSide = "hotSide", side = "side", width = "width", edgeDelay = "edgeDelay"
    static let openBar = "openBar", menuBarIcon = "menuBarIcon", dataDirectory = "dataDirectory"
    static let toggleKey = "hotkey.toggle", newNoteKey = "hotkey.newNote", hoverPreview = "hoverPreview"
    static let hideDelay = "hideDelay"                 // a pointer-opened panel closes this long after the pointer leaves
    static let previewDelay = "previewDelay"           // rest on a card this long to preview it
    static let previewHideDelay = "previewHideDelay"   // the preview closes this long after the pointer leaves
    static let previewWidth = "previewWidth"           // 0 = the default (300 pt)
    static let undoSeconds = "undoSeconds", showTags = "showTags", codeTab = "codeTab"
    static let trashDays = "trashDays"                 // 0 = keep until emptied
    static let backupsKept = "backupsKept"
    static let templatesFolder = "templatesFolder", dailyFolder = "dailyFolder", dailyTemplate = "dailyTemplate"
    static let dateFormat = "dateFormat", todayKey = "hotkey.today"
    static let systemCalendar = "systemCalendar" // dates in the Mac's calendar (e.g. Buddhist 2569) instead of Gregorian
    static let dateLanguage = "dateLanguage"     // month and day names: "" this Mac's language, "th", "en"
    static let versionsKept = "versionsKept"
    static let webImages = "webImages"                 // fetch web images in every note (else each note asks: WebImages.allows)
    static let reminders = "reminders", remindAt = "remindAt" // remindAt: the hour for due dates without a time
    static let touchID = "touchID", lockOnHide = "lockOnHide"
    static let keepOpen = "keepOpen"                   // the panel stays up when you click elsewhere or the pointer leaves
    static let panelOpacity = "panelOpacity"           // 1 = solid; lower lets what's behind show through
    static let hideFromCapture = "hideFromCapture"     // screen sharing, recordings and screenshots leave Cortexy's windows out
    static let quickLook = "quickLook"                 // double-clicking an attachment previews it (else opens it in its app)
    static let linkPreviews = "linkPreviews"           // pasted links get their page's title; resting on one shows the page's card
    static let selectionBar = "selectionBar"           // the formatting bar over selected text
    static let captureKey = "hotkey.capture", captureTarget = "captureTarget" // the capture box, and where it adds: inbox | today
    static let mirror = "mirror", mirrorDirectory = "mirrorDirectory" // a Markdown copy of the notes, kept up to date ("" = Markdown in the data folder)
    static let mirrorTwoWay = "mirrorTwoWay"                          // edits, new files and deletions in the copy come back
    static let spotlight = "spotlight"                                // notes in Spotlight
    static let sinkDone = "sinkDone"                                  // ticked tasks go to the bottom of their list
    static let weekFormat = "weekFormat", monthFormat = "monthFormat"             // titles of weekly and monthly notes
    static let weeklyTemplate = "weeklyTemplate", monthlyTemplate = "monthlyTemplate"

    static var keptOpen: Bool { UserDefaults.standard.bool(forKey: keepOpen) }
    static var sinksDone: Bool { UserDefaults.standard.object(forKey: sinkDone) as? Bool ?? true }
    /// For every window of ours: none while hidden from capture.
    static var sharing: NSWindow.SharingType { UserDefaults.standard.bool(forKey: hideFromCapture) ? .none : .readOnly }

    static let defaults: [String: Any] = [
        hotSide: true, side: "right", width: 360.0, edgeDelay: 0.15, openBar: false, menuBarIcon: true, hoverPreview: true,
        hideDelay: 0.35, previewDelay: 0.45, previewHideDelay: 0.2, previewWidth: 0.0, undoSeconds: 5.0, showTags: true,
        codeTab: 4, trashDays: 30, backupsKept: 14,
        templatesFolder: "Templates", dailyFolder: "Daily", dailyTemplate: "", dateFormat: "yyyy-MM-dd", todayKey: "", systemCalendar: false, versionsKept: 50, webImages: false, reminders: true, remindAt: 9, touchID: false, lockOnHide: true,
        keepOpen: false, panelOpacity: 1.0, hideFromCapture: false, quickLook: true, linkPreviews: true, selectionBar: true,
        captureKey: "", captureTarget: "inbox", mirror: false, mirrorDirectory: "", mirrorTwoWay: false, spotlight: true, sinkDone: true, weekFormat: "YYYY-'W'ww", monthFormat: "yyyy-MM", weeklyTemplate: "", monthlyTemplate: "",
        toggleKey: HotKeySpec(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥N").encoded,
        newNoteKey: "",
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    /// A numeric setting, falling back to its default even before `register()` (tests).
    static func number(_ key: String) -> Double {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.doubleValue ?? (defaults[key] as? NSNumber)?.doubleValue ?? 0
    }

    /// A text setting; an empty value counts as unset.
    static func text(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } ?? (defaults[key] as? String ?? "")
    }

    static var isLeft: Bool { UserDefaults.standard.string(forKey: side) == "left" }
}

final class PanelController: NSObject {
    static weak var shared: PanelController?

    let store: Store
    let nav: Nav
    let panel: SidePanel
    private(set) var shown = false
    private var openedByHover = false
    var holdOpen = 0 // our own dialogs are up; don't auto-hide
    private var pending: DispatchWorkItem?
    private var dragCountAtRest = NSPasteboard(name: .drag).changeCount
    private var monitors: [Any] = []
    private var syncTimer: Timer?
    private var lastReminderSettings = ""
    private lazy var openBar = OpenBar { [weak self] in self?.show(byHover: false) }
    lazy var preview = PreviewController(nav: nav)

    init(store: Store) {
        self.store = store
        nav = Nav(store: store)
        panel = SidePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        PanelController.shared = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // a window shadow outlines the square frame; the glass edge is enough
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = Prefs.sharing
        let host = FirstMouseHostingView(rootView: PanelFrame(layout: layout, root: RootView(nav: nav)))
        host.sizingOptions = [] // we own the window frame; don't let SwiftUI resize it
        host.dropHandler = { [weak self] in self?.nav.importPasteboard($0) ?? false }
        panel.contentView = NSView.container(for: host)
        self.host = host

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.mouseMoved()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            self?.mouseMoved()
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            preview.scrolled() // no preview pops up while the list is being scrolled or swiped
            return self.swipe(e) ? nil : e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = e.window, w.attachedSheet == nil else { return e }
            return (w === self.panel ? self.handlePanelKey(e) : Self.handleEditKey(e, in: w)) ? nil : e
        } as Any)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: panel)
        nc.addObserver(self, selector: #selector(settingsChanged), name: UserDefaults.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        registerHotKeys()
        openBar.update(visible: true)
        store.onSaved = { [weak self] in
            guard let self else { return }
            nav.scheduleReminders()
            store.updateMirror()
            SpotlightIndex.update(store)
        }
        store.onMerged = { [weak self] in self?.nav.flash("Combined with edits from another Mac") }
        store.onMirrorPulled = { [weak self] n in self?.nav.flash("\(MD.plural(n, "note")) updated from the Markdown copy") }
        // Locked notes lock again when the Mac sleeps or the screen locks.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.nav.lockAll() }
        }
        // ⌃⌘Q (Lock Screen) only says so here.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.nav.lockAll()
        }
        Reminders.shared.open = { [weak self] id, line in self?.show(byHover: false); self?.nav.openNote(id, line: line) }
        nav.scheduleReminders()
        // Another Mac may be writing to a synced data folder.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.store.reloadIfChangedExternally()
            self?.store.maintain() // a no-op until the day changes
            if let store = self?.store {
                ImageText.index(store) // text in new images, for search
                if UserDefaults.standard.bool(forKey: Prefs.mirrorTwoWay) { store.updateMirror() } // edits made in the Markdown copy
            }
        }
    }

    func registerHotKeys() {
        let d = UserDefaults.standard
        HotKeys.shared.set(1, HotKeySpec(encoded: d.string(forKey: Prefs.toggleKey) ?? "")) { [weak self] in self?.toggle() }
        HotKeys.shared.set(2, HotKeySpec(encoded: d.string(forKey: Prefs.newNoteKey) ?? "")) { [weak self] in
            self?.nav.newNote()
            self?.show(byHover: false)
        }
        HotKeys.shared.set(3, HotKeySpec(encoded: d.string(forKey: Prefs.todayKey) ?? "")) { [weak self] in
            self?.nav.openToday()
            self?.show(byHover: false)
        }
        HotKeys.shared.set(4, HotKeySpec(encoded: d.string(forKey: Prefs.captureKey) ?? "")) { [weak self] in
            if let self { CaptureWindow.shared.show(nav: nav) }
        }
        // Shortcuts made in Settings that work from any app (ids from 100); ones taken away are let go.
        let anywhere = CustomShortcut.all.filter { $0.anywhere && $0.spec != nil }
        for (i, s) in anywhere.enumerated() {
            HotKeys.shared.set(UInt32(100 + i), s.spec) { [weak self] in
                self?.show(byHover: false)
                self?.nav.run(s)
            }
        }
        for i in anywhere.count..<max(anywhere.count, customRegistered) { HotKeys.shared.set(UInt32(100 + i), nil) {} }
        customRegistered = anywhere.count
    }
    private var customRegistered = 0

    /// A shortcut made in Settings that works in Cortexy, for this key press.
    static func custom(for e: NSEvent) -> CustomShortcut? {
        guard let spec = HotKeySpec(event: e) else { return nil }
        return CustomShortcut.all.first { !$0.anywhere && $0.matches(spec) }
    }

    // MARK: Links in the editor

    private var linkItem: PreviewModel.Item?

    /// The pointer rests on a link in the panel's editor (nil: it left): a `[[note]]` previews the note, a web
    /// link its page's card. `rect` is the link in window coordinates.
    func hoverLink(_ url: URL?, rect: NSRect, in tv: MarkdownTextView) {
        guard tv.window === panel, let content = panel.contentView else { return }
        if let old = linkItem { preview.hover(old, inside: false, rect: .zero); linkItem = nil }
        guard let url else { return }
        let item: PreviewModel.Item
        if url.scheme == "cortexy", url.host == "open",
           let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "title" })?.value {
            guard let (_, n) = nav.resolve(title: title, from: tv.noteID) ?? nav.resolve(title: MD.splitLink(title).title, from: tv.noteID) else { return }
            item = .note(n.id)
        } else if ["http", "https"].contains(url.scheme ?? ""), LinkPreviews.enabled {
            item = .web(url)
        } else { return }
        linkItem = item
        preview.hover(item, inside: true, rect: CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height))
    }

    // MARK: Show / hide

    func toggle() { shown ? hide() : show(byHover: false) }

    func show(byHover: Bool) {
        cancelPending()
        if shown {
            if !byHover { panel.makeKeyAndOrderFront(nil) }
            return
        }
        store.reloadIfChangedExternally()
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier, let id = app.bundleIdentifier {
            nav.frontApp = (id, app.localizedName ?? id)
        }
        shown = true
        openedByHover = byHover
        openBar.update(visible: false)
        let screen = screen(at: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        shownOn = screen
        visibleCache = nil // the Dock or menu bar may have moved since
        // The window goes straight to its place (it's clear); the card slides in from the edge with a spring.
        let on = frame(on: screen), height = cardHeight(on: screen)
        let reopening = panel.isVisible // still sliding out: turn it around from where it is, don't restart
        hideWork?.cancel()
        settleWork?.cancel(); settling = false
        swipe = .undecided
        panel.setFrame(on, display: false)
        panel.alphaValue = Prefs.number(Prefs.panelOpacity)
        if reopening {
            withAnimation(Motion.card) { layout.out = false; layout.drag = 0; layout.height = height }
        } else {
            layout.drag = 0
            layout.out = true
            layout.height = height
        }
        panel.ignoresMouseEvents = !cardRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if byHover { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        if !reopening { DispatchQueue.main.async { [self] in withAnimation(Motion.card) { layout.out = false } } } // after it's drawn out
    }

    /// `lock: false` for a moment away that comes straight back (taking a screenshot for the open note).
    func hide(lock: Bool = true) {
        guard shown else { return }
        shown = false
        cancelPending()
        preview.hide()
        if case .note(_, let n) = nav.route { store.snapshot(n) }
        if lock, UserDefaults.standard.bool(forKey: Prefs.lockOnHide) { nav.lockAll() }
        nav.dragging = nil // a drag the panel closed under never ends
        nav.dropTarget = nil
        store.saveSoon() // in the background: writing on the main thread here cost the slide its first frames
        settleWork?.cancel(); settling = false
        swipe = .undecided
        // Sliding out, it no longer takes the keyboard or the mouse (a keystroke would land in the open note).
        panel.makeFirstResponder(nil)
        panel.ignoresMouseEvents = true
        withAnimation(Motion.card) {
            layout.out = true
            layout.drag = 0 // from wherever the fingers left it
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
            self.openBar.update(visible: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Two-finger swipe toward the edge closes it, following the fingers (as Notification Center does)

    private enum Swipe { case undecided, yes, no }
    private var swipe = Swipe.undecided
    private var swipeSamples: [(t: TimeInterval, dx: CGFloat)] = []

    /// A trackpad scroll in the panel: horizontal and toward the screen edge, it pulls the card; else it's a
    /// normal scroll (including one in the panel's own sideways strips). Returns true when the swipe took the event.
    private func swipe(_ e: NSEvent) -> Bool {
        guard e.hasPreciseScrollingDeltas else { return false }
        // Fingers to the right (with natural scrolling the deltas follow the fingers).
        let fingers = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        let outward: CGFloat = Prefs.isLeft ? -1 : 1
        if e.phase == .began || e.phase == .mayBegin { swipe = .undecided; swipeSamples = [] }
        // Decided by the first movement: mostly sideways, toward the edge, and not over a strip that scrolls sideways.
        if swipe == .undecided, e.phase == .changed || e.phase == .began, abs(e.scrollingDeltaX) + abs(e.scrollingDeltaY) > 0 {
            swipe = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.5 && fingers * outward > 0 && !overSidewaysScroller(e) ? .yes : .no
        }
        guard swipe == .yes else { return false }
        if e.phase == .changed || e.phase == .began {
            if fingers != 0 { swipeSamples.append((e.timestamp, fingers)) }
            swipeSamples.removeAll { e.timestamp - $0.t > 0.1 } // the last tenth of a second: how fast the fingers were going
            layout.drag = outward > 0 ? max(0, layout.drag + fingers) : min(0, layout.drag + fingers)
        } else if e.phase == .ended || e.phase == .cancelled {
            swipe = .undecided
            // Speed toward the edge at lifting, in points a second (the end event itself carries no movement).
            let speed = Self.releaseSpeed(swipeSamples.filter { e.timestamp - $0.t <= 0.1 }) * outward // a pause before lifting: 0
            // Moving back when lifted: it stays, however far it went. Else far enough, or a flick, closes it.
            if speed > -250, abs(layout.drag) > cardRect.width * 0.25 || speed > 450 { hide() }
            else { withAnimation(Motion.card) { layout.drag = 0 } }
        }
        return true
    }

    /// Points a second over the samples (time, movement) of the last moment; 0 with too little to tell.
    static func releaseSpeed(_ samples: [(t: TimeInterval, dx: CGFloat)]) -> CGFloat {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else { return samples.first.map { $0.dx * 60 } ?? 0 }
        return samples.dropFirst().reduce(0) { $0 + $1.dx } / CGFloat(max(1.0 / 120, last.t - first.t))
    }

    /// The pointer is over something that itself scrolls sideways (the tag strip, the search chips).
    private func overSidewaysScroller(_ e: NSEvent) -> Bool {
        guard let box = panel.contentView, var v = box.hitTest(box.convert(e.locationInWindow, from: nil)) else { return false }
        while let up = v.superview {
            if let sv = v as? NSScrollView, let doc = sv.documentView, doc.frame.width > sv.contentSize.width + 1 { return true }
            v = up
        }
        return false
    }

    /// Runs an open/save dialog (or similar) without the panel sliding away when it loses focus.
    func modal<T>(_ body: () -> T) -> T {
        holdOpen += 1
        NSApp.activate()
        defer {
            holdOpen -= 1
            if shown { panel.makeKeyAndOrderFront(nil) }
        }
        return body()
    }

    /// The clear window: the screen's whole height at its edge. It never resizes as the card does (that re-laid
    /// out everything in it and stuttered); the card hangs from its top, `margin` in from the screen's edges,
    /// and slides out past the screen's edge.
    private func frame(on screen: NSScreen) -> NSRect {
        let v = visible(screen), m = Self.margin
        let w = min(CGFloat(UserDefaults.standard.double(forKey: Prefs.width)), v.width - 2 * m)
        return NSRect(x: Prefs.isLeft ? v.minX : v.maxX - w - m, y: v.minY, width: w + m, height: v.height)
    }

    /// As tall as what it shows (like Dynamic Island); the screen's height at most.
    private func cardHeight(on screen: NSScreen) -> CGFloat {
        let v = visible(screen)
        return min(v.height - 2 * Self.margin, max(Self.minHeight, fitHeight ?? v.height, floorHeight))
    }

    /// The screen less its menu bar and Dock, asked once per showing: asking the window server is a round trip
    /// that took up to ~30 ms mid-animation, and the card asks on every change of height.
    func visible(_ screen: NSScreen) -> NSRect {
        if let v = visibleCache, v.screen == screen { return v.frame }
        let f = screen.visibleFrame
        visibleCache = (screen, f)
        return f
    }
    private var visibleCache: (screen: NSScreen, frame: NSRect)?

    // MARK: Fitting the content

    static let minHeight: CGFloat = 220
    static let margin: CGFloat = 8         // from the screen's top and edge to the card
    private var fitHeight: CGFloat?        // what the content asked for last
    private var floors: [String: CGFloat] = [:] // room asked for by what's up (an overlay, the suggestion list), by who asked
    private var floorHeight: CGFloat { floors.values.max() ?? 0 }
    private var shownOn: NSScreen?
    let layout = PanelLayout()
    private(set) var host: NSView?
    private var hideWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var settling = false
    private var chrome: CGFloat = 120 // the card's height beyond its page

    private var report: (content: CGFloat, container: CGFloat)?
    private var reportQueued = false

    /// A page says how tall its content is and how tall the room it has right now is. Taken on a later turn of
    /// the run loop, never inside the layout pass that reported it (resizing a window from there is what fed the
    /// layout loop), and several reports in one turn make one resize.
    func grow(content: CGFloat, container: CGFloat) {
        report = (content, container)
        guard !reportQueued else { return }
        reportQueued = true
        DispatchQueue.main.async { [self] in
            reportQueued = false
            guard shown, let (content, container) = report, let s = panel.screen ?? shownOn else { return }
            // Besides its page the card shows a header, the search field, bars: the card minus the page's room,
            // taken at rest (mid-spring the room is in between; once at rest the page reports again).
            if !settling { chrome = max(0, layout.height - container) }
            fitHeight = content + chrome
            refit(on: s)
        }
    }

    /// At least `h` tall while `who` needs room (0: done). Each asker's own, so one ending doesn't shrink another's.
    func needs(atLeast h: CGFloat, for who: String = "overlay") {
        floors[who] = h > 0 ? h : nil
        if shown, let s = panel.screen ?? shownOn { refit(on: s) }
    }

    /// The card springs to the new height inside its clear window; once it's at rest the page measures itself
    /// again, for anything that changed meanwhile.
    private func refit(on s: NSScreen) {
        let height = cardHeight(on: s)
        guard abs(height - layout.height) > 1 else { return }
        withAnimation(Motion.standard) { layout.height = height } // the spring the page's own rows and pages move with
        settleWork?.cancel()
        settling = true
        let work = DispatchWorkItem { [weak self] in self?.settling = false; self?.nav.measureTick += 1 }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.settle, execute: work)
    }

    @objc private func screensChanged() {
        visibleCache = nil
        settingsChanged()
    }

    @objc private func settingsChanged() {
        // Reminders on/off or their time: reschedule (fires for every setting, so only when those two moved).
        let reminders = "\(UserDefaults.standard.object(forKey: Prefs.reminders) ?? true)\(Prefs.number(Prefs.remindAt))"
        if reminders != lastReminderSettings { lastReminderSettings = reminders; nav.scheduleReminders() }
        registerHotKeys()
        openBar.update(visible: !shown)
        if shown { panel.alphaValue = Prefs.number(Prefs.panelOpacity) }
        for w in NSApp.windows where w.sharingType != Prefs.sharing { w.sharingType = Prefs.sharing }
        // Any setting written fires this (the last route, folded folders…): only a change of width, side or
        // screens moves the panel, and never while the card is mid-spring.
        let look = "\(Prefs.number(Prefs.width))\(Prefs.isLeft)\(NSScreen.screens.map(\.frame))"
        guard look != lastLook else { return }
        lastLook = look
        guard shown, let s = panel.screen else { return }
        let target = frame(on: s)
        if panel.frame != target { panel.setFrame(target, display: false) }
        layout.height = cardHeight(on: s)
        nav.measureTick += 1 // a new width wraps the text anew
    }
    private var lastLook = ""

    /// Clicking anywhere else closes the panel (our own sheets, menus and dialogs don't count), unless it's kept open.
    @objc private func resignedKey() {
        DispatchQueue.main.async { [self] in
            guard shown, holdOpen == 0, !Prefs.keptOpen, !panel.isKeyWindow, panel.attachedSheet == nil else { return }
            if SettingsWindow.isKey { return } // stays up to show settings changes live
            if let k = NSApp.keyWindow, k.sheetParent === panel || k.parent === panel { return }
            hide()
        }
    }

    // MARK: Hot side

    private func screen(at p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame.insetBy(dx: -1, dy: -1), false) }
    }

    /// Pointer pushed against the outer edge of a screen (not a seam between two displays),
    /// away from the corners so hot corners and Quick Note keep working.
    private func atEdge(_ p: NSPoint) -> Bool {
        guard let f = screen(at: p)?.frame, p.y > f.minY + 40, p.y < f.maxY - 40 else { return false }
        let left = Prefs.isLeft
        guard left ? p.x <= f.minX + 1 : p.x >= f.maxX - 2 else { return false }
        let beyond = NSPoint(x: left ? f.minX - 3 : f.maxX + 3, y: p.y)
        return !NSScreen.screens.contains { NSMouseInRect(beyond, $0.frame, false) }
    }

    /// Where the card is (headed, while it springs) on screen: the rest of its window is clear.
    var cardRect: NSRect {
        let f = panel.frame, m = Self.margin, h = max(0, min(layout.height, f.height - 2 * m))
        return NSRect(x: Prefs.isLeft ? f.minX + m : f.minX, y: f.maxY - m - h, width: f.width - m, height: h)
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        // The clear parts of our windows let clicks through to what's under them.
        if NSEvent.pressedMouseButtons == 0 {
            if shown { panel.ignoresMouseEvents = !cardRect.insetBy(dx: -2, dy: -2).contains(p) }
            preview.updateHitTesting(p)
        }
        if shown {
            // Opened by hover and never clicked: slide away once the pointer leaves.
            // Not while our own sheet or prompt is up (it holds the focus, so the panel isn't key), or Settings is.
            guard openedByHover, !Prefs.keptOpen, !panel.isKeyWindow, NSEvent.pressedMouseButtons == 0, holdOpen == 0, panel.attachedSheet == nil, !SettingsWindow.isKey else { return }
            if cardRect.insetBy(dx: -24, dy: -24).contains(p) || atEdge(p) || preview.contains(p) { cancelPending(); return }
            if pending == nil { schedule(Prefs.number(Prefs.hideDelay)) { [weak self] in self?.hide() } }
            return
        }
        // A held button usually means a window is being dragged to the edge; a file/text drag
        // (which writes the drag pasteboard) should still open the panel so it can be dropped in.
        let dragPB = NSPasteboard(name: .drag).changeCount
        if NSEvent.pressedMouseButtons == 0 { dragCountAtRest = dragPB }
        let buttonsOK = NSEvent.pressedMouseButtons == 0 || dragPB != dragCountAtRest
        guard UserDefaults.standard.bool(forKey: Prefs.hotSide), buttonsOK, atEdge(p) else {
            cancelPending()
            return
        }
        if pending == nil {
            // short dwell so flicking past the edge doesn't open it
            schedule(UserDefaults.standard.double(forKey: Prefs.edgeDelay)) { [weak self] in
                guard let self, self.atEdge(NSEvent.mouseLocation) else { return }
                self.show(byHover: true)
            }
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func schedule(_ delay: Double, _ block: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil // a cancelled item never runs, so this is always the current one
            block()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Keyboard

    /// Physical key → character, so shortcuts still work while typing with a Thai (or any non-Latin) layout.
    static let qwerty: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
        kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
        kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
    ]

    static func key(_ e: NSEvent) -> String? {
        // The key without Shift: on the Thai layout ⇧M types "?", which would hide that it's M.
        let typed = (e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers)?.lowercased() ?? ""
        return !typed.isEmpty && typed.unicodeScalars.allSatisfy(\.isASCII) ? typed : qwerty[Int(e.keyCode)]
    }

    /// Cut/copy/paste/undo for our other windows: an accessory app has no Edit menu to route them.
    static func handleEditKey(_ e: NSEvent, in w: NSWindow) -> Bool {
        if let s = custom(for: e), let c = shared { // a note window: the user's own act in the panel
            c.show(byHover: false)
            c.nav.run(s)
            return true
        }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command, .option], e.keyCode == UInt16(kVK_UpArrow) || e.keyCode == UInt16(kVK_DownArrow), w.firstResponder is MarkdownTextView {
            return NSApp.sendAction(e.keyCode == UInt16(kVK_UpArrow) ? #selector(MarkdownTextView.cxMoveUp(_:)) : #selector(MarkdownTextView.cxMoveDown(_:)), to: nil, from: w)
        }
        guard mods == .command || mods == [.command, .shift], let key = key(e) else { return false }
        let shift = mods.contains(.shift)
        // A note in its own window gets the editor's formatting keys too.
        if w.firstResponder is MarkdownTextView {
            let format = ["b": "cxBold:", "i": "cxItalic:", "e": "cxCode:", "k": "cxLink:", "l": "cxTask:", "[": "cxOutdent:", "]": "cxIndent:"]
            if shift, let action = MarkdownTextView.shiftFormat[key] { return NSApp.sendAction(Selector(action), to: nil, from: w) }
            if !shift, let action = format[key] { return NSApp.sendAction(Selector(action), to: nil, from: w) }
        }
        if let tv = w.firstResponder as? MarkdownTextView { // find in this window's note
            switch (key, shift) {
            case ("f", false): tv.find(.showFindInterface); return true
            case ("g", _) where tv.findBarShown: tv.find(shift ? .previousMatch : .nextMatch); return true
            default: break
            }
        }
        switch (key, shift) {
        case ("z", false): w.firstResponder?.undoManager?.undo()
        case ("z", true): w.firstResponder?.undoManager?.redo()
        case ("w", false): w.performClose(nil)
        case ("q", false): NSApp.terminate(nil)
        case ("x", false), ("c", false), ("v", false), ("a", false):
            let actions = ["x": "cut:", "c": "copy:", "v": "paste:", "a": "selectAll:"]
            return NSApp.sendAction(Selector(actions[key]!), to: nil, from: w)
        default: return false
        }
        return true
    }

    private var isEditingNote: Bool { if case .note = nav.route { true } else { false } }

    /// ⇧⌘M: pick a folder for the open (or selected) note.
    private func showMoveMenu() {
        var target: (UUID, UUID)?
        if case let .note(f, n) = nav.route { target = (f, n) }
        else if let s = nav.selection, let f = store.folderOf(s) { target = (f.id, s) }
        guard let (fid, nid) = target, let view = panel.contentView else { NSSound.beep(); return }
        let menu = NSMenu(title: "Move to")
        menu.addItem(withTitle: "Move to", action: nil, keyEquivalent: "").isEnabled = false
        for f in store.moveTargets where f.id != fid {
            let item = NSMenuItem(title: store.path(f.id), action: #selector(movePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [fid, nid, f.id]
            menu.addItem(item)
        }
        guard menu.items.count > 1 else { NSSound.beep(); return }
        menu.popUp(positioning: nil, at: NSPoint(x: 16, y: view.isFlipped ? 44 : view.bounds.height - 44), in: view)
    }

    @objc private func movePicked(_ item: NSMenuItem) {
        guard let ids = item.representedObject as? [UUID] else { return }
        store.moveNote(ids[1], from: ids[0], to: ids[2])
        if case .note(_, let open) = nav.route, open == ids[1] { nav.route = .note(ids[2], ids[1]) }
        nav.flash("Moved to \(item.title)")
    }

    private func handlePanelKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let responder = panel.firstResponder as? NSTextView
        if responder?.hasMarkedText() == true { return false } // an input method is composing (CJK etc.)
        if let s = Self.custom(for: e) { nav.run(s); return true } // the user's own come first
        let inText = responder != nil
        // The search box is the only field editor outside the note editor (bar the rename field).
        // (A smart folder's query bar is a field too, but not the search box: no hints, Tab and ↓ are the field's own.)
        let inSearch = responder?.isFieldEditor == true && !isEditingNote && nav.renaming == nil && nav.iconPicking == nil && !nav.onSmartFolder
        let code = Int(e.keyCode)

        // The ⌘O / ⌘P list owns the arrows, Return and Esc while it's up; typing goes to its field.
        if nav.palette != nil, mods.isEmpty {
            switch code {
            case kVK_Escape: nav.palette = nil
            case kVK_DownArrow, kVK_UpArrow: nav.movePalette(code == kVK_DownArrow ? 1 : -1)
            case kVK_Return: nav.runPalette()
            default: return false
            }
            return true
        }

        if mods.isEmpty {
            switch code {
            case kVK_Escape where isEditingNote && MarkdownTextView.active?.completing == true:
                return false // closes the suggestion list instead of the panel
            case kVK_Escape where isEditingNote && MarkdownTextView.active?.findBarShown == true:
                MarkdownTextView.active?.find(.hideFindInterface)
                return true
            case kVK_Escape where nav.renaming != nil:
                nav.renaming = nil // cancels the rename, not the panel
                return true
            case kVK_Escape where nav.historyNote != nil:
                nav.historyNote = nil
                return true
            case kVK_Escape where nav.calendarShown || nav.attachmentsShown:
                nav.calendarShown = false
                nav.attachmentsShown = false
                return true
            case kVK_Escape:
                if nav.iconPicking != nil { nav.iconPicking = nil } else if !nav.marked.isEmpty { nav.marked = [] } else if !nav.search.isEmpty { nav.search = "" } else { hide() }
                return true
            case kVK_Tab where inSearch:
                let hints = nav.searchHints(nav.search)
                guard let hint = nav.hintIndex.flatMap({ hints.indices.contains($0) ? hints[$0] : nil }) ?? hints.first else { return false }
                nav.apply(hint) // Tab takes the first hint (or the one the arrows are on)
                return true
            case kVK_DownArrow where inSearch, kVK_UpArrow where inSearch && nav.hintIndex != nil:
                if nav.moveHint(code == kVK_DownArrow ? 1 : -1) { return true } // along the hint list first
                if code == kVK_UpArrow { return true }
                panel.makeFirstResponder(nil)
                nav.moveSelection(1)
                return true
            case kVK_Return where inSearch && nav.hintIndex != nil && nav.applyHighlightedHint():
                return true
            case kVK_DownArrow where !inText, kVK_UpArrow where !inText:
                if inSearch { panel.makeFirstResponder(nil) }
                nav.moveSelection(code == kVK_DownArrow ? 1 : -1)
                return true
            case kVK_Return where !inText || (inSearch && !nav.search.isEmpty), kVK_RightArrow where !inText:
                return nav.openSelection()
            case kVK_LeftArrow where !inText:
                nav.back()
                return true
            case kVK_Space where !inText && nav.selection != nil:
                nav.foldSelection()
                return true
            default:
                return false
            }
        }
        if code == kVK_Delete, mods == .command, !inText {
            nav.deleteSelection()
            return true
        }
        if mods == [.command, .option, .shift], code == kVK_ANSI_V, isEditingNote, inText { // as typed: no link titles, no Markdown from HTML
            return NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: panel)
        }
        if mods == [.command, .option], code == kVK_UpArrow || code == kVK_DownArrow, isEditingNote, inText {
            return NSApp.sendAction(code == kVK_UpArrow ? #selector(MarkdownTextView.cxMoveUp(_:)) : #selector(MarkdownTextView.cxMoveDown(_:)), to: nil, from: panel)
        }
        guard mods.contains(.command), !mods.contains(.control), !mods.contains(.option), let key = Self.key(e) else { return false }
        let shift = mods.contains(.shift)

        switch (key, shift) {
        case ("n", false): nav.newNote()
        case ("n", true): nav.newFolder()
        case ("m", true): showMoveMenu()
        case ("f", false) where isEditingNote: MarkdownTextView.active?.find(.showFindInterface) // in this note
        case ("f", _): nav.searchFocus += 1 // ⇧⌘F in a note: all notes
        case ("g", let back) where isEditingNote && MarkdownTextView.active?.findBarShown == true:
            MarkdownTextView.active?.find(back ? .previousMatch : .nextMatch)
        case ("d", false): nav.openToday()
        case ("o", false): nav.palette = .open
        case ("p", false): nav.palette = .commands
        case ("g", false): GraphWindow.shared.show(nav: nav)
        case ("p", true): UserDefaults.standard.set(!Prefs.keptOpen, forKey: Prefs.keepOpen)
        // In a note ⌘[ / ⌘] move lines out and in (Notes, Pages); elsewhere ⌘[ is Back (← too, and the back button).
        case ("[", false) where isEditingNote && inText: return NSApp.sendAction(#selector(MarkdownTextView.cxOutdent(_:)), to: nil, from: panel)
        case ("]", false) where isEditingNote && inText: return NSApp.sendAction(#selector(MarkdownTextView.cxIndent(_:)), to: nil, from: panel)
        case ("[", false): nav.back()
        case ("]", false): nav.forward()
        case ("d", true): nav.calendarShown = true
        case (",", false): SettingsWindow.show()
        case ("w", false): hide()
        case ("q", false): NSApp.terminate(nil)
        // ⌘Z in the search box undoes its typing; the toast's Undo (a deleted note) only when there's none.
        case ("z", false) where nav.undoAction != nil && !isEditingNote && nav.renaming == nil && nav.iconPicking == nil
            && !(inText && responder?.undoManager?.canUndo == true): nav.undoLast()
        case ("a", false) where !inText: nav.markAll()
        case ("z", false): panel.firstResponder?.undoManager?.undo()
        case ("z", true): panel.firstResponder?.undoManager?.redo()
        case (let k, true) where isEditingNote && MarkdownTextView.shiftFormat[k] != nil:
            return NSApp.sendAction(Selector(MarkdownTextView.shiftFormat[k]!), to: nil, from: panel)
        case ("x", false), ("c", false), ("v", false), ("a", false), ("b", false), ("i", false),
             ("e", false), ("k", false), ("l", false):
            let actions = ["x": "cut:", "c": "copy:", "v": "paste:", "a": "selectAll:", "b": "cxBold:",
                           "i": "cxItalic:", "e": "cxCode:", "k": "cxLink:", "l": "cxTask:"]
            return NSApp.sendAction(Selector(actions[key]!), to: nil, from: panel)
        default: return false
        }
        return true
    }

    // MARK: URL scheme: cortexy://show | hide | toggle | new?text=…&folder=… | search?q=…

    func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ k: String) -> String? { items.first { $0.name == k }?.value }
        switch url.host {
        case "hide": hide()
        case "toggle": toggle()
        case "new": // show=0 (the command-line tool, AI agents): made without opening the panel, at home unless a folder is named
            guard q("show") == "0" else {
                nav.newNote(text: q("text") ?? "", folderName: q("folder"))
                return show(byHover: false)
            }
            let made = q("folder") == nil ? store.addNote(to: Folder.rootID, text: q("text") ?? "") : nav.newNote(text: q("text") ?? "", folderName: q("folder"), open: false)
            if made != nil { nav.flash("New note added") } // refused (a locked folder): its own message stays
        case "append": // to=inbox (default) | today | a note's title; the panel stays as it is
            if nav.append(q("text") ?? "", to: q("to")) { nav.flash("Added to \(q("to") ?? "Inbox")") }
        case "capture": CaptureWindow.shared.show(nav: nav)
        case "search":
            nav.search = q("q") ?? ""
            show(byHover: false)
        case "tag", "open":
            nav.openLink(url)
            show(byHover: false)
        default: show(byHover: false)
        }
    }
}

// MARK: Global hot keys (Carbon: no Accessibility permission needed)

/// A shortcut made in Settings → Shortcuts: keys, and the template to start a note from or the note to open.
/// It works in Cortexy (the panel, a note window), or from any app when `anywhere` (then it has ⌃ or ⌥ in it,
/// so it can't take another app's ⌘ shortcut).
struct CustomShortcut: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case template, note
        var id: Self { self }
        var name: String { self == .template ? "New note from template" : "Open note" }
    }
    var id = UUID()
    var keys = ""            // HotKeySpec.encoded; "" until recorded
    var action = Action.template
    var target: UUID?        // the template's or the note's id (its title can change)
    var folder: UUID?        // where a template's note goes; nil = home
    var anywhere = false

    var spec: HotKeySpec? { HotKeySpec(encoded: keys) }
    func matches(_ s: HotKeySpec) -> Bool { spec.map { $0.keyCode == s.keyCode && $0.modifiers == s.modifiers } ?? false }

    static let defaultsKey = "customShortcuts"
    static var all: [CustomShortcut] {
        get { UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([CustomShortcut].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    /// In-app keys a shortcut can't take (they'd stop copying, pasting, undoing, quitting…).
    static let reserved: [UInt32: String] = [UInt32(kVK_ANSI_C): "Copy", UInt32(kVK_ANSI_V): "Paste", UInt32(kVK_ANSI_X): "Cut",
                                             UInt32(kVK_ANSI_Z): "Undo", UInt32(kVK_ANSI_A): "Select All", UInt32(kVK_ANSI_Q): "Quit",
                                             UInt32(kVK_ANSI_W): "Close"]
    /// Cortexy's own ⌘ keys a shortcut takes over (allowed, but said).
    static let builtIn: [UInt32: String] = [UInt32(kVK_ANSI_B): "Bold", UInt32(kVK_ANSI_I): "Italic", UInt32(kVK_ANSI_E): "Code",
                                            UInt32(kVK_ANSI_K): "Link", UInt32(kVK_ANSI_L): "Checklist", UInt32(kVK_ANSI_N): "New Note",
                                            UInt32(kVK_ANSI_D): "Today's Note", UInt32(kVK_ANSI_F): "Find", UInt32(kVK_ANSI_O): "Quick Open",
                                            UInt32(kVK_ANSI_P): "Commands", UInt32(kVK_ANSI_G): "Graph / Find Next",
                                            UInt32(kVK_ANSI_LeftBracket): "Back", UInt32(kVK_ANSI_Comma): "Settings"]

    /// Why `s` can't be this shortcut's keys (nil: it can).
    static func problem(_ s: HotKeySpec, anywhere: Bool, others: [HotKeySpec]) -> String? {
        if others.contains(where: { $0.keyCode == s.keyCode && $0.modifiers == s.modifiers }) { return "Another Cortexy shortcut already uses \(s.display)." }
        if anywhere {
            if s.modifiers & UInt32(controlKey | optionKey) == 0 { return "From any app it needs ⌃ or ⌥ too, so it doesn't take another app's shortcut." }
            return HotKeys.problem(s, others: []) ?? (HotKeys.shared.available(s) ? nil : "\(s.display) is taken by macOS or another app.")
        }
        if s.modifiers == UInt32(cmdKey), let what = reserved[s.keyCode] { return "\(s.display) is \(what): it can't be replaced." }
        return nil
    }

    /// What of Cortexy's own it replaces, said under it.
    var replaces: String? {
        guard !anywhere, let s = spec, s.modifiers == UInt32(cmdKey), let what = Self.builtIn[s.keyCode] else { return nil }
        return "Replaces \(what) (\(s.display)) in Cortexy."
    }
}

struct HotKeySpec: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon flags
    var display: String

    var encoded: String { "\(keyCode),\(modifiers),\(display)" }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    init?(encoded: String) {
        let p = encoded.split(separator: ",", maxSplits: 2).map(String.init)
        guard p.count == 3, let k = UInt32(p[0]), let m = UInt32(p[1]) else { return nil }
        self.init(keyCode: k, modifiers: m, display: p[2])
    }

    /// From a key press in the recorder; needs ⌘, ⌃ or ⌥ so it can't swallow plain typing.
    init?(event e: NSEvent) {
        let f = e.modifierFlags
        guard !f.intersection([.command, .control, .option]).isEmpty else { return nil }
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                                    kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`", kVK_Home: "↖", kVK_End: "↘",
                                    kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋"]
        let key = names[Int(e.keyCode)] ?? PanelController.qwerty[Int(e.keyCode)]?.uppercased() ?? "?"
        let symbols = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "")
            + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
        self.init(keyCode: UInt32(e.keyCode), modifiers: m, display: symbols + key)
    }
}

final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var specs: [UInt32: HotKeySpec] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var paused = false

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func set(_ id: UInt32, _ spec: HotKeySpec?, action: @escaping () -> Void) {
        actions[id] = action
        guard specs[id] != spec else { return }
        unregister(id)
        specs[id] = spec
        if !paused { register(id) }
    }

    /// Whether macOS will deliver this combination to us (not taken by the system or another app).
    func available(_ s: HotKeySpec) -> Bool {
        var ref: EventHotKeyRef?
        let ok = RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: 0x4358_5459, id: 99), GetApplicationEventTarget(), 0, &ref) == noErr
        if let ref { UnregisterEventHotKey(ref) }
        return ok
    }

    /// Why a recorded shortcut can't be used, or nil if it can.
    static func problem(_ s: HotKeySpec, others: [HotKeySpec]) -> String? {
        let m = s.modifiers
        if m & UInt32(cmdKey | controlKey) == 0 { return "macOS doesn't deliver ⌥ or ⌥⇧ shortcuts to apps; add ⌘ or ⌃." }
        let essential = [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_N].map(UInt32.init)
        if m == UInt32(cmdKey), essential.contains(s.keyCode) { return "\(s.display) would stop working in every other app." }
        if others.contains(where: { $0.keyCode == s.keyCode && $0.modifiers == s.modifiers }) { return "Another Cortexy shortcut already uses \(s.display)." }
        return nil
    }

    /// While recording a new shortcut, the old ones must not fire (and swallow the key press).
    func pause(_ on: Bool) {
        paused = on
        for id in specs.keys { on ? unregister(id) : register(id) }
    }

    private func register(_ id: UInt32) {
        guard let s = specs[id], refs[id] == nil else { return }
        var ref: EventHotKeyRef?
        RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: 0x4358_5459, id: id), // 'CXTY'
                            GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
    }

    private func unregister(_ id: UInt32) {
        if let r = refs[id] { UnregisterEventHotKey(r) }
        refs[id] = nil
    }
}

// MARK: Open Bar: a thin handle on the screen edge you can click

final class OpenBar {
    private let panel: NSPanel

    init(onClick: @escaping () -> Void) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let host = FirstMouseHostingView(rootView: OpenBarView(action: onClick))
        host.sizingOptions = []
        panel.contentView = NSView.container(for: host)
    }

    func update(visible: Bool) {
        guard visible, UserDefaults.standard.bool(forKey: Prefs.openBar), let s = NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        let v = s.visibleFrame, w: CGFloat = 12, h: CGFloat = 110
        panel.setFrame(NSRect(x: Prefs.isLeft ? v.minX : v.maxX - w, y: v.midY - h / 2, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
}

struct OpenBarView: View {
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Capsule()
            .fill(.secondary.opacity(hover ? 0.8 : 0.35))
            .frame(width: hover ? 6 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
            .animation(Motion.quick, value: hover)
            .help("Open Cortexy")
            .accessibilityLabel("Open Cortexy")
            .accessibilityAddTraits(.isButton)
    }
}
