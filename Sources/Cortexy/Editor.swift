import AppKit
import Quartz
import SwiftUI

extension NSAttributedString.Key {
    /// A list marker the text view draws itself: "task", "done", or "bullet0"… (the nesting level, for ● ○ ■).
    static let cxMarker = NSAttributedString.Key("cxMarker")
    /// A due date: the text view draws a soft pill of this color behind it.
    static let cxPill = NSAttributedString.Key("cxPill")
    /// On an attachment character: the Markdown it stands for, e.g. `![](attachments/x.png)`.
    static let cxSource = NSAttributedString.Key("cxSource")
    /// On an attachment character: what double-clicking opens.
    static let cxOpen = NSAttributedString.Key("cxOpen")
}

/// Fonts and colors for one editor (and the note cards), from `Themes.textStyle` plus the note's code mode.
struct TextStyle: Equatable {
    var size: CGFloat = 14
    var design: NSFontDescriptor.SystemDesign = .default
    var family: String?     // an installed font family instead of a system design
    var codeFamily: String? // nil = the system monospaced font
    var code = false
    var accent: NSColor?
    var lineSpacing: CGFloat = 2
    var paragraphSpacing: CGFloat = 5
    var headingScale: CGFloat = 1
    var indentScale: CGFloat = 1.6 // list nesting, in text sizes

    func font(_ size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let s = size ?? self.size
        if code { return monoFont(s, weight: weight) }
        if let f = family.flatMap({ Self.font(family: $0, size: s, weight: weight) }) { return f }
        let base = NSFont.systemFont(ofSize: s, weight: weight)
        guard let d = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: d, size: s) ?? base
    }

    func monoFont(_ s: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let f = codeFamily.flatMap { Self.font(family: $0, size: s, weight: weight) } ?? .monospacedSystemFont(ofSize: s, weight: weight)
        // Thai in code would fall back to Ayuthaya, whose wide leading vowels leave gaps (คอม เมนต์); Thonburi reads normally.
        return NSFont(descriptor: f.fontDescriptor.addingAttributes([.cascadeList: [Self.thaiFallback]]), size: s) ?? f
    }
    private static let thaiFallback = NSFontDescriptor(fontAttributes: [.family: "Thonburi"])

    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: weight.rawValue >= NSFont.Weight.semibold.rawValue ? .boldFontMask : [],
                                  weight: 5, size: size)
    }

    /// Heading font size for `#` … `######`.
    func headingSize(_ level: Int) -> CGFloat { size + [8, 4, 2, 1, 0, 0][min(max(level, 1), 6) - 1] * headingScale }

    var body: NSFont { font() }
    var mono: NSFont { monoFont(size - 1) }
    var lineHeight: CGFloat { ceil(body.ascender - body.descender + body.leading) }
    var indentWidth: CGFloat { round(size * indentScale) } // one level of list nesting
    var checkColor: NSColor { accent ?? .controlAccentColor }

    /// The same fonts in SwiftUI.
    func swiftUI(_ size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> Font { Font(font(size, weight: weight) as CTFont) }
    func swiftUIMono(_ size: CGFloat) -> Font { Font(monoFont(size) as CTFont) }
}

/// Live Markdown styling. Markup outside the paragraph being edited is hidden, like SideNotes/Bear.
enum Styler {
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    /// A minimum line height keeps lines whose only characters are hidden markup (an empty `- [ ] `)
    /// from collapsing under the checkbox drawn on them.
    static func paragraph(_ st: TextStyle) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = st.lineSpacing
        p.paragraphSpacing = st.paragraphSpacing
        p.minimumLineHeight = ceil(st.body.ascender - st.body.descender + st.body.leading)
        return p
    }
    static func base(_ st: TextStyle) -> [NSAttributedString.Key: Any] {
        [.font: st.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph(st)]
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    // Spans are capped (500): an opener that never closes would otherwise retry the rest of a long line from
    // every position, seconds per keystroke on a pasted line of minified code.
    static let bold = re(#"(\*\*|__)(?=\S)(.{1,500}?)(?<=\S)\1"#)
    // `*` works inside a word (Thai has no spaces between words: นี่คือ*สำคัญ*มาก); `_` doesn't (snake_case).
    static let italic = re(#"(?<!\*)\*(?![*\s])(.{1,500}?)(?<![*\s])\*(?!\*)|(?<![_\w])_(?![_\s])(.{1,500}?)(?<![_\s])_(?![_\w])"#)
    static let strike = re(#"~~(?=\S)(.{1,500}?)(?<=\S)~~"#)
    static let code = re(#"`([^`\n]+)`"#)
    static let link = re(#"\[([^\]\n]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)"#) // one level of (…) in a URL: …/Foo_(bar)
    static let hex = re(#"(?<![\w&])#[0-9a-fA-F]{6}\b"#)
    static let quote = re(#"^\s*> ?"#)
    static let rule = re(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#) // ---, ***, ___, - - -: a divider
    static let fence = try! NSRegularExpression(pattern: #"^\h*```"#, options: .anchorsMatchLines)
    static let mark = re(#"==(?=\S)(.{1,500}?)(?<=\S)=="#)
    static let footnoteRef = re(#"\[\^([^\]\s]+)\](?!:)"#)
    static let footnoteDef = re(#"^\[\^([^\]\s]+)\]:[ \t]?"#)
    static let blockID = re(#"(?<=\s)\^[A-Za-z0-9-]+\s*$"#) // `text ^id`: what [[Note#^id]] points at
    static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static let codeBackground = NSColor.labelColor.withAlphaComponent(0.07)

    /// ``` lines before `location`; an odd count means `location` is inside a code block.
    static func fences(_ s: String, before location: Int) -> Int {
        fence.numberOfMatches(in: s, range: NSRange(location: 0, length: location))
    }

    /// The whole paragraphs touching `r`, clamped to the text.
    static func paragraphs(_ ns: NSString, _ r: NSRange) -> NSRange {
        let loc = min(r.location, ns.length)
        return ns.paragraphRange(for: NSRange(location: loc, length: min(r.length, ns.length - loc)))
    }

    /// Fenced code blocks: all of it (fences included), the code inside, and the language after ```.
    static func codeBlocks(_ s: String) -> [(whole: NSRange, body: NSRange, lang: String)] {
        let ns = s as NSString
        let lines = fence.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.paragraphRange(for: $0.range) }
        return stride(from: 0, to: lines.count, by: 2).map { i in
            let open = lines[i], close = i + 1 < lines.count ? lines[i + 1] : nil
            let info = ns.substring(with: open).trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(3)
            let lang = String(info.split(separator: " ").first ?? "")
            let end = close.map(NSMaxRange) ?? ns.length
            return (NSRange(location: open.location, length: end - open.location),
                    NSRange(location: NSMaxRange(open), length: max(0, (close?.location ?? ns.length) - NSMaxRange(open))), lang)
        }
    }

    /// Code blocks and tables restyle as a whole: their colors and column widths depend on all their lines.
    private static func wholeBlocks(_ ns: NSString, _ r: NSRange, _ blocks: [(whole: NSRange, body: NSRange, lang: String)]) -> NSRange {
        var out = r
        for b in blocks where NSIntersectionRange(b.whole, out).length > 0 || NSLocationInRange(out.location, b.whole) {
            out = NSUnionRange(out, b.whole)
        }
        return withTableRows(ns, out)
    }

    /// `r` and the table rows touching it, above and below.
    static func withTableRows(_ ns: NSString, _ r: NSRange) -> NSRange {
        var out = r
        func row(_ p: NSRange) -> Bool { MD.isTableRow(ns.substring(with: p)) }
        while out.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: out.location - 1, length: 0))
            guard row(prev) else { break }
            out = NSUnionRange(out, prev)
        }
        while NSMaxRange(out) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(out), length: 0))
            guard row(next) else { break }
            out = NSUnionRange(out, next)
        }
        return out
    }

    /// Styles the paragraphs touching `range` (default: everything).
    static func style(_ storage: NSTextStorage, active: NSRange, _ st: TextStyle, in range: NSRange? = nil) {
        let ns = storage.string as NSString
        let blocks = st.code ? [] : codeBlocks(storage.string)
        let meta = st.code ? 0 : MD.frontmatter(storage.string)?.length ?? 0 // restyles whole, like a code block
        let full = range.map { r -> NSRange in
            let out = wholeBlocks(ns, paragraphs(ns, r), blocks)
            return out.location < meta ? NSUnionRange(out, NSRange(location: 0, length: meta)) : out
        } ?? NSRange(location: 0, length: ns.length)
        // Attachments carry their own attributes; keep them across the reset below.
        var kept: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttribute(.attachment, in: full) { v, r, _ in
            guard v != nil else { return }
            var a: [NSAttributedString.Key: Any] = [:]
            for k in [NSAttributedString.Key.attachment, .cxSource, .cxOpen] { a[k] = storage.attribute(k, at: r.location, effectiveRange: nil) }
            kept.append((r, a))
        }

        storage.beginEditing()
        storage.setAttributes(base(st), range: full)
        var inCode = fences(storage.string, before: full.location) % 2 == 1
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range)
            let editing = NSIntersectionRange(range, active).length > 0
                || NSLocationInRange(active.location, range) || active.location == NSMaxRange(range)
            func markup(_ r: NSRange) {
                if editing {
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
                } else {
                    storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: r)
                }
            }
            func shift(_ r: NSRange) -> NSRange { NSRange(location: r.location + range.location, length: r.length) }

            if st.code { // Code Mode: all of it is code, so no headings, bullets or checkboxes; just its colors
                for (r, kind) in Syntax.tokens(line, lang: "") { storage.addAttribute(.foregroundColor, value: kind.color, range: shift(r)) }
                return
            }
            if range.location < meta { // frontmatter: kept, quieter
                storage.addAttributes([.font: st.monoFont(st.size - 2), .foregroundColor: NSColor.secondaryLabelColor], range: range)
                return
            }
            if MD.match(fence, line) != nil {
                inCode.toggle()
                storage.addAttributes([.font: st.mono, .foregroundColor: NSColor.tertiaryLabelColor], range: range)
                return
            }
            if inCode {
                storage.addAttributes([.font: st.mono, .backgroundColor: codeBackground], range: range)
                return
            }
            if MD.match(rule, line) != nil, !MD.isTableRule(line) {
                // A divider: drawn as a line across, its characters shown only while editing it.
                let p = NSMutableParagraphStyle()
                p.minimumLineHeight = st.size * 1.4
                storage.addAttribute(.paragraphStyle, value: p, range: range)
                markup(range)
                storage.addAttribute(.cxMarker, value: "hr", range: NSRange(location: range.location, length: 1))
                return
            }
            if let m = MD.match(MD.headingRegex, line) {
                storage.addAttribute(.font, value: st.font(st.headingSize(m.range(at: 1).length), weight: .bold), range: range)
                markup(shift(m.range))
            } else if let m = MD.match(MD.taskRegex, line) {
                let marker = NSRange(location: range.location + m.range(at: 1).length,
                                     length: m.range.length - m.range(at: 1).length)
                indentList(storage, line: line, range: range, st, marker: st.size * 1.7)
                let done = (line as NSString).substring(with: m.range(at: 2)) != " "
                // Collapse "- [ ] " to zero width and reserve a fixed gap with kerning, so "[x]" and "[ ]" line up.
                storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .cxMarker: done ? "done" : "task"], range: marker)
                storage.addAttribute(.kern, value: st.size * 1.7, range: NSRange(location: marker.location, length: 1))
                if done {
                    let rest = NSRange(location: NSMaxRange(marker), length: NSMaxRange(range) - NSMaxRange(marker))
                    storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                           .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
                }
            } else if let m = MD.match(MD.listRegex, line) {
                let marker = shift(m.range)
                let lead = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let symbol = (line as NSString).substring(with: NSRange(location: lead, length: m.range.length - lead))
                indentList(storage, line: line, range: range, st, marker: (symbol as NSString).size(withAttributes: [.font: st.body]).width)
                if line.trimmingCharacters(in: .whitespaces).first?.isNumber == true {
                    storage.addAttribute(.foregroundColor, value: st.checkColor, range: marker)
                } else {
                    let dash = NSRange(location: marker.location + lead, length: 1)
                    storage.addAttributes([.foregroundColor: NSColor.clear, .cxMarker: "bullet\(MD.indentLevel(line) % 3)"], range: dash)
                }
            } else if let m = MD.match(quote, line) {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                markup(shift(m.range))
                // A bar down its side (drawn), as on the cards; the text steps in past it.
                let p = ((storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                p.firstLineHeadIndent = 12
                p.headIndent = 12
                storage.addAttributes([.paragraphStyle: p, .cxMarker: "quote"], range: NSRange(location: range.location, length: 1))
                storage.addAttribute(.paragraphStyle, value: p, range: range)
            }
            inline(storage, line: line, at: range.location, st, markup: markup)
        }
        for b in blocks where NSIntersectionRange(b.whole, full).length > 0 {
            let code = ns.substring(with: b.body)
            for (r, kind) in Syntax.tokens(code, lang: b.lang) {
                storage.addAttribute(.foregroundColor, value: kind.color, range: NSRange(location: b.body.location + r.location, length: r.length))
            }
        }
        if !st.code {
            var paras: [NSRange] = []
            ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in paras.append(r) }
            let lines = paras.map { ns.substring(with: $0) }
            for t in MD.tables(lines) where !blocks.contains(where: { NSLocationInRange(paras[t.lowerBound].location, $0.body) }) {
                let rows = Array(paras[t])
                let editing = rows.contains { NSLocationInRange(active.location, $0) || active.location == NSMaxRange($0) }
                table(storage, rows: rows, lines: Array(lines[t]), st, editing: editing)
            }
        }
        for (r, a) in kept { storage.addAttributes(a.compactMapValues { $0 }, range: r) }
        // The fonts set above (the system font, say) may have no Thai: the text storage swaps in one that does,
        // but only for edits it processes itself. Styled from inside one (the caret moving as you type), it
        // didn't, and Thai typed in the paragraph showed blank glyphs until the caret went elsewhere.
        storage.invalidateAttributes(in: full)
        storage.endEditing()
    }

    /// Tables line their columns up: pipes dimmed, the header bold, the `| --- |` row drawn as a rule, and every
    /// cell padded with kerning to its column's width (padding with spaces can't: proportional fonts, Thai).
    /// While the caret is in the table it shows as monospaced source instead, to edit.
    private static func table(_ s: NSTextStorage, rows: [NSRange], lines: [String], _ st: TextStyle, editing: Bool) {
        if editing {
            for r in rows { s.addAttribute(.font, value: st.mono, range: r) }
            return
        }
        let cells = lines.map(MD.cellRanges)
        func at(_ row: Int, _ r: NSRange) -> NSRange { NSRange(location: rows[row].location + r.location, length: r.length) }
        func hide(_ r: NSRange) { if r.length > 0 { s.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: r) } }
        func trimmed(_ row: Int, _ c: NSRange) -> NSRange {
            let text = lines[row] as NSString
            var lo = c.location, hi = NSMaxRange(c)
            while lo < hi, [32, 9].contains(text.character(at: lo)) { lo += 1 }
            while hi > lo, [32, 9].contains(text.character(at: hi - 1)) { hi -= 1 }
            return NSRange(location: lo, length: hi - lo)
        }
        for row in lines.indices where row != 1 {
            let text = lines[row] as NSString
            for i in 0..<text.length where text.character(at: i) == 124 && (i == 0 || text.character(at: i - 1) != 92) {
                s.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: at(row, NSRange(location: i, length: 1)))
            }
            for c in cells[row] {
                let t = trimmed(row, c)
                hide(at(row, NSRange(location: c.location, length: t.location - c.location)))
                hide(at(row, NSRange(location: NSMaxRange(t), length: NSMaxRange(c) - NSMaxRange(t))))
                if row == 0 { addTrait(s, at(row, t), .bold) }
            }
        }
        // Column widths from the text as it's drawn (bold header, hidden markup and all).
        func width(_ row: Int, _ c: NSRange) -> CGFloat {
            let t = trimmed(row, c)
            return t.length == 0 ? 0 : ceil(s.attributedSubstring(from: at(row, t)).size().width)
        }
        var columns = [CGFloat](repeating: 0, count: cells.map(\.count).max() ?? 0)
        for row in cells.indices where row != 1 { for (i, c) in cells[row].enumerated() { columns[i] = max(columns[i], width(row, c)) } }
        let aligns = MD.alignments(lines[1]), gap = round(st.size * 0.8)
        for row in cells.indices where row != 1 {
            for (i, c) in cells[row].enumerated() {
                let extra = columns[i] - width(row, c)
                let (before, after): (CGFloat, CGFloat) = switch i < aligns.count ? aligns[i] : .left {
                case .left: (0, extra)
                case .right: (extra, 0)
                case .center: (floor(extra / 2), extra - floor(extra / 2))
                }
                let t = trimmed(row, c)
                // The pipe before a cell carries its left padding; the space after its text the right (kern on a
                // Thai ำ splits it, on half an emoji it's lost). Only a cell written without spaces (|ทำ|) uses its last character.
                if c.location > 0 {
                    s.addAttribute(.kern, value: t.length == 0 ? gap + columns[i] : gap / 2 + before, range: at(row, NSRange(location: c.location - 1, length: 1)))
                }
                if t.length > 0 {
                    let pad = NSMaxRange(c) > NSMaxRange(t) ? NSMaxRange(t) : NSMaxRange(t) - 1
                    s.addAttribute(.kern, value: gap / 2 + after, range: at(row, NSRange(location: pad, length: 1)))
                }
            }
        }
        // The rule row: no text, just a thin line under the header the width of the table.
        hide(rows[1])
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 7
        p.maximumLineHeight = 7
        s.addAttribute(.paragraphStyle, value: p, range: rows[1])
        let pipe = ("|" as NSString).size(withAttributes: [.font: st.body]).width
        let total = columns.reduce(0) { $0 + $1 + gap } + pipe * CGFloat(columns.count + 1)
        if rows[1].length > 0 { s.addAttribute(.cxMarker, value: "rule:\(Int(total))", range: NSRange(location: rows[1].location, length: 1)) }
    }

    static func addTrait(_ s: NSTextStorage, _ r: NSRange, _ t: NSFontDescriptor.SymbolicTraits) {
        s.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let f = value as? NSFont, f.pointSize > 1 else { return }
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(t))
            s.addAttribute(.font, value: NSFont(descriptor: d, size: f.pointSize) ?? f, range: sub)
        }
    }

    /// Nested list items indent by whole levels (the spaces before them take no room), and wrapped lines
    /// hang under the text rather than the marker, as in Notes or Word.
    private static func indentList(_ storage: NSTextStorage, line: String, range: NSRange, _ st: TextStyle, marker: CGFloat) {
        let lead = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
        if lead > 0 { storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: range.location, length: lead)) }
        let p = paragraph(st).mutableCopy() as! NSMutableParagraphStyle
        p.firstLineHeadIndent = CGFloat(MD.indentLevel(line)) * st.indentWidth
        p.headIndent = p.firstLineHeadIndent + marker
        storage.addAttribute(.paragraphStyle, value: p, range: range)
    }

    private static func inline(_ s: NSTextStorage, line: String, at offset: Int, _ st: TextStyle, markup: (NSRange) -> Void) {
        let lineRange = NSRange(location: 0, length: (line as NSString).length)
        guard lineRange.length <= 10_000 else { return } // a pasted blob (minified code, data), not prose: left plain
        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult, (NSRange) -> NSRange) -> Void) {
            for m in re.matches(in: line, range: lineRange) {
                body(m) { NSRange(location: $0.location + offset, length: $0.length) }
            }
        }
        func trait(_ r: NSRange, _ t: NSFontDescriptor.SymbolicTraits) { addTrait(s, r, t) }
        func superscript(_ r: NSRange) {
            s.addAttributes([.font: st.font(round(st.size * 0.72)), .baselineOffset: round(st.size * 0.35), .foregroundColor: st.checkColor], range: r)
        }
        // "[^1]: text" at the start of a line: a footnote's text, smaller, under its raised label.
        if let m = footnoteDef.firstMatch(in: line, range: lineRange) {
            s.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: st.font(st.size - 1)], range: NSRange(location: offset, length: lineRange.length))
            superscript(NSRange(location: offset + m.range(at: 1).location, length: m.range(at: 1).length))
            markup(NSRange(location: offset + m.range.location, length: 2))
            markup(NSRange(location: offset + NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
        }
        var codeRanges: [NSRange] = []
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }
        each(code) { m, at in
            codeRanges.append(m.range)
            s.addAttributes([.font: st.mono, .backgroundColor: codeBackground], range: at(m.range))
            markup(at(NSRange(location: m.range.location, length: 1)))
            markup(at(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
        }
        each(bold) { m, at in
            guard !inCode(m.range) else { return }
            trait(at(m.range(at: 2)), .bold)
            markup(at(m.range(at: 1)))
            markup(at(NSRange(location: NSMaxRange(m.range) - 2, length: 2)))
        }
        each(italic) { m, at in
            guard !inCode(m.range) else { return }
            trait(at(m.range), .italic)
            // Thai fonts have no italic face: lean Thai letters instead, or nothing would show.
            let r = at(m.range), text = s.string as NSString
            for i in r.location..<NSMaxRange(r) where (0x0E00...0x0E7F).contains(text.character(at: i)) {
                s.addAttribute(.obliqueness, value: 0.2, range: NSRange(location: i, length: 1))
            }
            markup(at(NSRange(location: m.range.location, length: 1)))
            markup(at(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
        }
        each(strike) { m, at in
            guard !inCode(m.range) else { return }
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                             .foregroundColor: NSColor.secondaryLabelColor], range: at(m.range))
            markup(at(NSRange(location: m.range.location, length: 2)))
            markup(at(NSRange(location: NSMaxRange(m.range) - 2, length: 2)))
        }
        each(link) { m, at in
            guard !inCode(m.range) else { return }
            let url = (line as NSString).substring(with: m.range(at: 2))
            if let u = URL(string: url) { s.addAttributes([.link: u, .foregroundColor: NSColor.linkColor], range: at(m.range(at: 1))) }
            markup(at(NSRange(location: m.range.location, length: 1)))
            markup(at(NSRange(location: m.range(at: 1).upperBound, length: NSMaxRange(m.range) - m.range(at: 1).upperBound)))
        }
        for m in detector.matches(in: line, range: lineRange) {
            if let u = m.url { s.addAttributes([.link: u, .foregroundColor: NSColor.linkColor], range: NSRange(location: m.range.location + offset, length: m.range.length)) }
        }
        // [[Note]] links: only the title (or the text after "|") shows outside the paragraph being edited.
        var linkRanges: [NSRange] = []
        each(MD.wikiRegex) { m, at in
            guard !inCode(m.range) else { return }
            linkRanges.append(m.range)
            let target = (line as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let shown = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1)
            s.addAttributes([.link: Link.note(target), .foregroundColor: NSColor.linkColor], range: at(shown))
            markup(at(NSRange(location: m.range.location, length: shown.location - m.range.location)))
            markup(at(NSRange(location: NSMaxRange(shown), length: NSMaxRange(m.range) - NSMaxRange(shown))))
        }
        each(MD.tagRegex) { m, at in
            guard !inCode(m.range), !linkRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }), // [[Title #x]] is a link
                  let t = MD.tagName((line as NSString).substring(with: m.range(at: 1))) else { return }
            s.addAttributes([.link: Link.tag(t), .foregroundColor: st.checkColor], range: at(m.range))
        }
        each(MD.dueRegex) { m, at in // due dates, colored by how pressing they are
            guard !inCode(m.range), let d = MD.due((line as NSString).substring(with: m.range)) else { return }
            let done = MD.match(MD.taskRegex, line).map { (line as NSString).substring(with: $0.range(at: 2)) != " " } ?? false
            let due = Due.of(d.date, hasTime: d.hasTime, done: done)
            s.addAttributes([.foregroundColor: due.color, .font: st.font(st.size - 1, weight: .medium)], range: at(m.range))
            if due != .done {
                let r = at(m.range)
                s.addAttribute(.cxPill, value: due.color, range: r)
                // Room for the pill's ends: past the space before it, and after its last digit.
                s.addAttribute(.kern, value: 4, range: NSRange(location: NSMaxRange(r) - 1, length: 1))
                if m.range.location > 0, (line as NSString).character(at: m.range.location - 1) == 32 {
                    s.addAttribute(.kern, value: 4, range: NSRange(location: r.location - 1, length: 1))
                }
            }
        }
        each(mark) { m, at in
            guard !inCode(m.range) else { return }
            s.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: at(m.range(at: 1)))
            markup(at(NSRange(location: m.range.location, length: 2)))
            markup(at(NSRange(location: NSMaxRange(m.range) - 2, length: 2)))
        }
        each(footnoteRef) { m, at in
            guard !inCode(m.range) else { return }
            superscript(at(m.range(at: 1)))
            s.addAttribute(.link, value: Link.footnote((line as NSString).substring(with: m.range(at: 1))), range: at(m.range(at: 1)))
            markup(at(NSRange(location: m.range.location, length: 2)))
            markup(at(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
        }
        each(blockID) { m, at in
            guard !inCode(m.range) else { return }
            markup(at(m.range))
        }
        each(hex) { m, at in
            guard let c = NSColor(hex: (line as NSString).substring(with: m.range)) else { return }
            let light = (c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114) > 0.6
            s.addAttributes([.backgroundColor: c, .foregroundColor: light ? NSColor.black : NSColor.white,
                             .font: st.mono], range: at(m.range))
        }
    }
}

/// Images and file chips shown in place of `![](…)` / `[name](file://…)`.
enum Attachments {
    private static let cache = NSCache<NSString, NSImage>()
    @Observable final class Loads { var count = 0 } // bumps when a background decode finishes, so cards redraw
    static let loads = Loads()
    private static var pending = Set<String>() // main thread only
    private static let queue = DispatchQueue(label: "com.cortexy.images", qos: .userInitiated, attributes: .concurrent)

    private static func isWeb(_ url: URL) -> Bool { url.scheme == "http" || url.scheme == "https" }

    /// Right now, for the editor (it needs the size to lay out): a local file, or a web image once fetched
    /// (fetched only if `note` allows it).
    static func image(at url: URL, note: UUID? = nil) -> NSImage? {
        if isWeb(url) { return WebImages.shared.image(url, note: note) }
        guard url.isFileURL else { return nil }
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        guard let img = decode(url) else { return nil }
        cache.setObject(img, forKey: url.path as NSString)
        return img
    }

    /// For cards: the image if it's ready, else nil while it's decoded off the main thread (scrolling never waits).
    static func imageSoon(at url: URL, note: UUID? = nil) -> NSImage? {
        if isWeb(url) { return WebImages.shared.image(url, note: note) }
        guard url.isFileURL else { return nil }
        let key = url.path
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        queue.async {
            let img = decode(url)
            DispatchQueue.main.async {
                pending.remove(key)
                guard let img else { return }
                cache.setObject(img, forKey: key as NSString)
                loads.count += 1
            }
        }
        return nil
    }

    /// Decoded at 1600 px at most (a 12-megapixel photo is otherwise decoded whole for a 300 pt card), sized in
    /// points like the original (a Retina screenshot stays half its pixel size).
    static func decode(_ url: URL) -> NSImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else {
            return NSImage(contentsOf: url)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        func number(_ k: CFString) -> Double? { (props?[k] as? NSNumber)?.doubleValue }
        let w = Double(thumb.width), h = Double(thumb.height)
        let longest = max(number(kCGImagePropertyPixelWidth) ?? w, number(kCGImagePropertyPixelHeight) ?? h) * 72 / max(number(kCGImagePropertyDPIWidth) ?? 72, 1)
        let scale = longest / max(w, h)
        return NSImage(cgImage: thumb, size: NSSize(width: w * scale, height: h * scale))
    }

    static func imageAttachment(_ img: NSImage, maxWidth: CGFloat) -> NSTextAttachment {
        let s = img.size
        let scale = min(1, maxWidth / max(s.width, 1), 320 / max(s.height, 1))
        let size = NSSize(width: floor(s.width * scale), height: floor(s.height * scale))
        let a = NSTextAttachment()
        a.image = rendered(img, size: size)
        a.bounds = CGRect(origin: .zero, size: size)
        return a
    }

    /// Drawn once, rounded, at the size shown (and the screen's scale): redrawing the text never rescales the original.
    private static func rendered(_ img: NSImage, size: NSSize) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard size.width >= 1, size.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return img }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).addClip()
        img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    static func fileAttachment(name: String, url: URL?) -> NSTextAttachment {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let tw = min(ceil((name as NSString).size(withAttributes: [.font: font]).width), 220)
        let size = NSSize(width: tw + 34, height: 22)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let chip = NSImage(size: size, flipped: false) { r in
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
            icon?.draw(in: NSRect(x: 6, y: 3, width: 16, height: 16))
            (name as NSString).draw(with: NSRect(x: 26, y: 5, width: tw, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
        let a = NSTextAttachment()
        a.image = chip
        a.bounds = CGRect(x: 0, y: -6, width: size.width, height: size.height)
        return a
    }
}

final class MarkdownTextView: NSTextView {
    /// The editor currently on screen, for toolbar actions that insert content (screenshots, images).
    static weak var active: MarkdownTextView?
    var didResize: (() -> Void)? // the text changed size without being typed in (loaded, an image arrived)

    var style = TextStyle()
    var previewing = false // read-only preview: no paragraph is being edited, so all markup stays hidden
    var onPreviewClick: () -> Void = {} // previews: a click that isn't on a link
    var resolve: (String) -> URL? = { _ in nil }
    var noteID: UUID? // whose text this is: whether its web images may be fetched
    var importFile: (URL) -> String = { $0.absoluteString }
    var importImage: (NSImage) -> String? = { _ in nil }
    private var lastActive = NSRange(location: NSNotFound, length: 0)
    private var converting = false
    enum Completion { case link, tag }
    /// Suggestions for what's typed after `[[` (note titles) or `#` (tags).
    var completionSource: (Completion, String) -> [String] = { _, _ in [] }
    private(set) var completing = false // the suggestion list is up; Esc belongs to it
    private var offered: [String] = []
    private var dirty: NSRange?    // edited since the last restyle
    private var unconverted: NSRange? // edited since the last look for typed attachments
    private var fenceCount = 0, metaLines = 0

    // MARK: Markdown ⇄ text storage

    private var maxImageWidth: CGFloat {
        let w = textContainer?.size.width ?? 0
        return w > 40 && w < 10_000 ? w - 12 : CGFloat(UserDefaults.standard.double(forKey: Prefs.width)) - 60
    }

    /// Replaces `![](…)` and `[name](file://…)` in `range` with attachment characters. Returns the length change.
    private func attach(in s: NSMutableAttributedString, range: NSRange) -> Int {
        var delta = 0
        for (re, isImage) in [(MD.imageRegex, true), (MD.fileLinkRegex, false)] {
            let ns = s.string as NSString
            let limit = NSRange(location: range.location, length: min(range.length + delta, ns.length - range.location))
            for m in re.matches(in: s.string, range: limit).reversed() {
                let src = ns.substring(with: m.range)
                let target = ns.substring(with: m.range(at: 2))
                let a: NSTextAttachment
                let open: URL?
                if isImage {
                    guard let url = resolve(target), let img = Attachments.image(at: url, note: noteID) else { continue }
                    a = Attachments.imageAttachment(img, maxWidth: maxImageWidth)
                    open = url
                } else {
                    open = URL(string: target)
                    a = Attachments.fileAttachment(name: MD.unescape(ns.substring(with: m.range(at: 1))), url: open)
                }
                let piece = NSMutableAttributedString(attachment: a)
                piece.addAttributes(Styler.base(style), range: NSRange(location: 0, length: 1))
                piece.addAttribute(.cxSource, value: src, range: NSRange(location: 0, length: 1))
                if let open { piece.addAttribute(.cxOpen, value: open, range: NSRange(location: 0, length: 1)) }
                s.replaceCharacters(in: m.range, with: piece)
                delta -= m.range.length - 1
            }
        }
        return delta
    }

    func load(_ markdown: String) {
        if textStorage?.delegate == nil {
            NotificationCenter.default.addObserver(self, selector: #selector(webImageArrived(_:)), name: WebImages.arrived, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(webImagesAllowed(_:)), name: WebImages.allowed, object: nil)
        }
        textStorage?.delegate = self
        // A long note is laid out where it's looked at, not from its start to the caret first (the editor stops
        // measuring such a note anyway, see `fit`); short ones stay contiguous, which keeps their scrolling exact.
        layoutManager?.allowsNonContiguousLayout = (markdown as NSString).length >= 20_000
        let s = NSMutableAttributedString(string: markdown, attributes: Styler.base(style))
        _ = attach(in: s, range: NSRange(location: 0, length: s.length))
        textStorage?.setAttributedString(s)
        unconverted = nil // attach() just did the whole text
        undoManager?.removeAllActions() // old undo ranges point into the text we just replaced
        restyle(force: true)
        DispatchQueue.main.async { [weak self] in self?.didResize?() }
    }

    /// This note's web images were just allowed: read it again, so its image links ask for them.
    @objc private func webImagesAllowed(_ n: Notification) {
        guard let id = n.object as? UUID, id == noteID else { return }
        let caret = selectedRange()
        load(markdown())
        setSelectedRange(NSRange(location: min(caret.location, (string as NSString).length), length: 0))
    }

    /// A web image this note shows just arrived: show it in place of its link, keeping the caret where it was.
    @objc private func webImageArrived(_ n: Notification) {
        guard let url = n.object as? URL, string.contains(url.absoluteString) else { return }
        if isEditable, undoManager?.canUndo == true {
            // Swapped in as an edit of its own, so the undo history typed before it stays good.
            let ns = string as NSString
            var at = ns.range(of: url.absoluteString)
            while at.location != NSNotFound {
                unconverted = unconverted.map { NSUnionRange($0, at) } ?? at
                at = ns.range(of: url.absoluteString, range: NSRange(location: NSMaxRange(at), length: ns.length - NSMaxRange(at)))
            }
            convertTypedAttachments()
            return DispatchQueue.main.async { [weak self] in self?.didResize?() }
        }
        let ns = string as NSString, caret = selectedRange().location
        // Links before the caret shrink to one character each.
        let shift = MD.imageRegex.matches(in: string, range: NSRange(location: 0, length: ns.length))
            .filter { NSMaxRange($0.range) <= caret && resolve(ns.substring(with: $0.range(at: 2))) == url }
            .reduce(0) { $0 + $1.range.length - 1 }
        load(markdown())
        setSelectedRange(NSRange(location: max(0, min(caret - shift, (string as NSString).length)), length: 0))
        DispatchQueue.main.async { [weak self] in self?.didResize?() }
    }

    func markdown(in range: NSRange? = nil) -> String {
        guard let st = textStorage else { return string }
        let r = range ?? NSRange(location: 0, length: st.length)
        let ns = st.string as NSString
        var out = ""
        st.enumerateAttribute(.cxSource, in: r) { v, sub, _ in
            let text = ns.substring(with: sub)
            guard let src = v as? String else { out += text; return }
            // Only attachment characters stand for Markdown; anything typed next to them is itself.
            for ch in text { out += ch == "\u{FFFC}" ? src : String(ch) }
        }
        return out
    }

    /// Turns freshly typed or pasted `![](…)`/file links into attachments, undoably, keeping the caret in place.
    func convertTypedAttachments() {
        guard !converting, !hasMarkedText(), let st = textStorage, let edited = unconverted,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return }
        unconverted = nil
        let plain = st.string as NSString
        let full = NSRange(location: 0, length: plain.length)
        // Only the paragraphs just typed in: elsewhere links were converted already, or can't be (web, missing files).
        let scope = Styler.paragraphs(plain, edited)
        guard MD.imageRegex.firstMatch(in: st.string, range: scope) != nil || MD.fileLinkRegex.firstMatch(in: st.string, range: scope) != nil else { return }
        let copy = NSMutableAttributedString(attributedString: st)
        guard attach(in: copy, range: scope) != 0 else { return }
        converting = true
        defer { converting = false }
        let caretFromEnd = plain.length - selectedRange().location
        if shouldChangeText(in: full, replacementString: copy.string) {
            st.setAttributedString(copy)
            didChangeText()
            setSelectedRange(NSRange(location: max(0, copy.length - caretFromEnd), length: 0))
        }
    }

    /// Restyles only what changed: edited paragraphs, plus the ones the caret left and entered (markup shows
    /// only where the caret is). Adding or removing a ``` line changes everything after it, so that restyles all.
    private var restyleQueued = false, restyleAfterEdit = false

    func restyle(force: Bool = false) {
        guard let storage = textStorage, !hasMarkedText() else { return } // don't disturb IME composition
        let ns = string as NSString
        let active = previewing ? NSRange(location: NSNotFound, length: 0)
            : ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        let fences = Styler.fences(string, before: ns.length), meta = style.code ? 0 : MD.frontmatter(string)?.lines ?? 0
        // Asked from inside the layout manager's handling of an edit (the caret moved because of it), restyling
        // beyond the paragraphs being edited — a whole table going from source to aligned, say — leaves it drawing
        // the glyphs of the old fonts (a table left with Return came out as rubbish). That waits for the edit to
        // be through; the paragraph being typed in is styled at once, which is cheaper there (before it's laid out).
        let editing = storage.editedMask != []
        func afterTheEdit(_ force: Bool) {
            restyleAfterEdit = restyleAfterEdit || force
            guard !restyleQueued else { return }
            restyleQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                restyleQueued = false
                let forced = restyleAfterEdit
                restyleAfterEdit = false
                restyle(force: forced)
            }
        }
        if force || fences != fenceCount || meta != metaLines { // frontmatter appearing or ending changes the lines in it
            if editing { return afterTheEdit(force) }
            Styler.style(storage, active: active, style)
        } else {
            let parts = (dirty.map { [$0] } ?? []) + (active != lastActive ? [active, lastActive] : [])
            guard !parts.isEmpty else { return }
            let ranges = Set(parts.map { Styler.paragraphs(ns, $0) })
            if editing {
                // What would really be restyled (a table goes whole) against the paragraphs being edited.
                let at = min(storage.editedRange.location, ns.length)
                let near = NSUnionRange(Styler.paragraphs(ns, NSRange(location: at, length: min(storage.editedRange.length, ns.length - at))), active)
                if ranges.contains(where: { NSUnionRange(near, Styler.withTableRows(ns, $0)) != near }) { return afterTheEdit(false) }
            }
            for r in ranges { Styler.style(storage, active: active, style, in: r) }
        }
        dirty = nil
        lastActive = active
        fenceCount = fences
        metaLines = meta
        typingAttributes = Styler.base(style)
        needsDisplay = true
    }

    // MARK: Drawn markers (checkboxes, bullets)

    private func markers() -> [(range: NSRange, kind: String, rect: NSRect)] {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return [] }
        let glyphs = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var out: [(NSRange, String, NSRect)] = []
        storage.enumerateAttribute(.cxMarker, in: chars) { value, range, _ in
            guard let kind = value as? String else { return }
            let g = lm.glyphIndexForCharacter(at: range.location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: g)
            // Optical center of the text beside it: checkboxes line up with capitals, bullets with lowercase.
            let x = frag.minX + loc.x + textContainerOrigin.x
            if kind == "hr" { // a divider, across the text
                out.append((range, kind, NSRect(x: textContainerOrigin.x + tc.lineFragmentPadding, y: frag.midY + textContainerOrigin.y,
                                                width: tc.size.width - 2 * tc.lineFragmentPadding, height: 1)))
                return
            }
            if kind == "quote" { // the bar down a quote's whole paragraph
                let para = (storage.string as NSString).paragraphRange(for: range)
                let box = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil), in: tc)
                out.append((range, kind, NSRect(x: textContainerOrigin.x + tc.lineFragmentPadding, y: box.minY + textContainerOrigin.y + 2, width: 3, height: max(1, box.height - 4))))
                return
            }
            if kind.hasPrefix("rule:") { // a table's header rule: its width is in the marker
                out.append((range, kind, NSRect(x: x, y: frag.midY + textContainerOrigin.y, width: CGFloat(Int(kind.dropFirst(5)) ?? 0), height: 1)))
                return
            }
            let lift = kind.hasPrefix("bullet") ? style.body.xHeight / 2 : style.body.capHeight / 2
            let midY = frag.minY + loc.y - lift + textContainerOrigin.y
            out.append((range, kind, NSRect(x: x - 1, y: midY - 9, width: 18, height: 18)))
        }
        return out
    }

    /// Each code block's copy button (drawn at its opening fence's right end), for clicks; set as it's drawn.
    private var codeButtons: [(rect: NSRect, body: NSRange)] = []
    private var copied: (at: Int, when: Date)?

    private func drawCodeButtons(_ dirtyRect: NSRect) {
        codeButtons = []
        guard fenceCount > 0, !style.code, let lm = layoutManager, let tc = textContainer else { return }
        let look = "\(effectiveAppearance.name.rawValue)|\(window?.backingScaleFactor ?? 2)"
        for b in Styler.codeBlocks(string) where b.body.length > 0 {
            let g = lm.glyphIndexForCharacter(at: b.whole.location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let r = NSRect(x: textContainerOrigin.x + tc.size.width - tc.lineFragmentPadding - 18, y: frag.midY + textContainerOrigin.y - 8, width: 16, height: 16)
            codeButtons.append((r, b.body))
            guard r.intersects(dirtyRect) else { continue }
            let done = copied.map { $0.at == b.body.location && Date().timeIntervalSince($0.when) < 1.2 } ?? false
            let name = done ? "checkmark" : "doc.on.doc"
            guard let img = markerImage(name, size: style.size - 2, colors: [done ? style.checkColor : .tertiaryLabelColor], key: "\(name)|\(style.size)|\(look)") else { continue }
            img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !previewing { drawCodeButtons(dirtyRect) }
        // As drawn now (a system accent color changes without the style changing).
        let look = "\(effectiveAppearance.name.rawValue)|\(window?.backingScaleFactor ?? 2)|\(style.checkColor.usingColorSpace(.sRGB).map { "\($0)" } ?? "")"
        for m in markers() where m.rect.intersects(dirtyRect) {
            if m.kind.hasPrefix("rule:") || m.kind == "hr" {
                NSColor.separatorColor.setFill()
                m.rect.fill()
                continue
            }
            if m.kind == "quote" {
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: m.rect, xRadius: 1.5, yRadius: 1.5).fill()
                continue
            }
            let done = m.kind == "done"
            let bullet = m.kind.hasPrefix("bullet")
            let level = Int(m.kind.dropFirst(6)) ?? 0
            let name = bullet ? ["circle.fill", "circle", "square.fill"][level % 3] : done ? "checkmark.square.fill" : "square"
            let size: CGFloat = bullet ? (level == 1 ? 7 : 6) : style.size + 1
            let colors: [NSColor] = done ? [.white, style.checkColor] : bullet ? [style.checkColor] : [.secondaryLabelColor] // check, box
            guard let img = markerImage(name, size: size, colors: colors, key: "\(name)|\(size)|\(look)") else { continue }
            let s = img.size
            // Symbol images carry padding below the glyph; center the visible glyph (its alignment rect), not the image.
            let glyphMid = img.alignmentRect.midY // bottom-up image coordinates
            let r = NSRect(x: m.rect.minX + (bullet ? 1 : 0), y: m.rect.midY - (s.height - glyphMid), width: s.width, height: s.height)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Due dates sit on a soft pill of their color (gray text alone was easy to miss), under the selection.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let chars = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil)
        storage.enumerateAttribute(.cxPill, in: chars) { value, range, _ in
            guard let color = value as? NSColor, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let text = storage.string as NSString
            // One pill per line it's on (a date and time can wrap), around the letters: from the line's baseline,
            // as a line's own rect has its spacing in it, and without the space it wrapped at.
            lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, line, _ in
                var part = lm.characterRange(forGlyphRange: NSIntersectionRange(line, glyphs), actualGlyphRange: nil)
                while part.length > 0, text.character(at: NSMaxRange(part) - 1) == 32 { part.length -= 1 }
                guard part.length > 0 else { return }
                let g = lm.glyphRange(forCharacterRange: part, actualCharacterRange: nil)
                let r = lm.boundingRect(forGlyphRange: g, in: tc), base = frag.minY + lm.location(forGlyphAt: g.location).y
                let box = NSRect(x: r.minX - 4, y: base - font.ascender - 1, width: r.width + 8, height: font.ascender - font.descender + 2)
                    .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                color.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            }
        }
    }

    /// A checkbox or bullet symbol drawn once into a bitmap (for this look: its colors follow light and dark),
    /// then only copied: drawing the symbol itself each time was most of what redrawing the editor cost.
    private func markerImage(_ name: String, size: CGFloat, colors: [NSColor], key: String) -> NSImage? {
        if let img = Self.markerImages[key] { return img }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let s = symbol.size, scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(s.width * scale)), pixelsHigh: Int(ceil(s.height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = s
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        effectiveAppearance.performAsCurrentDrawingAppearance { symbol.draw(in: NSRect(origin: .zero, size: s)) }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: s)
        img.addRepresentation(rep)
        img.alignmentRect = symbol.alignmentRect // where the glyph sits in it, for centering
        if Self.markerImages.count > 200 { Self.markerImages.removeAll() } // ponytail: themes and sizes come and go
        Self.markerImages[key] = img
        return img
    }
    private static var markerImages: [String: NSImage] = [:]

    /// The first click on a panel that isn't focused yet (opened by the pointer) places the caret right away,
    /// instead of only focusing the panel and leaving the caret where it was.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The toolbar and screenshots act on the editor you're typing in (the panel's, or a note window's).
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, !previewing { MarkdownTextView.active = self }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        if !previewing { Self.active = self } // a click into a window that kept its focus doesn't make it first responder again
        let p = convert(event.locationInWindow, from: nil)
        if previewing {
            let i = characterIndexForInsertion(at: p)
            if let st = textStorage, i < st.length, st.attribute(.link, at: i, effectiveRange: nil) != nil { return super.mouseDown(with: event) }
            return onPreviewClick()
        }
        if let b = codeButtons.first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }) {
            copyToPasteboard(markdown(in: b.body))
            copied = (b.body.location, Date())
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.needsDisplay = true }
            return
        }
        if event.modifierFlags.contains(.command), event.clickCount == 1, quickCopy(at: p, link: event.modifierFlags.contains(.option)) { return }
        if let hit = markers().first(where: { ($0.kind == "task" || $0.kind == "done") && $0.rect.contains(p) }) {
            // "- [ ] " → the box character is 3 UTF-16 units in
            let box = NSRange(location: hit.range.location + 3, length: 1)
            replace(box, with: hit.kind == "done" ? " " : "x")
            return
        }
        // In the paragraph being edited a click on a link puts the caret there, to edit it; ⌘-click, or a
        // click in another paragraph, follows it.
        if !event.modifierFlags.contains(.command), event.clickCount == 1, let st = textStorage {
            let i = characterIndexForInsertion(at: p)
            let para = (string as NSString).paragraphRange(for: NSRange(location: min(i, st.length), length: 0))
            if i < st.length, st.attribute(.link, at: i, effectiveRange: nil) != nil, NSLocationInRange(selectedRange().location, para) {
                return setSelectedRange(NSRange(location: i, length: 0))
            }
        }
        if event.clickCount == 2, let url = attachmentURL(at: p) {
            if UserDefaults.standard.object(forKey: Prefs.quickLook) as? Bool ?? true { quickLook(url) } else { NSWorkspace.shared.open(url) }
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Resting on a link previews it

    private var hoverArea: NSTrackingArea?
    private var hoveredLink: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        guard !previewing else { return }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !previewing, let lm = layoutManager, let tc = textContainer, let st = textStorage, st.length > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let g = lm.glyphIndex(for: inContainer, in: tc)
        var r = NSRange()
        let i = lm.characterIndexForGlyph(at: g)
        guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(inContainer), i < st.length,
              let url = st.attribute(.link, at: i, effectiveRange: &r) as? URL else { return leaveLink() }
        guard r != hoveredLink else { return }
        leaveLink()
        hoveredLink = r
        // Where it is in the window: its first line's part, as a link can wrap.
        var box = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: g, length: 1)) { _, used, _, _, _ in box = box.intersection(used) }
        let inWindow = convert(box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), to: nil)
        PanelController.shared?.hoverLink(url, rect: inWindow, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        leaveLink()
    }

    private func leaveLink() {
        guard hoveredLink != nil else { return }
        hoveredLink = nil
        PanelController.shared?.hoverLink(nil, rect: .zero, in: self)
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// ⌘-click: a code block, heading, list item or quote is copied (and flashes); ⌥⌘-click copies a link.
    /// Anything else (a plain paragraph, a link without ⌥) is left to the usual click.
    private func quickCopy(at p: NSPoint, link: Bool) -> Bool {
        guard let st = textStorage, st.length > 0 else { return false }
        let i = min(characterIndexForInsertion(at: p), st.length - 1)
        let target = st.attribute(.link, at: i, effectiveRange: nil)
        if link, let url = target as? URL {
            let title = url.host == "open" ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.map { "[[\($0)]]" } : nil
            copyToPasteboard(title ?? url.absoluteString)
            var r = NSRange()
            _ = st.attribute(.link, at: i, effectiveRange: &r)
            showFindIndicator(for: r)
            return true
        }
        guard target == nil else { return false }
        let ns = string as NSString
        let line = ns.substring(to: i).components(separatedBy: "\n").count - 1
        guard let text = MD.quickCopy(markdown(), line: line) else { return false }
        copyToPasteboard(text)
        showFindIndicator(for: ns.paragraphRange(for: NSRange(location: i, length: 0)))
        return true
    }

    // MARK: Quick Look for attachments

    private var lookingAt: URL?

    func quickLook(_ url: URL) {
        lookingAt = url
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), ql.isVisible { return ql.reloadData() }
        NSApp.activate()
        ql.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { lookingAt != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        PanelController.shared?.holdOpen += 1 // the preview takes the focus; the panel stays
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        lookingAt = nil
        PanelController.shared?.holdOpen -= 1
    }

    private func attachmentURL(at p: NSPoint) -> URL? {
        guard let lm = layoutManager, let tc = textContainer, let st = textStorage, st.length > 0 else { return nil }
        let inContainer = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let g = lm.glyphIndex(for: inContainer, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(inContainer) else { return nil }
        let i = lm.characterIndexForGlyph(at: g)
        return i < st.length ? st.attribute(.cxOpen, at: i, effectiveRange: nil) as? URL : nil
    }

    // MARK: Clipboard and drops speak Markdown, not attachment characters

    /// Marks what Cortexy copied: pasted back into a note it's the Markdown, not the HTML made from it.
    static let markdownType = NSPasteboard.PasteboardType("com.cortexy.markdown")

    override func copy(_ sender: Any?) {
        let r = selectedRange()
        guard r.length > 0 else { return }
        Self.write(markdown(in: r), to: NSPasteboard.general)
    }

    /// Markdown as text, and as HTML and RTF so Mail, Notes, Pages and Docs keep its formatting.
    static func write(_ md: String, to pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(md, forType: .string)
        pb.setString(md, forType: markdownType)
        let html = MD.html(md)
        pb.setString(html, forType: .html)
        if let rich = try? NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                               .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
           let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length)) {
            pb.setData(rtf, forType: .rtf)
        }
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        replace(selectedRange(), with: "", select: NSRange(location: selectedRange().location, length: 0))
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        return pboard.setString(markdown(in: selectedRange()), forType: .string)
    }

    override func paste(_ sender: Any?) { paste(from: NSPasteboard.general) }

    /// Files become attachments; a link pasted over words links them (and a bare one gets its page's title);
    /// rich text from elsewhere comes as Markdown; pasted code goes into a code block. In code, all of it is plain.
    func paste(from pb: NSPasteboard) {
        if insertFiles(from: pb) { return }
        let sel = selectedRange(), ns = string as NSString
        let lineStart = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0)).location
        guard !style.code, Styler.fences(string, before: lineStart) % 2 == 0, let text = pb.string(forType: .string) else { return plainPaste(pb) }
        if let url = MD.singleURL(text) { return pasteLink(url) }
        if pb.availableType(from: [Self.markdownType]) == nil, let html = pb.string(forType: .html), let md = MD.markdown(fromHTML: html), !md.isEmpty {
            return insertText(md, replacementRange: sel)
        }
        if MD.looksLikeCode(text) { return insertBlock("```\n" + text.trimmingCharacters(in: .newlines) + "\n```") }
        plainPaste(pb)
    }

    private func plainPaste(_ pb: NSPasteboard) {
        guard let text = pb.string(forType: .string) else { return super.paste(nil) }
        insertText(text, replacementRange: selectedRange())
    }

    private func pasteLink(_ url: URL) {
        let sel = selectedRange(), ns = string as NSString
        let picked = sel.length > 0 ? ns.substring(with: sel) : ""
        if !picked.isEmpty, !picked.contains("\n"), MD.singleURL(picked) == nil { // words selected: they become the link
            return insertText("[\(MD.escape(picked))](\(url.absoluteString))", replacementRange: sel)
        }
        let link = url.absoluteString
        insertText(link, replacementRange: sel)
        guard LinkPreviews.enabled else { return }
        let at = NSRange(location: sel.location, length: (link as NSString).length)
        Task { @MainActor [weak self] in
            guard let info = await LinkPreviews.shared.info(url), !info.title.isEmpty, let self else { return }
            let now = string as NSString
            guard NSMaxRange(at) <= now.length, now.substring(with: at) == link else { return } // edited meanwhile: leave it
            let title = String(info.title.prefix(120))
            let new = "[\(MD.escape(title))](\(link))", caret = selectedRange()
            let delta = (new as NSString).length - at.length
            replace(at, with: new, select: caret.location >= NSMaxRange(at) ? NSRange(location: caret.location + delta, length: caret.length) : caret)
        }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL, .png, .tiff] }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let i = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let keep = selectedRange()
        setSelectedRange(NSRange(location: i, length: 0))
        if insertFiles(from: sender.draggingPasteboard) { return true }
        setSelectedRange(keep)
        return super.performDragOperation(sender)
    }

    /// Files and images from a pasteboard: images are copied into the notes folder, other files are linked.
    private func insertFiles(from pb: NSPasteboard) -> Bool {
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            insertBlock(files.map(importFile).joined(separator: "\n"))
            return true
        }
        if pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb), let md = importImage(img) {
            insertBlock(md)
            return true
        }
        return false
    }

    /// Puts the caret at the start of line `line` (as in the Markdown) and scrolls there, for the outline.
    func reveal(line: Int) {
        let ns = string as NSString
        var loc = 0
        for _ in 0..<line {
            let r = ns.range(of: "\n", range: NSRange(location: loc, length: ns.length - loc))
            guard r.location != NSNotFound else { break }
            loc = NSMaxRange(r)
        }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: loc, length: 0))
        scrollRangeToVisible(ns.paragraphRange(for: NSRange(location: loc, length: 0)))
        showFindIndicator(for: ns.paragraphRange(for: NSRange(location: loc, length: 0)))
    }

    // MARK: Completing [[links]] and #tags

    private static let tagTail = try! NSRegularExpression(pattern: MD.tagStart + #"([\p{L}\p{M}\p{N}_/-]*)$"#)

    /// What's being typed right before the caret: a link title after an open `[[`, or a tag after `#`.
    func completionContext() -> (Completion, NSRange)? {
        let sel = selectedRange()
        guard sel.length == 0, !style.code else { return nil }
        let ns = string as NSString
        let start = ns.paragraphRange(for: NSRange(location: sel.location, length: 0)).location
        guard Styler.fences(string, before: start) % 2 == 0 else { return nil } // inside a code block
        let before = ns.substring(with: NSRange(location: start, length: sel.location - start)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        if open.location != NSNotFound {
            let typed = before.substring(from: NSMaxRange(open))
            if !typed.contains("]") && !typed.contains("|") {
                return (.link, NSRange(location: start + NSMaxRange(open), length: before.length - NSMaxRange(open)))
            }
        }
        if let m = Self.tagTail.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) {
            return (.tag, NSRange(location: start + m.range(at: 1).location, length: m.range(at: 1).length))
        }
        return nil
    }

    /// Called after each edit: opens the suggestion list when there's something to suggest.
    func suggestCompletions() {
        guard !completing, !hasMarkedText(), window != nil, let (kind, r) = completionContext() else { return }
        let partial = (string as NSString).substring(with: r)
        if kind == .tag && partial.isEmpty { return }
        let options = completionSource(kind, partial)
        guard !options.isEmpty, options != [partial] else { return }
        completing = true
        complete(nil)
        if window?.firstResponder !== self || !completing { completing = false }
    }

    override var rangeForUserCompletion: NSRange { completionContext()?.1 ?? super.rangeForUserCompletion }

    override func completions(forPartialWordRange r: NSRange, indexOfSelectedItem i: UnsafeMutablePointer<Int>) -> [String]? {
        guard let (kind, _) = completionContext() else { return super.completions(forPartialWordRange: r, indexOfSelectedItem: i) }
        i.pointee = -1 // nothing picked until ↓: typing #home then Return keeps "#home", it doesn't become #homework
        offered = completionSource(kind, (string as NSString).substring(with: r))
        return offered
    }

    /// A picked suggestion is finished off: `]]` after a title, a space after a tag (Thai has no other word break).
    override func insertCompletion(_ word: String, forPartialWordRange r: NSRange, movement: Int, isFinal: Bool) {
        var word = word
        let picked = offered.contains(word)
        if isFinal {
            let kind = completionContext()?.0
            completing = false
            if movement != NSTextMovement.cancel.rawValue, picked {
                let rest = (string as NSString).substring(from: min(NSMaxRange(r), (string as NSString).length))
                if kind == .link && !rest.hasPrefix("]]") { word += "]]" }
                if kind == .tag && !rest.hasPrefix(" ") { word += " " }
            }
        }
        super.insertCompletion(word, forPartialWordRange: r, movement: movement, isFinal: isFinal)
        // Return with nothing picked closes the list and still makes the new line it was pressed for.
        if isFinal, movement == NSTextMovement.return.rawValue, !picked { doCommand(by: #selector(insertNewline(_:))) }
    }

    /// Puts the caret at the first `text` (ignoring case and accents) and flashes it, after opening from a search.
    func reveal(text: String) {
        let ns = string as NSString
        let r = ns.range(of: text, options: MD.searchOptions(text))
        guard r.location != NSNotFound else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: r.location, length: 0))
        scrollRangeToVisible(r)
        showFindIndicator(for: r)
    }

    /// From a footnote mark to its text ("[^1]: …").
    func revealFootnote(_ label: String) {
        let ns = string as NSString
        let r = ns.range(of: "[^\(label)]:")
        guard r.location != NSNotFound else { return }
        let line = ns.paragraphRange(for: r)
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        scrollRangeToVisible(line)
        showFindIndicator(for: line)
    }

    /// Inserts Markdown on its own line at the caret.
    func insertBlock(_ md: String) {
        let ns = string as NSString
        let sel = selectedRange()
        let before = sel.location > 0 && ns.character(at: sel.location - 1) != 10 ? "\n" : ""
        let after = NSMaxRange(sel) < ns.length && ns.character(at: NSMaxRange(sel)) != 10 ? "\n" : ""
        let text = before + md + after
        replace(sel, with: text, select: NSRange(location: sel.location + (text as NSString).length, length: 0))
    }

    // MARK: Editing commands (toolbar + shortcuts, reached via the responder chain)

    private func plain(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: Styler.base(style)) }

    /// Existing text in `range`, attachments included.
    private func piece(_ range: NSRange) -> NSAttributedString {
        textStorage?.attributedSubstring(from: range) ?? plain((string as NSString).substring(with: range))
    }

    /// Undoable replacement.
    private func replace(_ range: NSRange, with s: String, select: NSRange? = nil) { replace(range, with: plain(s), select: select) }

    private func replace(_ range: NSRange, with new: NSAttributedString, select: NSRange? = nil) {
        let keep = selectedRanges
        guard shouldChangeText(in: range, replacementString: new.string) else { return }
        textStorage?.replaceCharacters(in: range, with: new)
        if let select { setSelectedRange(select) } else { selectedRanges = keep }
        didChangeText()
        restyle()
    }

    private func wrap(_ marker: String) {
        let ns = string as NSString
        var sel = selectedRange()
        let m = (marker as NSString).length
        // Spaces at a selection's edges stay outside the markers ("**word **" wouldn't render).
        if sel.length > 0 {
            let t = ns.substring(with: sel)
            let lead = t.prefix(while: \.isWhitespace).utf16.count, trail = t.reversed().prefix(while: \.isWhitespace).reduce(0) { $0 + $1.utf16.count }
            if lead + trail < sel.length { sel = NSRange(location: sel.location + lead, length: sel.length - lead - trail) }
        }
        // How many marker characters touch the selection on one side: "**" around a word is bold, not two italics.
        func run(from i: Int, step: Int) -> Int {
            var n = 0, i = i
            while i >= 0, i < ns.length, ns.substring(with: NSRange(location: i, length: 1)) == String(marker.prefix(1)) { n += 1; i += step }
            return n
        }
        if sel.length == 0 {
            let before = sel.location >= m ? ns.substring(with: NSRange(location: sel.location - m, length: m)) : ""
            let after = sel.location + m <= ns.length ? ns.substring(with: NSRange(location: sel.location, length: m)) : ""
            let doubled = sel.location + m < ns.length && ns.substring(with: NSRange(location: sel.location + m, length: 1)) == String(marker.prefix(1))
            if before == marker && after == marker {
                // "**|**" → pressing again removes the empty pair
                replace(NSRange(location: sel.location - m, length: 2 * m), with: "", select: NSRange(location: sel.location - m, length: 0))
                return
            }
            if after == marker && (m > 1 || !doubled) {
                // "**bold|**" → pressing again steps out of the formatting
                setSelectedRange(NSRange(location: sel.location + m, length: 0))
                return
            }
        }
        if sel.length > 0, sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker,
           m > 1 || (run(from: sel.location - 1, step: -1) % 2 == 1 && run(from: NSMaxRange(sel), step: 1) % 2 == 1) {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: piece(sel), select: NSRange(location: sel.location - m, length: sel.length))
        } else {
            let wrapped = NSMutableAttributedString(attributedString: plain(marker))
            wrapped.append(piece(sel))
            wrapped.append(plain(marker))
            replace(sel, with: wrapped, select: NSRange(location: sel.location + m, length: sel.length))
        }
    }

    /// Applies `f` to each selected line. `f` only edits line prefixes (indent, markers), so attachment
    /// characters come through in order and get their attributes back.
    private func transformLines(_ f: (String) -> String) {
        let ns = string as NSString
        var para = ns.paragraphRange(for: selectedRange())
        if para.length > 0, ns.substring(with: NSRange(location: NSMaxRange(para) - 1, length: 1)) == "\n" { para.length -= 1 }
        let old = piece(para)
        var attachments: [[NSAttributedString.Key: Any]] = []
        (old.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: old.length), options: .byComposedCharacterSequences) { ch, r, _, _ in
            if ch == "\u{FFFC}" { attachments.append(old.attributes(at: r.location, effectiveRange: nil)) }
        }
        let newText = old.string.components(separatedBy: "\n").map(f).joined(separator: "\n")
        let new = NSMutableAttributedString(attributedString: plain(newText))
        var next = attachments.makeIterator()
        (newText as NSString).enumerateSubstrings(in: NSRange(location: 0, length: new.length), options: .byComposedCharacterSequences) { ch, r, _, _ in
            if ch == "\u{FFFC}", let a = next.next() { new.setAttributes(a, range: r) }
        }
        let delta = new.length - old.length
        let sel = selectedRange()
        replace(para, with: new, select: sel.length == 0
            ? NSRange(location: max(para.location, sel.location + delta), length: 0)
            : NSRange(location: para.location, length: new.length))
    }

    private var currentLine: String {
        let ns = string as NSString
        return ns.substring(with: ns.paragraphRange(for: NSRange(location: selectedRange().location, length: 0)))
    }

    @objc func cxBold(_ sender: Any?) { wrap("**") }
    @objc func cxItalic(_ sender: Any?) { wrap("*") }
    @objc func cxCode(_ sender: Any?) { wrap("`") }
    @objc func cxStrike(_ sender: Any?) { wrap("~~") }
    @objc func cxTask(_ sender: Any?) { transformLines(MD.toggleChecklist) }
    @objc func cxBullet(_ sender: Any?) { transformLines(MD.toggleBullet) }
    @objc func cxQuote(_ sender: Any?) { transformLines(MD.toggleQuote) }
    @objc func cxHighlight(_ sender: Any?) { wrap("==") }
    @objc func cxDivider(_ sender: Any?) { insertBlock("---") }

    /// Numbers the selected lines 1, 2, 3…; lines that are all numbered already go back to plain.
    @objc func cxNumbered(_ sender: Any?) {
        let ns = string as NSString
        let lines = ns.substring(with: ns.paragraphRange(for: selectedRange())).components(separatedBy: "\n").filter { !$0.isEmpty }
        let numbered = !lines.isEmpty && lines.allSatisfy { MD.match(Self.numberedItem, $0) != nil }
        var n = 0
        transformLines { line in
            guard !line.isEmpty else { return line }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let body = MD.match(MD.listRegex, line).map { (line as NSString).substring(from: $0.range.upperBound) } ?? String(line.dropFirst(indent.count))
            if numbered { return indent + body }
            n += 1
            return indent + "\(n). " + body
        }
    }

    /// The selected lines inside a ``` block, or an empty one to type in.
    @objc func cxCodeBlock(_ sender: Any?) {
        if selectedRange().length == 0 && currentLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let start = selectedRange().location
            insertBlock("```\n\n```")
            let ns = string as NSString
            let open = ns.range(of: "```\n", range: NSRange(location: start, length: ns.length - start))
            if open.location != NSNotFound { setSelectedRange(NSRange(location: NSMaxRange(open), length: 0)) }
            return
        }
        let ns = string as NSString
        let total = ns.substring(with: ns.paragraphRange(for: selectedRange())).trimmingCharacters(in: .newlines).components(separatedBy: "\n").count
        var i = 0
        transformLines { line in
            i += 1
            return (i == 1 ? "```\n" : "") + line + (i == total ? "\n```" : "")
        }
    }

    var findBarShown: Bool { enclosingScrollView?.isFindBarVisible == true }
    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performFindPanelAction(item)
    }

    /// ⇧⌘ formatting keys, in the panel and in note windows.
    static let shiftFormat = ["x": "cxStrike:", "7": "cxNumbered:", "8": "cxBullet:", "9": "cxQuote:", "h": "cxHighlight:"]
    @objc func cxHeading(_ sender: Any?) { transformLines(MD.cycleHeading) }
    @objc func cxLink(_ sender: Any?) {
        let sel = selectedRange()
        let link = NSMutableAttributedString(attributedString: plain("["))
        link.append(sel.length > 0 ? piece(sel) : plain("link"))
        link.append(plain("](https://)"))
        let start = sel.location + link.length - 9 // select "https://"
        replace(sel, with: link, select: NSRange(location: start, length: 8))
    }

    // MARK: Tables

    /// The table rows around the caret, as (range without the line break, text).
    private func tableRows() -> [(range: NSRange, text: String)] {
        let ns = string as NSString
        var start = ns.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        guard MD.isTableRow(ns.substring(with: start)) else { return [] }
        while start.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: start.location - 1, length: 0))
            guard MD.isTableRow(ns.substring(with: prev)) else { break }
            start = prev
        }
        var rows: [(NSRange, String)] = [], loc = start.location
        while loc < ns.length {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            var text = ns.substring(with: p)
            guard MD.isTableRow(text) else { break }
            if text.hasSuffix("\n") { text.removeLast() }
            rows.append((NSRange(location: p.location, length: (text as NSString).length), text))
            loc = NSMaxRange(p)
        }
        return rows
    }

    /// Tab / ⇧Tab in a table: to the next or previous cell. Tab from the last cell adds a row.
    private func moveCell(forward: Bool) {
        let rows = tableRows()
        let caret = selectedRange().location
        // Each cell's text, selected on arrival so typing replaces it (a placeholder like "Column" goes at once).
        let cells = rows.filter { !MD.isTableRule($0.text) }.flatMap { row in
            MD.cellRanges(row.text).map { c -> NSRange in
                let text = (row.text as NSString).substring(with: c), body = text.trimmingCharacters(in: .whitespaces)
                // An empty cell: the caret between its spaces.
                let offset = body.isEmpty ? (text.hasPrefix(" ") ? 1 : 0) : text.prefix { $0 == " " }.utf16.count
                return NSRange(location: row.range.location + c.location + offset, length: body.utf16.count)
            }
        }
        let starts = cells.map(\.location)
        if forward {
            if let next = cells.first(where: { $0.location > caret }) { return setSelectedRange(next) }
            guard let last = rows.last, let header = rows.first else { return }
            let row = "\n|" + String(repeating: "  |", count: max(1, MD.cellRanges(header.text).count))
            replace(NSRange(location: NSMaxRange(last.range), length: 0), with: row, select: NSRange(location: NSMaxRange(last.range) + 3, length: 0))
        } else {
            let current = starts.last { $0 <= caret } ?? caret
            if let prev = cells.last(where: { $0.location < current }) { setSelectedRange(prev) }
        }
    }

    /// Return at the end of a table row adds a row; on an empty last row it leaves the table.
    private func continueTable() -> Bool {
        let rows = tableRows(), sel = selectedRange()
        guard sel.length == 0, let row = rows.first(where: { NSLocationInRange(sel.location, $0.range) || sel.location == NSMaxRange($0.range) }),
              sel.location == NSMaxRange(row.range), !MD.isTableRule(row.text) else { return false }
        if MD.cells(row.text).allSatisfy(\.isEmpty), row.range.location == rows.last?.range.location {
            replace(row.range, with: "", select: NSRange(location: row.range.location, length: 0))
        } else {
            // From the header row, the new row goes below the |---| rule, or the table breaks.
            let i = rows.firstIndex { $0.range.location == row.range.location } ?? 0
            let after = i + 1 < rows.count && MD.isTableRule(rows[i + 1].text) ? NSMaxRange(rows[i + 1].range) : sel.location
            let new = "\n|" + String(repeating: "  |", count: max(1, MD.cellRanges(rows[0].text).count))
            replace(NSRange(location: after, length: 0), with: new, select: NSRange(location: after + 3, length: 0))
        }
        return true
    }

    /// Gives the line a due date (tomorrow; it becomes a task if it isn't one) and selects it to type over,
    /// or selects the date it has.
    @objc func cxDue(_ sender: Any?) {
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = ns.substring(with: para).trimmingCharacters(in: .newlines)
        if let m = MD.match(MD.dueRegex, line) {
            return setSelectedRange(NSRange(location: para.location + m.range(at: 1).location, length: m.range(at: 1).length))
        }
        let tomorrow = MD.dayString(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        transformLines { l in
            let task = MD.match(MD.taskRegex, l) == nil ? MD.toggleChecklist(l) : l
            return task + (task.hasSuffix(" ") ? "" : " ") + "📅 " + tomorrow
        }
        let now = string as NSString
        let date = now.range(of: tomorrow, options: .backwards, range: now.paragraphRange(for: NSRange(location: para.location, length: 0)))
        if date.location != NSNotFound { setSelectedRange(date) }
    }

    @objc func cxTable(_ sender: Any?) {
        let start = selectedRange().location
        insertBlock("| Column | Column |\n| --- | --- |\n|  |  |")
        let ns = string as NSString
        let first = ns.range(of: "Column", range: NSRange(location: start, length: ns.length - start))
        if first.location != NSNotFound { setSelectedRange(first) }
    }

    /// The caret is inside a ``` block (or the note is in Code Mode): keys type code, not Markdown.
    private var inCode: Bool {
        style.code || Styler.fences(string, before: (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0)).location) % 2 == 1
    }

    override func insertTab(_ sender: Any?) {
        let code = inCode
        if !code, MD.isTableRow(currentLine) { return moveCell(forward: true) }
        if !code, MD.listMarker(currentLine) != nil { transformLines { "  " + $0 } }
        else if code {
            let n = max(1, Int(Prefs.number(Prefs.codeTab)))
            replace(selectedRange(), with: String(repeating: " ", count: n), select: NSRange(location: selectedRange().location + n, length: 0))
        }
        else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !inCode, MD.isTableRow(currentLine) { return moveCell(forward: false) }
        guard currentLine.hasPrefix(" ") || currentLine.hasPrefix("\t") || selectedRange().length > 0 else { return } // nothing to outdent: no empty undo step
        transformLines { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0.hasPrefix("\t") ? String($0.dropFirst()) : $0 }
    }

    /// ⌘] / ⌘[ (as in Notes and Pages): the selected lines one level in or out, whatever they are.
    @objc func cxMoveUp(_ sender: Any?) { moveLines(up: true) }
    @objc func cxMoveDown(_ sender: Any?) { moveLines(up: false) }

    /// The selected lines trade places with the one above or below; images and files go along.
    private func moveLines(up: Bool) {
        guard let st = textStorage, let plan = MD.moveLines(string, selectedRange(), up: up) else { return NSSound.beep() }
        let new = NSMutableAttributedString(attributedString: st.attributedSubstring(from: plan.order[0]))
        new.append(NSAttributedString(string: "\n", attributes: Styler.base(style)))
        new.append(st.attributedSubstring(from: plan.order[1]))
        replace(plan.range, with: new, select: plan.selection)
        scrollRangeToVisible(selectedRange())
    }

    @objc func cxIndent(_ sender: Any?) { transformLines { "  " + $0 } }
    @objc func cxOutdent(_ sender: Any?) {
        guard currentLine.hasPrefix(" ") || currentLine.hasPrefix("\t") || selectedRange().length > 0 else { return }
        transformLines { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0.hasPrefix("\t") ? String($0.dropFirst()) : $0 }
    }

    /// Return inside a list continues it; Return on an empty item ends it. Tables get a new row.
    func continueList() -> Bool {
        guard !inCode else { return false }
        if MD.isTableRow(currentLine), continueTable() { return true }
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        var para = ns.paragraphRange(for: sel)
        if para.length > 0, ns.substring(with: NSRange(location: NSMaxRange(para) - 1, length: 1)) == "\n" { para.length -= 1 }
        let line = ns.substring(with: para)
        // Quotes go on too.
        guard let marker = MD.listMarker(line) ?? MD.match(Styler.quote, line).map({ ns.substring(with: NSRange(location: para.location + $0.range.location, length: $0.range.length)) }),
              sel.location >= para.location + (marker as NSString).length else { return false }
        let end = para.location + (marker as NSString).length
        if line.trimmingCharacters(in: .whitespaces) == marker.trimmingCharacters(in: .whitespaces) {
            // An empty item: a nested one steps out a level, a top-level one ends the list.
            if line.hasPrefix(" ") || line.hasPrefix("\t") { insertBacktab(nil) }
            else { replace(para, with: "", select: NSRange(location: para.location, length: 0)) }
        } else if sel.location == end {
            // At the start of the item's text: an empty item opens above; this one keeps its text and tick.
            let above = MD.match(MD.taskRegex, marker) != nil ? MD.nextMarker(marker) : marker // unticked; same number (renumbered below)
            replace(NSRange(location: para.location, length: 0), with: above + "\n", select: NSRange(location: end + (above as NSString).length + 1, length: 0))
        } else {
            let insert = "\n" + MD.nextMarker(marker)
            replace(sel, with: insert, select: NSRange(location: sel.location + (insert as NSString).length, length: 0))
        }
        renumber(around: selectedRange().location)
        return true
    }

    /// Numbers the run of numbered items at the caret's indent 1, 2, 3… (from the run's first number) after
    /// Return added or split one, so it never reads 1, 2, 2.
    private func renumber(around loc: Int) {
        let ns = string as NSString
        func numbered(_ p: NSRange) -> (lead: String, digits: NSRange)? {
            let line = ns.substring(with: p)
            guard let m = MD.match(Self.numberedItem, line) else { return nil }
            return ((line as NSString).substring(with: m.range(at: 1)), NSRange(location: p.location + m.range(at: 2).location, length: m.range(at: 2).length))
        }
        let here = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        guard let item = numbered(here) else { return }
        var first = here
        while first.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: first.location - 1, length: 0))
            guard let p = numbered(prev), p.lead == item.lead else { break }
            first = prev
        }
        var fixes: [(NSRange, String)] = [], p = first, n = Int(MD.asciiDigits(ns.substring(with: numbered(first)!.digits))) ?? 1
        while p.length > 0, let it = numbered(p), it.lead == item.lead {
            let have = ns.substring(with: it.digits), want = have == MD.asciiDigits(have) ? String(n) : MD.thaiDigits(String(n))
            if have != want { fixes.append((it.digits, want)) }
            n += 1
            guard NSMaxRange(p) < ns.length else { break }
            p = ns.paragraphRange(for: NSRange(location: NSMaxRange(p), length: 0))
        }
        guard let lo = fixes.first?.0.location, let hi = fixes.last.map({ NSMaxRange($0.0) }) else { return }
        let span = NSRange(location: lo, length: hi - lo)
        let new = NSMutableString(string: ns.substring(with: span))
        for (r, s) in fixes.reversed() { new.replaceCharacters(in: NSRange(location: r.location - lo, length: r.length), with: s) }
        let keep = selectedRange(), delta = new.length - span.length
        guard shouldChangeText(in: span, replacementString: new as String) else { return }
        for (r, s) in fixes.reversed() { textStorage?.replaceCharacters(in: r, with: s) } // just the digits: attachments in the run stay
        setSelectedRange(NSRange(location: keep.location > lo ? keep.location + delta : keep.location, length: 0))
        didChangeText()
        restyle()
    }
    private static let numberedItem = try! NSRegularExpression(pattern: #"^(\s*)(\d+)\. "#)

    /// How much of a list line's start is hidden: its indent, and for bullets and tasks the marker too (drawn
    /// as ● and ☐). Numbered items show their number.
    private func hiddenPrefix(_ para: NSRange) -> Int {
        guard para.length > 0, !style.code else { return 0 }
        let line = (string as NSString).substring(with: para)
        guard let m = MD.listMarker(line), Styler.fences(string, before: para.location) % 2 == 0 else { return 0 }
        let lead = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
        return m.trimmingCharacters(in: .whitespaces).first?.isNumber == true ? lead : (m as NSString).length
    }

    /// A caret never rests inside that hidden start (typing there breaks the marker, and it can't be seen):
    /// it goes to the start of the item's text. ⌘←, clicks at the left edge and arrows all land there.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if ranges.count == 1, ranges[0].rangeValue.length == 0, !hasMarkedText() {
            let loc = ranges[0].rangeValue.location
            let para = (string as NSString).paragraphRange(for: NSRange(location: min(loc, (string as NSString).length), length: 0))
            let hidden = hiddenPrefix(para)
            if hidden > 0, loc >= para.location, loc < para.location + hidden { ranges = [NSValue(range: NSRange(location: para.location + hidden, length: 0))] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// ← from the start of an item's text goes over its hidden marker to the line above.
    override func moveLeft(_ sender: Any?) {
        let sel = selectedRange(), para = (string as NSString).paragraphRange(for: NSRange(location: sel.location, length: 0))
        let hidden = hiddenPrefix(para)
        if sel.length == 0, hidden > 0, sel.location == para.location + hidden {
            return setSelectedRange(NSRange(location: max(0, para.location - 1), length: 0))
        }
        super.moveLeft(sender)
    }

    /// ⌫ at the start of an item's text: a nested item steps out a level, a top-level one becomes plain text.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange(), para = (string as NSString).paragraphRange(for: NSRange(location: sel.location, length: 0))
        let hidden = hiddenPrefix(para)
        if sel.length == 0, hidden > 0, sel.location == para.location + hidden {
            let line = (string as NSString).substring(with: para)
            if line.hasPrefix(" ") || line.hasPrefix("\t") { return insertBacktab(nil) }
            if let m = MD.listMarker(line) {
                return replace(NSRange(location: para.location, length: (m as NSString).length), with: "", select: NSRange(location: para.location, length: 0))
            }
        }
        super.deleteBackward(sender)
    }
}

extension MarkdownTextView: NSTextStorageDelegate {
    /// Remembers which characters changed (in today's coordinates) so restyling can stay local.
    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range r: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        func merged(_ d: NSRange?) -> NSRange {
            guard let d else { return r }
            let oldEnd = NSMaxRange(r) - delta // where this edit's replaced text used to end
            let dEnd = NSMaxRange(d) >= oldEnd ? NSMaxRange(d) + delta : min(NSMaxRange(d), r.location)
            let start = min(d.location, r.location)
            return NSRange(location: start, length: max(NSMaxRange(r), dEnd) - start)
        }
        dirty = merged(dirty)
        unconverted = merged(unconverted)
        if lastActive.location != NSNotFound { lastActive = merged(lastActive) } // keep pointing at the same text
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var style: TextStyle
    let store: Store
    var onLink: (URL) -> Bool = { _ in false } // cortexy:// links (tags, [[notes]]); others open normally
    var complete: (MarkdownTextView.Completion, String) -> [String] = { _, _ in [] }
    var caretKey: UUID? // the note: its caret is remembered for next time
    var onFit: ((_ content: CGFloat, _ room: CGFloat) -> Void)? // how tall the text wants to be, and the room it has, after each change
    var measureTick = 0             // changes when it should say so again (the panel came to rest)

    /// Where the caret was in each note this session.
    static var carets: [UUID: Int] = [:]

    func makeNSView(context: Context) -> NSScrollView {
        let tv = MarkdownTextView(usingTextLayoutManager: false) // TextKit 1: stable glyph geometry for drawn checkboxes
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false // keep Markdown characters literal
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand] // colors come from the styling: links blue, tags accent
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        configure(tv)
        tv.noteID = caretKey // the note's own say on fetching its web images
        let remembered = caretKey.flatMap { Self.carets[$0] } // read first: loading moves the caret (and reports it)
        tv.load(text)
        // Back where you were in this note, else at its end.
        let end = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(remembered ?? end, end), length: 0))
        MarkdownTextView.active = tv

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        tv.usesFindBar = true // ⌘F finds in this note
        tv.isIncrementalSearchingEnabled = true
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.scrollRangeToVisible(tv.selectedRange()) // so you see where typing goes
            context.coordinator.fit(tv)
        }
        tv.didResize = { [weak tv, weak coordinator = context.coordinator] in if let tv { coordinator?.fit(tv) } }
        return scroll
    }

    private func configure(_ tv: MarkdownTextView) {
        tv.style = style
        tv.isContinuousSpellCheckingEnabled = !style.code
        tv.resolve = { [store] in store.resolve($0) }
        tv.importFile = { [store] in store.markdown(forFile: $0) }
        tv.importImage = { [store] in store.markdown(forImage: $0) }
        tv.completionSource = complete
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? MarkdownTextView else { return }
        if context.coordinator.measured != measureTick {
            context.coordinator.measured = measureTick
            DispatchQueue.main.async { context.coordinator.fit(tv) }
        }
        if tv.style != style {
            configure(tv)
            tv.load(tv.markdown()) // fonts change the size of everything, attachments included
        }
        // Usually `text` is what the editor just sent; only rebuild the Markdown to compare when it isn't.
        if text != context.coordinator.pushed, tv.markdown() != text {
            let caret = tv.selectedRange()
            tv.load(text)
            tv.setSelectedRange(NSRange(location: min(caret.location, (tv.string as NSString).length), length: 0))
        }
        context.coordinator.pushed = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var pushed: String? // the text last sent to the store
        /// This editor's own undo history: not the window's, which every note opened in it would share (⌘Z in
        /// one note undoing another), and which kept closed notes' text alive. It goes when the editor does.
        let undo = UndoManager()
        var measured = 0 // the measureTick last answered
        var reported = false // told the panel its height yet
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// Tells the panel how tall the text wants to be and the room it has. Past a screenful the answer is
        /// "more than fits" either way, so long notes aren't laid out in full.
        func fit(_ tv: MarkdownTextView) {
            guard let onFit = parent.onFit, let lm = tv.layoutManager, let tc = tv.textContainer, let scroll = tv.enclosingScrollView else { return }
            let room = scroll.contentSize.height
            if (tv.string as NSString).length >= 20_000 { return onFit(100_000, room) }
            lm.ensureLayout(for: tc)
            // Room to type in, grown a few lines at a time before the caret gets to the bottom: Return never has
            // to scroll the text while the card springs, and the card doesn't spring for every line.
            let line = tv.style.size * 1.6, text = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2 + 12
            if text + line > room || text + 5 * line < room || !reported {
                reported = true
                onFit(text + 3 * line, room)
            }
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? MarkdownTextView else { return }
            tv.convertTypedAttachments()
            let md = tv.markdown()
            pushed = md
            parent.text = md
            tv.restyle()
            tv.suggestCompletions()
            fit(tv)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            return parent.onLink(url)
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? MarkdownTextView else { return }
            tv.restyle()
            // Only while it's on screen: an editor being taken away (the note left) moves its caret too, and that
            // overwrote where you'd been, so the note reopened somewhere else.
            if let key = parent.caretKey, tv.window != nil { MarkdownEditor.carets[key] = tv.selectedRange().location }
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            sel == #selector(NSResponder.insertNewline(_:)) && (textView as? MarkdownTextView)?.continueList() == true
        }

        /// Typing right after an attachment must not inherit its attachment attributes.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            new.filter { ![.attachment, .cxSource, .cxOpen, .link].contains($0.key) }
        }
    }
}

extension Syntax.Kind {
    var color: NSColor {
        switch self {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemBlue
        case .type: .systemTeal
        }
    }
}

extension Due {
    var color: NSColor {
        switch self {
        case .overdue: .systemRed
        case .today: .systemOrange
        case .later: Themes.shared.current.accentNSColor ?? .controlAccentColor // gray was easy to miss
        case .done: .tertiaryLabelColor
        }
    }
}

extension MarkdownTextView: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { lookingAt == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { lookingAt as NSURL? }
}
