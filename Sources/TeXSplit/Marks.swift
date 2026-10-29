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
                "comment": m.comment, "quoted": m.quoted, "anchor_text": m.quoted,
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

/// The marks of one window: which annotations are ours, keeping the saved list
/// in step with them, putting them back after a rebuild, and undo.
final class MarkBook {
    private(set) var marks: [Mark]
    private var idOf: [ObjectIdentifier: String] = [:]
    private var annotationOf: [String: PDFAnnotation] = [:]
    private let store: MarkStore
    /// (page, x, y) top-left -> (file, line), and (file, line) -> (page, y)
    var locate: ((PDFPage, NSPoint) -> (String, Int)?)?
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
        let probe = NSPoint(x: a.bounds.minX + min(4, a.bounds.width / 2), y: a.bounds.maxY - min(4, a.bounds.height / 2))
        let existing = mark(for: a)
        let src = locate?(page, probe) ?? existing.map { ($0.file, $0.line) } ?? ("", 0)
        let anchor = position?(src.0, src.1)?.y ?? y
        var m = existing ?? Mark(id: Mark.newID(), kind: subtypeName(a), quoted: quoted ?? "", comment: "", file: src.0, line: src.1,
                                 page: 0, x: 0, y: 0, w: 0, h: 0, anchorY: anchor, lineWidth: 1, archive: nil, created: Date())
        m.kind = subtypeName(a)
        if let quoted { m.quoted = quoted }
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
}
