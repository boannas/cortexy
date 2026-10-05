import AppKit
import PDFKit
import SwiftUI

// How notes look in the editor: the text style (fonts, sizes), live Markdown styling, attachments (images,
// files, PDF pages) and callout kinds. Pure attribute work on a text storage; MarkdownTextView draws the rest.

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
    var readOnly = false // a note set to Read Only: shown, not edited
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
    static let callout = re(#"^(\s*>\s*)\[!([A-Za-z-]+)\]([+-]?)[ \t]*"#) // > [!note]- Title
    /// `==🔴text==` (Obsidian's colored highlights): the emoji at the start picks the color.
    static let highlightColors: [(String, NSColor)] = [("🔴", .systemRed), ("🟠", .systemOrange), ("🟢", .systemGreen), ("🔵", .systemBlue), ("🟣", .systemPurple)]
    static func highlight(_ inner: String) -> (color: NSColor, emoji: Int) {
        for (e, c) in highlightColors where inner.hasPrefix(e) { return (c, (e as NSString).length) }
        return (.systemYellow, 0)
    }

    /// The callout a quote paragraph belongs to: its header's type and fold (`-` folded, `+` foldable), the
    /// header line, and the whole run of `>` lines.
    static func callout(_ ns: NSString, _ para: NSRange) -> (type: String, fold: String, header: NSRange, run: NSRange)? {
        func isQuote(_ r: NSRange) -> Bool { MD.match(quote, ns.substring(with: r)) != nil }
        var top = para, bottom = para
        while top.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: top.location - 1, length: 0))
            guard isQuote(prev) else { break }
            top = prev
        }
        let head = ns.substring(with: top)
        guard let m = MD.match(callout, head) else { return nil }
        while NSMaxRange(bottom) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(bottom), length: 0))
            guard isQuote(next) else { break }
            bottom = next
        }
        let h = head as NSString
        return (h.substring(with: m.range(at: 2)).lowercased(), h.substring(with: m.range(at: 3)), top, NSUnionRange(top, bottom))
    }

    static let blockID = re(#"(?<=\s)\^[A-Za-z0-9-]+\s*$"#) // `text ^id`: what [[Note#^id]] points at
    static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static let codeBackground = NSColor.labelColor.withAlphaComponent(0.07)

    /// ``` lines before `location`; an odd count means `location` is inside a code block.
    static func fences(_ s: String, before location: Int) -> Int {
        // Most notes have no code: a plain search says so far faster than the regex (this runs on every key).
        guard (s as NSString).range(of: "```", options: .literal, range: NSRange(location: 0, length: location)).location != NSNotFound else { return 0 }
        return fence.numberOfMatches(in: s, range: NSRange(location: 0, length: location))
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

    /// `r` and the table rows touching it, above and below; and the quote lines (a callout's header styles its body).
    static func withTableRows(_ ns: NSString, _ r: NSRange) -> NSRange {
        var out = r
        func row(_ p: NSRange) -> Bool { let l = ns.substring(with: p); return MD.isTableRow(l) || MD.match(quote, l) != nil }
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
    /// `blocks`: the note's code blocks when the caller has them already (several ranges restyled at once).
    static func style(_ storage: NSTextStorage, active: NSRange, _ st: TextStyle, in range: NSRange? = nil,
                      blocks known: [(whole: NSRange, body: NSRange, lang: String)]? = nil, sums knownSums: [Int: String]? = nil) {
        let ns = storage.string as NSString
        let blocks = st.code ? [] : known ?? codeBlocks(storage.string)
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

        var sumCache = knownSums
        func sums() -> [Int: String] { // read once a style, only if a line asks (names set above it count)
            if sumCache == nil { sumCache = Calc.results(storage.string) }
            return sumCache!
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
                let box = (line as NSString).substring(with: m.range(at: 2)), done = MD.isDone(box)
                let kind = box == "/" ? "doing" : box == "-" ? "cancelled" : done ? "done" : "task"
                // Collapse "- [ ] " to zero width and reserve a fixed gap with kerning, so "[x]" and "[ ]" line up.
                storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .cxMarker: kind], range: marker)
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
            } else if MD.match(quote, line) != nil, let co = callout(ns, range) {
                // A callout: a tinted box (drawn), its header bold in the type's color with an icon; folded (`-`),
                // its body is out of sight until the caret goes in.
                let inRun = NSIntersectionRange(co.run, active).length > 0 || NSLocationInRange(active.location, co.run) || active.location == NSMaxRange(co.run)
                let p = paragraph(st).mutableCopy() as! NSMutableParagraphStyle
                p.firstLineHeadIndent = 14
                p.headIndent = 14
                storage.addAttribute(.paragraphStyle, value: p, range: range)
                let color = Callouts.color(co.type)
                if range.location == co.header.location {
                    let hm = MD.match(callout, line)!
                    let title = (line as NSString).substring(from: NSMaxRange(hm.range)).trimmingCharacters(in: .whitespacesAndNewlines)
                    storage.addAttributes([.foregroundColor: color, .font: st.font(weight: .semibold)], range: range)
                    if editing {
                        markup(shift(hm.range))
                        storage.addAttribute(.cxMarker, value: "callout:\(co.type)", range: NSRange(location: range.location, length: 1))
                    } else {
                        let typeWord = shift(hm.range(at: 2))
                        if title.isEmpty { // no title: the type's name stands in (its brackets hidden)
                            markup(NSRange(location: range.location, length: typeWord.location - range.location))
                            markup(NSRange(location: NSMaxRange(typeWord), length: NSMaxRange(shift(hm.range)) - NSMaxRange(typeWord)))
                        } else {
                            markup(shift(hm.range))
                        }
                        storage.addAttribute(.cxMarker, value: "calloutHead:\(co.type):\(co.fold)", range: NSRange(location: range.location, length: 1))
                        storage.addAttribute(.kern, value: st.size * 1.5, range: NSRange(location: range.location, length: 1)) // room for the icon
                    }
                } else if co.fold == "-" && !inRun {
                    let tiny = NSMutableParagraphStyle()
                    tiny.minimumLineHeight = 0.01
                    tiny.maximumLineHeight = 0.01
                    storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: tiny], range: range)
                    return
                } else {
                    markup(shift(MD.match(quote, line)!.range))
                    storage.addAttribute(.cxMarker, value: "callout:\(co.type)", range: NSRange(location: range.location, length: 1))
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
            // A sum: its result is drawn after the "=" (see `markers`).
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("="), !trimmed.hasSuffix("=="), let result = sums()[range.location] {
                let eq = (line as NSString).range(of: "=", options: .backwards)
                storage.addAttribute(.cxMarker, value: "sum:" + result, range: NSRange(location: range.location + eq.location, length: 1))
            }
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
            let done = MD.taskStatus(line).map(MD.isDone) ?? false
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
            let (color, emoji) = highlight((line as NSString).substring(with: m.range(at: 1)))
            s.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: at(m.range(at: 1)))
            if emoji > 0 { markup(at(NSRange(location: m.range(at: 1).location, length: emoji))) }
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

    /// `width`: what `![alt|300](…)` asks for; otherwise it fits the text's width and 320 pt of height.
    static func imageAttachment(_ img: NSImage, maxWidth: CGFloat, width: CGFloat? = nil) -> NSTextAttachment {
        let s = img.size
        let scale = width.map { min($0, maxWidth) / max(s.width, 1) } ?? min(1, maxWidth / max(s.width, 1), 320 / max(s.height, 1))
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

    private static let pdfThumbs = NSCache<NSURL, NSImage>()

    /// A PDF shows its first page (double-click: Quick Look), with its name under it.
    static func pdfAttachment(name: String, url: URL) -> NSTextAttachment? {
        let thumb: NSImage
        if let hit = pdfThumbs.object(forKey: url as NSURL) { thumb = hit } else {
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let box = page.bounds(for: .mediaBox), w: CGFloat = 150
            thumb = page.thumbnail(of: NSSize(width: w, height: min(w * box.height / max(box.width, 1), 210)), for: .mediaBox)
            pdfThumbs.setObject(thumb, forKey: url as NSURL)
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let size = NSSize(width: thumb.size.width + 8, height: thumb.size.height + 26)
        let card = NSImage(size: size, flipped: false) { r in
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).fill()
            thumb.draw(in: NSRect(x: 4, y: 22, width: thumb.size.width, height: thumb.size.height))
            (name as NSString).draw(with: NSRect(x: 6, y: 5, width: r.width - 12, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
        let a = NSTextAttachment()
        a.image = card
        a.bounds = CGRect(origin: .zero, size: size)
        return a
    }

    static func fileAttachment(name: String, url: URL?) -> NSTextAttachment {
        if let url, url.isFileURL, url.pathExtension.lowercased() == "pdf", let a = pdfAttachment(name: name, url: url) { return a }
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

/// An embedded note (`![[Note]]`), drawn as a framed card of its text: rendered once, like an image.
enum Embeds {
    /// `note`: what the link found (nil: no such note). `part`: the heading or block asked for, if any.
    @MainActor static func attachment(target: String, note: Note?, part: (heading: String?, block: String?), store: Store, width: CGFloat, dark: Bool) -> NSTextAttachment {
        let shown: String? = note.flatMap { n in n.lock != nil ? nil : MD.embedText(n.text, heading: part.heading, block: part.block) }
        let view = EmbedCard(target: target, title: note?.title, text: shown, locked: note?.lock != nil, store: store)
            .frame(width: max(200, width))
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(Themes.shared.current.accentColor)
        let r = ImageRenderer(content: view)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let a = NSTextAttachment()
        if let img = r.nsImage {
            a.image = img
            a.bounds = CGRect(origin: .zero, size: img.size)
        }
        return a
    }
}

/// What an embed looks like: the note's title (a link), its text as on a card, a bar down its side.
struct EmbedCard: View {
    let target: String
    let title: String?
    let text: String?
    let locked: Bool
    let store: Store

    static let maxLines = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title.map { $0 + (target.contains("#") ? "  ›  " + (MD.splitLink(target).heading ?? MD.splitLink(target).block.map { "^" + $0 } ?? "") : "") } ?? target,
                  systemImage: locked ? "lock.fill" : title == nil ? "questionmark.square.dashed" : "arrow.turn.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.cortexyAccentText)
            if locked {
                Text("This note is locked.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if title == nil {
                Text("No note called “\(MD.splitLink(target).title)” yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let text {
                let lines = text.components(separatedBy: "\n")
                let cut = lines.count > Self.maxLines
                var n = Note()
                let _ = n.text = (cut ? lines.prefix(Self.maxLines).joined(separator: "\n") : text)
                NoteCard(note: n, store: store, exporting: true, plain: true)
                if cut { Text("…").foregroundStyle(.tertiary) }
            } else {
                Text("That part of the note isn't there any more.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(alignment: .leading) { Capsule().fill(Color.cortexyAccent.opacity(0.6)).frame(width: 3).padding(.vertical, 6) }
    }
}

/// Obsidian's callout types: their colors and icons (aliases share them).
enum Callouts {
    private static let kinds: [(names: [String], color: NSColor, symbol: String)] = [
        (["note"], .systemBlue, "pencil"), (["abstract", "summary", "tldr"], .systemTeal, "doc.text"),
        (["info"], .systemBlue, "info.circle"), (["todo"], .systemBlue, "checkmark.circle"),
        (["tip", "hint", "important"], .systemCyan, "flame"), (["success", "check", "done"], .systemGreen, "checkmark"),
        (["question", "help", "faq"], .systemOrange, "questionmark.circle"), (["warning", "caution", "attention"], .systemOrange, "exclamationmark.triangle"),
        (["failure", "fail", "missing"], .systemRed, "xmark"), (["danger", "error"], .systemRed, "bolt"),
        (["bug"], .systemRed, "ladybug"), (["example"], .systemPurple, "list.bullet"), (["quote", "cite"], .systemGray, "quote.opening"),
    ]
    private static func kind(_ t: String) -> (names: [String], color: NSColor, symbol: String) { kinds.first { $0.names.contains(t.lowercased()) } ?? kinds[0] }
    static func color(_ t: String) -> NSColor { kind(t).color }
    static func symbol(_ t: String) -> String { kind(t).symbol }
}
