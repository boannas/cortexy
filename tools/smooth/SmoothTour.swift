import AppKit
import QuartzCore
import SwiftUI
import Testing

@testable import Cortexy

// Frame meter, run by tools/smooth/tour.sh in a copy of the repo (never add it to Tests/: it drives the real panel). Each scenario drives the real panel on screen and
// reports how much time the main thread made frames late: hitch ms per second (< 5 smooth) and the worst frame.

@MainActor final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0, began: CFTimeInterval = 0
    private(set) var hitch: Double = 0, worst: Double = 0, frames = 0

    /// Its own 2-pt window that stays up (a hidden panel's display link stops, which read as a long frame).
    private static let window: NSWindow = {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true; w.level = .floating
        w.isReleasedWhenClosed = false
        return w
    }()

    func start(on view: NSView) {
        last = 0; hitch = 0; worst = 0; frames = 0
        began = CACurrentMediaTime()
        if let screen = view.window?.screen ?? NSScreen.main { Self.window.setFrameOrigin(NSPoint(x: screen.frame.midX, y: screen.frame.midY)) }
        Self.window.orderFrontRegardless()
        let l = Self.window.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime(), frame = max(1.0 / 240, l.targetTimestamp - l.timestamp)
        if last > 0 {
            let gap = now - last
            if gap > frame * 1.5 { hitch += gap - frame; worst = max(worst, gap) }
        }
        last = now
        frames += 1
    }

    func stop(_ name: String) {
        link?.invalidate()
        let secs = max(0.001, CACurrentMediaTime() - began)
        print(String(format: "SMOOTH %-14@ %7.1f ms/s   worst %6.1f ms   %d frames", name as NSString, hitch * 1000 / secs, worst * 1000, frames))
    }
}

@MainActor private func editorOf(_ v: NSView) -> MarkdownTextView? {
    if let t = v as? MarkdownTextView, !t.previewing { return t }
    for s in v.subviews { if let t = editorOf(s) { return t } }
    return nil
}

@MainActor private func library(_ dir: URL) -> (Store, UUID, UUID) {
    let s = Store(testing: dir)
    let work = s.addFolder("Work")
    let count = Int(ProcessInfo.processInfo.environment["SMOOTH_NOTES"] ?? "") ?? 300
    for i in 0..<count {
        _ = s.addNote(to: i % 2 == 0 ? work : Folder.rootID,
                      text: "# Note \(i) แผนงาน\n- [ ] task \(i) 📅 2026-10-\(10 + i % 18)\nSome **bold** text with [[Note \(i + 1)]] and #tag\(i % 7)\n> a quote")
    }
    var long = "# Long note\n"
    for i in 0..<3000 {
        switch i % 6 {
        case 0: long += "## Section \(i)\n"
        case 1: long += "- [ ] item \(i) with a [[link]] and `code`\n"
        case 2: long += "Plain paragraph \(i) ภาษาไทยปนกับ English, **bold** and *italic* and ==mark==.\n"
        case 3: long += "1. numbered \(i)\n"
        case 4: long += "> quote \(i)\n"
        default: long += "rent\(i) = \(i * 10)\n"
        }
    }
    let longID = s.addNote(to: work, text: long)!
    return (s, work, longID)
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("smooth-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@MainActor private func panel() async throws -> (PanelController, UUID, UUID) {
    Prefs.register()
    let (s, work, long) = library(tempDir())
    let c = PanelController(store: s)
    c.holdOpen += 1
    c.show(byHover: false)
    try await Task.sleep(for: .milliseconds(800))
    return (c, work, long)
}

@Suite(.serialized) @MainActor struct SmoothTour {
    @Test func slide() async throws {
        let (c, _, _) = try await panel()
        let m = FrameMeter(); m.start(on: c.panel.contentView!)
        var hideCost = 0.0, showCost = 0.0
        for _ in 0..<4 {
            var t = CACurrentMediaTime(); c.hide(); hideCost += CACurrentMediaTime() - t
            try await Task.sleep(for: .milliseconds(500))
            t = CACurrentMediaTime(); c.show(byHover: false); showCost += CACurrentMediaTime() - t
            try await Task.sleep(for: .milliseconds(600))
        }
        m.stop("slide")
        print(String(format: "SMOOTH slide calls: hide %.1f ms, show %.1f ms (each, on average)", hideCost * 250, showCost * 250))
    }

    @Test func typing() async throws {
        let (c, work, long) = try await panel()
        c.nav.route = .note(work, long)
        try await Task.sleep(for: .milliseconds(1500))
        let tv = try #require(editorOf(c.panel.contentView!))
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length / 2, length: 0))
        let m = FrameMeter(); m.start(on: c.panel.contentView!)
        for i in 0..<120 { // ~ 8 keys a second
            if i % 20 == 19 { tv.insertNewline(nil) } else { tv.insertText(i % 5 == 4 ? " " : "ก", replacementRange: tv.selectedRange()) }
            try await Task.sleep(for: .milliseconds(120))
        }
        m.stop("typing")
    }

    @Test func openLong() async throws {
        let (c, work, long) = try await panel()
        let m = FrameMeter(); m.start(on: c.panel.contentView!)
        for _ in 0..<4 {
            c.nav.route = .note(work, long); try await Task.sleep(for: .milliseconds(700))
            c.nav.route = .folder(work); try await Task.sleep(for: .milliseconds(700))
        }
        m.stop("openLong")
    }

    @Test func pages() async throws {
        let (c, work, _) = try await panel()
        let m = FrameMeter(); m.start(on: c.panel.contentView!)
        for _ in 0..<6 {
            c.nav.route = .folder(work); try await Task.sleep(for: .milliseconds(500))
            c.nav.route = .home; try await Task.sleep(for: .milliseconds(500))
        }
        m.stop("pages")
    }

    @Test func search() async throws {
        let (c, _, _) = try await panel()
        let m = FrameMeter(); m.start(on: c.panel.contentView!)
        for _ in 0..<3 {
            for ch in "note 12 แผน" { c.nav.search += String(ch); try await Task.sleep(for: .milliseconds(90)) }
            try await Task.sleep(for: .milliseconds(400))
            c.nav.search = ""; try await Task.sleep(for: .milliseconds(400))
        }
        m.stop("search")
    }

    @Test func hover() async throws {
        let (c, work, _) = try await panel()
        c.nav.route = .folder(work)
        try await Task.sleep(for: .milliseconds(800))
        let notes = c.store.folder(work)!.notes.prefix(6).map(\.id)
        let card = c.cardRect
        let m = FrameMeter(); m.start(on: c.panel.contentView!)
        for (i, id) in notes.enumerated() {
            let row = CGRect(x: 20, y: 120 + CGFloat(i) * 44, width: card.width - 40, height: 40) // in the panel, top-left
            let onScreen = NSPoint(x: card.minX + row.midX, y: card.maxY - row.midY)
            c.preview.pointer = { onScreen }
            c.preview.hover(.note(id), inside: true, rect: row)
            try await Task.sleep(for: .milliseconds(900))
        }
        m.stop("hover")
    }

    /// The first note opened in a fresh process, cold, and after the launch prewarm (same steps as the app's).
    @Test func firstOpenCold() async throws { try await firstOpen(warm: false) }
    @Test func firstOpenWarm() async throws { try await firstOpen(warm: true) }

    private func firstOpen(warm: Bool) async throws {
        let (c, work, _) = try await panel()
        if warm {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let tv = NSTextView(frame: w.contentView!.bounds)
            tv.isContinuousSpellCheckingEnabled = true
            tv.isRichText = false
            w.contentView = tv
            w.makeFirstResponder(tv)
            tv.string = "Cortexy"
            tv.checkTextInDocument(nil)
            try await Task.sleep(for: .milliseconds(1500))
            w.close()
        }
        let first = c.store.folder(work)!.notes.first!.id, second = c.store.folder(work)!.notes.dropFirst().first!.id
        for (label, id) in [("first", first), ("second", second)] {
            let m = FrameMeter(); m.start(on: c.panel.contentView!)
            let t0 = CACurrentMediaTime()
            c.nav.route = .note(work, id)
            var opened = 0.0
            for _ in 0..<200 {
                try await Task.sleep(for: .milliseconds(2))
                if let tv = editorOf(c.panel.contentView!), tv.window != nil { opened = CACurrentMediaTime() - t0; break }
            }
            try await Task.sleep(for: .milliseconds(600))
            m.stop((warm ? "warm " : "cold ") + label)
            print(String(format: "SMOOTH %@ open %@: editor up after %.0f ms", warm ? "warm" : "cold", label, opened * 1000))
            c.nav.route = .folder(work)
            try await Task.sleep(for: .milliseconds(600))
        }
    }
}
