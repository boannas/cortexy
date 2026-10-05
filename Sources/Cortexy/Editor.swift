import AppKit
import Quartz
import SwiftUI

// The editor's text view: loading and restyling (Styler.swift does the styling), what it draws over the text
// (checkboxes, bullets, callouts, sums, copy buttons), clicks and keys, paste and copy, the suggestion list,
// link previews and Quick Look. MarkdownEditor.swift puts it in SwiftUI.

final class MarkdownTextView: NSTextView {
    /// The editor currently on screen, for toolbar actions that insert content (screenshots, images).
    static weak var active: MarkdownTextView?
    var didResize: (() -> Void)? // the text changed size without being typed in (loaded, an image arrived)

    var style = TextStyle()
    var previewing = false // read-only preview: no paragraph is being edited, so all markup stays hidden
    var onPreviewClick: () -> Void = {} // previews: a click that isn't on a link
    var resolve: (String) -> URL? = { _ in nil }
    /// The notes, for embeds (`![[Note]]`); nil: embeds stay as typed.
    var store: Store?
    var noteID: UUID? // whose text this is: whether its web images may be fetched
    var importFile: (URL) -> String = { $0.absoluteString }
    var importImage: (NSImage) -> String? = { _ in nil }
    private var lastActive = NSRange(location: NSNotFound, length: 0)
    private var converting = false
    enum Completion { case link, tag, command }
    /// Suggestions for what's typed after `[[` (note titles) or `#` (tags).
    var completionSource: (Completion, String) -> [String] = { _, _ in [] }
    private(set) var completing = false // the suggestion list is up; the arrows, Return, Tab and Esc belong to it
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
        var delta = attachEmbeds(in: s, range: range)
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
                    a = Attachments.imageAttachment(img, maxWidth: maxImageWidth, width: MD.imageSize(ns.substring(with: m.range(at: 1))).width)
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

    /// `![[Note]]` lines as the note's card (read-only; clicking it opens the note). Whole lines only, outside code.
    private func attachEmbeds(in s: NSMutableAttributedString, range: NSRange) -> Int {
        guard let store, !style.code, s.string.contains("![[") else { return 0 }
        let ns = s.string as NSString
        let fence = Styler.codeBlocks(s.string).map(\.whole)
        var delta = 0
        let limit = NSRange(location: range.location, length: min(range.length, ns.length - range.location))
        for m in MD.embedRegex.matches(in: s.string, range: limit).reversed() where !fence.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let parts = MD.splitLink(target)
            let note = store.note(titled: target) ?? store.note(titled: parts.title)
            let whole = note.map { $0.title.localizedCaseInsensitiveCompare(target) == .orderedSame } ?? false // "C# tips" is a title, not C's heading
            if let note, note.id == noteID { continue } // a note embedding itself: left as typed
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua // as this editor looks
            let a = Embeds.attachment(target: target, note: note, part: whole ? (nil, nil) : (parts.heading, parts.block), store: store, width: maxImageWidth, dark: dark)
            let piece = NSMutableAttributedString(attachment: a)
            piece.addAttributes(Styler.base(style), range: NSRange(location: 0, length: 1))
            piece.addAttribute(.cxSource, value: ns.substring(with: m.range), range: NSRange(location: 0, length: 1))
            piece.addAttribute(.cxOpen, value: Link.note(target), range: NSRange(location: 0, length: 1))
            s.replaceCharacters(in: m.range, with: piece)
            delta -= m.range.length - 1
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

    /// Turns freshly typed or pasted `![](…)`, file links and `![[Note]]` lines into attachments, undoably, keeping the caret in place.
    func convertTypedAttachments() {
        guard !converting, !hasMarkedText(), let st = textStorage, let edited = unconverted,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return }
        unconverted = nil
        let plain = st.string as NSString
        let full = NSRange(location: 0, length: plain.length)
        // Only the paragraphs just typed in: elsewhere links were converted already, or can't be (web, missing files).
        let scope = Styler.paragraphs(plain, edited)
        guard [MD.imageRegex, MD.fileLinkRegex, MD.embedRegex].contains(where: { $0.firstMatch(in: st.string, range: scope) != nil }) else { return }
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
            var ranges = Set(parts.map { Styler.paragraphs(ns, $0) })
            // Any edit may change a sum (a name's line edited, or deleted): the lines that show sums are styled again,
            // with the results worked out once for all of them.
            let sumRanges = dirty == nil ? [] : Self.sumLines(ns)
            ranges.formUnion(sumRanges)
            let sums = sumRanges.isEmpty ? nil : Calc.results(string)
            if editing {
                // What would really be restyled (a table goes whole) against the paragraphs being edited.
                let at = min(storage.editedRange.location, ns.length)
                let near = NSUnionRange(Styler.paragraphs(ns, NSRange(location: at, length: min(storage.editedRange.length, ns.length - at))), active)
                if ranges.contains(where: { NSUnionRange(near, Styler.withTableRows(ns, $0)) != near }) { return afterTheEdit(false) }
            }
            let blocks = fences == 0 || style.code ? [] : Styler.codeBlocks(string) // once, not once per range
            for r in ranges { Styler.style(storage, active: active, style, in: r, blocks: blocks, sums: sums) }
        }
        dirty = nil
        lastActive = active
        fenceCount = fences
        metaLines = meta
        typingAttributes = Styler.base(style)
        needsDisplay = true
    }

    /// The lines ending in "=" (sums to show). Found by searching for "=" before a line break, not by walking
    /// every line: this runs on each key typed on a line with "=", and walking a 3,000-line note cost frames.
    static func sumLines(_ ns: NSString) -> [NSRange] {
        // No "=" at a line's end anywhere (the usual case): said by two plain searches, no walk at all.
        guard ns.range(of: "=\n", options: .literal).location != NSNotFound || ns.range(of: "= \n", options: .literal).location != NSNotFound
              || ns.hasSuffix("=") || ns.hasSuffix("= ") else { return [] }
        var out: [NSRange] = [], from = 0
        func add(_ eq: Int) { // the "=" at `eq` ends its line (spaces aside); "==" is a highlight's end, not a sum
            if eq > 0, ns.character(at: eq - 1) == 61 { return }
            out.append(ns.paragraphRange(for: NSRange(location: eq, length: 0)))
        }
        while from < ns.length {
            let nl = ns.range(of: "\n", options: .literal, range: NSRange(location: from, length: ns.length - from))
            let end = nl.location == NSNotFound ? ns.length : nl.location
            var k = end - 1
            while k >= from, ns.character(at: k) == 32 || ns.character(at: k) == 9 { k -= 1 }
            if k >= from, ns.character(at: k) == 61 { add(k) }
            from = end + 1
        }
        return out
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
            if kind.hasPrefix("calloutHead:") { // a callout's icon before its title, and its fold chevron at the end
                let parts = kind.split(separator: ":", omittingEmptySubsequences: false)
                let midY = frag.minY + loc.y - style.body.capHeight / 2 + textContainerOrigin.y
                out.append((range, "callout-icon:\(parts[1])", NSRect(x: x - 1, y: midY - 9, width: 18, height: 18)))
                if parts.count > 2, !parts[2].isEmpty {
                    out.append((range, "callout-fold:\(parts[2])", NSRect(x: textContainerOrigin.x + tc.size.width - tc.lineFragmentPadding - 20, y: midY - 9, width: 18, height: 18)))
                }
                return
            }
            if kind.hasPrefix("callout:") { return } // its box is drawn under the text (drawBackground)
            if kind.hasPrefix("sum:") { // after the "=": where its result is written
                let box = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                out.append((range, kind, NSRect(x: box.maxX + textContainerOrigin.x + 6, y: box.minY + textContainerOrigin.y, width: 200, height: box.height)))
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
            if m.kind.hasPrefix("sum:") {
                let text = NSAttributedString(string: String(m.kind.dropFirst(4)), attributes: [.font: style.font(weight: .semibold), .foregroundColor: style.checkColor])
                text.draw(at: NSPoint(x: m.rect.minX, y: m.rect.minY + (m.rect.height - text.size().height) / 2))
                continue
            }
            if m.kind.hasPrefix("callout-") {
                let arg = String(m.kind.split(separator: ":").last ?? "")
                let icon = m.kind.hasPrefix("callout-icon")
                let name = icon ? Callouts.symbol(arg) : arg == "-" ? "chevron.right" : "chevron.down"
                let color = icon ? Callouts.color(arg) : NSColor.secondaryLabelColor
                guard let img = markerImage(name, size: style.size - (icon ? 0 : 3), colors: [color], key: "\(name)|\(style.size)|\(icon)|\(arg)|\(look)") else { continue }
                let r = NSRect(x: m.rect.midX - img.size.width / 2, y: m.rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height)
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                continue
            }
            let done = m.kind == "done"
            let bullet = m.kind.hasPrefix("bullet")
            let level = Int(m.kind.dropFirst(6)) ?? 0
            let name = bullet ? ["circle.fill", "circle", "square.fill"][level % 3]
                : done ? "checkmark.square.fill" : m.kind == "doing" ? "square.lefthalf.filled" : m.kind == "cancelled" ? "xmark.square" : "square"
            let size: CGFloat = bullet ? (level == 1 ? 7 : 6) : style.size + 1
            let colors: [NSColor] = done ? [.white, style.checkColor] : bullet || m.kind == "doing" ? [style.checkColor] : [.secondaryLabelColor] // check, box
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
        // Callouts: each line's band of the box, tinted in the type's color, with a bar down its side.
        storage.enumerateAttribute(.cxMarker, in: chars) { value, range, _ in
            guard let kind = value as? String, kind.hasPrefix("callout") else { return }
            let type = String(kind.split(separator: ":")[1])
            let para = (storage.string as NSString).paragraphRange(for: range)
            let glyphs = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
            var band = NSRect.null
            lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, _, _ in band = band.union(frag) }
            band = NSRect(x: textContainerOrigin.x + tc.lineFragmentPadding, y: band.minY + textContainerOrigin.y,
                          width: tc.size.width - 2 * tc.lineFragmentPadding, height: band.height)
            Callouts.color(type).withAlphaComponent(0.1).setFill()
            band.fill()
            Callouts.color(type).withAlphaComponent(0.7).setFill()
            NSRect(x: band.minX, y: band.minY, width: 3, height: band.height).fill()
        }
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

    override func resignFirstResponder() -> Bool {
        // Focus gone elsewhere: the list goes (a beat later, so a click on one of its rows still lands).
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.firstResponder !== self else { return }
            if let box = suggestionBox, let r = window?.firstResponder as? NSView, r.isDescendant(of: box) { return }
            hideSuggestions()
        }
        return super.resignFirstResponder()
    }

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
        if let hit = markers().first(where: { $0.kind.hasPrefix("callout-fold:") && $0.rect.insetBy(dx: -4, dy: -4).contains(p) }),
           let m = Styler.callout.firstMatch(in: string, range: (string as NSString).paragraphRange(for: hit.range)) {
            replace(m.range(at: 3), with: hit.kind.hasSuffix("-") ? "+" : "-") // folds and unfolds, kept in the note
            return
        }
        if let hit = markers().first(where: { ["task", "done", "doing", "cancelled"].contains($0.kind) && $0.rect.contains(p) }) {
            // "- [ ] " → the box character is 3 UTF-16 units in
            let box = NSRange(location: hit.range.location + 3, length: 1)
            let locked = !isEditable // a read-only note still ticks its boxes
            isEditable = true
            let ticking = hit.kind == "task" || hit.kind == "doing"
            let line = (string as NSString).paragraphRange(for: hit.range)
            let next = ticking ? MD.nextOccurrence((string as NSString).substring(with: line).trimmingCharacters(in: .newlines)) : nil
            replace(box, with: ticking ? "x" : " ")
            if let next { // a repeating task: its next one goes under it
                let end = NSMaxRange(line) > 0 && (string as NSString).character(at: NSMaxRange(line) - 1) == 10 ? NSMaxRange(line) - 1 : NSMaxRange(line)
                replace(NSRange(location: end, length: 0), with: "\n" + next)
            }
            if Prefs.sinksDone { sinkTask(at: line.location) }
            isEditable = !locked
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
        if let url = attachmentURL(at: p), url.scheme == "cortexy" { // an embedded note: a click opens it
            if event.clickCount == 1 { _ = delegate?.textView?(self, clickedOnLink: url, at: characterIndexForInsertion(at: p)) }
            return
        }
        if event.clickCount == 2, let url = attachmentURL(at: p) {
            if UserDefaults.standard.object(forKey: Prefs.quickLook) as? Bool ?? true { quickLook(url) } else { NSWorkspace.shared.open(url) }
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: The bar over a selection

    private var selectionBar: NSView?

    /// Bold, italic and the rest, just above what's selected once the selecting is done.
    private func placeSelectionBar() {
        let sel = selectedRange()
        guard sel.length > 0, !previewing, isEditable, window != nil, UserDefaults.standard.object(forKey: Prefs.selectionBar) as? Bool ?? true,
              let lm = layoutManager, let tc = textContainer else { selectionBar?.isHidden = true; return }
        let bar = selectionBar ?? {
            let v = FirstMouseHostingView(rootView: SelectionBar())
            v.frame.size = v.fittingSize
            addSubview(v)
            selectionBar = v
            return v
        }()
        var first = NSRect.null // the selection's first line
        lm.enumerateEnclosingRects(forGlyphRange: lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil), withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, stop in
            first = r
            stop.pointee = true
        }
        guard !first.isNull else { bar.isHidden = true; return }
        first = first.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let size = bar.frame.size
        var y = first.minY - size.height - 4 // above (the view is flipped)
        if y < visibleRect.minY { y = first.maxY + 4 }
        let x = min(max(visibleRect.minX + 4, first.minX), visibleRect.maxX - size.width - 4)
        bar.frame.origin = NSPoint(x: x, y: y)
        bar.isHidden = false
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

    /// Right-click an image: its size (written into the note as Obsidian does, `![alt|400](…)`).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard isEditable, let st = textStorage, st.length > 0 else { return menu }
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let at = [i, i - 1].first { $0 >= 0 && $0 < st.length && (st.attribute(.cxSource, at: $0, effectiveRange: nil) as? String)?.hasPrefix("![") == true }
        guard let at else { return menu }
        let size = NSMenu(title: "Image Size")
        for (title, w) in [("Small", 200), ("Medium", 400), ("Large", 600), ("Fit the Note", 0)] {
            let item = NSMenuItem(title: title, action: #selector(resizeImage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [at, w]
            size.addItem(item)
        }
        let top = NSMenuItem(title: "Image Size", action: nil, keyEquivalent: "")
        top.submenu = size
        menu.insertItem(top, at: 0)
        for (i, (title, action)) in [("Copy Text in Image", #selector(copyImageText(_:))), ("Add Text from Image Below", #selector(insertImageText(_:)))].enumerated() {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = at
            menu.insertItem(item, at: 1 + i)
        }
        menu.insertItem(.separator(), at: 3)
        return menu
    }

    /// The text in an image (read on this Mac), then `use` with it on the main thread; says so if there's none.
    private func imageText(at i: Int, _ use: @escaping (String) -> Void) {
        guard let st = textStorage, i < st.length, let url = st.attribute(.cxOpen, at: i, effectiveRange: nil) as? URL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = ImageText.read(url) ?? ""
            DispatchQueue.main.async { text.isEmpty ? NSSound.beep() : use(text) }
        }
    }

    @objc private func copyImageText(_ item: NSMenuItem) {
        imageText(at: item.representedObject as? Int ?? 0) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    }

    @objc private func insertImageText(_ item: NSMenuItem) {
        let at = item.representedObject as? Int ?? 0
        imageText(at: at) { [weak self] text in
            guard let self else { return }
            let line = (string as NSString).paragraphRange(for: NSRange(location: at, length: 0))
            setSelectedRange(NSRange(location: NSMaxRange(line), length: 0))
            insertBlock(text)
        }
    }

    @objc private func resizeImage(_ item: NSMenuItem) {
        guard let v = item.representedObject as? [Int], let st = textStorage, v[0] < st.length,
              let src = st.attribute(.cxSource, at: v[0], effectiveRange: nil) as? String else { return }
        replace(NSRange(location: v[0], length: 1), with: MD.resized(src, width: v[1] > 0 ? v[1] : nil))
        convertTypedAttachments()
    }

    /// The task at `loc` to its place in its list: a ticked one below the unticked ones, an unticked one back
    /// above the ticked ones. Its images and files go along (the lines move as they are).
    func sinkTask(at loc: Int) {
        let ns = string as NSString
        let lines = string.components(separatedBy: "\n")
        let i = ns.substring(to: min(loc, ns.length)).components(separatedBy: "\n").count - 1
        guard let plan = MD.sinkOrder(lines, at: i), let st = textStorage else { return }
        var starts: [Int] = [], at = 0 // where each line starts
        for l in lines { starts.append(at); at += (l as NSString).length + 1 }
        func range(_ k: Int) -> NSRange { NSRange(location: starts[k], length: (lines[k] as NSString).length) }
        let whole = NSUnionRange(range(plan.run.lowerBound), range(plan.run.upperBound - 1))
        let new = NSMutableAttributedString()
        var moved: [Int: Int] = [:] // each line's new start
        for (n, k) in plan.order.enumerated() {
            if n > 0 { new.append(NSAttributedString(string: "\n", attributes: Styler.base(style))) }
            moved[k] = whole.location + new.length
            new.append(st.attributedSubstring(from: range(k)))
        }
        // The caret stays in its own line (it would keep its offset and land in another task).
        let caret = selectedRange()
        let caretLine = plan.run.first { NSLocationInRange(caret.location, NSRange(location: starts[$0], length: (lines[$0] as NSString).length + 1)) }
        let select = caretLine.map { NSRange(location: moved[$0]! + caret.location - starts[$0], length: caret.length) }
        replace(whole, with: new, select: select)
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
        // RTF through WebKit's importer, which would fetch web images (and wait for them): their alt text instead.
        let local = html.replacingOccurrences(of: #"<img[^>]*alt="([^"]*)"[^>]*>"#, with: "$1", options: .regularExpression)
        if let rich = try? NSAttributedString(data: Data(local.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
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
        if let url = MD.singleURL(text), plainProse(at: sel.location) { return pasteLink(url) }
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

    /// Where a pasted link may become `[Title](link)`: not inside a link's `(…)` or `<…>`, inline code or the
    /// frontmatter (it'd break them); there it goes in as copied.
    private func plainProse(at loc: Int) -> Bool {
        let ns = string as NSString
        guard loc >= MD.frontmatter(string)?.length ?? 0 else { return false }
        let start = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0)).location
        let before = ns.substring(with: NSRange(location: start, length: loc - start))
        if before.filter({ $0 == "`" }).count % 2 == 1 { return false }
        return !(before.hasSuffix("(") || before.hasSuffix("<") || before.hasSuffix("[") || before.hasSuffix("=") || before.hasSuffix("\""))
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
        var open = before.range(of: "[[", options: .backwards)
        // "[[[WH+] T": the link opens at the run's first two brackets; the third is the title's own.
        while open.location != NSNotFound, open.location > 0, before.character(at: open.location - 1) == 91 { open.location -= 1 }
        if open.location != NSNotFound {
            let typed = before.substring(from: NSMaxRange(open))
            if !typed.contains("]]") && !typed.contains("|") {
                return (.link, NSRange(location: start + NSMaxRange(open), length: before.length - NSMaxRange(open)))
            }
        }
        if let m = Self.tagTail.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) {
            return (.tag, NSRange(location: start + m.range(at: 1).location, length: m.range(at: 1).length))
        }
        if !style.readOnly, let m = Self.slashTail.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) {
            return (.command, NSRange(location: start + m.range.location, length: m.range.length)) // the "/" too: picking one removes it
        }
        return nil
    }

    /// `/` at a line's start or after a space, then what's typed: the command menu.
    private static let slashTail = try! NSRegularExpression(pattern: #"(?:^|(?<=\s))/[\p{L}\p{N}]*$"#)
    /// The `/` menu: what each command is called, and the editing action it runs.
    static let commands: [(title: String, action: String)] = [
        ("Heading 1", "cxHeading1:"), ("Heading 2", "cxHeading2:"), ("Heading 3", "cxHeading3:"), ("Bullet List", "cxBullet:"),
        ("Numbered List", "cxNumbered:"), ("Checklist", "cxTask:"), ("Quote", "cxQuote:"), ("Callout", "cxCallout:"),
        ("Code Block", "cxCodeBlock:"), ("Table", "cxTable:"), ("Divider", "cxDivider:"), ("Highlight", "cxHighlight:"),
        ("Due Date", "cxDue:"), ("Today's Date", "cxToday:"), ("Mark In Progress", "cxDoing:"), ("Mark Cancelled", "cxCancelled:"),
        ("Repeat Weekly", "cxRepeat:"),
    ]

    /// What the list offers for `kind` and what's typed so far.
    private func options(_ kind: Completion, _ partial: String) -> [String] {
        guard kind == .command else { return completionSource(kind, partial) }
        let typed = String(partial.dropFirst()) // after the "/"
        return Self.commands.compactMap { c in MD.fuzzy(typed, c.title).map { ("/" + c.title, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: The suggestion list
    //
    // Drawn inside the editor, under the caret. (NSTextView's own completion list is a window of its own: from the
    // panel, which doesn't make Cortexy the active app, it often didn't show, and clicking it took the focus away.)

    private var suggestionBox: FirstMouseHostingView<SuggestionList>?
    /// What the list shows, what it was made for, the text it replaces, and the row picked with the arrows (nil:
    /// none yet, so Return still makes a new line: typing #home then Return keeps "#home", not #homework).
    private(set) var suggestions: [String] = []
    private var suggestionKind: Completion?
    private var suggestionRange = NSRange(location: NSNotFound, length: 0)
    private(set) var highlighted: Int?
    private var askedForRoom = false // the panel was asked to grow for the list
    var suggestionRangeStart: Int { suggestionRange.location }

    /// After each edit: shows the list when what's being typed has suggestions, and hides it when not.
    func suggestCompletions() {
        guard !hasMarkedText(), window != nil, let (kind, r) = completionContext() else { return hideSuggestions() }
        let partial = (string as NSString).substring(with: r)
        let options = (kind == .tag && partial.isEmpty) ? [] : options(kind, partial)
        guard !options.isEmpty, options != [partial] else { return hideSuggestions() }
        if options != suggestions || kind != suggestionKind { highlighted = nil }
        suggestions = Array(options.prefix(30))
        suggestionKind = kind
        suggestionRange = r
        completing = true
        showSuggestions()
    }

    func hideSuggestions() {
        guard completing || suggestionBox?.isHidden == false else { return }
        if askedForRoom { askedForRoom = false; PanelController.shared?.needs(atLeast: 0, for: "suggestions") }
        completing = false
        suggestions = []
        highlighted = nil
        suggestionBox?.isHidden = true
    }

    private func showSuggestions() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        // In the panel, room to show it: the panel grows while the list is up (a short note makes a short panel).
        if let c = PanelController.shared, window === c.panel, !askedForRoom {
            askedForRoom = true
            c.needs(atLeast: 440, for: "suggestions")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in if self?.completing == true { self?.showSuggestions() } } // placed again once it's grown
        }
        let caret = min(selectedRange().location, (string as NSString).length)
        var at = NSRect(x: 0, y: 0, width: 0, height: style.lineHeight) // the caret, in the text container
        if lm.numberOfGlyphs > 0 {
            let r = lm.boundingRect(forGlyphRange: NSRange(location: lm.glyphIndexForCharacter(at: max(0, caret - 1)), length: 1), in: tc)
            at = NSRect(x: caret > 0 ? r.maxX : r.minX, y: r.minY, width: 0, height: r.height)
        }
        at = at.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // Below the caret's line, or above it when there's more room there; as tall as fits (it scrolls).
        let below = visibleRect.maxY - at.maxY - 6, above = at.minY - visibleRect.minY - 6
        let room = max(below, above, 90)
        let list = SuggestionList(items: suggestions, highlighted: highlighted, kind: suggestionKind ?? .link, maxHeight: room) { [weak self] in self?.pickSuggestion($0) }
        let box = suggestionBox ?? {
            let v = FirstMouseHostingView(rootView: list)
            addSubview(v)
            suggestionBox = v
            return v
        }()
        box.rootView = list
        box.frame.size = NSSize(width: SuggestionList.width, height: list.height)
        let size = box.frame.size
        let y = below >= size.height || below >= above ? at.maxY + 2 : at.minY - size.height - 2
        box.frame.origin = NSPoint(x: min(max(visibleRect.minX + 4, at.minX - 12), visibleRect.maxX - size.width - 4), y: y)
        box.isHidden = false
    }

    /// ↑ ↓ move along the list, ↩ or ⇥ take the row (⇥ the first one if none is picked), Esc closes it. Anything
    /// else goes on to the editor. Returns whether the key was the list's.
    func handleSuggestionKey(_ sel: Selector) -> Bool {
        guard completing, !suggestions.isEmpty else { return false }
        switch sel {
        case #selector(moveDown(_:)): highlighted = min((highlighted ?? -1) + 1, suggestions.count - 1)
        case #selector(moveUp(_:)): highlighted = max((highlighted ?? suggestions.count) - 1, 0)
        case #selector(insertTab(_:)): pickSuggestion(suggestions[highlighted ?? 0]); return true
        case #selector(insertNewline(_:)):
            guard let h = highlighted else { hideSuggestions(); return false } // nothing picked: the new line it was pressed for
            pickSuggestion(suggestions[h]); return true
        case #selector(cancelOperation(_:)): hideSuggestions(); return true
        default: return false
        }
        showSuggestions()
        return true
    }

    /// A suggestion taken: in place of what was typed, finished off with `]]` after a title and a space after a
    /// tag (Thai has no other word break). A `/` command takes its typed name away and runs on the line.
    func pickSuggestion(_ word: String) {
        guard let kind = suggestionKind, NSMaxRange(suggestionRange) <= (string as NSString).length else { return hideSuggestions() }
        let r = suggestionRange
        hideSuggestions()
        if kind == .command, let c = Self.commands.first(where: { "/" + $0.title == word }) {
            replace(r, with: "", select: NSRange(location: r.location, length: 0))
            NSApp.sendAction(Selector(c.action), to: self, from: self)
            return
        }
        let rest = (string as NSString).substring(from: NSMaxRange(r))
        var text = word
        var after = 0 // past the "]]" that was there already
        if kind == .link { if rest.hasPrefix("]]") { after = 2 } else { text += "]]" } }
        if kind == .tag, !rest.hasPrefix(" ") { text += " " }
        replace(r, with: text, select: NSRange(location: r.location + (text as NSString).length + after, length: 0))
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
    @objc func cxHeading1(_ sender: Any?) { transformLines { MD.heading($0, level: 1) } }
    @objc func cxHeading2(_ sender: Any?) { transformLines { MD.heading($0, level: 2) } }
    @objc func cxHeading3(_ sender: Any?) { transformLines { MD.heading($0, level: 3) } }
    @objc func cxCallout(_ sender: Any?) { transformLines { $0.hasPrefix("> [!") ? $0 : "> [!note] " + ($0.hasPrefix("> ") ? String($0.dropFirst(2)) : $0) } }
    @objc func cxDoing(_ sender: Any?) { transformLines { MD.setStatus($0, MD.taskStatus($0) == "/" ? " " : "/") } }
    @objc func cxCancelled(_ sender: Any?) { transformLines { MD.setStatus($0, MD.taskStatus($0) == "-" ? " " : "-") } }
    @objc func cxRepeat(_ sender: Any?) { transformLines { MD.repetition($0) == nil ? MD.setStatus($0, MD.taskStatus($0) ?? " ") + " 🔁 every week" : $0 } }
    @objc func cxToday(_ sender: Any?) { insertText(Nav.expand("{{date}}").text, replacementRange: selectedRange()) }
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
        if stillSelecting { selectionBar?.isHidden = true } else { placeSelectionBar() }
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

extension MarkdownTextView: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { lookingAt == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { lookingAt as NSURL? }
}

extension MarkdownTextView {
    /// The caret went elsewhere (a click, ←/→): the list goes unless it's still in what's being typed.
    func caretMovedForSuggestions() {
        guard completing else { return }
        guard let (_, r) = completionContext(), r.location == suggestionRangeStart else { return hideSuggestions() }
    }
}
