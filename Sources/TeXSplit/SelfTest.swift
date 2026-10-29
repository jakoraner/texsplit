import AppKit
import PDFKit

/// `TEXSPLIT_SELFTEST=1`: drive the markup code paths a person would, log what
/// happened, and leave the window showing the markup toolbar and the notes list.
extension ChapterWindow {
    func runSelfTest() {
        let log: (String) -> Void = { FileHandle.standardError.write(("SELFTEST " + $0 + "\n").data(using: .utf8)!) }
        let view = selfTestPDFView
        guard let doc = view.document, let page = doc.page(at: min(6, doc.pageCount - 1)) else { log("no document"); return }
        let before = book.marks.count
        // 1. highlight a word by text selection
        if let sel = doc.findString("the", withOptions: []).first(where: { $0.pages.first == page }) ?? doc.findString("the", withOptions: []).first(where: { $0.pages.first == page }) {
            view.setCurrentSelection(sel, animate: false)
            log("highlight applied: \(view.applyMarkup("Highlight", color: Palette.highlights[0].1, comment: "Self-test: highlight with a note"))")
        }
        // 2. underline + note on another
        if let sel = doc.findString("and", withOptions: []).first(where: { $0.pages.first == page }) {
            view.setCurrentSelection(sel, animate: false)
            log("underline applied: \(view.applyMarkup("Underline", color: .systemRed, comment: "Self-test: underline with a note"))")
        }
        let h = page.bounds(for: .mediaBox).height
        // 3. shapes, ink, text box, note through the public pieces
        let rect = PDFAnnotation(bounds: NSRect(x: 66, y: h - 778, width: 470, height: 182), forType: .square, withProperties: nil)
        rect.color = .systemRed; let b = PDFBorder(); b.lineWidth = 3; rect.border = b
        book.add(rect, to: page)
        let ink = PDFAnnotation(bounds: NSRect(x: 540, y: h - 650, width: 40, height: 50), forType: .ink, withProperties: nil)
        let path = NSBezierPath(); path.lineWidth = 2; path.move(to: NSPoint(x: 6, y: 25)); path.line(to: NSPoint(x: 16, y: 10)); path.line(to: NSPoint(x: 36, y: 46))
        ink.add(path); ink.color = .systemBlue
        book.add(ink, to: page)
        let text = PDFAnnotation(bounds: NSRect(x: 380, y: h - 600, width: 160, height: 20), forType: .freeText, withProperties: nil)
        text.contents = "Self-test text box"; text.font = NSFont(name: "Helvetica", size: 12); text.fontColor = .systemRed; text.color = .clear
        let nb = PDFBorder(); nb.lineWidth = 0; text.border = nb
        book.add(text, to: page)
        let note = PDFAnnotation(bounds: NSRect(x: 548, y: h - 236, width: 20, height: 20), forType: .text, withProperties: nil)
        note.iconType = .comment; note.color = Palette.note; note.contents = "Self-test note"
        book.add(note, to: page)
        log("marks: \(before) -> \(book.marks.count)")
        let kinds = book.marks.map(\.kind).joined(separator: ",")
        log("kinds: \(kinds)")
        log("anchors: " + book.marks.map { "\($0.kind)@\(($0.file as NSString).lastPathComponent):\($0.line)" }.joined(separator: " "))
        // 4. undo / redo of the last add
        book.undo.undo(); log("after undo: \(book.marks.count)")
        book.undo.redo(); log("after redo: \(book.marks.count)")
        // 5. re-place on a fresh copy of the document, as after a rebuild
        if let data = doc.dataRepresentation(), let fresh = PDFDocument(data: data) {
            for i in 0..<fresh.pageCount { fresh.page(at: i)?.annotations.forEach { fresh.page(at: i)?.removeAnnotation($0) } }
            view.document = fresh
            book.place(on: fresh)
            let placed = book.marks.filter { book.annotation(for: $0.id) != nil }.count
            log("re-placed after rebuild: \(placed) of \(book.marks.count)")
        }
        selfTestSetUp()
        if let url = selfTestExport() { log("exported \(url.path)") }
    }
}
