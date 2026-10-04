import Foundation

/// Line-level Markdown helpers shared by the editor and the note cards. Pure string logic.
enum MD {
    enum Line: Equatable {
        case blank, fence
        case heading(Int, String)
        case task(Bool, String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case image(alt: String, path: String)  // a line that is only `![alt](path)`
        case file(name: String, url: String)   // a line that is only `[name](file://…)`
        case text(String)
        case meta(String)                      // a line of the YAML frontmatter at the top (Obsidian's properties)

        var isMeta: Bool { if case .meta = self { true } else { false } }
    }

    /// `- [ ]` to do, `- [x]` done, `- [/]` in progress, `- [-]` cancelled (Obsidian Tasks' statuses).
    static let taskRegex = try! NSRegularExpression(pattern: #"^(\s*)[-*+] \[([ xX/\-])\] "#)
    static let listRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+] \[[ xX/\-]\] |[-*+] |\d+\. )"#)
    /// Whether a task's box says it's finished with: done or cancelled.
    static func isDone(_ box: String) -> Bool { ["x", "X", "-"].contains(box) }
    /// A task line's box: " ", "x", "/" or "-" (nil: not a task).
    static func taskStatus(_ line: String) -> String? { match(taskRegex, line).map { (line as NSString).substring(with: $0.range(at: 2)) } }
    static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6}) +"#)
    /// Inline image `![alt](path)` and file link `[name](file://…)`; the editor shows both as attachments.
    static let imageRegex = try! NSRegularExpression(pattern: #"!\[((?:\\.|[^\]\\\n])*)\]\(([^)\s]+)\)"#)
    static let fileLinkRegex = try! NSRegularExpression(pattern: #"(?<!!)\[((?:\\.|[^\]\\\n])+)\]\((file://[^)\s]+)\)"#)

    /// The first `lines` lines of `text` (without the break after them), and whether that's all of it: what a
    /// card or a preview reads of a long note.
    static func head(_ text: String, lines: Int) -> (text: String, whole: Bool) {
        let ns = text as NSString
        var start = 0
        for i in 0..<max(1, lines) {
            let nl = ns.range(of: "\n", options: .literal, range: NSRange(location: start, length: ns.length - start))
            guard nl.location != NSNotFound else { return (text, true) }
            if i == lines - 1 { return (ns.substring(to: nl.location), nl.location + 1 == ns.length) }
            start = nl.location + 1
        }
        return (text, true)
    }

    /// The web addresses of the images the text shows (`![…](https://…)`).
    static func webImages(_ text: String) -> [String] {
        let ns = text as NSString
        return imageRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 2)) }
            .filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
    }

    /// Escapes `[`, `]` and `\` so a file name can sit inside link text.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }

    /// Whole-line match of `re`, returning capture groups 1 and 2.
    private static func whole(_ re: NSRegularExpression, _ line: String) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let m = match(re, t), m.range.location == 0, m.range.length == (t as NSString).length else { return nil }
        let ns = t as NSString
        return (unescape(ns.substring(with: m.range(at: 1))), ns.substring(with: m.range(at: 2)))
    }

    static func match(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Parses every line; the array index is the line index in `text.components(separatedBy: "\n")`.
    static func lines(_ text: String) -> [Line] {
        var inCode = false
        let meta = frontmatter(text)?.lines ?? 0
        return text.components(separatedBy: "\n").enumerated().map { i, l in i < meta ? .meta(l) : line(l, inCode: &inCode) }
    }

    /// One line, given whether a code fence above it is still open.
    private static func line(_ raw: String, inCode: inout Bool) -> Line {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") { inCode.toggle(); return .fence }
        if inCode { return .code(raw) }
        if t.isEmpty { return .blank }
        if let (alt, path) = whole(imageRegex, raw) { return .image(alt: alt, path: path) }
        if let (name, url) = whole(fileLinkRegex, raw) { return .file(name: name, url: url) }
        let ns = raw as NSString
        if let m = match(taskRegex, raw) {
            return .task(isDone(ns.substring(with: m.range(at: 2))), ns.substring(from: m.range.upperBound))
        }
        if let m = match(headingRegex, raw) {
            return .heading(m.range(at: 1).length, ns.substring(from: m.range.upperBound))
        }
        if let m = match(listRegex, raw) {
            let marker = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            let rest = ns.substring(from: m.range.upperBound)
            return marker.first?.isNumber == true ? .numbered(marker, rest) : .bullet(rest)
        }
        if t.hasPrefix(">") { return .quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        return .text(raw)
    }

    /// First non-empty line without its Markdown markers. Reads only down to that line: it's asked for all the
    /// time (sorting, cards, the palette, reminders), and parsing a long note whole each time froze typing.
    static func title(_ text: String) -> String {
        let ns = text as NSString
        var inCode = false, start = frontmatter(text)?.length ?? 0
        while start <= ns.length {
            let nl = ns.range(of: "\n", options: .literal, range: NSRange(location: start, length: ns.length - start))
            let end = nl.location == NSNotFound ? ns.length : nl.location
            switch line(ns.substring(with: NSRange(location: start, length: end - start)), inCode: &inCode) {
            case .image(let s, _), .file(let s, _): if !s.isEmpty { return s }
            case .heading(_, let s), .task(_, let s), .bullet(let s), .numbered(_, let s), .quote(let s), .text(let s):
                let clean = plainInline(s).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { return clean }
            default: break
            }
            start = end + 1
        }
        return "Empty Note"
    }

    /// Inline formatting taken off, leaving its text: `**bold**`, `*it*`, `` `code` ``, `[[T|shown]]`, `[a](url)`.
    /// Only real pairs: a lone `_` or `*` (snake_case, 2*3) is kept, so `[[snake_case]]` finds its note.
    static func plainInline(_ s: String) -> String {
        var out = s
        for (re, template) in plainPasses {
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: template)
        }
        return out
    }
    private static let plainPasses: [(NSRegularExpression, String)] = [
        (Styler.code, "$1"), (try! NSRegularExpression(pattern: #"\[\[[^\]|\n]+\|([^\]\n]+)\]\]"#), "$1"),
        (try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#), "$1"), (Styler.link, "$1"),
        (Styler.bold, "$2"), (Styler.italic, "$1$2"), (Styler.strike, "$1"), (Styler.mark, "$1"),
    ]

    /// Headings for the outline menu: line index, level and plain title.
    static func headings(_ text: String) -> [(line: Int, level: Int, title: String)] {
        lines(text).enumerated().compactMap { i, l in
            guard case let .heading(level, s) = l else { return nil }
            let t = s.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : (i, level, t)
        }
    }

    /// `- [ ] a` ⇄ `- [x] a`; other lines unchanged.
    static func toggleTask(_ line: String) -> String {
        guard let m = match(taskRegex, line) else { return line }
        let box = m.range(at: 2)
        let ns = line as NSString
        return ns.replacingCharacters(in: box, with: isDone(ns.substring(with: box)) ? " " : "x")
    }

    /// Ticking a repeating task (`🔁 every week`) also adds its next one, below it.
    static func toggleTask(in text: String, line i: Int) -> String {
        var ls = text.components(separatedBy: "\n")
        guard ls.indices.contains(i) else { return text }
        let next = taskStatus(ls[i]).map(isDone) == false ? nextOccurrence(ls[i]) : nil
        ls[i] = toggleTask(ls[i])
        if let next { ls.insert(next, at: i + 1) }
        return ls.joined(separator: "\n")
    }

    /// The line with its box set to `status` (a plain line or list item becomes a task first).
    static func setStatus(_ line: String, _ status: String) -> String {
        let task = match(taskRegex, line) == nil ? toggleChecklist(line) : line
        guard let m = match(taskRegex, task) else { return line }
        return (task as NSString).replacingCharacters(in: m.range(at: 2), with: status)
    }

    /// ⌘L: plain → task, bullet → task, task → plain.
    /// "- x" ↔ "x"; a task or number becomes a bullet.
    static func toggleBullet(_ line: String) -> String {
        let ns = line as NSString, indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if match(taskRegex, line) == nil, line.dropFirst(indent.count).hasPrefix("- ") || line.dropFirst(indent.count).hasPrefix("* ") {
            return indent + line.dropFirst(indent.count + 2)
        }
        if let m = match(listRegex, line) { return indent + "- " + ns.substring(from: m.range.upperBound) }
        return line.isEmpty ? line : indent + "- " + line.dropFirst(indent.count)
    }

    /// "> x" ↔ "x".
    static func toggleQuote(_ line: String) -> String {
        line.hasPrefix("> ") ? String(line.dropFirst(2)) : line.hasPrefix(">") ? String(line.dropFirst()) : line.isEmpty ? line : "> " + line
    }

    static func toggleChecklist(_ line: String) -> String {
        let ns = line as NSString
        if let m = match(taskRegex, line) {
            return ns.substring(with: m.range(at: 1)) + ns.substring(from: m.range.upperBound)
        }
        if let m = match(listRegex, line) {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            return indent + "- [ ] " + ns.substring(from: m.range.upperBound)
        }
        return "- [ ] " + line
    }

    /// The line as a heading of `level` (whatever it was before).
    static func heading(_ line: String, level: Int) -> String {
        let rest = match(headingRegex, line).map { (line as NSString).substring(from: $0.range.upperBound) } ?? line
        return String(repeating: "#", count: level) + " " + rest
    }

    /// Toolbar heading button: text → # → ## → ### → text.
    static func cycleHeading(_ line: String) -> String {
        guard let m = match(headingRegex, line) else { return "# " + line }
        let rest = (line as NSString).substring(from: m.range.upperBound)
        let level = m.range(at: 1).length
        return level >= 3 ? rest : String(repeating: "#", count: level + 1) + " " + rest
    }

    /// How deep a list line is nested: each tab, or every two spaces, before it is one level.
    static func indentLevel(_ line: String) -> Int {
        var tabs = 0, spaces = 0
        for c in line {
            if c == "\t" { tabs += 1 } else if c == " " { spaces += 1 } else { break }
        }
        return tabs + spaces / 2
    }

    /// The list marker at the start of a line (with indentation), if any.
    static func listMarker(_ line: String) -> String? {
        match(listRegex, line).map { (line as NSString).substring(with: $0.range) }
    }

    /// Marker for the next line when Return is pressed in a list: ticks reset, numbers count up.
    static func nextMarker(_ marker: String) -> String {
        if let m = match(taskRegex, marker) {
            return (marker as NSString).replacingCharacters(in: m.range(at: 2), with: " ")
        }
        let indent = marker.prefix { $0 == " " || $0 == "\t" }
        let body = marker.dropFirst(indent.count)
        let number = String(body.dropLast(2))
        if let n = Int(asciiDigits(number)), body.hasSuffix(". ") {
            let next = String(n + 1)
            return indent + (number == asciiDigits(number) ? next : thaiDigits(next)) + ". " // ๑. goes on to ๒.
        }
        return marker
    }

    /// Words as the system's dictionary splits them, so Thai (no spaces between words) counts right.
    static func wordCount(_ s: String) -> Int {
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    /// "1 note", "2 notes".
    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// ๐–๙ as 0–9, and back.
    static func asciiDigits(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { (0x0E50...0x0E59).contains($0.value) ? Unicode.Scalar($0.value - 0x0E50 + 48)! : $0 }))
    }
    static func thaiDigits(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { (48...57).contains($0.value) ? Unicode.Scalar($0.value - 48 + 0x0E50)! : $0 }))
    }
}

// MARK: Tags and [[links]]

extension MD {
    /// `#tag` at the start of a line, after a space, "(" or an opening quote, or straight after Thai text (Thai
    /// doesn't space words: ส่งงาน#ด่วน). Not after a Latin letter (page#section). Thai marks count as letters.
    static let tagStart = #"(?:^|(?<=[\s(“‘"'\p{Thai}]))#"#
    static let tagRegex = try! NSRegularExpression(pattern: tagStart + #"([\p{L}\p{M}\p{N}_/-]+)"#, options: .anchorsMatchLines)
    /// `[[Title]]` or `[[Title|shown text]]`.
    static let wikiRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]|\n]+)(?:\|([^\[\]\n]+))?\]\]"#)
    static let codeSpanRegex = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)

    /// The tag a `#…` match names, or nil when it's a number or a 6-digit hex color (`#decade` stays a color).
    static func tagName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/-"))
        guard t.contains(where: \.isLetter), !(t.count == 6 && t.allSatisfy(\.isHexDigit)) else { return nil }
        return t.lowercased()
    }

    /// Each line outside code blocks, with inline code blanked out (so `#x` in code isn't a tag).
    private static func prose(_ text: String) -> [String] {
        var inCode = false
        return text.components(separatedBy: "\n").compactMap { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); return nil }
            if inCode { return nil }
            return codeSpanRegex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: " ")
        }
    }

    /// Tags in a note, lowercased, first-seen order.
    static func tags(_ text: String) -> [String] {
        var seen: [String] = []
        let props = properties(text)
        for t in (props["tags"] ?? []) + (props["tag"] ?? []) {
            if let t = tagName(t.hasPrefix("#") ? String(t.dropFirst()) : t), !seen.contains(t) { seen.append(t) }
        }
        for line in prose(text) {
            let full = NSRange(location: 0, length: (line as NSString).length), links = wikiRegex.matches(in: line, range: full).map(\.range)
            for m in tagRegex.matches(in: line, range: full) where !links.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                if let t = tagName((line as NSString).substring(with: m.range(at: 1))), !seen.contains(t) { seen.append(t) }
            }
        }
        return seen
    }

    /// Titles a note links to with `[[…]]`.
    static func wikiLinks(_ text: String) -> [String] {
        prose(text).flatMap { line in
            wikiRegex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).map {
                (line as NSString).substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// For the cards: `[[T|shown]]` and `#tag` become Markdown links to `cortexy://`, outside code spans.
    static func linkify(_ s: String) -> String {
        let s = s.contains("^") ? s.replacingOccurrences(of: #"\s\^[A-Za-z0-9-]+\s*$"#, with: "", options: .regularExpression) : s // a block's ^id
        guard s.contains("[[") || s.contains("#") else { return s }
        return s.components(separatedBy: "`").enumerated().map { i, part in
            guard i % 2 == 0 else { return part } // odd pieces sit between backticks
            let ns = part as NSString, full = NSRange(location: 0, length: ns.length)
            let links = wikiRegex.matches(in: part, range: full)
            var edits: [(NSRange, String)] = links.map { m in
                let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let shown = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : target
                return (m.range, "[\(escape(shown))](\(Link.note(target).absoluteString))")
            }
            // A #tag inside [[Title #x]] is part of the title, not a tag.
            for m in tagRegex.matches(in: part, range: full) where !links.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
                guard let t = tagName(ns.substring(with: m.range(at: 1))) else { continue }
                edits.append((m.range, "[#\(escape(ns.substring(with: m.range(at: 1))))](\(Link.tag(t).absoluteString))"))
            }
            var out = part
            for (r, s) in edits.sorted(by: { $0.0.location > $1.0.location }) { out = (out as NSString).replacingCharacters(in: r, with: s) }
            return out
        }.joined(separator: "`")
    }

    /// Higher is better; nil = no match. Prefix beats a word start, beats anywhere, beats letters in order.
    /// Compared by Unicode scalar, not by Character: Thai typed so far (ประช) matches before its vowel or tone
    /// mark arrives, though ช and ชุ are different Characters.
    static func fuzzy(_ query: String, _ s: String) -> Int? {
        let q = Array(fold(query).unicodeScalars), t = Array(fold(s).unicodeScalars)
        if q.isEmpty { return 0 }
        if t.starts(with: q) { return 1000 - t.count }
        if let r = t.firstRange(of: q) {
            let wordStart = r.lowerBound == 0 || !t[r.lowerBound - 1].properties.isAlphabetic
            return (wordStart ? 800 : 600) - t.count
        }
        var i = 0, gaps = 0
        for c in q {
            guard let j = t[i...].firstIndex(of: c) else { return nil }
            gaps += j - i
            i = j + 1
        }
        return max(1, 300 - gaps - t.count / 4)
    }

    /// How search compares text. Latin ignores case and accents (cafe finds Café). Thai keeps its tone and
    /// vowel marks, which change the word (ข้าว rice, ข่าว news, ขาว white), and matches a word still being
    /// typed (ใช finds ใช้).
    static func searchOptions(_ term: String) -> String.CompareOptions {
        term.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) } ? [.caseInsensitive, .literal] : [.caseInsensitive, .diacriticInsensitive]
    }

    static func finds(_ term: String, in text: String) -> Bool { text.range(of: term, options: searchOptions(term)) != nil }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

/// In-app links from notes. They are also accepted from outside (Raycast, Shortcuts).
enum Link {
    static func tag(_ t: String) -> URL {
        URL(string: "cortexy://tag/" + (t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? t))!
    }
    static func footnote(_ label: String) -> URL {
        URL(string: "cortexy://footnote/" + (label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label))!
    }
    static func note(_ title: String) -> URL {
        var c = URLComponents()
        c.scheme = "cortexy"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "title", value: title)]
        return c.url!
    }
}

// MARK: Frontmatter and link targets

extension MD {
    /// YAML frontmatter (Obsidian's properties): a `---` first line down to the next `---` or `...` line. Its
    /// length in UTF-16 (the closing line's break included) and its number of lines; nil when there's none.
    /// Every line between must read as YAML (`key: value`, `- item`, indented, blank, `#` comment), so a note
    /// that merely starts with a divider and has another further down isn't taken for one.
    static func frontmatter(_ text: String) -> (length: Int, lines: Int)? {
        guard text.hasPrefix("---") else { return nil }
        let ns = text as NSString
        var start = 0, n = 0
        while start <= ns.length, n < 200 {
            let nl = ns.range(of: "\n", options: .literal, range: NSRange(location: start, length: ns.length - start))
            let end = nl.location == NSNotFound ? ns.length : nl.location
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let line = raw.trimmingCharacters(in: .whitespaces)
            if n == 0 {
                guard line == "---" else { return nil }
            } else if line == "---" || line == "..." {
                return (nl.location == NSNotFound ? ns.length : end + 1, n + 1)
            } else if match(yamlLine, raw) == nil {
                return nil
            }
            guard nl.location != NSNotFound else { return nil }
            start = end + 1
            n += 1
        }
        return nil
    }
    private static let yamlLine = try! NSRegularExpression(pattern: #"^(?:\s*|\s*#.*|\s*- .*|\s*-|\s+\S.*|[^\s:#-][^:]*:(?:\s.*)?)$"#)

    /// The frontmatter's keys (lowercased) and values: `key: value`, `key: [a, b]`, or `key:` above `- a` lines.
    /// Enough for `tags` and `aliases`; nested YAML is skipped.
    static func properties(_ text: String) -> [String: [String]] {
        guard let fm = frontmatter(text), fm.lines > 2 else { return [:] }
        func clean(_ s: some StringProtocol) -> String {
            s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        var out: [String: [String]] = [:], key: String?
        for line in text.components(separatedBy: "\n")[1..<(fm.lines - 1)] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- "), let k = key {
                out[k, default: []].append(clean(t.dropFirst(2)))
                continue
            }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { key = nil; continue }
            let k = clean(line[..<colon]).lowercased(), v = clean(line[line.index(after: colon)...])
            key = k
            if v.hasPrefix("["), v.hasSuffix("]") {
                out[k] = v.dropFirst().dropLast().split(separator: ",").map(clean).filter { !$0.isEmpty }
            } else if !v.isEmpty {
                out[k] = [v]
            }
        }
        return out
    }

    /// Other names a `[[link]]` may use for the note (`aliases:` in its frontmatter).
    static func aliases(_ text: String) -> [String] {
        guard text.hasPrefix("---") else { return [] }
        let p = properties(text)
        return (p["aliases"] ?? []) + (p["alias"] ?? [])
    }

    /// A `[[…]]` target's parts: `Note#Heading` → a heading, `Note#^id` → a block (the line ending in ` ^id`).
    /// An empty title means the note the link is in.
    static func splitLink(_ target: String) -> (title: String, heading: String?, block: String?) {
        guard let hash = target.firstIndex(of: "#") else { return (target.trimmingCharacters(in: .whitespaces), nil, nil) }
        let title = target[..<hash].trimmingCharacters(in: .whitespaces)
        let rest = target[target.index(after: hash)...]
        if rest.hasPrefix("^") { return (title, nil, rest.dropFirst().trimmingCharacters(in: .whitespaces)) }
        return (title, rest.components(separatedBy: "#").last!.trimmingCharacters(in: .whitespaces), nil) // Note#A#B: B
    }

    /// Whether a `[[target]]` means the note called `name`: all of it, or the part before `#heading`.
    static func links(_ target: String, to name: String) -> Bool {
        target.localizedCaseInsensitiveCompare(name) == .orderedSame
            || target.contains("#") && splitLink(target).title.localizedCaseInsensitiveCompare(name) == .orderedSame
    }

    /// The line a link's `#heading` or `#^block` points at.
    static func line(heading: String?, block: String?, in text: String) -> Int? {
        if let heading {
            return headings(text).first {
                $0.title.localizedCaseInsensitiveCompare(heading) == .orderedSame || plainInline($0.title).localizedCaseInsensitiveCompare(heading) == .orderedSame
            }?.line
        }
        guard let block, !block.isEmpty else { return nil }
        return text.components(separatedBy: "\n").firstIndex {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "^" + block || t.hasSuffix(" ^" + block)
        }
    }

    /// `text` with `[[old]]`, `[[old|shown]]` and `[[old#heading]]` pointing at `new`, after a rename. `isNote`
    /// says whether a whole target is a note's own title ("C# tips" is a note, not note "C"'s heading).
    static func relinked(_ text: String, from old: String, to new: String, isNote: (String) -> Bool = { _ in false }) -> String {
        guard text.contains("[[") else { return text }
        let out = NSMutableString(string: text)
        for m in wikiRegex.matches(in: text, range: NSRange(location: 0, length: out.length)).reversed() {
            let r = m.range(at: 1), target = (text as NSString).substring(with: r)
            let t = target.trimmingCharacters(in: .whitespaces)
            if t.localizedCaseInsensitiveCompare(old) == .orderedSame {
                out.replaceCharacters(in: r, with: new)
            } else if let hash = t.firstIndex(of: "#"), splitLink(t).title.localizedCaseInsensitiveCompare(old) == .orderedSame, !isNote(t) {
                out.replaceCharacters(in: r, with: new + t[hash...])
            }
        }
        return out as String
    }
}

// MARK: Moving lines and quick copy

extension MD {
    /// ⌥⌘↑ / ⌥⌘↓: the selected lines swap with the line above or below. What to replace, the two pieces in their
    /// new order (joined by a line break), and where the selection goes; nil at the top or bottom.
    static func moveLines(_ text: String, _ sel: NSRange, up: Bool) -> (range: NSRange, order: [NSRange], selection: NSRange)? {
        let ns = text as NSString
        func line(at loc: Int) -> NSRange { // without its line break
            let p = ns.paragraphRange(for: NSRange(location: min(max(0, loc), ns.length), length: 0))
            let brk = p.length > 0 && ns.character(at: NSMaxRange(p) - 1) == 10
            return NSRange(location: p.location, length: p.length - (brk ? 1 : 0))
        }
        var end = NSMaxRange(sel)
        if sel.length > 0, ns.character(at: end - 1) == 10 { end -= 1 } // a selection up to a line's start leaves that line
        let first = line(at: sel.location), last = line(at: end)
        let block = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        if up {
            guard block.location > 0 else { return nil }
            let prev = line(at: block.location - 1)
            return (NSRange(location: prev.location, length: NSMaxRange(block) - prev.location), [block, prev],
                    NSRange(location: sel.location - prev.length - 1, length: sel.length))
        }
        guard NSMaxRange(block) < ns.length else { return nil }
        let next = line(at: NSMaxRange(block) + 1)
        return (NSRange(location: block.location, length: NSMaxRange(next) - block.location), [next, block],
                NSRange(location: sel.location + next.length + 1, length: sel.length))
    }

    /// ⌘-click copies the thing under the pointer: a code block's code, a heading's text, a list item's text, a
    /// whole quote. nil for a plain paragraph (the click does what it always did).
    static func quickCopy(_ text: String, line i: Int) -> String? {
        let raw = text.components(separatedBy: "\n"), parsed = lines(text)
        guard parsed.indices.contains(i) else { return nil }
        switch parsed[i] {
        case .code, .fence: // the block it's in, fence to fence (an unclosed one runs to the end)
            let fences = parsed.indices.filter { parsed[$0] == .fence }
            for k in stride(from: 0, to: fences.count, by: 2) {
                let open = fences[k], close = k + 1 < fences.count ? fences[k + 1] : parsed.count
                if open <= i && i <= close { return raw[(open + 1)..<max(open + 1, close)].joined(separator: "\n") }
            }
            return nil
        case .heading(_, let s): return plainInline(s).trimmingCharacters(in: .whitespaces)
        case .task(_, let s), .bullet(let s), .numbered(_, let s): return s
        case .quote:
            var top = i, bottom = i
            while top > 0, case .quote = parsed[top - 1] { top -= 1 }
            while bottom + 1 < parsed.count, case .quote = parsed[bottom + 1] { bottom += 1 }
            return parsed[top...bottom].map { if case .quote(let q) = $0 { q } else { "" } }.joined(separator: "\n")
        default: return nil
        }
    }
}

// MARK: Pasting and copying

extension MD {
    /// A pasted bit of text that is one web address (spaces around it allowed), with tracking parameters taken off.
    static func singleURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace), let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              u.host?.isEmpty == false else { return nil }
        return withoutTracking(u)
    }

    /// `utm_…`, `fbclid` and the like say where a link was shared from; they do nothing for the page.
    static func withoutTracking(_ u: URL) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false), let items = c.queryItems, !items.isEmpty else { return u }
        let host = c.host?.lowercased() ?? ""
        let shareTag = host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("spotify.com")
        let kept = items.filter { i in
            let n = i.name.lowercased()
            return !(n.hasPrefix("utm_") || ["fbclid", "gclid", "dclid", "msclkid", "yclid", "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi"].contains(n)
                     || shareTag && n == "si")
        }
        guard kept.count != items.count else { return u }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url ?? u
    }

    /// Text that reads as code (most lines end in `;` `{` `}` `)` or start indented or with a keyword), not prose
    /// or Markdown: pasted, it goes into a code block.
    static func looksLikeCode(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 3, s.contains(where: { "{}();=".contains($0) }) else { return false }
        let markdown = lines.filter { l in ["- ", "* ", "# ", "## ", "> ", "|"].contains { l.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }
        if markdown.count * 3 > lines.count { return false }
        let codey = lines.filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return [";", "{", "}", ")", "(", ","].contains { t.hasSuffix($0) } || l.hasPrefix("    ") || l.hasPrefix("\t") || match(codeKeyword, l) != nil
        }
        return codey.count * 3 >= lines.count * 2
    }
    private static let codeKeyword = try! NSRegularExpression(pattern: #"^\s*(?:func|def|class|import|from|return|const|let|var|if|for|while|public|private|struct|fn|package|#include|SELECT|INSERT|UPDATE|end)\b"#)

    // MARK: HTML in

    /// Rich text pasted from a browser, Notes, Docs or Word, as Markdown: headings, bold, italic, links, lists,
    /// quotes, code, tables. nil when the HTML has nothing of that (a code editor's colored text): paste it plain.
    static func markdown(fromHTML html: String) -> String? {
        guard html.range(of: #"<(h[1-6]|p|li|a|strong|b|em|i|table|blockquote|pre|img|hr|del|s|mark)[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let doc = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]), let root = doc.rootElement() else { return nil }
        let body = ((try? root.nodes(forXPath: "//body"))?.first as? XMLElement) ?? root
        var out = HTMLReader().blocks(body, indent: "")
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct HTMLReader {
        func name(_ n: XMLNode) -> String { (n.name ?? "").lowercased() }
        func style(_ e: XMLElement) -> String { (e.attribute(forName: "style")?.stringValue ?? "").lowercased().replacingOccurrences(of: " ", with: "") }
        static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "table", "hr", "section", "article", "header", "footer", "main"]

        /// `**x**` around the text, its spaces outside: "** word**" wouldn't render.
        func wrap(_ s: String, _ m: String) -> String {
            let core = s.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return s }
            let lead = s.prefix { $0 == " " }, trail = String(s.reversed().prefix { $0 == " " })
            return lead + m + core + m + trail
        }

        func inline(_ n: XMLNode, pre: Bool = false) -> String {
            if n.kind == .text {
                let t = n.stringValue ?? ""
                return pre ? t : t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            }
            guard let e = n as? XMLElement else { return "" }
            let inner = { (e.children ?? []).map { inline($0, pre: pre) }.joined() }
            let st = style(e)
            switch name(e) {
            case "script", "style", "head", "title", "meta": return ""
            case "br": return "\n"
            case "strong", "b": return st.contains("font-weight:normal") || st.contains("font-weight:400") ? inner() : wrap(inner(), "**")
            case "em", "i": return wrap(inner(), "*")
            case "del", "s", "strike": return wrap(inner(), "~~")
            case "mark": return wrap(inner(), "==")
            case "code": return pre ? inner() : wrap(inner(), "`")
            case "a":
                let href = e.attribute(forName: "href")?.stringValue ?? "", text = inner()
                guard ["http", "https", "mailto"].contains(where: { href.lowercased().hasPrefix($0 + ":") }) else { return text }
                let shown = text.trimmingCharacters(in: .whitespaces)
                return shown.isEmpty || shown == href ? href : "[\(MD.escape(shown))](\(href))"
            case "img":
                let src = e.attribute(forName: "src")?.stringValue ?? "", alt = e.attribute(forName: "alt")?.stringValue ?? ""
                return src.hasPrefix("http") ? "![\(MD.escape(alt))](\(src))" : alt
            case "input" where (e.attribute(forName: "type")?.stringValue ?? "").lowercased() == "checkbox":
                return e.attribute(forName: "checked") != nil ? "[x] " : "[ ] "
            default:
                var t = inner()
                if st.contains("font-weight:700") || st.contains("font-weight:bold") || st.contains("font-weight:600") { t = wrap(t, "**") }
                if st.contains("font-style:italic") { t = wrap(t, "*") }
                if st.contains("line-through") { t = wrap(t, "~~") }
                return t
            }
        }

        func hasBlocks(_ e: XMLElement) -> Bool { (e.children ?? []).contains { Self.blockTags.contains(name($0)) } }

        func blocks(_ e: XMLElement, indent: String) -> String {
            var out = "", run = ""
            func indented(_ s: String) -> String { // "" when there's nothing to it
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? "" : t.components(separatedBy: "\n").map { indent + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            }
            func flush() {
                let t = indented(run)
                if !t.isEmpty { out += t + "\n\n" }
                run = ""
            }
            for c in e.children ?? [] {
                guard let el = c as? XMLElement, Self.blockTags.contains(name(el)) else { run += inline(c); continue }
                flush()
                switch name(el) {
                case let h where h.count == 2 && h.hasPrefix("h") && h.last!.isNumber:
                    let text = inline(el).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                    if !text.isEmpty { out += indent + String(repeating: "#", count: Int(h.dropFirst()) ?? 1) + " " + text.replacingOccurrences(of: "**", with: "") + "\n\n" }
                case "ul", "ol": out += list(el, ordered: name(el) == "ol", indent: indent) + "\n"
                case "blockquote":
                    out += blocks(el, indent: "").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                        .map { indent + ($0.isEmpty ? ">" : "> " + $0) }.joined(separator: "\n") + "\n\n"
                case "pre": out += indent + "```\n" + (el.stringValue ?? "").trimmingCharacters(in: .newlines) + "\n```\n\n"
                case "table": out += table(el) + "\n"
                case "hr": out += indent + "---\n\n"
                default: // p, div…: a paragraph (Notes puts each line in a div), or blocks inside
                    if hasBlocks(el) { out += blocks(el, indent: indent) }
                    else if case let t = indented(inline(el)), !t.isEmpty { out += t + (name(el) == "p" ? "\n\n" : "\n") }
                }
            }
            flush()
            return out
        }

        func list(_ e: XMLElement, ordered: Bool, indent: String) -> String {
            var out = "", n = 0
            for li in (e.children ?? []).compactMap({ $0 as? XMLElement }) where name(li) == "li" {
                n += 1
                let nested = (li.children ?? []).compactMap { $0 as? XMLElement }.filter { ["ul", "ol"].contains(name($0)) }
                var text = (li.children ?? []).filter { !["ul", "ol"].contains(name($0)) }.map { c -> String in
                    if let el = c as? XMLElement, ["p", "div"].contains(name(el)) { return inline(el) + " " }
                    return inline(c)
                }.joined().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                var marker = ordered ? "\(n). " : "- "
                if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") { marker = "- "; text = String(text.prefix(4)) + String(text.dropFirst(4)) }
                out += indent + marker + text + "\n"
                for sub in nested { out += list(sub, ordered: name(sub) == "ol", indent: indent + "  ") }
            }
            return out
        }

        func table(_ e: XMLElement) -> String {
            let rows = ((try? e.nodes(forXPath: ".//tr")) ?? []).compactMap { $0 as? XMLElement }.map { tr in
                (tr.children ?? []).compactMap { $0 as? XMLElement }.filter { ["td", "th"].contains(name($0)) }.map {
                    inline($0).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
                }
            }.filter { !$0.isEmpty }
            guard let width = rows.map(\.count).max(), width > 0 else { return "" }
            let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
            var lines = padded.map { "| " + $0.joined(separator: " | ") + " |" }
            lines.insert("|" + Array(repeating: " --- |", count: width).joined(), at: 1)
            return lines.joined(separator: "\n") + "\n"
        }
    }

    // MARK: HTML out

    /// A note (or part of one) as HTML, for pasting into Mail, Notes, Pages or Docs with its formatting.
    static func html(_ text: String) -> String {
        let raw = text.components(separatedBy: "\n"), parsed = lines(text), tables = tables(raw)
        var out = "", lists: [String] = [], quote = false, i = 0
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        func closeLists(to depth: Int = 0) { while lists.count > depth { out += "</\(lists.removeLast())>" } }
        func closeQuote() { if quote { out += "</blockquote>"; quote = false } }
        func item(_ kind: String, _ level: Int, _ body: String) {
            closeQuote()
            closeLists(to: level + 1)
            while lists.count < level + 1 { out += "<\(kind)>"; lists.append(kind) }
            if lists.last != kind { closeLists(to: level); out += "<\(kind)>"; lists.append(kind) }
            out += "<li>\(body)</li>"
        }
        while i < parsed.count {
            if let t = tables.first(where: { $0.lowerBound == i }) {
                closeLists(); closeQuote()
                let rows = raw[t].enumerated().filter { $0.offset != 1 }.map { cells(raw[t.lowerBound + $0.offset]) }
                out += "<table>" + rows.enumerated().map { r, cs in "<tr>" + cs.map { r == 0 ? "<th>\(inlineHTML($0))</th>" : "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
                i = t.upperBound
                continue
            }
            let level = indentLevel(raw[i])
            switch parsed[i] {
            case .fence:
                closeLists(); closeQuote()
                var code: [String] = []
                i += 1
                while i < parsed.count, parsed[i] != .fence { code.append(raw[i]); i += 1 }
                out += "<pre><code>\(esc(code.joined(separator: "\n")))</code></pre>"
            case .heading(let n, let s): closeLists(); closeQuote(); out += "<h\(n)>\(inlineHTML(s))</h\(n)>"
            case .task(let done, let s): item("ul", level, (done ? "☑ " : "☐ ") + inlineHTML(s))
            case .bullet(let s): item("ul", level, inlineHTML(s))
            case .numbered(_, let s): item("ol", level, inlineHTML(s))
            case .quote(let s):
                closeLists()
                if !quote { out += "<blockquote>"; quote = true } else { out += "<br>" }
                out += inlineHTML(s)
            case .image(let alt, let path):
                closeLists(); closeQuote()
                out += path.hasPrefix("http") ? "<p><img src=\"\(esc(path))\" alt=\"\(esc(alt))\"></p>" : "<p>\(esc(alt))</p>"
            case .file(let name, let url): closeLists(); closeQuote(); out += "<p><a href=\"\(esc(url))\">\(esc(name))</a></p>"
            case .text(let s):
                closeLists(); closeQuote()
                out += match(Styler.rule, s) != nil ? "<hr>" : "<p>\(inlineHTML(s))</p>"
            case .blank: closeLists(); closeQuote()
            case .code(let s): out += esc(s) // (only inside a fence, handled above)
            case .meta: break
            }
            i += 1
        }
        closeLists(); closeQuote()
        return "<meta charset=\"utf-8\">" + out
    }

    /// Inline Markdown as HTML: code spans kept as they are, the rest escaped and formatted.
    static func inlineHTML(_ s: String) -> String {
        s.components(separatedBy: "`").enumerated().map { i, part in
            let e = part.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            guard i % 2 == 0 else { return "<code>\(e)</code>" }
            var t = e
            for (re, tmpl) in inlinePasses { t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: tmpl) }
            return t
        }.joined()
    }
    private static let inlinePasses: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"\[\[[^\]|\n]+\|([^\]\n]+)\]\]"#), "$1"), (try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#), "$1"),
        (try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\((https?://[^)\s]+)\)"#), "<img src=\"$2\" alt=\"$1\">"),
        (Styler.link, "<a href=\"$2\">$1</a>"), (Styler.bold, "<b>$2</b>"), (Styler.italic, "<i>$1$2</i>"), (Styler.strike, "<s>$1</s>"), (Styler.mark, "<mark>$1</mark>"),
    ]
}

// MARK: Image sizes

extension MD {
    /// `![cat|300](…)` or `![|300x200](…)` (Obsidian's): the alt text, and the width asked for.
    static func imageSize(_ alt: String) -> (alt: String, width: CGFloat?) {
        guard let bar = alt.lastIndex(of: "|") else { return (alt, nil) }
        let spec = alt[alt.index(after: bar)...].split(separator: "x").first.map(String.init) ?? ""
        guard let w = Double(spec), w > 0 else { return (alt, nil) }
        return (String(alt[..<bar]), CGFloat(w))
    }

    /// The image source with its width set (nil: back to fitting), for the editor's size menu.
    static func resized(_ src: String, width: Int?) -> String {
        guard let m = imageRegex.firstMatch(in: src, range: NSRange(location: 0, length: (src as NSString).length)) else { return src }
        let ns = src as NSString
        let alt = imageSize(unescape(ns.substring(with: m.range(at: 1)))).alt
        return ns.replacingCharacters(in: m.range(at: 1), with: escape(alt) + (width.map { "|\($0)" } ?? ""))
    }
}

// MARK: Mentions, tags, diffs

extension MD {
    /// Where `name` (a note's title) appears in `text` as plain words: not inside a `[[link]]`, code or the
    /// frontmatter. Latin names must be whole words; any name must be at least 3 letters (Thai has no spaces
    /// between words, so a short one would be found inside others).
    static func mentionRanges(_ name: String, in text: String) -> [NSRange] {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.count >= 3, finds(n, in: text) else { return [] }
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        let skip = wikiRegex.matches(in: text, range: all).map(\.range) + Styler.code.matches(in: text, range: all).map(\.range)
            + Styler.codeBlocks(text).map(\.whole) + [NSRange(location: 0, length: frontmatter(text)?.length ?? 0)]
        let latin = !n.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
        func letter(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let u = Unicode.Scalar(ns.character(at: i)) else { return false }
            return u.properties.isAlphabetic || CharacterSet.decimalDigits.contains(u)
        }
        var out: [NSRange] = [], from = 0
        while from < ns.length {
            let r = ns.range(of: n, options: searchOptions(n), range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            if !skip.contains(where: { NSIntersectionRange($0, r).length > 0 }), !latin || (!letter(r.location - 1) && !letter(NSMaxRange(r))) { out.append(r) }
            from = NSMaxRange(r)
        }
        return out
    }

    /// `#old` and `#old/…` as `#new`, in the text and in the frontmatter's `tags:`.
    static func renamedTag(_ text: String, from old: String, to new: String) -> String {
        let out = NSMutableString(string: text)
        let meta = frontmatter(text)?.length ?? 0
        for m in tagRegex.matches(in: text, range: NSRange(location: meta, length: out.length - meta)).reversed() {
            let raw = (text as NSString).substring(with: m.range(at: 1))
            guard tagName(raw) == old || raw.lowercased().hasPrefix(old + "/") else { continue }
            out.replaceCharacters(in: NSRange(location: m.range(at: 1).location, length: (old as NSString).length), with: new)
        }
        guard meta > 0 else { return out as String }
        // In the frontmatter: the values of `tags:` (inline or as `- item` lines).
        var lines = (out.substring(to: meta) as String).components(separatedBy: "\n"), inTags = false
        let token = try! NSRegularExpression(pattern: #"(^|[\[\s,"'#])"# + NSRegularExpression.escapedPattern(for: old) + #"(?=$|[\]\s,"'/])"#, options: .caseInsensitive)
        for i in lines.indices.dropFirst() {
            let l = lines[i]
            if !l.hasPrefix(" "), !l.hasPrefix("\t"), !l.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                inTags = l.lowercased().hasPrefix("tags:") || l.lowercased().hasPrefix("tag:")
            }
            guard inTags else { continue }
            let colon = l.firstIndex(of: ":").map { l.distance(from: l.startIndex, to: $0) + 1 } ?? 0
            let head = String(l.prefix(colon)), body = String(l.dropFirst(colon))
            lines[i] = head + token.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: new))
        }
        return lines.joined(separator: "\n") + out.substring(from: meta)
    }

    enum Change: Equatable { case same, added, removed }

    /// Line by line, what changed from `old` to `new`: lines kept, those only in the new text, those gone.
    static func diffLines(_ old: String, _ new: String) -> [(Change, String)] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in b.difference(from: a) {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [(Change, String)] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { out.append((.removed, a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { out.append((.added, b[j])); j += 1 }
            else if j < b.count { out.append((.same, b[j])); i += 1; j += 1 }
            else { i += 1 }
        }
        return out
    }

    /// Reading time at about 230 words a minute (rounded up; 0 for an empty note).
    static func readingMinutes(_ words: Int) -> Int { words == 0 ? 0 : max(1, Int((Double(words) / 230).rounded(.up))) }
}

// MARK: Repeating tasks

extension MD {
    /// `🔁 every week`, `🔁 every 2 days`, `🔁 ทุกเดือน`: how often a task comes back.
    static let repeatRegex = try! NSRegularExpression(pattern: #"🔁\s*(?:every\s+(?:(\d+)\s+)?(day|week|month|year)s?|ทุก\s*(?:(\d+)\s*)?(วัน|สัปดาห์|อาทิตย์|เดือน|ปี))"#, options: .caseInsensitive)

    static func repetition(_ line: String) -> (unit: Calendar.Component, count: Int)? {
        guard let m = match(repeatRegex, line) else { return nil }
        let ns = line as NSString
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        let n = Int(asciiDigits(group(1) ?? group(3) ?? "1")) ?? 1
        let unit: Calendar.Component = switch (group(2) ?? group(4) ?? "").lowercased() {
        case "week", "สัปดาห์", "อาทิตย์": .weekOfYear
        case "month", "เดือน": .month
        case "year", "ปี": .year
        default: .day
        }
        return (unit, max(1, n))
    }

    /// A repeating task's next one: unticked, its date moved on by one repetition (from its date, or from
    /// today if it has none), written as the date was (พ.ศ. year, Thai digits).
    static func nextOccurrence(_ line: String, today: Date = Date()) -> String? {
        guard taskStatus(line) != nil, let rule = repetition(line) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let fresh = setStatus(line, " ")
        guard let due = due(fresh) else {
            let next = cal.date(byAdding: rule.unit, value: rule.count, to: cal.startOfDay(for: today))!
            return fresh + " 📅 " + dayString(next)
        }
        let next = cal.date(byAdding: rule.unit, value: rule.count, to: due.date)!
        guard let m = match(dueRegex, fresh) else { return nil }
        let old = (fresh as NSString).substring(with: m.range(at: 1))
        var day = dayString(next)
        if let y = Int(asciiDigits(String(old.prefix(4)))), y >= 2400 { day = String(Int(day.prefix(4))! + 543) + day.dropFirst(4) }
        if old != asciiDigits(old) { day = thaiDigits(day) }
        return (fresh as NSString).replacingCharacters(in: m.range(at: 1), with: day)
    }
}

// MARK: Sums in notes

/// A line ending in `=` shows its result (`12 × 3 + 4 =`); `name = expression` lines set names to use later
/// (`rent = 12,000`). Numbers may have thousands commas, Thai digits, `%` (of 1), `k`/`m` suffixes are not read.
/// The parser is its own: NSExpression throws Objective-C exceptions on bad input, which Swift can't catch.
enum Calc {
    static let assignment = try! NSRegularExpression(pattern: #"^\s*(?:[-*+] |\d+\. )?([\p{L}_][\p{L}\p{M}\p{N}_ ]*?)\s*=\s*(.+?)\s*$"#)

    /// Results by the UTF-16 offset of their line's start, for the lines that end in `=`.
    static func results(_ text: String) -> [Int: String] {
        guard text.contains("=") else { return [:] }
        var vars: [String: Double] = [:], out: [Int: String] = [:], inCode = false, at = 0
        let meta = MD.frontmatter(text)?.lines ?? 0
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            defer { at += (line as NSString).length + 1 }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            guard !inCode, i >= meta, line.contains("=") else { continue }
            var body = line.trimmingCharacters(in: .whitespaces)
            let asks = body.hasSuffix("=") && !body.hasSuffix("==")
            if asks { body = String(body.dropLast()).trimmingCharacters(in: .whitespaces) }
            if let m = MD.match(assignment, body) {
                let ns = body as NSString
                let name = ns.substring(with: m.range(at: 1)).lowercased(), rhs = ns.substring(with: m.range(at: 2))
                guard let v = evaluate(rhs, vars: vars, alone: true) else { continue }
                vars[name] = v
                if asks { out[at] = format(v) }
            } else if asks, let v = evaluate(body.replacingOccurrences(of: #"^(?:[-*+] |\d+\. )"#, with: "", options: .regularExpression), vars: vars) {
                out[at] = format(v)
            }
        }
        return out
    }

    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(v) < 1 ? 6 : 4
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// nil for anything that isn't a sum: words, unknown names, and (unless `alone`, as in `rent = 12,000`) a
    /// lone number: a heading "2024 =" isn't asking.
    static func evaluate(_ s: String, vars: [String: Double], alone: Bool = false) -> Double? {
        var p = Parser(tokens: tokenize(s, names: Set(vars.keys)), vars: vars)
        guard !p.tokens.isEmpty, let v = p.expression(), p.i == p.tokens.count, v.isFinite,
              alone || p.tokens.count > 1 || p.usedName else { return nil }
        return v
    }

    enum Token: Equatable { case number(Double), name(String), op(Character) }

    /// `names`: the ones set so far, so a name of several words ("rent per month") is read as one.
    static func tokenize(_ s: String, names: Set<String> = []) -> [Token] {
        let chars = Array(MD.asciiDigits(s))
        var out: [Token] = [], i = 0
        func word(at k: Int) -> (String, Int) { // letters, digits and _ from k; and where it ends
            var j = k
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j].unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) { j += 1 }
            return (String(chars[k..<j]).lowercased(), j)
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || c == "." {
                var j = i, text = ""
                while j < chars.count {
                    if chars[j].isNumber || chars[j] == "." { text.append(chars[j]); j += 1 }
                    // 12,000: a comma before exactly three digits groups thousands
                    else if chars[j] == ",", (1...3).allSatisfy({ j + $0 < chars.count && chars[j + $0].isNumber }),
                            j + 4 >= chars.count || !chars[j + 4].isNumber { j += 1 }
                    else { break }
                }
                guard let v = Double(text) else { return [] }
                out.append(.number(v))
                i = j
            } else if c.isLetter || c == "_" {
                var (name, j) = word(at: i)
                while true { // more words, while they make up a known name
                    var k = j
                    while k < chars.count, chars[k] == " " { k += 1 }
                    guard k > j, k < chars.count, chars[k].isLetter else { break }
                    let (next, end) = word(at: k)
                    let joined = name + " " + next
                    guard names.contains(where: { $0 == joined || $0.hasPrefix(joined + " ") }) else { break }
                    name = joined
                    j = end
                }
                out.append(.name(name))
                i = j
            } else if "+-*/×÷^%()".contains(c) {
                out.append(.op(c == "×" ? "*" : c == "÷" ? "/" : c))
                i += 1
            } else { return [] } // anything else: not a sum
        }
        return out
    }

    struct Parser {
        let tokens: [Token]
        let vars: [String: Double]
        var i = 0, depth = 0, usedName = false

        mutating func peek(_ c: Character) -> Bool { i < tokens.count && tokens[i] == .op(c) }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while peek("+") || peek("-") {
                let plus = peek("+"); i += 1
                guard let r = term() else { return nil }
                v = plus ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while peek("*") || peek("/") {
                let times = peek("*"); i += 1
                guard let r = power() else { return nil }
                v = times ? v * r : v / r
            }
            return v
        }

        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek("^") { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }

        mutating func unary() -> Double? {
            if peek("-") { i += 1; return unary().map { -$0 } }
            if peek("+") { i += 1; return unary() }
            guard var v = primary() else { return nil }
            while peek("%") { i += 1; v /= 100 }
            return v
        }

        mutating func primary() -> Double? {
            guard i < tokens.count else { return nil }
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { return nil }
            switch tokens[i] {
            case .number(let v): i += 1; return v
            case .name(let n):
                i += 1
                if ["sqrt", "abs", "round"].contains(n), peek("(") {
                    guard let a = primary() else { return nil }
                    return n == "sqrt" ? sqrt(a) : n == "abs" ? abs(a) : a.rounded()
                }
                usedName = true
                return vars[n]
            case .op("("):
                i += 1
                guard let v = expression(), peek(")") else { return nil }
                i += 1
                return v
            default: return nil
            }
        }
    }
}

// MARK: Search queries

/// What the search box, smart folders and `cortexy://search` understand:
/// `words` `"exact phrase"` `-without` `#tag` / `tag:x` `path:Work` / `in:Work`
/// `is:task` `is:todo` `is:done` `is:pinned` `is:snippet` `is:code` `is:archived`.
struct Query: Equatable {
    var words: [String] = []
    var excluded: [String] = []
    var tags: [String] = []
    var paths: [String] = []
    var flags: Set<String> = []

    init(_ s: String) {
        let tokens = try! NSRegularExpression(pattern: #"-?"[^"]*"|\S+"#)
        let ns = s as NSString
        for m in tokens.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            var t = ns.substring(with: m.range)
            let negated = t.hasPrefix("-") && t.count > 1
            if negated { t.removeFirst() }
            if t.hasPrefix("\"") { t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()
            if negated { excluded.append(t) }
            else if lower.hasPrefix("tag:") { tags.append(String(lower.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
            else if t.hasPrefix("#"), let tag = MD.tagName(String(t.dropFirst())) { tags.append(tag) }
            else if lower.hasPrefix("path:") || lower.hasPrefix("in:") { paths.append(String(t.drop { $0 != ":" }.dropFirst())) }
            else if lower.hasPrefix("is:") { flags.insert(String(lower.dropFirst(3))) }
            else { words.append(t) }
        }
    }

    var isEmpty: Bool { words.isEmpty && excluded.isEmpty && tags.isEmpty && paths.isEmpty && flags.isEmpty }

    /// `path` is the note's folder path ("Work › Projects"; "" at the top level).
    func matches(_ n: Note, path: String) -> Bool {
        guard n.archived == flags.contains("archived") else { return false }
        if flags.contains("pinned") && !n.pinned || flags.contains("snippet") && !n.snippet || flags.contains("code") && !n.code { return false }
        let text = n.lock == nil ? n.text : n.title // a locked note is found by its title, the only part not sealed
        for w in words where !MD.finds(w, in: text) && !MD.finds(w, in: path) { return false }
        for w in excluded where MD.finds(w, in: text) { return false }
        for p in paths where !MD.finds(p, in: path) { return false }
        if !tags.isEmpty {
            let have = MD.tags(n.text)
            for t in tags where !have.contains(where: { $0 == t || $0.hasPrefix(t + "/") }) { return false }
        }
        if !flags.isDisjoint(with: ["task", "todo", "done"]) {
            let tasks = MD.lines(n.text).compactMap { if case .task(let done, _) = $0 { done } else { nil } }
            if tasks.isEmpty || flags.contains("todo") && !tasks.contains(false) || flags.contains("done") && tasks.contains(false) { return false }
        }
        return true
    }
}

// MARK: Tables

extension MD {
    static let tableRuleRegex = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$"#)

    static func isTableRow(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    static func isTableRule(_ line: String) -> Bool { line.contains("|") && match(tableRuleRegex, line) != nil }

    /// Line runs that form tables: a header row, a `| --- |` rule, then any body rows.
    static func tables(_ lines: [String]) -> [Range<Int>] {
        var out: [Range<Int>] = [], i = 0
        while i < lines.count {
            if isTableRow(lines[i]), i + 1 < lines.count, isTableRule(lines[i + 1]) {
                var j = i + 2
                while j < lines.count, isTableRow(lines[j]), !isTableRule(lines[j]) { j += 1 }
                out.append(i..<j)
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// Each cell of a row as the text between its pipes (`\|` doesn't split). Outer pipes don't make empty cells.
    static func cellRanges(_ line: String) -> [NSRange] {
        let ns = line as NSString
        var pipes: [Int] = [], i = 0
        while i < ns.length {
            switch ns.character(at: i) {
            case 92: i += 1 // backslash: skip the escaped character
            case 124: pipes.append(i)
            default: break
            }
            i += 1
        }
        let bounds = [-1] + pipes + [ns.length]
        var cells = (0..<bounds.count - 1).map { NSRange(location: bounds[$0] + 1, length: max(0, bounds[$0 + 1] - bounds[$0] - 1)) }
        func blank(_ r: NSRange) -> Bool { ns.substring(with: r).trimmingCharacters(in: .whitespaces).isEmpty }
        if let first = pipes.first, blank(NSRange(location: 0, length: first)), !cells.isEmpty { cells.removeFirst() }
        if let last = pipes.last, blank(NSRange(location: last + 1, length: ns.length - last - 1)), !cells.isEmpty { cells.removeLast() }
        return cells
    }

    static func cells(_ line: String) -> [String] {
        cellRanges(line).map { (line as NSString).substring(with: $0).trimmingCharacters(in: .whitespaces) }
    }

    enum Align { case left, center, right }
    static func alignments(_ rule: String) -> [Align] {
        cells(rule).map { $0.hasPrefix(":") && $0.hasSuffix(":") ? .center : $0.hasSuffix(":") ? .right : .left }
    }
}

// MARK: Code colors

/// A small tokenizer for code blocks: comments, strings, numbers, keywords, and capitalized type names.
/// The language comes from the opening fence (```swift); unknown or missing ones get a generic set.
enum Syntax {
    enum Kind { case keyword, string, comment, number, type }

    private static let words: [String: String] = [
        "swift": "let var func if else guard return for in while repeat switch case default break continue struct class enum protocol extension import self Self init deinit nil true false try catch throw throws rethrows async await some any where as is static private fileprivate public internal open final override mutating inout defer do lazy weak typealias associatedtype subscript",
        "js": "const let var function return if else for while do switch case default break continue class extends new this super import export from as async await try catch finally throw typeof instanceof in of null undefined true false yield interface type enum implements public private protected readonly static void delete",
        "python": "def return if elif else for while in not and or is class import from as with try except finally raise pass break continue lambda yield global nonlocal None True False self async await del assert match case",
        "go": "func package import var const type struct interface map chan go defer return if else for range switch case default break continue select fallthrough nil true false",
        "rust": "fn let mut const static struct enum impl trait pub use mod crate self Self super match if else loop while for in return break continue as where move ref async await dyn true false unsafe type",
        "java": "class interface extends implements public private protected static final void new return if else for while do switch case default break continue try catch finally throw throws import package this super null true false var val fun object when is in override abstract data sealed enum",
        "c": "int char float double void long short unsigned signed struct union enum typedef static const extern return if else for while do switch case default break continue sizeof NULL nullptr true false class public private protected namespace using template typename new delete auto include define bool",
        "ruby": "def end if elsif else unless while until for in do return class module self nil true false and or not begin rescue ensure yield require puts then",
        "shell": "if then else elif fi for while do done case esac function return in export local echo exit cd sudo",
        "sql": "select from where insert into values update set delete create table drop alter join left right inner outer on group by order having limit as and or not null is in like distinct union count sum avg min max primary key index view",
        "data": "true false null yes no",
    ]
    private static let aliases: [String: String] = [
        "swift": "swift", "js": "js", "javascript": "js", "ts": "js", "typescript": "js", "jsx": "js", "tsx": "js", "dart": "js",
        "py": "python", "python": "python", "go": "go", "golang": "go", "rs": "rust", "rust": "rust",
        "java": "java", "kotlin": "java", "kt": "java", "cs": "java", "csharp": "java", "scala": "java",
        "c": "c", "cpp": "c", "c++": "c", "h": "c", "m": "c", "objc": "c", "objective-c": "c",
        "rb": "ruby", "ruby": "ruby", "sh": "shell", "bash": "shell", "zsh": "shell", "shell": "shell", "console": "shell",
        "sql": "sql", "json": "data", "yaml": "data", "yml": "data", "toml": "data",
    ]
    private static let generic = Set("if else for while return function func def class let var const import true false null nil None".split(separator: " ").map(String.init))
    private static var cache: [String: NSRegularExpression] = [:]

    /// Tokens in `code`, ranges relative to it.
    static func tokens(_ code: String, lang: String) -> [(NSRange, Kind)] {
        let family = aliases[lang.lowercased()] ?? ""
        let keywords = words[family].map { Set($0.split(separator: " ").map(String.init)) } ?? generic
        let typed = ["swift", "js", "java", "rust", "go", "c"].contains(family)
        let re = regex(family)
        let ns = code as NSString
        return re.matches(in: code, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            if m.range(at: 1).location != NSNotFound { return (m.range, .comment) }
            if m.range(at: 2).location != NSNotFound { return (m.range, .string) }
            if m.range(at: 3).location != NSNotFound { return (m.range, .number) }
            let word = ns.substring(with: m.range)
            if keywords.contains(family == "sql" ? word.lowercased() : word) { return (m.range, .keyword) }
            if typed, word.first?.isUppercase == true, word.count > 1 { return (m.range, .type) }
            return nil
        }
    }

    private static func regex(_ family: String) -> NSRegularExpression {
        if let r = cache[family] { return r }
        let comment = switch family {
        case "python", "ruby", "shell", "data": #"#[^\n]*"#
        case "sql": #"--[^\n]*"#
        case "": #"//[^\n]*|/\*[\s\S]*?(?:\*/|$)|(?<![\w$])#\s[^\n]*"#
        default: #"//[^\n]*|/\*[\s\S]*?(?:\*/|$)"#
        }
        let string = #""""[\s\S]*?(?:"""|$)|"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?|`(?:\\.|[^`\\])*`?"#
        let pattern = "(\(comment))|(\(string))|(\\b(?:0[xX][0-9a-fA-F]+|\\d+(?:\\.\\d+)?)\\b)|(\\b[A-Za-z_][A-Za-z0-9_]*\\b)"
        let r = try! NSRegularExpression(pattern: pattern)
        cache[family] = r
        return r
    }
}

// MARK: Due dates

extension MD {
    /// `📅 2026-10-05` or `@2026-10-05`, with an optional time: `📅 2026-10-05 14:30`.
    static let dueRegex = try! NSRegularExpression(pattern: #"(?:📅\s?|(?<![\w@.])@)(\d{4}-\d{2}-\d{2})(?:[ T](\d?\d:\d\d))?"#)
    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }
    private static let day = formatter("yyyy-MM-dd"), dayTime = formatter("yyyy-MM-dd H:mm")

    static func due(_ line: String) -> (date: Date, hasTime: Bool, range: NSRange)? {
        guard let m = match(dueRegex, line) else { return nil }
        let ns = line as NSString
        var d = asciiDigits(ns.substring(with: m.range(at: 1)))
        if let y = Int(d.prefix(4)), y >= 2400 { d = String(y - 543) + d.dropFirst(4) } // a Buddhist-era year (พ.ศ.)
        if m.range(at: 2).location != NSNotFound, let date = dayTime.date(from: d + " " + asciiDigits(ns.substring(with: m.range(at: 2)))) {
            return (date, true, m.range)
        }
        return day.date(from: d).map { ($0, false, m.range) }
    }

    static func dayString(_ date: Date) -> String { day.string(from: date) }
}

/// How pressing a due date is: done ones don't count, a date without a time is overdue from the next day.
enum Due {
    case done, overdue, today, later

    static func of(_ date: Date, hasTime: Bool, done: Bool, now: Date = Date()) -> Due {
        if done { return .done }
        let cal = Calendar.current
        if hasTime ? date < now : date < cal.startOfDay(for: now) { return .overdue }
        return cal.isDate(date, inSameDayAs: now) ? .today : .later
    }
}
