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
    }

    static let taskRegex = try! NSRegularExpression(pattern: #"^(\s*)[-*+] \[([ xX])\] "#)
    static let listRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+] \[[ xX]\] |[-*+] |\d+\. )"#)
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
        return text.components(separatedBy: "\n").map { line($0, inCode: &inCode) }
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
            return .task(ns.substring(with: m.range(at: 2)) != " ", ns.substring(from: m.range.upperBound))
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
        var inCode = false, start = 0
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
        return ns.replacingCharacters(in: box, with: ns.substring(with: box) == " " ? "x" : " ")
    }

    static func toggleTask(in text: String, line i: Int) -> String {
        var ls = text.components(separatedBy: "\n")
        guard ls.indices.contains(i) else { return text }
        ls[i] = toggleTask(ls[i])
        return ls.joined(separator: "\n")
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
