import AppKit
import CryptoKit
import Observation
import Vision

// What a note shows from outside: web images (fetched only when allowed), web link titles and cards, and the
// text read from images for search.

/// Images from the web for `![](https://…)`: fetched in the background once, kept in Caches, shown when they
/// arrive (editors reload, cards redraw). Settings → General can turn fetching off.
@Observable final class WebImages {
    static let shared = WebImages()
    static let arrived = Notification.Name("CortexyWebImageArrived")
    private(set) var arrivals = 0 // bumps on each arrival, so views showing images redraw
    @ObservationIgnored private let memory = NSCache<NSURL, NSImage>()
    @ObservationIgnored private var loading = Set<URL>()
    @ObservationIgnored private var failed = Set<URL>()

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cortexy/Web", isDirectory: true)
    }

    /// Fetching an image tells its server the note was opened (a tracking pixel can do just that), so it's done only
    /// with Settings' "every note" on, or for a note whose images were loaded with its "Load" button.
    func allows(_ note: UUID?) -> Bool {
        (UserDefaults.standard.object(forKey: Prefs.webImages) as? Bool ?? false) || note.map(allowedNotes.contains) == true
    }

    /// A note's "Load Images": its web images, now and from then on.
    func allow(_ note: UUID) {
        allowedNotes.insert(note)
        UserDefaults.standard.set(allowedNotes.map(\.uuidString), forKey: Self.allowedKey)
        arrivals += 1 // cards look again
        NotificationCenter.default.post(name: Self.allowed, object: note)
    }
    static let allowed = Notification.Name("CortexyWebImagesAllowed")
    private static let allowedKey = "webImageNotes"
    @ObservationIgnored private var allowedNotes = Set((UserDefaults.standard.stringArray(forKey: "webImageNotes") ?? []).compactMap(UUID.init(uuidString:)))

    /// Whether it may still show up: fetching is allowed for its note and hasn't failed.
    func coming(_ url: URL, note: UUID?) -> Bool { allows(note) && !failed.contains(url) }

    /// The image if it's here (fetched before: showing it asks no server); otherwise nil, and it's fetched (once)
    /// for next time if its note allows that.
    func image(_ url: URL, note: UUID?) -> NSImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        let file = directory.appendingPathComponent(SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
        if let img = NSImage(contentsOf: file) {
            memory.setObject(img, forKey: url as NSURL)
            return img
        }
        if allows(note) { fetch(url, to: file) }
        return nil
    }

    private func fetch(_ url: URL, to file: URL) {
        guard !loading.contains(url), !failed.contains(url) else { return }
        loading.insert(url)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 20)) { data, _, _ in
            DispatchQueue.main.async { [self] in
                loading.remove(url)
                guard let data, data.count < 25_000_000, let img = NSImage(data: data) else {
                    failed.insert(url)
                    arrivals += 1 // redraw: what was waiting for it shows the link instead
                    return
                }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                memory.setObject(img, forKey: url as NSURL)
                arrivals += 1
                NotificationCenter.default.post(name: Self.arrived, object: url)
            }
        }.resume()
    }
}

/// A web page's title, description and picture, for a pasted link's text and the card shown when the pointer
/// rests on a link. Asking tells the site about it, so it's done only while Settings allows it.
@MainActor @Observable final class LinkPreviews {
    static let shared = LinkPreviews()
    struct Info: Codable, Equatable { var title = "", summary = "", image: URL? }

    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.linkPreviews) as? Bool ?? true }
    /// How a page is fetched (tests answer without the network).
    @ObservationIgnored var load: (URL) async throws -> (Data, URLResponse) = { url in
        var r = URLRequest(url: url, timeoutInterval: 12)
        r.setValue("text/html", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: r)
    }
    private(set) var found: [URL: Info] = [:] // observed: a card waiting for its page redraws
    @ObservationIgnored private var asking: [URL: Task<Info?, Never>] = [:]

    func info(_ url: URL) async -> Info? {
        if let hit = found[url] { return hit }
        if let t = asking[url] { return await t.value }
        guard Self.enabled else { return nil }
        let task = Task<Info?, Never> { [load] in
            guard let (data, response) = try? await load(url), (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            let enc = (response.textEncodingName.map { CFStringConvertIANACharSetNameToEncoding($0 as CFString) })
                .flatMap { $0 == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding($0)) } ?? .utf8
            let head = data.prefix(600_000)
            let html = String(data: head, encoding: enc) ?? String(decoding: head, as: UTF8.self)
            return Self.parse(html, base: url)
        }
        asking[url] = task
        let info = await task.value
        asking[url] = nil
        if let info { found[url] = info }
        return info
    }

    /// `<title>`, then `og:` / `twitter:` tags, from a page's HTML.
    nonisolated static func parse(_ html: String, base: URL) -> Info {
        let ns = html as NSString, all = NSRange(location: 0, length: ns.length)
        func meta(_ names: [String]) -> String? {
            for n in names {
                for p in [#"<meta[^>]+(?:property|name)\s*=\s*["']\#(n)["'][^>]*content\s*=\s*["']([^"']*)["']"#,  // either order
                          #"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']\#(n)["']"#] {
                    if let m = try? NSRegularExpression(pattern: p, options: .caseInsensitive).firstMatch(in: html, range: all),
                       case let v = ns.substring(with: m.range(at: 1)), !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
                }
            }
            return nil
        }
        var title = meta(["og:title", "twitter:title"])
        if title == nil, let r = html.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            title = String(html[r]).replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let image = meta(["og:image", "og:image:url", "twitter:image"]).flatMap { URL(string: decode($0), relativeTo: base)?.absoluteURL }
        return Info(title: decode(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression),
                    summary: decode(meta(["og:description", "description", "twitter:description"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    image: image.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil })
    }

    /// `&amp;`, `&#39;`, `&#x2014;` and friends.
    nonisolated static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "] { out = out.replacingOccurrences(of: k, with: v) }
        let re = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        for m in re.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed() {
            let ns = out as NSString, hex = ns.substring(with: m.range(at: 1)) == "x"
            guard let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let c = Unicode.Scalar(n) else { continue }
            out = ns.replacingCharacters(in: m.range, with: String(Character(c)))
        }
        return out
    }
}

/// Text in images, read on this Mac (Vision, Thai and English), so a search finds words in screenshots and photos.
/// Each attachment is read once in the background and kept in `OCR/<file>.txt`; a sealed (locked) one never is,
/// and its kept text goes when the image is sealed or deleted.
enum ImageText {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "bmp"]

    static func read(_ url: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLanguages = ["th-TH", "en-US"].filter(supported.contains)
        guard (try? VNImageRequestHandler(url: url).perform([request])) != nil else { return nil }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static var cache: [String: String] = [:] // file name → its text, as read from OCR/
    static func forget(_ name: String) { cache[name] = nil }
    private static var busy = false
    private static let queue = DispatchQueue(label: "cortexy.ocr", qos: .utility)

    /// The kept text of the images a note shows (empty until they've been read).
    static func text(for n: Note, in store: Store) -> String {
        MD.imageRegex.matches(in: n.text, range: NSRange(location: 0, length: (n.text as NSString).length)).compactMap { m in
            let path = (n.text as NSString).substring(with: m.range(at: 2))
            guard path.hasPrefix("attachments/") else { return nil }
            let name = String(path.dropFirst("attachments/".count))
            if let hit = cache[name] { return hit }
            let t = try? String(contentsOf: store.directory.appendingPathComponent("OCR/\(name).txt"), encoding: .utf8)
            if let t { cache[name] = t }
            return t
        }.joined(separator: "\n")
    }

    /// Reads the images not read yet, one at a time off the main thread, and drops text whose image is gone
    /// (deleted, or sealed into `.locked`). Called now and then; does nothing while a pass is running.
    static func index(_ store: Store) {
        guard !busy else { return }
        busy = true
        let dir = store.directory
        queue.async {
            defer { DispatchQueue.main.async { busy = false } }
            let fm = FileManager.default, att = dir.appendingPathComponent("attachments"), ocr = dir.appendingPathComponent("OCR")
            let files = Set(((try? fm.contentsOfDirectory(atPath: att.path)) ?? []).filter { imageTypes.contains(($0 as NSString).pathExtension.lowercased()) })
            let kept = (try? fm.contentsOfDirectory(atPath: ocr.path)) ?? []
            for k in kept where !files.contains(String(k.dropLast(4))) {
                try? fm.removeItem(at: ocr.appendingPathComponent(k))
                DispatchQueue.main.async { cache[String(k.dropLast(4))] = nil }
            }
            for f in files where !kept.contains(f + ".txt") {
                guard let text = read(att.appendingPathComponent(f)), fm.fileExists(atPath: att.appendingPathComponent(f).path) else { continue } // sealed meanwhile: keep nothing
                try? fm.createDirectory(at: ocr, withIntermediateDirectories: true)
                try? text.write(to: ocr.appendingPathComponent(f + ".txt"), atomically: true, encoding: .utf8)
                DispatchQueue.main.async { cache[f] = text }
            }
        }
    }
}
