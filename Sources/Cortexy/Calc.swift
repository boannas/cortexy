import Foundation

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
