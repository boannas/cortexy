import Foundation

// What comes in and goes out through the clipboard: a pasted link (tracking taken off), pasted code, rich text
// read as Markdown, and Markdown written as HTML for other apps.

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
        (try! NSRegularExpression(pattern: MD.wikiAlias), "$1"), (try! NSRegularExpression(pattern: MD.wikiPlain), "$1"),
        (try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\((https?://[^)\s]+)\)"#), "<img src=\"$2\" alt=\"$1\">"),
        (Styler.link, "<a href=\"$2\">$1</a>"), (Styler.bold, "<b>$2</b>"), (Styler.italic, "<i>$1$2</i>"), (Styler.strike, "<s>$1</s>"), (Styler.mark, "<mark>$1</mark>"),
    ]
}
