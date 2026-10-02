import AppKit
import SwiftUI

@main
struct CortexyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    @AppStorage(Prefs.menuBarIcon) private var menuBarIcon = true

    var body: some Scene {
        MenuBarExtra("Cortexy", systemImage: "note.text", isInserted: $menuBarIcon) {
            Button("Show Cortexy") { app.controller?.show(byHover: false) }
            Button("New Note") {
                app.controller?.nav.newNote()
                app.controller?.show(byHover: false)
            }
            Divider()
            QuickSettingsMenu()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PanelController?
    private var queuedURLs: [URL] = []
    private let services = ServiceProvider()

    func applicationWillFinishLaunching(_ n: Notification) {
        Prefs.register()
        Reminders.shared.start() // before launch ends, so clicking a reminder that launched the app is caught
        // cortexy:// links (Raycast, Alfred, Shortcuts, `open cortexy://new?text=hi`)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, even when run via `swift run`
        NSApp.appearance = Themes.shared.look.appearance
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        let dir = ProcessInfo.processInfo.environment["CORTEXY_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? Store.configuredDirectory
        let store = Store(directory: dir)
        let c = PanelController(store: store)
        controller = c
        #if DEBUG
        if Snapshot.runIfRequested(c) { return }
        #endif
        NoteWindows.shared.restore(nav: c.nav)
        // Launch activation settles after this returns and would steal key focus (closing the panel), so wait a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            if store.isFirstRun || store.recovering || !queuedURLs.isEmpty { c.show(byHover: false) }
            if store.recovering { c.nav.flash("Your notes file couldn't be read yet, so the newest backup is showing. Edits you make now will replace the file.") }
            queuedURLs.forEach(c.handle)
            queuedURLs = []
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows the panel — the way back if the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show(byHover: false)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NoteWindows.quitting = true // the windows open now should open again next time
        return .terminateNow
    }

    func applicationWillTerminate(_ n: Notification) {
        controller?.nav.lockAll() // notes written in an open locked folder are sealed before they're saved
        controller?.store.save()
    }

    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if let controller { controller.handle(url) } else { queuedURLs.append(url) }
    }
}
