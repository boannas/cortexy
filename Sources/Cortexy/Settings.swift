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
    @AppStorage(Prefs.webImages) private var webImages = false
    @AppStorage(Prefs.reminders) private var reminders = true
    @AppStorage(Prefs.remindAt) private var remindAt = 9
    @AppStorage(Prefs.templatesFolder) private var templatesFolder = "Templates"
    @AppStorage(Prefs.dailyFolder) private var dailyFolder = "Daily"
    @AppStorage(Prefs.dailyTemplate) private var dailyTemplate = ""
    @AppStorage(Prefs.dateFormat) private var dateFormat = "yyyy-MM-dd"
    @AppStorage(Prefs.systemCalendar) private var systemCalendar = false
    @AppStorage(Prefs.dateLanguage) private var dateLanguage = ""
    @AppStorage(Prefs.keepOpen) private var keepOpen = false
    @AppStorage(Prefs.panelOpacity) private var panelOpacity = 1.0
    @AppStorage(Prefs.hideFromCapture) private var hideFromCapture = false
    @AppStorage(Prefs.quickLook) private var quickLook = true
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
                Toggle("Keep the panel open when I click elsewhere (⇧⌘P)", isOn: $keepOpen)
                ValueSlider(title: "Opacity", value: $panelOpacity, range: 0.4...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                Toggle("Hide Cortexy from screen sharing and recordings", isOn: $hideFromCapture)
                    .help("Its windows are left out of screen sharing, recordings and screenshots, yours included")
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
                Toggle("Load web images in every note", isOn: $webImages)
                Toggle("Double-click an attachment to preview it (Quick Look)", isOn: $quickLook)
                    .help("For ![](https://…) in notes. Off, a note's web images load only after you press Load in it: fetching one tells its server you opened the note.")
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
            RestoreDefaults(keys: Self.keys)
        }
        .formStyle(.grouped)
    }

    /// What this tab sets (launch at login is the system's, not reset).
    static let keys = [Prefs.hotSide, Prefs.side, Prefs.edgeDelay, Prefs.hideDelay, Prefs.width, Prefs.openBar, Prefs.menuBarIcon, "colorStyle",
                       Prefs.hoverPreview, Prefs.previewDelay, Prefs.previewHideDelay, Prefs.previewWidth, Prefs.undoSeconds, Prefs.showTags,
                       Prefs.codeTab, Prefs.webImages, Prefs.reminders, Prefs.remindAt, Prefs.templatesFolder, Prefs.dailyFolder,
                       Prefs.dailyTemplate, Prefs.dateFormat, Prefs.systemCalendar, Prefs.dateLanguage,
                       Prefs.keepOpen, Prefs.panelOpacity, Prefs.hideFromCapture, Prefs.quickLook]
}

/// A tab's "Restore Defaults": its settings back to how Cortexy comes (asks first).
struct RestoreDefaults: View {
    let keys: [String]
    var also: () -> Void = {}

    var body: some View {
        let changed = keys.contains { UserDefaults.standard.object(forKey: $0) != nil } // set by hand (defaults aren't stored)
        HStack {
            Spacer()
            Button("Restore Defaults…") {
                let a = NSAlert()
                a.messageText = "Restore this tab's settings to how Cortexy comes?"
                a.addButton(withTitle: "Restore")
                a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                for k in keys { UserDefaults.standard.removeObject(forKey: k) }
                also()
            }
            .disabled(!changed)
        }
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
                // Grouped by what they can write: a font missing Thai or English says so in its name too.
                Section("System (Thai in Thonburi)") {
                    ForEach(Theme.Design.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Section("Thai and English") {
                    ForEach(Fonts.families.filter { Fonts.thai.contains($0) && Fonts.latin.contains($0) }, id: \.self) { Text($0).tag($0) }
                }
                Section("⚠︎ No Thai — Thai shows in Thonburi") {
                    ForEach(Fonts.families.filter { !Fonts.thai.contains($0) && Fonts.latin.contains($0) }, id: \.self) { Text("\($0) — no Thai").tag($0) }
                }
                Section("⚠︎ No English letters") {
                    ForEach(Fonts.families.filter { !Fonts.latin.contains($0) }, id: \.self) {
                        Text("\($0) — \(Fonts.thai.contains($0) ? "no English" : "no Thai or English")").tag($0)
                    }
                }
            }
            .disabled(look.useThemeFont)
            FontCoverage(style: Themes.shared.textStyle)
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
    /// Families that have English (Latin) letters: some are for one other script, or symbols, only.
    static let latin = Set(families.filter { f in
        let set = NSFontManager.shared.font(withFamily: f, traits: [], weight: 5, size: 12)?.coveredCharacterSet
        return set?.contains(Unicode.Scalar(0x41)!) == true && set?.contains(Unicode.Scalar(0x61)!) == true
    })

    /// What `font` itself has, and the fonts the system writes Thai and English in where it has none.
    static func coverage(_ font: NSFont) -> (thai: Bool, english: Bool, thaiStandIn: String, englishStandIn: String) {
        let set = font.coveredCharacterSet
        func standIn(_ s: String) -> String {
            let f = CTFontCreateForString(font as CTFont, s as CFString, CFRange(location: 0, length: 1))
            return (CTFontCopyFamilyName(f) as String).trimmingCharacters(in: CharacterSet(charactersIn: ".")).replacingOccurrences(of: "UI", with: "")
        }
        return (set.contains(Unicode.Scalar(0x0E01)!), set.contains(Unicode.Scalar(0x41)!) && set.contains(Unicode.Scalar(0x61)!),
                standIn("ก"), standIn("A"))
    }

    static let monospaced = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
        .compactMap { NSFont(name: $0, size: 12)?.familyName }).filter { !$0.hasPrefix(".") }.sorted()
}

/// Under the font picker: a line of English and Thai in the font as notes will show it, and in plain words
/// whether the font has each (a theme's or a chosen font with no Thai is marked, not left to be noticed).
struct FontCoverage: View {
    let style: TextStyle

    var body: some View {
        let font = style.body, has = Fonts.coverage(font), name = font.familyName ?? font.fontName
        let system = style.family == nil // a system design: Thai in the system's Thai font is how macOS writes it
        VStack(alignment: .leading, spacing: 5) {
            Text("Aa Bb 123  ·  ภาษาไทย กขค ๑๒๓").font(Font(font as CTFont)).lineLimit(1)
            Group {
                switch (has.thai, has.english) {
                case (true, true):
                    Label("\(name) has Thai and English", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case (false, true) where system:
                    Label("System font: Thai is written in \(has.thaiStandIn)", systemImage: "info.circle").foregroundStyle(.secondary)
                case (false, true):
                    Label("\(name) has no Thai: Thai shows in \(has.thaiStandIn), and may look heavier or out of place",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case (true, false):
                    Label("\(name) has no English letters: English shows in \(has.englishStandIn)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case (false, false):
                    Label("\(name) has neither Thai nor English letters: English shows in \(has.englishStandIn), Thai in \(has.thaiStandIn). Pick another font.",
                          systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .font(.caption.weight(.medium))
        }
    }
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
                        Text("Aa ก").font(.system(size: 9, weight: .semibold, design: theme.design.swiftUI)).padding(3)
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
        Text("System designs have no Thai of their own: Thai is written in Thonburi with any of them.")
            .font(.caption).foregroundStyle(.secondary)
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
            CustomShortcutsSection()
            Section("In the panel") {
                ForEach(Self.panelKeys, id: \.0) { name, keys in LabeledContent(name, value: keys) }
            }
            // The three global ones; shortcuts you made stay (each has its own remove button).
            RestoreDefaults(keys: [Prefs.toggleKey, Prefs.newNoteKey, Prefs.todayKey]) { PanelController.shared?.registerHotKeys() }
        }
        .formStyle(.grouped)
    }

    static let panelKeys: [(String, String)] = [
        ("New note / folder", "⌘N / ⇧⌘N"), ("Today's note", "⌘D"), ("Search", "⌘F"), ("Quick open / commands", "⌘O / ⌘P"), ("Back", "⌘[ or ← (outside a note)"),
        ("Move selection / open", "↑ ↓ / ↩"), ("Fold selected note", "Space"), ("Delete selected", "⌘⌫"),
        ("Move note to folder", "⇧⌘M"), ("Select several notes or folders", "⌘-click / ⇧-click / ⌘A"),
        ("Bold / italic / code / link", "⌘B / ⌘I / ⌘E / ⌘K"), ("Checklist / strikethrough", "⌘L / ⇧⌘X"),
        ("Indent list item", "⇥ / ⇧⇥"), ("Lines in / out in a note", "⌘] / ⌘["), ("Move lines up / down", "⌥⌘↑ / ⌥⌘↓"),
        ("Copy a code block, heading, list item or quote", "⌘-click (a link: ⌥⌘-click)"), ("Keep the panel open", "⇧⌘P"), ("Hide panel", "Esc or ⌘W"), ("Settings", "⌘,"),
    ]
}

struct HotKeyRecorder: View {
    @AppStorage private var stored: String
    private let key: String

    init(key: String) {
        self.key = key
        _stored = AppStorage(wrappedValue: "", key)
    }

    /// The app's other global shortcuts (its own and the user's), which this one mustn't repeat.
    private var others: [HotKeySpec] {
        [Prefs.toggleKey, Prefs.newNoteKey, Prefs.todayKey].filter { $0 != key }.compactMap { HotKeySpec(encoded: UserDefaults.standard.string(forKey: $0) ?? "") }
            + CustomShortcut.all.compactMap(\.spec)
    }

    var body: some View {
        KeyRecorder(keys: $stored, fallback: Prefs.defaults[key] as? String ?? "") { spec in
            HotKeys.problem(spec, others: others) ?? (HotKeys.shared.available(spec) ? nil : "\(spec.display) is taken by macOS or another app.")
        }
    }
}

/// Click, then press the keys (Esc cancels): kept only if `check` finds nothing wrong, else it says why.
struct KeyRecorder: View {
    @Binding var keys: String
    var fallback = ""
    let check: (HotKeySpec) -> String?
    @Local private var recording = false
    @Local private var monitor: Any?
    @Local private var closeObserver: Any?
    @Local private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Type shortcut…" : HotKeySpec(encoded: keys)?.display ?? "Record Shortcut")
                        .frame(minWidth: 120)
                }
                if !keys.isEmpty && !recording {
                    Button { keys = ""; problem = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                        .accessibilityLabel("Clear shortcut")
                }
                if !fallback.isEmpty && keys != fallback && !recording {
                    Button { keys = fallback; problem = nil } label: { Image(systemName: "arrow.counterclockwise") }
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
            problem = check(spec)
            if problem == nil { keys = spec.encoded } else { NSSound.beep() }
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

/// Shortcuts the user makes: keys → a template to start a note from, or a note to open.
struct CustomShortcutsSection: View {
    @Local private var shortcuts = CustomShortcut.all

    var body: some View {
        let nav = PanelController.shared?.nav
        Section {
            ForEach($shortcuts) { $s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $s.action) { ForEach(CustomShortcut.Action.allCases) { Text($0.name).tag($0) } }
                            .labelsHidden()
                            .fixedSize()
                        Picker("", selection: $s.target) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(targets(s.action, nav), id: \.id) { n in Text(n.title).tag(UUID?.some(n.id)) }
                        }
                        .labelsHidden()
                        Spacer(minLength: 8)
                        KeyRecorder(keys: $s.keys) { spec in
                            CustomShortcut.problem(spec, anywhere: s.anywhere, others: others(than: s.id))
                        }
                        Button { shortcuts.removeAll { $0.id == s.id } } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove this shortcut")
                            .accessibilityLabel("Remove shortcut")
                    }
                    HStack(spacing: 10) {
                        if s.action == .template {
                            Text("into").foregroundStyle(.secondary)
                            Picker("Into", selection: $s.folder) {
                                Text("Home").tag(UUID?.none)
                                ForEach(folders(nav), id: \.id) { f in Text(nav?.store.path(f.id) ?? f.name).tag(UUID?.some(f.id)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            if let id = s.folder, !folders(nav).contains(where: { $0.id == id }) {
                                Text("Its folder is gone: notes go home").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Toggle("From any app", isOn: $s.anywhere)
                            .toggleStyle(.checkbox)
                            .onChange(of: s.anywhere) {
                                // Keys that can't work there are dropped (and the reason shown by the recorder next time).
                                if let spec = s.spec, CustomShortcut.problem(spec, anywhere: s.anywhere, others: others(than: s.id)) != nil { s.keys = "" }
                            }
                        if let note = s.replaces { Text(note).font(.caption).foregroundStyle(.orange) }
                        if s.target != nil, !targets(s.action, nav).contains(where: { $0.id == s.target }) {
                            Text("Its \(s.action == .template ? "template" : "note") is gone").font(.caption).foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 2)
            }
            Button("Add Shortcut") { shortcuts.append(CustomShortcut()) }
        } header: {
            Text("Your shortcuts")
        } footer: {
            Text("Start a note from a template, or open a note, with keys of your own. They work in Cortexy; with “From any app” they work everywhere, and need ⌃ or ⌥ so they don't take another app's ⌘ keys.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: shortcuts) { CustomShortcut.all = shortcuts; PanelController.shared?.registerHotKeys() }
    }

    /// Where a template's notes can go: folders that hold notes (not smart ones, not Templates itself).
    private func folders(_ nav: Nav?) -> [Folder] {
        guard let nav else { return [] }
        return nav.store.moveTargets.filter { $0.id != Folder.rootID && $0.id != nav.templatesFolder?.id }
            .sorted { nav.store.path($0.id).localizedStandardCompare(nav.store.path($1.id)) == .orderedAscending }
    }

    /// Templates for the template action; every live note for the other.
    private func targets(_ a: CustomShortcut.Action, _ nav: Nav?) -> [Note] {
        guard let nav else { return [] }
        if a == .template { return nav.templates }
        return nav.store.liveFolders.flatMap(\.notes).filter { !$0.archived }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Every other shortcut's keys, built-in global ones included.
    private func others(than id: UUID) -> [HotKeySpec] {
        shortcuts.filter { $0.id != id }.compactMap(\.spec)
            + [Prefs.toggleKey, Prefs.newNoteKey, Prefs.todayKey].compactMap { HotKeySpec(encoded: UserDefaults.standard.string(forKey: $0) ?? "") }
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
                    Button("Change Password…") { PanelController.shared?.nav.askToChangePassword() }
                        .disabled(PanelController.shared?.nav.anyLocked != true)
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
            // Not the notes folder, Touch ID or the password: those aren't settings to undo by accident.
            RestoreDefaults(keys: [Prefs.trashDays, Prefs.backupsKept, Prefs.versionsKept, Prefs.lockOnHide])
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
