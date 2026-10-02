#if DEBUG
import AppKit

/// Dev tool for screenshot tests: `CORTEXY_SNAPSHOT_DIR=/tmp/s CORTEXY_DATA_DIR=/tmp/d .build/debug/Cortexy`
/// walks through every screen on throwaway data. At each step it writes `<step>.ready` containing the
/// screen rect to capture (x,y,w,h, top-left origin) and waits for `<step>.done` before moving on.
enum Snapshot {
    static func runIfRequested(_ c: PanelController) -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["CORTEXY_SNAPSHOT_DIR"] else { return false }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = c.store, nav = c.nav, themes = Themes.shared
        let keepTheme = themes.currentID
        themes.currentID = "system"
        seed(store)
        let work = store.folders.first { $0.name == "Work" }!, home = store.folders.first { $0.name == "Home" }!
        let sprint = work.notes.first { $0.text.hasPrefix("# Sprint") }!
        c.holdOpen += 1 // stay up even if another app takes focus mid-run

        var steps: [(String, () -> NSWindow)] = [
            ("01-folders", { nav.route = .home; return c.panel }),
            ("02-notes", { nav.route = .folder(work.id); return c.panel }),
            ("03-selection", { nav.moveSelection(1); nav.moveSelection(1); return c.panel }),
            ("04-editor", { nav.route = .note(work.id, sprint.id); return c.panel }),
            ("05-search", { nav.route = .home; nav.search = "milk"; return c.panel }),
            ("06-theme-midnight", { nav.search = ""; themes.currentID = "midnight"; nav.route = .folder(work.id); return c.panel }),
            ("07-theme-paper-editor", { themes.currentID = "paper"; nav.route = .note(home.id, home.notes[0].id); return c.panel }),
            ("08-theme-terminal", { themes.currentID = "terminal"; nav.route = .folder(work.id); return c.panel }),
            ("09-settings", { themes.currentID = "system"; SettingsWindow.show(); return NSApp.windows.first { $0.title == "Cortexy Settings" }! }),
        ]
        func next() {
            guard !steps.isEmpty else {
                themes.currentID = keepTheme
                NSApp.terminate(nil)
                return
            }
            let (name, go) = steps.removeFirst()
            let w = go()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSLog("snapshot \(name): shown=\(c.shown) visible=\(w.isVisible) key=\(w.isKeyWindow) alpha=\(w.alphaValue) frame=\(w.frame)")
                let f = w.frame, top = NSScreen.screens[0].frame.maxY
                try? "\(Int(f.minX)),\(Int(top - f.maxY)),\(Int(f.width)),\(Int(f.height))"
                    .write(to: out.appendingPathComponent("\(name).ready"), atomically: true, encoding: .utf8)
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
                    guard FileManager.default.fileExists(atPath: out.appendingPathComponent("\(name).done").path) else { return }
                    t.invalidate()
                    next()
                }
            }
        }
        // Showing during launch doesn't animate, so wait for launch to finish (as the real app does).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c.show(byHover: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { next() }
        return true
    }

    private static func seed(_ s: Store) {
        guard !s.folders.contains(where: { $0.name == "Work" }) else { return } // (a new library also has the guide)
        let work = s.addFolder("Work")
        s.updateFolder(work) { $0.color = .blue; $0.pinned = true }
        let img = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { r in
            NSGradient(colors: [.systemIndigo, .systemTeal])?.draw(in: r, angle: 30)
            ("Q3 roadmap" as NSString).draw(at: NSPoint(x: 40, y: 150), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.white])
            return true
        }
        let shot = s.markdown(forImage: img) ?? ""
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        s.addNote(to: work, text: "Design review\n\(shot)\n\(s.markdown(forFile: readme))")
        s.addNote(to: work, text: "# Sprint 42\n- [x] Review PR #318\n- [ ] Ship **Cortexy** 0.2\n- [ ] Update `build.sh` docs\n  - [ ] indented subtask\n\n\(shot)\nDemo on Friday — colors #3B82F6 and #F97316")
        let snippet = s.addNote(to: work, text: "Thanks for your email! I'll get back to you by end of day.")!
        s.updateNote(work, snippet) { $0.snippet = true; $0.color = .green }
        s.updateNote(work, s.folder(work)!.notes.last!.id) { $0.folded = true }
        let home = s.addFolder("Home")
        s.updateFolder(home) { $0.color = .green }
        s.addNote(to: home, text: "## Groceries\n- [ ] milk\n- [ ] eggs\n- [x] coffee\n\n> buy the oat one")
        let ideas = s.addFolder("Ideas", in: work)
        let code = s.addNote(to: ideas, text: "func greet() {\n    print(\"hello\")\n}")!
        s.updateNote(ideas, code) { $0.code = true }
    }
}
#endif
