import AppKit
import Observation
import SwiftUI

/// Themes tint the glass panel and cards and pick fonts; text colors stay system-adaptive,
/// so every theme works in both Light and Dark mode.
struct Theme: Codable, Identifiable, Hashable {
    enum Design: String, Codable, CaseIterable, Identifiable {
        case standard, rounded, serif, mono
        var id: Self { self }
        var name: String { ["standard": "System", "rounded": "Rounded", "serif": "Serif", "mono": "Monospaced"][rawValue]! }
        var swiftUI: Font.Design { [.default, .rounded, .serif, .monospaced][Design.allCases.firstIndex(of: self)!] }
        var appKit: NSFontDescriptor.SystemDesign { [.default, .rounded, .serif, .monospaced][Design.allCases.firstIndex(of: self)!] }
    }

    var id: String
    var name: String
    var panelTint: String? = nil // hex; nil = plain glass
    var tintStrength = 0.25
    var cardTint: String? = nil
    var cardOpacity = 0.55
    var accent: String? = nil    // nil = system accent color
    var design = Design.standard // the theme's suggested typeface; `Look.useThemeFont` decides if it's used
    var fontSize = 14.0          // older custom themes set a size; it now only seeds `Look.fontSize`
    var isCustom = false

    var accentColor: Color? { accent.flatMap(Color.init(hex:)) }
    var accentNSColor: NSColor? { accent.flatMap(NSColor.init(hex:)) }
    /// The panel's tint, painted under plain glass rather than via `Glass.tint`: the system drops glass tint
    /// while the window isn't key, and a hover-opened panel never is.
    /// A dark tint (Obsidian, Dracula…) under Light mode's black text is thinned, so labels stay readable.
    var panelColor: Color? {
        guard let hex = panelTint, let c = NSColor(hex: hex) else { return nil }
        let darkTint = c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114 < 0.35
        let lightMode = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua
        return Color(nsColor: c).opacity(darkTint && lightMode ? min(tintStrength, 0.2) : tintStrength)
    }
}

/// Text and layout from Settings → Appearance, kept apart from the color theme. With `useThemeFont` on,
/// the theme picks the typeface (Paper is serif, Terminal monospaced); everything else here always applies.
struct Look: Codable, Equatable {
    enum Density: String, Codable, CaseIterable, Identifiable {
        case compact, comfortable, roomy
        var id: Self { self }
        var cardPadding: CGFloat { [6, 10, 14][Density.allCases.firstIndex(of: self)!] }
        var spacing: CGFloat { [3, 6, 10][Density.allCases.firstIndex(of: self)!] }
        var rowHeight: CGFloat { [28, 34, 40][Density.allCases.firstIndex(of: self)!] }
    }

    var useThemeFont = true
    var font = Theme.Design.standard.rawValue // a system design, or an installed font family
    var fontSize = 14.0
    var lineSpacing = 2.0
    var paragraphSpacing = 5.0
    var headingScale = 1.0
    var listIndent = 1.6                      // one level of list nesting, in text sizes
    var codeFont = ""                         // "" = the system monospaced font
    var density = Density.comfortable
    var cornerRadius = 14.0                   // cards; rows and the panel follow it
    var titleOnly = true                      // cards show just the title; rest the pointer on one to read it
    var cardLines = 14
    var formatBar = true
    var noteInfo = true
    var mode = "system"                       // system, light, dark

    var appearance: NSAppearance? { mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil }

    /// Saved settings over the defaults, so a missing or new field never loses the rest.
    static func decode(_ data: Data?) -> Look? {
        guard let data, let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Look())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(saved) { _, new in new }) else { return nil }
        return try? JSONDecoder().decode(Look.self, from: merged)
    }
}

extension Theme {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Theme"
        panelTint = try c.decodeIfPresent(String.self, forKey: .panelTint)
        tintStrength = try c.decodeIfPresent(Double.self, forKey: .tintStrength) ?? 0.25
        cardTint = try c.decodeIfPresent(String.self, forKey: .cardTint)
        cardOpacity = try c.decodeIfPresent(Double.self, forKey: .cardOpacity) ?? 0.55
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        design = (try? c.decodeIfPresent(Design.self, forKey: .design)) ?? .standard
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? true
    }

    private static func t(_ name: String, _ tint: String?, _ card: String?, _ accent: String?,
                          _ design: Design = .standard, strength: Double = 0.25) -> Theme {
        Theme(id: name.lowercased(), name: name, panelTint: tint, tintStrength: strength,
              cardTint: card, accent: accent, design: design)
    }

    static let builtIn: [Theme] = [
        t("System", nil, nil, nil),
        t("Graphite", "6B6B70", nil, "8E8E93"),
        t("Charcoal", "2C2C2E", "3A3A3C", "0A84FF", strength: 0.55),
        t("Obsidian", "000000", "000000", "BF5AF2", strength: 0.55),
        t("Slate", "475569", "64748B", "3B82F6", strength: 0.3),
        t("Midnight", "1C2A4A", "2E4A7D", "5E8BFF", strength: 0.45),
        t("Denim", "1F4E79", "4A7BB7", "4A90E2", strength: 0.4),
        t("Ocean", "0A84FF", "0A84FF", "0A84FF", strength: 0.22),
        t("Sky", "64D2FF", "64D2FF", "0A84FF", strength: 0.2),
        t("Glacier", "A5D8FF", "D0EBFF", "339AF0"),
        t("Lagoon", "30B0C7", "30B0C7", "30B0C7"),
        t("Seafoam", "2EC4B6", "CBF3F0", "2EC4B6"),
        t("Mint", "63E6BE", "63E6BE", "00A67E"),
        t("Aurora", "00C9A7", "845EC2", "00C9A7", strength: 0.3),
        t("Forest", "2F6B3A", "34C759", "34C759", strength: 0.35),
        t("Moss", "5C6B3C", "8A9A5B", "6B8E23", strength: 0.35),
        t("Matcha", "9DBF6B", "B5D67E", "6E9E2F"),
        t("Lemon", "FFD60A", "FFD60A", "C9A100", strength: 0.2),
        t("Butter", "FFF3B0", "FFF3B0", "E0A800"),
        t("Tangerine", "FF8C00", "FFB347", "FF8C00", strength: 0.22),
        t("Sunset", "FF9F0A", "FF6B3D", "FF6B3D"),
        t("Ember", "5A1A0A", "FF6B3D", "FF9F0A", strength: 0.45),
        t("Peach", "FFB199", "FFB199", "FF7A59"),
        t("Coral", "FF6F61", "FF6F61", "FF453A", strength: 0.22),
        t("Cherry", "C81E3A", "FF375F", "FF375F", strength: 0.3),
        t("Rose", "FF7AA2", "FF7AA2", "FF2D55"),
        t("Bubblegum", "FF9FF3", "FECAE0", "F368E0", .rounded),
        t("Lilac", "D7C4F2", "E6DAF7", "9B72CF"),
        t("Lavender", "B79CFF", "B79CFF", "8E6BFF"),
        t("Grape", "7D3CFF", "9B6BFF", "AF52DE", strength: 0.3),
        t("Plum", "5B2A5C", "8E4585", "C45AB3", strength: 0.4),
        t("Dracula", "282A36", "BD93F9", "FF79C6", strength: 0.55),
        t("Nord", "5E81AC", "88C0D0", "5E81AC", strength: 0.3),
        t("Solarized", "B58900", "FDF6E3", "268BD2", strength: 0.18),
        t("Sand", "D6C3A5", "E6D5B8", "A67C52"),
        t("Paper", "F5EFE0", "F5EFE0", "A67C52", .serif),
        t("Ivory", "FFFFF0", "FFFFF0", "8E6B3E", .serif, strength: 0.2),
        t("Sepia", "8B6B4A", "C9A27E", "8B5E3C", .serif, strength: 0.3),
        t("Espresso", "3B2A20", "6F4E37", "C08552", strength: 0.5),
        t("Cloud", "E5E5EA", "FFFFFF", "0A84FF", .rounded, strength: 0.2),
        t("Mono", nil, nil, "8E8E93", .mono),
        t("Terminal", "0B3D0B", "00C853", "00E676", .mono, strength: 0.5),
    ]
}

@Observable final class Themes {
    static let shared = Themes()

    var custom: [Theme] { didSet { persist() } }
    var currentID: String { didSet { UserDefaults.standard.set(currentID, forKey: "themeID") } }
    var look: Look {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(look), forKey: "look")
            if look.mode != oldValue.mode { NSApp?.appearance = look.appearance }
        }
    }

    var all: [Theme] { Theme.builtIn + custom }
    var current: Theme { all.first { $0.id == currentID } ?? Theme.builtIn[0] }

    private init() {
        let d = UserDefaults.standard
        let id = d.string(forKey: "themeID") ?? "system"
        let custom = d.data(forKey: "customThemes").flatMap { try? JSONDecoder().decode([Theme].self, from: $0) } ?? []
        currentID = id
        self.custom = custom
        // First run with separate settings: keep the size the current custom theme had.
        look = Look.decode(d.data(forKey: "look"))
            ?? { var l = Look(); l.fontSize = custom.first { $0.id == id }?.fontSize ?? 14; return l }()
    }

    /// The typeface the look and theme add up to: a system design, or nil for an installed family (`look.font`).
    var design: Theme.Design? { look.useThemeFont ? current.design : Theme.Design(rawValue: look.font) }

    /// Fonts and spacing for the editor and the note cards.
    var textStyle: TextStyle {
        let l = look
        return TextStyle(size: l.fontSize, design: (design ?? .standard).appKit, family: design == nil ? l.font : nil,
                         codeFamily: l.codeFont.isEmpty ? nil : l.codeFont, accent: current.accentNSColor,
                         lineSpacing: l.lineSpacing, paragraphSpacing: l.paragraphSpacing, headingScale: l.headingScale,
                         indentScale: l.listIndent)
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: "customThemes")
    }

    /// Copies a theme into an editable custom one and selects it.
    func duplicate(_ t: Theme) {
        var n = t
        n.id = UUID().uuidString
        n.name = "\(t.name) Copy"
        n.isCustom = true
        custom.append(n)
        currentID = n.id
    }

    func update(_ t: Theme) {
        if let i = custom.firstIndex(where: { $0.id == t.id }) { custom[i] = t }
    }

    func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        if currentID == id { currentID = "system" }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

extension Color {
    init?(hex: String) {
        guard let c = NSColor(hex: hex) else { return nil }
        self.init(nsColor: c)
    }
}

extension NoteColor {
    /// Folder icons in the theme's key: less saturated, nudged toward the panel tint, so they sit on
    /// tinted glass instead of shouting over it. Note cards already use these colors at low opacity.
    func harmonized(with theme: Theme) -> Color? {
        guard let c = nsColor?.usingColorSpace(.sRGB) else { return nil }
        var (h, s, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var soft = NSColor(hue: h, saturation: s * 0.62, brightness: min(1, b * 0.96 + 0.04), alpha: a)
        if let tint = theme.panelTint.flatMap(NSColor.init(hex:)), let mixed = soft.blended(withFraction: 0.18, of: tint) {
            soft = mixed
        }
        return Color(nsColor: soft)
    }
}

extension Color {
    /// The accent as TEXT: pulled toward the label color until it reads (4.5:1) on the panel, light or dark.
    /// The raw accent stays for fills and outlines; Terminal's green or Lemon's yellow can't be read as text.
    static var cortexyAccentText: Color {
        let base = Themes.shared.current.accentNSColor ?? .controlAccentColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let backdrop = dark ? 0.12 : 0.93 // the panel's typical luminance
            func lum(_ c: NSColor) -> Double {
                let c = c.usingColorSpace(.sRGB) ?? c
                func f(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
            }
            func ratio(_ c: NSColor) -> Double { (max(lum(c), backdrop) + 0.05) / (min(lum(c), backdrop) + 0.05) }
            var c = base.usingColorSpace(.sRGB) ?? base, mix = 0.0
            while ratio(c) < 4.5, mix < 1 {
                mix += 0.1
                c = (base.usingColorSpace(.sRGB) ?? base).blended(withFraction: mix, of: dark ? .white : .black) ?? c
            }
            return c
        })
    }

    /// The theme's accent (Rose, Forest…), else the system's: for highlights SwiftUI's `.tint` doesn't reach.
    static var cortexyAccent: Color { Themes.shared.current.accentColor ?? .accentColor }
}
