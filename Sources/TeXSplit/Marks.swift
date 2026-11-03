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

    func load() -> [Mark] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Mark].self, from: data)) ?? []
    }

    func save(_ marks: [Mark]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(marks).write(to: file, options: .atomic)
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

    init(store: MarkStore) {
        self.store = store
        marks = store.load()
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
        store.save(marks)
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
        marks.removeAll { $0.id == id }
        idOf[ObjectIdentifier(a)] = nil
        annotationOf[id] = nil
        store.save(marks)
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

    /// Draw every mark on a freshly built document.
    func place(on doc: PDFDocument) {
        idOf.removeAll()
        annotationOf.removeAll()
        let author = NSFullUserName()
        for i in marks.indices {
            var m = marks[i]
            let expected = position?(m.file, m.line) ?? (m.page, m.anchorY)
            let stored = m.archive.flatMap { try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData($0) as? PDFAnnotation }
            var placed: PDFAnnotation?
            if m.isTextMarkup {
                let hits = doc.findString(m.quoted, withOptions: [])
                let best = hits.min { a, b in Self.distance(a, doc, expected) < Self.distance(b, doc, expected) }
                if let sel = best, let page = sel.pages.first {
                    let a = Self.markup(kind: m.kind, selection: sel, page: page, color: stored?.color ?? .systemYellow)
                    a.contents = m.comment
                    a.userName = author
                    page.addAnnotation(a)
                    placed = a
                }
            } else if let a = stored, let page = doc.page(at: max(0, min(doc.pageCount - 1, expected.page - 1))) {
                // Keep the mark's offset from its anchor line.
                let top = expected.y + (m.y - m.anchorY)
                let height = page.bounds(for: .mediaBox).height
                a.bounds = NSRect(x: m.x, y: Double(height) - top - m.h, width: m.w, height: m.h)
                let b = PDFBorder()
                b.lineWidth = CGFloat(m.lineWidth)
                a.border = b
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
        }
        undo.removeAllActions()
        store.save(marks)
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
