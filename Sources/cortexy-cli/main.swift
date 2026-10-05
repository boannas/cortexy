import AppKit
import Foundation

// `cortexy`: Cortexy notes from the command line and for AI agents (an MCP server over stdio).
//   cortexy list [folder]          titles, with their folders
//   cortexy search <words>         notes with all the words, and the line each was found on
//   cortexy read <title>           a note's Markdown
//   cortexy new <text> [--folder F]   a new note (through the app)
//   cortexy append <text> [--to T]    added to a note's end: Inbox (default), "today", or a title (through the app)
//   cortexy mcp                    serve the same as MCP tools on stdin/stdout
// It reads the notes file and never writes it: new notes and additions go to the running app through
// cortexy:// links (the app opens if it isn't running), so the app stays the one writer. Locked notes, locked
// folders and Recently Deleted are left out.

struct Library {
    struct Folder: Decodable { let id: UUID; let name: String?; let parent: UUID?; let locked: Bool?; let notes: [Note]? }
    struct Note: Decodable { let id: UUID; let text: String?; let lock: String?; let archived: Bool? }
    struct Entry { let title: String; let path: String; let text: String }

    static let root = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let trash = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let entries: [Entry]

    /// The data folder: CORTEXY_DATA_DIR, the one chosen in Cortexy's Settings, or the default.
    static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["CORTEXY_DATA_DIR"] { return URL(fileURLWithPath: env, isDirectory: true) }
        if let chosen = UserDefaults(suiteName: "com.cortexy.app")?.string(forKey: "dataDirectory") { return URL(fileURLWithPath: chosen, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cortexy", isDirectory: true)
    }

    init(directory: URL = Library.directory) throws {
        let folders = try JSONDecoder().decode([Folder].self, from: Data(contentsOf: directory.appendingPathComponent("cortexy.json")))
        let byID = Dictionary(folders.map { ($0.id, $0) }) { a, _ in a }
        func chain(_ f: Folder) -> [Folder] { // the folder and those above it
            var out = [f], seen: Set<UUID> = [f.id]
            while let p = out.last?.parent, let up = byID[p], seen.insert(p).inserted { out.append(up) }
            return out
        }
        entries = folders.flatMap { f -> [Entry] in
            let up = chain(f)
            guard !up.contains(where: { $0.id == Library.trash || $0.locked == true }) else { return [] }
            let path = up.reversed().filter { $0.id != Library.root }.compactMap(\.name).joined(separator: " › ")
            return (f.notes ?? []).compactMap { n in
                guard n.lock == nil, n.archived != true, let text = n.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return Entry(title: Library.title(text), path: path, text: text)
            }
        }
    }

    /// As the app has it: the first line with words (past any frontmatter), without its Markdown markers.
    static func title(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            lines = lines[(end + 1)...]
        }
        for l in lines {
            var t = l.trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: #"^(#{1,6} |[-*+] \[[ xX/\-]\] |[-*+] |\d+\. |> ?)"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\[\[(?:[^\]|\n]*\|)?([^\]\n]+)\]\]"#, with: "$1", options: .regularExpression)
            t = t.replacingOccurrences(of: #"[*_`~]|=="#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return "Empty Note"
    }

    func find(_ title: String) -> Entry? {
        entries.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
            ?? entries.first { $0.title.localizedCaseInsensitiveContains(title) }
    }

    func search(_ q: String) -> [(Entry, String)] {
        let words = q.split(separator: " ").map(String.init)
        return entries.compactMap { e in
            let hay = e.text + "\n" + e.path
            guard !words.isEmpty, words.allSatisfy({ hay.localizedCaseInsensitiveContains($0) }) else { return nil }
            let line = e.text.components(separatedBy: "\n").first { l in words.contains { l.localizedCaseInsensitiveContains($0) } } ?? ""
            return (e, line.trimmingCharacters(in: .whitespaces))
        }
    }
}

enum Commands {
    static func list(_ lib: Library, folder: String?) -> String {
        lib.entries.filter { folder == nil || $0.path.localizedCaseInsensitiveContains(folder!) }
            .map { $0.path.isEmpty ? $0.title : "\($0.title)  —  \($0.path)" }.joined(separator: "\n")
    }

    static func search(_ lib: Library, _ q: String) -> String {
        let hits = lib.search(q)
        return hits.isEmpty ? "No notes found for “\(q)”." : hits.map { e, line in "\(e.title)\(e.path.isEmpty ? "" : "  —  " + e.path)\n    \(line)" }.joined(separator: "\n")
    }

    static func read(_ lib: Library, _ title: String) -> String? { lib.find(title).map(\.text) }

    /// Hands the change to the app (it opens if needed) without bringing it forward.
    static func send(_ host: String, _ items: [URLQueryItem]) -> Bool {
        var c = URLComponents()
        c.scheme = "cortexy"
        c.host = host
        c.queryItems = items + [URLQueryItem(name: "show", value: "0")]
        guard let url = c.url else { return false }
        if ProcessInfo.processInfo.environment["CORTEXY_DRY_RUN"] != nil { // tests: say it, on stderr (stdout carries MCP replies)
            FileHandle.standardError.write(Data("would open \(url.absoluteString)\n".utf8))
            return true
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", url.absoluteString]
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}

// MARK: MCP (JSON-RPC 2.0, one message per line on stdin/stdout)

enum MCP {
    static let tools: [[String: Any]] = [
        tool("search_notes", "Search the user's Cortexy notes. Returns matching note titles, folders and the line found.", ["query": ("string", "Words to find (all must appear)")], required: ["query"]),
        tool("read_note", "Read a Cortexy note's full Markdown by its title.", ["title": ("string", "The note's title")], required: ["title"]),
        tool("list_notes", "List note titles with their folders.", ["folder": ("string", "Only notes in folders whose path contains this")], required: []),
        tool("create_note", "Create a new Cortexy note (Markdown; its first line is its title).", ["text": ("string", "The note's Markdown"), "folder": ("string", "Folder name (made if missing)")], required: ["text"]),
        tool("append_to_note", "Add text to the end of a note: the Inbox note by default, \"today\" for today's daily note, or a note's title.", ["text": ("string", "Markdown to add"), "note": ("string", "inbox, today, or a note title")], required: ["text"]),
    ]

    static func tool(_ name: String, _ about: String, _ props: [String: (String, String)], required: [String]) -> [String: Any] {
        ["name": name, "description": about,
         "inputSchema": ["type": "object", "properties": props.mapValues { ["type": $0.0, "description": $0.1] }, "required": required]]
    }

    /// The answer to one request (nil for a notification).
    static func handle(_ msg: [String: Any]) -> [String: Any]? {
        guard let method = msg["method"] as? String else { return nil }
        let id = msg["id"]
        if id == nil { return nil } // notifications/initialized and the like
        func reply(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": result] }
        switch method {
        case "initialize":
            let asked = (msg["params"] as? [String: Any])?["protocolVersion"] as? String
            return reply(["protocolVersion": asked ?? "2025-06-18", "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "cortexy", "version": "1.0"],
                          "instructions": "The user's personal notes from the Cortexy app. Search before reading; titles are each note's first line."])
        case "ping": return reply([:])
        case "tools/list": return reply(["tools": tools])
        case "tools/call":
            let p = msg["params"] as? [String: Any] ?? [:]
            let args = p["arguments"] as? [String: Any] ?? [:]
            let (text, failed) = call(p["name"] as? String ?? "", args)
            return reply(["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }

    static func call(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        func s(_ k: String) -> String? { (a[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        do {
            switch name {
            case "search_notes": return (Commands.search(try Library(), s("query") ?? ""), false)
            case "read_note":
                guard let t = s("title") else { return ("A title is needed.", true) }
                return Commands.read(try Library(), t).map { ($0, false) } ?? ("No note titled “\(t)”.", true)
            case "list_notes": return (Commands.list(try Library(), folder: s("folder")), false)
            case "create_note":
                guard let t = s("text") else { return ("Text is needed.", true) }
                return Commands.send("new", [URLQueryItem(name: "text", value: t)] + (s("folder").map { [URLQueryItem(name: "folder", value: $0)] } ?? []))
                    ? ("Created.", false) : ("Couldn't reach Cortexy.", true)
            case "append_to_note":
                guard let t = s("text") else { return ("Text is needed.", true) }
                return Commands.send("append", [URLQueryItem(name: "text", value: t), URLQueryItem(name: "to", value: s("note") ?? "inbox")])
                    ? ("Added.", false) : ("Couldn't reach Cortexy.", true)
            default: return ("Unknown tool \(name).", true)
            }
        } catch {
            return ("Couldn't read the notes: \(error.localizedDescription)", true)
        }
    }

    static func serve() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            guard let out = handle(msg), let json = try? JSONSerialization.data(withJSONObject: out),
                  let s = String(data: json, encoding: .utf8) else { continue }
            print(s)
            fflush(stdout)
        }
    }
}

// MARK: Main

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

let command = args.isEmpty ? "help" : args.removeFirst()
switch command {
case "mcp": MCP.serve()
case "list", "search", "read":
    let folder = option("--folder")
    guard let lib = try? Library() else { fail("Couldn't read the notes in \(Library.directory.path)") }
    switch command {
    case "list": print(Commands.list(lib, folder: folder ?? args.first))
    case "search": print(Commands.search(lib, args.joined(separator: " ")))
    default: print(Commands.read(lib, args.joined(separator: " ")) ?? { fail("No note titled “\(args.joined(separator: " "))”.") }())
    }
case "new":
    let folder = option("--folder")
    guard Commands.send("new", [URLQueryItem(name: "text", value: args.joined(separator: " "))] + (folder.map { [URLQueryItem(name: "folder", value: $0)] } ?? [])) else { fail("Couldn't reach Cortexy.") }
case "append":
    let to = option("--to")
    guard Commands.send("append", [URLQueryItem(name: "text", value: args.joined(separator: " ")), URLQueryItem(name: "to", value: to ?? "inbox")]) else { fail("Couldn't reach Cortexy.") }
default:
    print("""
    cortexy list [folder] | search <words> | read <title> | new <text> [--folder F] | append <text> [--to inbox|today|title] | mcp
    Notes are read from \(Library.directory.path); new notes and additions go through the Cortexy app.
    """)
}
