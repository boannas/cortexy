import AppKit
import LocalAuthentication
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Cortexy Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            // The panel stays up beside Settings (to see changes live) and takes the focus back after.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                if let c = PanelController.shared, c.shown { c.panel.makeKeyAndOrderFront(nil) }
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static var isKey: Bool { window?.isKeyWindow == true }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 640, height: 560)
    }
}

// MARK: General

/// A slider with its value written beside it.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    let label: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(label(value)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
        }
    }

    static func seconds(_ v: Double) -> String { v == 0 ? "Instant" : String(format: "%.2f s", v) }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.hotSide) private var hotSide = true
    @AppStorage(Prefs.side) private var side = "right"
    @AppStorage(Prefs.edgeDelay) private var delay = 0.15
    @AppStorage(Prefs.hideDelay) private var hideDelay = 0.35
    @AppStorage(Prefs.width) private var width = 360.0
    @AppStorage(Prefs.openBar) private var openBar = false
    @AppStorage(Prefs.menuBarIcon) private var menuBarIcon = true
    @AppStorage("colorStyle") private var colorStyle = "tint"
    @AppStorage(Prefs.hoverPreview) private var hoverPreview = true
    @AppStorage(Prefs.previewDelay) private var previewDelay = 0.45
    @AppStorage(Prefs.previewHideDelay) private var previewHideDelay = 0.2
    @AppStorage(Prefs.previewWidth) private var previewWidth = 0.0
    @AppStorage(Prefs.undoSeconds) private var undoSeconds = 5.0
    @AppStorage(Prefs.showTags) private var showTags = true
    @AppStorage(Prefs.codeTab) private var codeTab = 4
    @AppStorage(Prefs.webImages) private var webImages = true
    @AppStorage(Prefs.reminders) private var reminders = true
    @AppStorage(Prefs.remindAt) private var remindAt = 9
    @AppStorage(Prefs.templatesFolder) private var templatesFolder = "Templates"
    @AppStorage(Prefs.dailyFolder) private var dailyFolder = "Daily"
    @AppStorage(Prefs.dailyTemplate) private var dailyTemplate = ""
    @AppStorage(Prefs.dateFormat) private var dateFormat = "yyyy-MM-dd"
    @AppStorage(Prefs.systemCalendar) private var systemCalendar = false
    @AppStorage(Prefs.dateLanguage) private var dateLanguage = ""
    @Local private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Panel") {
                Picker("Screen edge", selection: $side) {
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                .pickerStyle(.segmented)
                Toggle("Open when the pointer touches the edge", isOn: $hotSide)
                ValueSlider(title: "Open after", value: $delay, range: 0...0.6, label: ValueSlider.seconds).disabled(!hotSide)
                ValueSlider(title: "Close after the pointer leaves", value: $hideDelay, range: 0...2, step: 0.05, label: ValueSlider.seconds)
                    .disabled(!hotSide)
                    .help("Only when the pointer opened the panel and you haven't clicked in it")
                ValueSlider(title: "Width", value: $width, range: 280...560, step: 10) { "\(Int($0)) pt" }
                Toggle("Show Open Bar on the screen edge", isOn: $openBar)
            }
            Section {
                Toggle("Preview a note when the pointer rests on its card", isOn: $hoverPreview)
                Group {
                    ValueSlider(title: "Show after", value: $previewDelay, range: 0.1...2, label: ValueSlider.seconds)
                    ValueSlider(title: "Hide after the pointer leaves", value: $previewHideDelay, range: 0...1.5, label: ValueSlider.seconds)
                    Toggle("Default width (300 pt)", isOn: Binding(get: { previewWidth == 0 }, set: { previewWidth = $0 ? 0 : 440 }))
                    if previewWidth > 0 {
                        ValueSlider(title: "Preview width", value: $previewWidth, range: 280...900, step: 10) { "\(Int($0)) pt" }
                    }
                }
                .disabled(!hoverPreview)
            } header: {
                Text("Preview")
            } footer: {
                Text("The preview opens beside the panel and scrolls; click its text to edit the note.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes") {
                Picker("Note colors", selection: $colorStyle) {
                    Text("Tinted background").tag("tint")
                    Text("Side bar").tag("bar")
                }
                Toggle("Show tags on the home screen", isOn: $showTags)
                Toggle("Load images from the web", isOn: $webImages)
                    .help("For ![](https://…) in notes. Off, they stay links and nothing is fetched (no tracking pixels).")
                ValueSlider(title: "Undo stays offered for", value: $undoSeconds, range: 2...20, step: 1) { "\(Int($0)) s" }
                Picker("Tab in code mode", selection: $codeTab) {
                    ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                }
            }
            Section {
                Toggle("Remind me when tasks are due", isOn: $reminders)
                Picker("Dates without a time remind at", selection: $remindAt) {
                    ForEach(5...22, id: \.self) { h in Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)).tag(h) }
                }
                .disabled(!reminders)
            } header: {
                Text("Due Dates")
            } footer: {
                Text("Give a task a date: “- [ ] Call Ann 📅 2026-10-05 14:30” (or @2026-10-05), or use the calendar button under the editor. They're listed under Upcoming on the home screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Templates folder", text: $templatesFolder)
                TextField("Daily notes folder", text: $dailyFolder)
                Picker("Daily note template", selection: $dailyTemplate) {
                    Text("None (just the date)").tag("")
                    // Each title once: two templates with one name would repeat an ID (and pick the same one anyway).
                    ForEach(NSOrderedSet(array: PanelController.shared?.nav.templates.map(\.title) ?? []).array as! [String], id: \.self) { Text($0).tag($0) }
                }
                TextField("Date format", text: $dateFormat)
                Picker("Month and day names", selection: $dateLanguage) {
                    Text("This Mac's language").tag("")
                    Text("ไทย").tag("th")
                    Text("English").tag("en")
                }
                if Calendar.current.identifier != .gregorian {
                    let name = Locale.current.localizedString(for: Calendar.current.identifier) ?? "\(Calendar.current.identifier)"
                    Toggle("Use this Mac's calendar for years (\(name))" as String, isOn: $systemCalendar)
                }
                LabeledContent("Today is", value: Nav.expand("{{date}} · {{weekday}}").text).id("\(systemCalendar)\(dateLanguage)")
            } header: {
                Text("Templates & Daily Notes")
            } footer: {
                Text("Notes in the templates folder show under ⋯ → New from Template and in ⌘P. In a template, {{date}} {{time}} {{weekday}} and {{folder}} fill in, {{date:MMMM yyyy}} takes any date format, and {{cursor}} is where typing starts. ⌘D opens today's note.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show in menu bar", isOn: $menuBarIcon)
                Toggle("Launch at login", isOn: Binding(get: { atLogin }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("Cortexy: login item: \(error)") // e.g. running outside the .app bundle
                        NSAlert(error: error).runModal()
                    }
                    // macOS may want it allowed in System Settings first: take the user there instead of just switching back off.
                    if on, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    atLogin = SMAppService.mainApp.status == .enabled
                }))
            } header: {
                Text("System")
            } footer: {
                Text("Without the menu bar icon, open Settings from the panel's ⋯ menu or with ⌘, while the panel is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    private let themes = Themes.shared

    var body: some View {
        let current = themes.current
        Form {
            Section("Color Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                    ForEach(themes.all) { t in
                        ThemeTile(theme: t, selected: t.id == themes.currentID)
                            .onTapGesture { themes.currentID = t.id }
                            .contextMenu {
                                Button("Duplicate") { themes.duplicate(t) }
                                if t.isCustom { Button("Delete", role: .destructive) { themes.delete(t.id) } }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            Section(current.isCustom ? "Customize “\(current.name)”" : "Customize") {
                if current.isCustom {
                    ThemeEditor(theme: current)
                    Button("Delete Theme", role: .destructive) { themes.delete(current.id) }
                } else {
                    HStack {
                        Text("Built-in themes can't be changed.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Duplicate and Edit") { themes.duplicate(current) }
                    }
                }
            }
            Section("Preview") { AppearancePreview() }
            LookEditor()
        }
        .formStyle(.grouped)
    }
}

/// A sample card drawn with the current theme, text and layout settings.
struct AppearancePreview: View {
    private static let sample: Note = {
        var n = Note()
        n.text = "# Groceries\n- [ ] Oat milk\n- [x] Coffee beans\n**Bold**, *italic* and `code`\nภาษาไทย อ่านง่าย\n> Bring the bags"
        n.color = .blue
        return n
    }()

    var body: some View {
        let theme = Themes.shared.current
        if let store = PanelController.shared?.store {
            NoteCard(note: Self.sample, store: store, exporting: true) // all of it, even with title-only cards, to see text settings
                .frame(width: 300)
                .padding(12)
                .background(theme.panelColor ?? .clear, in: .rect(cornerRadius: Themes.shared.look.cornerRadius + 8))
                .background(.regularMaterial, in: .rect(cornerRadius: Themes.shared.look.cornerRadius + 8))
                .tint(theme.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }
}

/// Text and layout settings (`Look`): they apply with any color theme.
struct LookEditor: View {
    private func bind<T>(_ kp: WritableKeyPath<Look, T>) -> Binding<T> {
        Binding(get: { Themes.shared.look[keyPath: kp] }, set: { Themes.shared.look[keyPath: kp] = $0 })
    }

    private func slider(_ title: String, _ kp: WritableKeyPath<Look, Double>, _ range: ClosedRange<Double>,
                        step: Double = 1, _ label: (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: bind(kp), in: range, step: step)
                Text(label(Themes.shared.look[keyPath: kp])).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
    }

    var body: some View {
        let look = Themes.shared.look
        Section {
            Toggle("Use the theme's font", isOn: bind(\.useThemeFont))
            Picker("Font", selection: bind(\.font)) {
                ForEach(Theme.Design.allCases) { Text($0.name).tag($0.rawValue) }
                Divider()
                ForEach(Fonts.families, id: \.self) { Text(Fonts.thai.contains($0) ? $0 : "\($0)  (no Thai)").tag($0) }
            }
            .disabled(look.useThemeFont)
            if !look.useThemeFont, Fonts.families.contains(look.font), !Fonts.thai.contains(look.font) {
                Text("\(look.font) has no Thai letters, so Thai text shows in the system's Thai font and may look heavier.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Stepper("Size: \(Int(look.fontSize)) pt", value: bind(\.fontSize), in: 10...28)
            slider("Line spacing", \.lineSpacing, 0...12) { "\(Int($0)) pt" }
            slider("Paragraph spacing", \.paragraphSpacing, 0...20) { "\(Int($0)) pt" }
            slider("Headings", \.headingScale, 0.5...2, step: 0.1) { "\(Int(($0 * 100).rounded()))%" }
            slider("List indent", \.listIndent, 0.8...3, step: 0.1) { "\(Int((look.fontSize * $0).rounded())) pt" }
            Picker("Code font", selection: bind(\.codeFont)) {
                Text("System Monospaced").tag("")
                Divider()
                ForEach(Fonts.monospaced, id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Text")
        } footer: {
            Text("With the theme's font on, Paper, Ivory and Sepia use Serif, Bubblegum and Cloud use Rounded, and Mono and Terminal use Monospaced.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Layout") {
            Picker("Appearance", selection: bind(\.mode)) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Picker("Density", selection: bind(\.density)) {
                ForEach(Look.Density.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            slider("Corner radius", \.cornerRadius, 4...22) { "\(Int($0)) pt" }
            Toggle("Cards show only the title (rest the pointer on one to read it)", isOn: bind(\.titleOnly))
            Stepper("Lines shown on cards: \(look.cardLines)", value: bind(\.cardLines), in: 2...40).disabled(look.titleOnly)
            Toggle("Show the formatting bar", isOn: bind(\.formatBar))
            Toggle("Show date and word count", isOn: bind(\.noteInfo))
            HStack {
                Spacer()
                Button("Reset Text & Layout") { Themes.shared.look = Look() }.disabled(look == Look())
            }
        }
    }
}

/// Installed font families for the pickers (hidden system faces start with ".").
enum Fonts {
    static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
    /// Families that have Thai letters.
    static let thai = Set(families.filter { f in
        NSFontManager.shared.font(withFamily: f, traits: [], weight: 5, size: 12)?.coveredCharacterSet.contains(Unicode.Scalar(0x0E01)!) == true
    })
    static let monospaced = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
        .compactMap { NSFont(name: $0, size: 12)?.familyName }).filter { !$0.hasPrefix(".") }.sorted()
}

struct ThemeTile: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        let tint = theme.panelTint.flatMap(Color.init(hex:))
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint?.opacity(min(1, theme.tintStrength * 2.4)) ?? .clear) }
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.85))
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.cardTint.flatMap(Color.init(hex:))?.opacity(0.2) ?? .clear) }
                    .overlay(alignment: .topLeading) {
                        Text("Aa").font(.system(size: 9, weight: .semibold, design: theme.design.swiftUI)).padding(3)
                    }
                    .padding(8)
                Circle().fill(theme.accentColor ?? .accentColor).frame(width: 8, height: 8).padding(4)
            }
            .frame(height: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
            }
            Text(theme.name).font(.caption).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct ThemeEditor: View {
    let theme: Theme

    private func set(_ change: (inout Theme) -> Void) {
        var t = theme
        change(&t)
        Themes.shared.update(t)
    }

    private func bind<T>(_ kp: WritableKeyPath<Theme, T>) -> Binding<T> {
        Binding(get: { theme[keyPath: kp] }, set: { v in set { $0[keyPath: kp] = v } })
    }

    /// An optional hex color as a toggle + color well.
    @ViewBuilder private func colorRow(_ title: String, _ kp: WritableKeyPath<Theme, String?>, off: String) -> some View {
        let value = theme[keyPath: kp]
        HStack {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { on in set { $0[keyPath: kp] = on ? "0A84FF" : nil } }))
            Spacer()
            if value == nil { Text(off).foregroundStyle(.secondary) }
            ColorPicker(title, selection: Binding(
                get: { value.flatMap(Color.init(hex:)) ?? .accentColor },
                set: { c in set { $0[keyPath: kp] = NSColor(c).hex } }
            ), supportsOpacity: false)
            .labelsHidden()
            .disabled(value == nil)
        }
    }

    var body: some View {
        TextField("Name", text: bind(\.name))
        colorRow("Panel tint", \.panelTint, off: "Plain glass")
        LabeledContent("Tint strength") { Slider(value: bind(\.tintStrength), in: 0.05...0.7) }
            .disabled(theme.panelTint == nil)
        colorRow("Card tint", \.cardTint, off: "None")
        LabeledContent("Card opacity") { Slider(value: bind(\.cardOpacity), in: 0.15...0.95) }
        colorRow("Accent", \.accent, off: "System")
        Picker("Suggested font", selection: bind(\.design)) {
            ForEach(Theme.Design.allCases) { Text($0.name).tag($0) }
        }
    }
}

// MARK: Shortcuts

struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Show or hide the panel") { HotKeyRecorder(key: Prefs.toggleKey) }
                LabeledContent("New note") { HotKeyRecorder(key: Prefs.newNoteKey) }
                LabeledContent("Today's note") { HotKeyRecorder(key: Prefs.todayKey) }
            } header: {
                Text("Global")
            } footer: {
                Text("Work from any app. Click a shortcut, then press the new keys (Esc cancels).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("In the panel") {
                ForEach(Self.panelKeys, id: \.0) { name, keys in LabeledContent(name, value: keys) }
            }
        }
        .formStyle(.grouped)
    }

    static let panelKeys: [(String, String)] = [
        ("New note / folder", "⌘N / ⇧⌘N"), ("Today's note", "⌘D"), ("Search", "⌘F"), ("Quick open / commands", "⌘O / ⌘P"), ("Back", "⌘[ or ←"),
        ("Move selection / open", "↑ ↓ / ↩"), ("Fold selected note", "Space"), ("Delete selected", "⌘⌫"),
        ("Move note to folder", "⇧⌘M"), ("Select several notes or folders", "⌘-click / ⇧-click / ⌘A"),
        ("Bold / italic / code / link", "⌘B / ⌘I / ⌘E / ⌘K"), ("Checklist / strikethrough", "⌘L / ⇧⌘X"),
        ("Indent list item", "⇥ / ⇧⇥"), ("Hide panel", "Esc or ⌘W"), ("Settings", "⌘,"),
    ]
}

struct HotKeyRecorder: View {
    @AppStorage private var stored: String
    @Local private var recording = false
    @Local private var monitor: Any?
    @Local private var closeObserver: Any?
    @Local private var problem: String?
    private let key: String

    init(key: String) {
        self.key = key
        _stored = AppStorage(wrappedValue: "", key)
    }

    private var fallback: String { Prefs.defaults[key] as? String ?? "" }
    /// The app's other global shortcuts, which this one mustn't repeat.
    private var others: [HotKeySpec] {
        [Prefs.toggleKey, Prefs.newNoteKey, Prefs.todayKey].filter { $0 != key }.compactMap { HotKeySpec(encoded: UserDefaults.standard.string(forKey: $0) ?? "") }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Type shortcut…" : HotKeySpec(encoded: stored)?.display ?? "Record Shortcut")
                        .frame(minWidth: 120)
                }
                if !stored.isEmpty && !recording {
                    Button { stored = ""; problem = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                        .accessibilityLabel("Clear shortcut")
                }
                if !fallback.isEmpty && stored != fallback && !recording {
                    Button { stored = fallback; problem = nil } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Back to \(HotKeySpec(encoded: fallback)?.display ?? "the default")")
                        .accessibilityLabel("Reset shortcut")
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard let window = NSApp.keyWindow else { return }
        recording = true
        HotKeys.shared.pause(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window === window else { return e } // only keys typed into Settings
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            guard let spec = HotKeySpec(event: e) else { NSSound.beep(); return nil }
            // Checked before it's kept: one that can't work, or that's taken, says why instead of failing silently.
            problem = HotKeys.problem(spec, others: others) ?? (HotKeys.shared.available(spec) ? nil : "\(spec.display) is taken by macOS or another app.")
            if problem == nil { stored = spec.encoded } else { NSSound.beep() }
            stop()
            return nil
        }
        // onDisappear doesn't fire when the (reused) Settings window closes.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in stop() }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        monitor = nil
        closeObserver = nil
        if recording { HotKeys.shared.pause(false) }
        recording = false
    }
}

// MARK: Data

struct DataSettings: View {
    @Local private var message: String?
    @AppStorage(Prefs.trashDays) private var trashDays = 30
    @AppStorage(Prefs.backupsKept) private var backupsKept = 14
    @AppStorage(Prefs.versionsKept) private var versionsKept = 50
    @AppStorage(Prefs.touchID) private var touchID = false
    @AppStorage(Prefs.lockOnHide) private var lockOnHide = true

    var body: some View {
        let dir = PanelController.shared?.store.directory ?? Store.configuredDirectory
        Form {
            Section {
                LabeledContent("Notes folder") {
                    Text(dir.path(percentEncoded: false)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("cortexy.json")]) }
                    Button("Change…", action: change)
                    if UserDefaults.standard.string(forKey: Prefs.dataDirectory) != nil {
                        Button("Use Default") { DataLocation.switchTo(nil) }
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Pick a folder in iCloud Drive, OneDrive or Dropbox to share notes between Macs. Edits from another Mac show up within seconds; if both change at once, the other version is kept as a conflict copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recently Deleted") {
                Picker("Keep deleted notes and folders", selection: $trashDays) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                    Text("Until emptied").tag(0)
                }
            }
            Section {
                let biometrics = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
                Toggle("Unlock with Touch ID", isOn: Binding(get: { touchID && biometrics }, set: { on in
                    touchID = on
                    if !on { Keychain.delete() }
                    else if let p = PanelController.shared?.nav.password { Keychain.save(p) } // open now: no need to type it again
                }))
                .disabled(!biometrics)
                .help(biometrics ? "" : "This Mac has no Touch ID set up")
                Toggle("Lock again when the panel closes", isOn: $lockOnHide)
                HStack {
                    Spacer()
                    Button("Lock All Now") { PanelController.shared?.nav.lockAll() }
                }
            } header: {
                Text("Locked Notes")
            } footer: {
                Text("Right-click a note → Lock Note. One password opens all locked notes; if it's forgotten, they can't be opened, not even by Cortexy. They also lock when the Mac sleeps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Versions kept per note", selection: $versionsKept) {
                    ForEach([10, 25, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
            } header: {
                Text("Version History")
            } footer: {
                Text("Kept when you open a note, every few minutes while you edit it, and when you leave it. Right-click a note → Version History.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backups & Export") {
                Picker("Daily backups to keep", selection: $backupsKept) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("Backups folder") {
                    Button("Open Backups Folder") {
                        let backups = dir.appendingPathComponent("Backups")
                        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true) // none yet on the first day
                        NSWorkspace.shared.open(backups)
                    }
                }
                LabeledContent("All notes as Markdown files") { Button("Export…", action: export) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Scripting", value: "cortexy:// links · AppleScript · Services menu")
            }
        }
        .formStyle(.grouped)
    }

    private func change() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use Folder"
        guard p.runModal() == .OK, let url = p.url else { return }
        DataLocation.switchTo(url)
    }

    private func export() {
        guard let store = PanelController.shared?.store else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Export Here"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let out = try store.exportMarkdown(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            message = "Exported to \(out.lastPathComponent)"
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}

enum DataLocation {
    /// Moves Cortexy to another data folder (nil = default) and restarts. An empty folder gets a copy of the
    /// current notes; a folder that already has Cortexy notes is used as is, and the old notes stay where they were.
    static func switchTo(_ dir: URL?) {
        guard let store = PanelController.shared?.store else { return }
        let target = dir ?? Store.defaultDirectory
        guard target.standardizedFileURL.path != store.directory.standardizedFileURL.path else { return }
        let fm = FileManager.default
        let hasNotes = fm.fileExists(atPath: target.appendingPathComponent("cortexy.json").path)

        let alert = NSAlert()
        alert.messageText = hasNotes ? "Use the notes already in “\(target.lastPathComponent)”?" : "Move your notes to “\(target.lastPathComponent)”?"
        alert.informativeText = hasNotes
            ? "That folder already has Cortexy notes. Your current notes stay in the old folder. Cortexy will restart."
            : "Your notes, attachments, version history and backups are copied there. Cortexy will restart."
        alert.addButton(withTitle: hasNotes ? "Switch" : "Move Notes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.save()
        if !hasNotes {
            do {
                try store.copyLibrary(to: target)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
        if let dir { UserDefaults.standard.set(dir.path, forKey: Prefs.dataDirectory) }
        else { UserDefaults.standard.removeObject(forKey: Prefs.dataDirectory) }
        relaunch()
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
