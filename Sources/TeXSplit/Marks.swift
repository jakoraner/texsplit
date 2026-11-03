import AppKit
import PDFKit

/// Anything drawn on the live PDF: a highlight, note, shape, text box or drawing.
/// It is anchored to the source line under it, so it survives rebuilds: text
/// markups are re-found by their text near that line's new position, everything
/// else moves with the line.
struct Mark: Codable {
    var id: String
    var kind: String          // PDF subtype as Preview writes it: Highlight, Underline, StrikeOut, Text, FreeText, Square, Circle, Line, Ink
    var quoted: String        // marked text (text markups)
    /// Notes and text boxes: the sentence of the PDF text nearest to them, so a
    /// note always says what it is about. Optional: older marks files lack it.
    var anchor: String?
    var comment: String
    var file: String          // relative to the thesis folder, e.g. Chapters/05_Methods.tex
    var line: Int
    var page: Int             // 1-based, in the build it was last placed on
    var x: Double             // bounds, top-left PDF points (SyncTeX convention)
    var y: Double
    var w: Double
    var h: Double
    var anchorY: Double       // where `line` typeset in that build
    var lineWidth: Double
    var archive: Data?        // the PDFAnnotation itself, for colours, paths and fonts
    var created: Date

    static func newID() -> String { String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)) }
    static let textMarkups: Set<String> = ["Highlight", "Underline", "StrikeOut"]
    var isTextMarkup: Bool { Mark.textMarkups.contains(kind) }
    static let anchored: Set<String> = ["Text", "FreeText"]
    /// The text a mark is about: what it marks, else the sentence beside it.
    var context: String { quoted.isEmpty ? anchor ?? "" : quoted }
}

/// The PDF text nearest to a point: the line under it, or the closest line above
/// or below, also when the point is in the margin. Returns the sentence that line
/// belongs to and a point on the line itself, for SyncTeX.
func nearestText(on page: PDFPage, at p: NSPoint) -> (sentence: String, probe: NSPoint)? {
    let box = page.bounds(for: .mediaBox)
    func line(at q: NSPoint) -> PDFSelection? {
        guard box.contains(q), let s = page.selectionForLine(at: q),
              let t = s.string, t.trimmingCharacters(in: .whitespacesAndNewlines).count > 1 else { return nil }
        return s
    }
    // Where it was dropped, then towards the text column (notes often sit in the margin).
    let xs = [p.x, box.midX, box.minX + box.width * 0.3, box.minX + box.width * 0.7]
    var found: PDFSelection?
    search: for dy in stride(from: CGFloat(0), through: 80, by: 2) {
        for x in xs {
            for y in dy == 0 ? [p.y] : [p.y - dy, p.y + dy] {   // below first: a note sits at the start of what it is about
                if let s = line(at: NSPoint(x: x, y: y)) { found = s; break search }
            }
        }
    }
    guard let sel = found, let lineText = sel.string else { return nil }
    let r = sel.bounds(for: page)
    let probe = NSPoint(x: r.minX + min(8, r.width / 2), y: r.midY)
    return (sentence(around: lineText, in: page.string ?? ""), probe)
}

/// The sentence of `text` a line belongs to, at most about 400 characters;
/// the line itself if it is not found in the page text.
func sentence(around line: String, in pageText: String) -> String {
    let clean = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    let l = clean(line)
    let page = clean(pageText) as NSString
    let hit = page.range(of: l)
    guard hit.location != NSNotFound else { return l }
    // A sentence ends at ".", "?" or "!" followed by a space.
    let ender: Set<unichar> = [46, 63, 33]
    func endsSentence(_ i: Int) -> Bool { i >= 1 && i < page.length && page.character(at: i) == 32 && ender.contains(page.character(at: i - 1)) }
    var start = hit.location
    while start > 0 && hit.location - start < 250 && !endsSentence(start - 1) { start -= 1 }
    var end = NSMaxRange(hit)
    while end < page.length && end - NSMaxRange(hit) < 250 && !endsSentence(end) { end += 1 }
    return page.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
}

func subtypeName(_ a: PDFAnnotation) -> String {
    (a.type ?? "").replacingOccurrences(of: "/", with: "")
}

/// Where a window's marks live and how they are written for the agents:
/// `render/review/live/` beside the existing review PDFs, in the queue format
/// `scripts/pdf_review.py extract` writes (same JSON keys, same Markdown).
struct MarkStore {
    let repoRoot: URL
    let stem: String

    var dir: URL { repoRoot.appendingPathComponent("render/review/live", isDirectory: true) }
    var file: URL { dir.appendingPathComponent("\(stem)-marks.json") }
    /// Every version the app overwrote: `history/<stem>-<yyyyMMdd-HHmmss>.json`.
    var historyDir: URL { dir.appendingPathComponent("history", isDirectory: true) }
    /// Versions kept per chapter.
    static var historyLimit = 200

    func decode(_ data: Data) -> [Mark]? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode([Mark].self, from: data)
    }

    func encode(_ marks: [Mark]) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(marks)
    }

    func load() -> [Mark] { read().flatMap { decode($0.data) } ?? [] }

    /// The file as it is on disk now, and when it was last written.
    func read() -> (data: Data, date: Date)? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (data, modDate() ?? .distantPast)
    }

    func modDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Write the list as it is, nothing kept. Returns what was written.
    @discardableResult
    func write(_ marks: [Mark]) -> Data? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = encode(marks), (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return data
    }

    /// Write the list, first keeping the file's previous content in `history/` when it
    /// differs and is not an empty list. Returns what was written.
    @discardableResult
    func save(_ marks: [Mark]) -> Data? {
        if let old = try? Data(contentsOf: file), old != encode(marks), decode(old)?.isEmpty != true {
            keepInHistory(old)
        }
        return write(marks)
    }

    private func keepInHistory(_ data: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(stem)-\(f.string(from: Date()))"
        var url = historyDir.appendingPathComponent("\(base).json")
        var n = 2
        while fm.fileExists(atPath: url.path) { url = historyDir.appendingPathComponent("\(base)-\(n).json"); n += 1 }
        try? data.write(to: url, options: .atomic)
        // Oldest first, by when they were written; keep the newest `historyLimit`.
        let pattern = "^" + NSRegularExpression.escapedPattern(for: stem) + #"-\d{8}-\d{6}(-\d+)?\.json$"#
        let mine = ((try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.range(of: pattern, options: .regularExpression) != nil }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let sorted = mine.sorted { (date($0), $0.lastPathComponent) < (date($1), $1.lastPathComponent) }
        for u in sorted.dropLast(Self.historyLimit) { try? fm.removeItem(at: u) }
    }

    /// Write the queue (`-comments.json` + `.md`) and a copy of the marked PDF. Returns the .md URL.
    func export(_ marks: [Mark], pdf: PDFDocument, thesisFolder: String, sourceLine: (Mark) -> String) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let name = "\(stem)-\(f.string(from: Date()))"
        let author = NSFullUserName()
        let rows: [[String: Any]] = marks.sorted { ($0.page, $0.y) < ($1.page, $1.y) }.map { m in
            [
                "id": m.id, "page": m.page, "type": m.kind, "author": author,
                "comment": m.comment, "quoted": m.quoted, "anchor_text": m.context,
                "file": "\(thesisFolder)/\(m.file)", "line": m.line, "source_line": sourceLine(m),
            ]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        try? json.write(to: dir.appendingPathComponent("\(name)-comments.json"))

        var md = "# PDF review queue — \(name).pdf\n\n\(rows.count) annotation(s).\n"
        for r in rows {
            md += "\n## [\(r["id"]!)] p.\(r["page"]!) · \(r["type"]!) → `\(r["file"]!):\(r["line"]!)`\n\n"
            md += "- **by:** \(author)\n"
            if let q = r["quoted"] as? String, !q.isEmpty { md += "- **marked text:** \(q)\n" }
            else if let q = r["anchor_text"] as? String, !q.isEmpty { md += "- **next to:** \(q)\n" }
            md += "- **source line:** `\(r["source_line"]!)`\n\n"
            let c = r["comment"] as? String ?? ""
            md += c.isEmpty ? "> _(no comment text — mark only)_\n" : c.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n"
        }
        let mdURL = dir.appendingPathComponent("\(name)-comments.md")
        try? md.write(to: mdURL, atomically: true, encoding: .utf8)
        writeShowingNotes(pdf, to: dir.appendingPathComponent("\(name).pdf"))
        return mdURL
    }
}

/// One mark of the previous review round as the thesis repo resolved it:
/// `render/review/live/archive/<chapter>-resolutions-vN-*.json`.
struct Resolution {
    let id: String
    let page: Int
    let quoted: String
    let comment: String
    let status: String        // applied, declined, question, needs-approval
    let action: String
    let newText: String

    /// The newest round for a chapter: highest N, then the most recently written.
    static func latestFile(in archive: URL, stem: String) -> URL? {
        let prefix = "\(stem)-resolutions-v"
        let files = (try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func version(_ u: URL) -> Int {
            Int(u.lastPathComponent.dropFirst(prefix.count).prefix { $0.isNumber }) ?? -1
        }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" && version($0) >= 0 }
            .max { (version($0), date($0)) < (version($1), date($1)) }
    }

    /// Lenient: unknown keys are ignored, missing ones are empty, `page` may be a number or a string.
    static func load(_ url: URL) -> [Resolution] {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        func str(_ r: [String: Any], _ k: String) -> String {
            if let s = r[k] as? String { return s }
            if let n = r[k] as? NSNumber { return n.stringValue }
            return ""
        }
        return rows.map { r in
            Resolution(id: str(r, "id"), page: Int(str(r, "page")) ?? 0, quoted: str(r, "quoted"), comment: str(r, "comment"),
                       status: str(r, "status").lowercased(), action: str(r, "action"), newText: str(r, "new_text"))
        }
    }

    /// Where it is drawn in this build: over its new text if found (else its old text),
    /// otherwise in the right margin of its original page.
    static func place(_ list: [Resolution], on doc: PDFDocument) -> [GhostMark] {
        var stacked: [Int: Int] = [:]
        return list.compactMap { r in
            let original = max(0, min(doc.pageCount - 1, r.page - 1))
            for text in [r.newText, r.quoted] {
                if let sel = find(text, in: doc, near: original), let page = sel.pages.first {
                    return GhostMark(resolution: r, page: page, rect: sel.bounds(for: page).insetBy(dx: -2, dy: -1.5), placed: true)
                }
            }
            guard doc.pageCount > 0, let page = doc.page(at: original) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let k = stacked[original, default: 0]
            stacked[original] = k + 1
            return GhostMark(resolution: r, page: page, rect: NSRect(x: box.maxX - 46, y: box.maxY - 70 - CGFloat(k) * 18, width: 14, height: 14), placed: false)
        }
    }

    /// The text, or failing that its first eight words (line breaks and hyphens
    /// differ between source and PDF), the hit nearest the original page.
    private static func find(_ text: String, in doc: PDFDocument, near page: Int) -> PDFSelection? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 || text.count >= 12 else { return nil }
        for probe in [words.joined(separator: " "), words.prefix(8).joined(separator: " ")] where probe.count >= 8 {
            let hits = doc.findString(probe, withOptions: [.caseInsensitive])
            if let best = hits.min(by: { distance($0, doc, page) < distance($1, doc, page) }) { return best }
        }
        return nil
    }

    private static func distance(_ s: PDFSelection, _ doc: PDFDocument, _ page: Int) -> Int {
        s.pages.first.map { abs(doc.index(for: $0) - page) } ?? .max
    }
}

struct GhostMark {
    let resolution: Resolution
    let page: PDFPage
    let rect: NSRect
    /// False when its text was not found and it sits in the margin of its old page.
    let placed: Bool
}

/// A document's text as marks are matched against it: no whitespace and no hyphens,
/// ligatures spelled out. A highlight's quote keeps the line breaks and hyphenation of
/// the build it was made on ("split-latent per- mutation"), and PDFKit's findString
/// does not match a space against a line break, so an exact search lost every
/// highlight over more than one line at the next rebuild. Squeezed, the quote is found
/// whatever the new build's line breaks are.
struct SqueezedText {
    private let text: NSString
    private let map: [(page: Int, index: Int)]   // per squeezed UTF-16 unit: where it came from

    private static let skipped: Set<unichar> = [0x2D, 0xAD, 0x2010, 0x2011]   // hyphen, soft hyphen, Unicode hyphens
    private static let ligatures: [unichar: String] = [0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st"]

    private static func squeeze(_ s: NSString, page: Int, into units: inout [unichar], map: inout [(page: Int, index: Int)]) {
        let space = CharacterSet.whitespacesAndNewlines
        for i in 0..<s.length {
            let c = s.character(at: i)
            if skipped.contains(c) { continue }
            if let scalar = Unicode.Scalar(c), space.contains(scalar) { continue }
            if let l = ligatures[c] {
                for u in l.utf16 { units.append(u); map.append((page, i)) }
            } else {
                units.append(c)
                map.append((page, i))
            }
        }
    }

    static func squeeze(_ s: String) -> String {
        var units: [unichar] = [], map: [(page: Int, index: Int)] = []
        squeeze(s as NSString, page: 0, into: &units, map: &map)
        return String(utf16CodeUnits: units, count: units.count)
    }

    init(_ doc: PDFDocument) {
        var units: [unichar] = [], map: [(page: Int, index: Int)] = []
        for p in 0..<doc.pageCount {
            Self.squeeze((doc.page(at: p)?.string ?? "") as NSString, page: p, into: &units, map: &map)
        }
        text = String(utf16CodeUnits: units, count: units.count) as NSString
        self.map = map
    }

    /// Every place the quote occurs, as selections in the document (at most 50).
    func find(_ quoted: String, in doc: PDFDocument) -> [PDFSelection] {
        let q = Self.squeeze(quoted)
        guard !q.isEmpty else { return [] }
        var out: [PDFSelection] = []
        var from = 0
        while from < text.length, out.count < 50 {
            let r = text.range(of: q, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard r.location != NSNotFound else { break }
            from = r.location + 1
            let a = map[r.location], b = map[NSMaxRange(r) - 1]
            guard let pa = doc.page(at: a.page), let pb = doc.page(at: b.page) else { continue }
            let sel = a.page == b.page
                ? pa.selection(for: NSRange(location: a.index, length: b.index - a.index + 1))
                : doc.selection(from: pa, atCharacterIndex: a.index, to: pb, atCharacterIndex: b.index)
            if let sel { out.append(sel) }
        }
        return out
    }
}

/// The marks of one window: which annotations are ours, keeping the saved list
/// in step with them, putting them back after a rebuild, and undo.
final class MarkBook {
    private(set) var marks: [Mark]
    private var idOf: [ObjectIdentifier: String] = [:]
    private var annotationOf: [String: PDFAnnotation] = [:]
    private let store: MarkStore
    /// (page, x, y) top-left -> (file, line), and (file, line) -> (page, y)
    var locate: ((PDFPage, NSPoint) -> (String, Int)?)?
    /// (file, SyncTeX line, text) -> the nearby source line that holds that text,
    /// skipping the blank and comment lines SyncTeX often lands on between paragraphs.
    var refine: ((String, Int, String) -> Int)?
    var position: ((String, Int) -> (page: Int, y: Double)?)?
    var onChange: (() -> Void)?
    var refresh: ((PDFPage) -> Void)?
    let undo = UndoManager()

    /// The last version of every mark this book has held. A save never leaves one of
    /// them out unless it was deleted on purpose (`deleted`): whatever else drops a mark
    /// from `marks`, it is put back before the file is written.
    private var known: [String: Mark] = [:]
    /// Marks deleted by hand (Delete, Cut, undoing an Add), per marks file, shared by
    /// every window on that file, so another window's stale list does not bring them back.
    private static var deletedByFile: [String: Set<String>] = [:]
    private var deleted: Set<String> {
        get { Self.deletedByFile[store.file.path] ?? [] }
        set { Self.deletedByFile[store.file.path] = newValue }
    }
    /// The file's content and date as this book last read or wrote it; anything else on
    /// disk was written by another process (or another window).
    private var seen: Data?
    private var seenDate: Date?

    init(store: MarkStore) {
        self.store = store
        let disk = store.read()
        marks = disk.flatMap { store.decode($0.data) } ?? []
        if let disk, marks.isEmpty, store.decode(disk.data) == nil {
            log("\(store.file.lastPathComponent) could not be read; it is kept in history/ before it is next written")
        }
        seen = disk?.data
        seenDate = disk?.date
        for m in marks { known[m.id] = m }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write("TeX Split marks (\(store.stem)): \(s)\n".data(using: .utf8)!)
    }

    // MARK: the file

    /// Write the list, after taking in what changed on disk and putting back any mark
    /// that went missing without being deleted.
    private func persist() {
        reconcile()
        dropDeleted()
        let ids = Set(marks.map(\.id))
        let lost = known.values.filter { !ids.contains($0.id) && !deleted.contains($0.id) }.sorted { $0.created < $1.created }
        if !lost.isEmpty {
            log("kept \(lost.count) mark(s) that were about to be dropped without being deleted: \(lost.map(\.id).joined(separator: ", "))")
            marks += lost
        }
        if let data = store.save(marks) {
            seen = data
            seenDate = store.modDate()
        }
    }

    /// Take in a marks file another process changed. An empty list written after ours is
    /// the archive procedure (archive, write `[]`, read on): the marks made before it are
    /// dropped. Anything else is merged by id, ours winning. Returns true if `marks` changed.
    @discardableResult
    private func reconcile() -> Bool {
        guard let disk = store.read(), disk.data != seen else { return false }
        defer { seen = disk.data; seenDate = disk.date }
        guard let theirs = store.decode(disk.data) else {
            log("\(store.file.lastPathComponent) was changed by another program and cannot be read; keeping ours (the file goes to history/)")
            return false
        }
        if theirs.isEmpty, disk.date >= (seenDate ?? .distantPast) {
            let gone = marks.filter { $0.created <= disk.date }
            guard !gone.isEmpty else { return false }
            log("the file was emptied at \(disk.date) (archived?): dropping \(gone.count) mark(s) made before that")
            for m in gone {
                if let a = annotationOf[m.id], let page = a.page { page.removeAnnotation(a); refresh?(page) }
                annotationOf[m.id] = nil
                known[m.id] = nil
            }
            let goneIDs = Set(gone.map(\.id))
            idOf = idOf.filter { !goneIDs.contains($0.value) }
            marks.removeAll { goneIDs.contains($0.id) }
            return true
        }
        let ours = Set(marks.map(\.id))
        let new = theirs.filter { !ours.contains($0.id) && !deleted.contains($0.id) }
        guard !new.isEmpty else { return false }
        log("the file was changed by another program: merged \(new.count) mark(s) from it")
        for m in new { marks.append(m); known[m.id] = m }
        return true
    }

    /// Marks deleted in another window on the same file.
    private func dropDeleted() {
        let gone = marks.filter { deleted.contains($0.id) }
        for m in gone {
            if let a = annotationOf[m.id], let page = a.page { page.removeAnnotation(a); refresh?(page) }
            if let a = annotationOf[m.id] { idOf[ObjectIdentifier(a)] = nil }
            annotationOf[m.id] = nil
        }
        if !gone.isEmpty { marks.removeAll { deleted.contains($0.id) } }
    }

    /// Called by the window's timer: take in a marks file changed by someone else.
    /// Returns true when the marks changed; the caller then places them again.
    func syncFromDisk() -> Bool {
        guard let d = store.modDate(), d != seenDate else { return false }
        guard reconcile() else { return false }
        persist()
        return true
    }

    func owns(_ a: PDFAnnotation) -> Bool { idOf[ObjectIdentifier(a)] != nil }
    func mark(for a: PDFAnnotation) -> Mark? { idOf[ObjectIdentifier(a)].flatMap { id in marks.first { $0.id == id } } }
    func annotation(for id: String) -> PDFAnnotation? { annotationOf[id] }

    private func topLeft(_ a: PDFAnnotation, _ page: PDFPage) -> (Double, Double) {
        (Double(a.bounds.minX), Double(page.bounds(for: .mediaBox).height - a.bounds.maxY))
    }

    /// Record (or refresh) the mark for an annotation that is on a page.
    @discardableResult
    func capture(_ a: PDFAnnotation, quoted: String? = nil) -> Mark? {
        guard let page = a.page, let doc = page.document else { return nil }
        let (x, y) = topLeft(a, page)
        var probe = NSPoint(x: a.bounds.minX + min(4, a.bounds.width / 2), y: a.bounds.maxY - min(4, a.bounds.height / 2))
        // A note or text box takes the sentence nearest to it, and its source line from there.
        var near: String?
        if Mark.anchored.contains(subtypeName(a)), let t = nearestText(on: page, at: NSPoint(x: a.bounds.midX, y: a.bounds.midY)) {
            near = t.sentence
            probe = t.probe
        }
        let existing = mark(for: a)
        var src = locate?(page, probe) ?? existing.map { ($0.file, $0.line) } ?? ("", 0)
        if let text = quoted ?? near ?? existing?.context, !text.isEmpty, let better = refine?(src.0, src.1, text) { src.1 = better }
        let anchor = position?(src.0, src.1)?.y ?? y
        var m = existing ?? Mark(id: Mark.newID(), kind: subtypeName(a), quoted: quoted ?? "", comment: "", file: src.0, line: src.1,
                                 page: 0, x: 0, y: 0, w: 0, h: 0, anchorY: anchor, lineWidth: 1, archive: nil, created: Date())
        m.kind = subtypeName(a)
        if let quoted { m.quoted = quoted }
        if let near { m.anchor = near }
        m.comment = a.contents ?? ""
        m.file = src.0
        m.line = src.1
        m.page = doc.index(for: page) + 1
        (m.x, m.y) = (x, y)
        (m.w, m.h) = (Double(a.bounds.width), Double(a.bounds.height))
        m.anchorY = anchor
        m.lineWidth = Double(a.border?.lineWidth ?? 1)
        m.archive = try? NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: false)
        if let i = marks.firstIndex(where: { $0.id == m.id }) { marks[i] = m } else { marks.append(m) }
        idOf[ObjectIdentifier(a)] = m.id
        annotationOf[m.id] = a
        known[m.id] = m
        deleted.remove(m.id)
        persist()
        onChange?()
        return m
    }

    // MARK: edits with undo

    func add(_ a: PDFAnnotation, to page: PDFPage, quoted: String? = nil) {
        page.addAnnotation(a)
        capture(a, quoted: quoted)
        undo.registerUndo(withTarget: self) { $0.remove(a) }
        undo.setActionName("Add \(MarkBook.label(a))")
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page, let id = idOf[ObjectIdentifier(a)] else { return }
        let quoted = mark(for: a)?.quoted
        page.removeAnnotation(a)
        deleted.insert(id)
        marks.removeAll { $0.id == id }
        idOf[ObjectIdentifier(a)] = nil
        annotationOf[id] = nil
        persist()
        onChange?()
        undo.registerUndo(withTarget: self) { $0.add(a, to: page, quoted: quoted) }
        undo.setActionName("Delete \(MarkBook.label(a))")
    }

    /// Call after changing an annotation in place; `before` is its archive from before the change.
    func changed(_ a: PDFAnnotation, before: Data?) {
        capture(a)
        guard let before, let page = a.page else { return }
        undo.registerUndo(withTarget: self) { book in
            guard let old = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(before) as? PDFAnnotation else { return }
            let now = try? NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: false)
            a.bounds = old.bounds
            a.contents = old.contents
            a.color = old.color
            if let w = book.mark(for: a)?.lineWidth { let b = PDFBorder(); b.lineWidth = CGFloat(w); a.border = a.border ?? b }
            book.refresh?(page)
            book.changed(a, before: now)
        }
    }

    static func label(_ a: PDFAnnotation) -> String {
        switch subtypeName(a) {
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strikethrough"
        case "Text": return "Note"
        case "FreeText": return "Text"
        case "Ink": return "Drawing"
        default: return "Shape"
        }
    }

    // MARK: after a rebuild

    /// Text markups that were not found in the last build's text and sit where they were.
    private(set) var unfound = 0

    /// Draw every mark on a freshly built document. A text markup goes over its text
    /// wherever the new build put it; if that text is gone it stays visible at its old
    /// place beside its source line. No mark is ever dropped here.
    func place(on doc: PDFDocument) {
        // Placing twice on one document must not draw everything twice.
        for a in annotationOf.values { a.page?.removeAnnotation(a) }
        idOf.removeAll()
        annotationOf.removeAll()
        unfound = 0
        reconcile()
        dropDeleted()
        let author = NSFullUserName()
        var text: SqueezedText?
        for i in marks.indices {
            var m = marks[i]
            let expected = position?(m.file, m.line) ?? (m.page, m.anchorY)
            let stored = m.archive.flatMap { try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData($0) as? PDFAnnotation }
            var placed: PDFAnnotation?
            if m.isTextMarkup {
                if text == nil { text = SqueezedText(doc) }
                let hits = text!.find(m.quoted, in: doc)
                let best = hits.min { a, b in Self.distance(a, doc, expected) < Self.distance(b, doc, expected) }
                if let sel = best, let page = sel.pages.first {
                    let a = Self.markup(kind: m.kind, selection: sel, page: page, color: stored?.color ?? .systemYellow)
                    a.contents = m.comment
                    a.userName = author
                    page.addAnnotation(a)
                    placed = a
                } else {
                    unfound += 1
                }
            }
            if placed == nil, let a = stored, let page = doc.page(at: max(0, min(doc.pageCount - 1, expected.page - 1))) {
                // Keep the mark's offset from its anchor line.
                let top = expected.y + (m.y - m.anchorY)
                let height = page.bounds(for: .mediaBox).height
                a.bounds = NSRect(x: m.x, y: Double(height) - top - m.h, width: m.w, height: m.h)
                if !m.isTextMarkup {
                    let b = PDFBorder()
                    b.lineWidth = CGFloat(m.lineWidth)
                    a.border = b
                }
                page.addAnnotation(a)
                placed = a
            }
            guard let a = placed, let page = a.page else { continue }
            idOf[ObjectIdentifier(a)] = m.id
            annotationOf[m.id] = a
            m.page = doc.index(for: page) + 1
            m.y = Double(page.bounds(for: .mediaBox).height - a.bounds.maxY)
            m.anchorY = expected.y
            marks[i] = m
            known[m.id] = m
        }
        undo.removeAllActions()
        persist()
        onChange?()
    }

    private static func distance(_ sel: PDFSelection, _ doc: PDFDocument, _ expected: (page: Int, y: Double)) -> Double {
        guard let page = sel.pages.first else { return .infinity }
        let p = doc.index(for: page) + 1
        let y = Double(page.bounds(for: .mediaBox).height - sel.bounds(for: page).maxY)
        return Double(abs(p - expected.page)) * 10_000 + abs(y - expected.y)
    }

    /// One text-markup annotation over a (multi-line) selection, with one quad per line, as Preview writes it.
    static func markup(kind: String, selection: PDFSelection, page: PDFPage, color: NSColor) -> PDFAnnotation {
        let lines = selection.selectionsByLine().filter { $0.pages.first == page }
        let rects = lines.map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        let union = rects.reduce(rects.first ?? selection.bounds(for: page)) { $0.union($1) }
        let type: PDFAnnotationSubtype = kind == "Underline" ? .underline : kind == "StrikeOut" ? .strikeOut : .highlight
        let a = PDFAnnotation(bounds: union, forType: type, withProperties: nil)
        a.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
            let o = union.origin
            return [NSPoint(x: r.minX - o.x, y: r.maxY - o.y), NSPoint(x: r.maxX - o.x, y: r.maxY - o.y),
                    NSPoint(x: r.minX - o.x, y: r.minY - o.y), NSPoint(x: r.maxX - o.x, y: r.minY - o.y)].map { NSValue(point: $0) }
        }
        a.color = color
        return a
    }

    func export(pdf: PDFDocument, thesisFolder: String, sourceLine: (Mark) -> String) -> URL? {
        store.export(marks, pdf: pdf, thesisFolder: thesisFolder, sourceLine: sourceLine)
    }

    var storeDir: URL { store.dir }
    var stem: String { store.stem }
}
