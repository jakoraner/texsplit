// Marks harness: MarkBook and MarkStore against real PDFKit documents, no window.
// Run with ./test-marks.sh. Every check prints PASS or FAIL; the exit code counts FAILs.
import AppKit
import PDFKit

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS" : "FAIL", what)
    if !ok { failures += 1 }
}

/// A PDF whose lines are exactly as given (one array of lines per page), so a test
/// controls the line breaks and hyphenation a TeX build would produce.
func makePDF(_ pages: [[String]]) -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    let font = NSFont(name: "Times-Roman", size: 11) ?? .systemFont(ofSize: 11)
    for lines in pages {
        ctx.beginPDFPage(nil)
        for (i, l) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: 72, y: 770 - CGFloat(i) * 14)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return PDFDocument(data: data as Data)!
}

/// Highlight a text as applyMarkup does: the selection, its quote joined line by line.
func highlight(_ text: String, in doc: PDFDocument, book: MarkBook) -> String? {
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i), let s = page.string else { continue }
        let r = (s as NSString).range(of: text)
        guard r.location != NSNotFound, let sel = page.selection(for: r) else { continue }
        let quoted = sel.selectionsByLine().compactMap(\.string).joined(separator: " ")
        let a = MarkBook.markup(kind: "Highlight", selection: sel, page: page, color: .systemYellow)
        book.add(a, to: page, quoted: quoted)
        return book.mark(for: a)?.id
    }
    return nil
}

func covered(_ id: String, _ words: String, book: MarkBook, doc: PDFDocument) -> Bool {
    guard let a = book.annotation(for: id), let page = a.page else { return false }
    guard let hit = doc.findString(words, withOptions: []).first(where: { $0.pages.first == page }) else { return false }
    return a.bounds.intersects(hit.bounds(for: page))
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("texsplit-marks-\(UUID().uuidString)")
func freshStore(_ name: String) -> MarkStore {
    let root = tmp.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return MarkStore(repoRoot: root, stem: "04b_RelatedWork")
}

// MARK: 1. A highlight over several lines survives rebuilds, reflow and moved paragraphs

let beforeLines = [
    ["Some opening text about reading that stays where it is.",
     "Representation learning fits a short code to raw input with an objective that does not",
     "need the label of interest (Section 2.4.2). To separate who produced a signal from what",
     "it is about, the current approach in biosignal modelling is the contrastive split-latent per-",
     "mutation autoencoder (CSLP-AE), developed for electroencephalography (EEG).",
     "Cognitive models of eye movements come next."],
]
let before = makePDF(beforeLines)
// The same text after an agent moved a paragraph above it and reflowed the lines.
let after = makePDF([
    ["A paragraph the agent moved up from later in the chapter, now first.",
     "Cognitive models of eye movements come next."],
    ["Some opening text about reading that stays where it is. Representation",
     "learning fits a short code to raw input with an objective that does not need the label of",
     "interest (Section 2.4.2). To separate who produced a signal from what it is about, the",
     "current approach in biosignal modelling is the contrastive split-latent permutation auto-",
     "encoder (CSLP-AE), developed for electroencephalography (EEG)."],
])
do {
    let store = freshStore("rebuild")
    let book = MarkBook(store: store)
    let h1 = highlight("Representation learning fits a short code to raw input with an objective that does not\nneed the label of interest (Section 2.4.2).", in: before, book: book)
    let h2 = highlight("To separate who produced a signal from what\nit is about, the current approach in biosignal modelling is the contrastive split-latent per-\nmutation autoencoder (CSLP-AE)", in: before, book: book)
    let h3 = highlight("Cognitive models of eye movements", in: before, book: book)
    check(h1 != nil && h2 != nil && h3 != nil, "three highlights made, two of them over several lines")
    // Same layout, rebuilt: every highlight must be drawn again.
    let same = makePDF(beforeLines)
    book.place(on: same)
    for (id, w) in [(h1, "Representation learning"), (h2, "To separate who"), (h3, "Cognitive models")] {
        check(id.map { covered($0, w, book: book, doc: same) } ?? false, "same build: highlight over '\(w)' re-placed on its text")
    }
    book.place(on: after)
    for (id, w) in [(h1, "learning fits a short"), (h2, "To separate who"), (h3, "Cognitive models")] {
        check(id.map { covered($0, w, book: book, doc: after) } ?? false, "reflowed + moved: highlight over '\(w)' re-placed on its text")
    }
    check(book.marks.count == 3 && store.load().count == 3, "all three marks still in the book and on disk")
    // Text rewritten: the mark stays in the list and stays visible at its line.
    let rewritten = makePDF([["Something else entirely now stands here.", "Cognitive models of eye movements come next."]])
    book.place(on: rewritten)
    check(book.marks.count == 3, "rewritten text: marks kept")
    check([h1, h2].allSatisfy { $0.flatMap { book.annotation(for: $0) } != nil }, "rewritten text: highlights still drawn (at their old place)")
    check(book.unfound == 2, "rewritten text: the two not found are counted (\(book.unfound))")
}

// MARK: 2. Another process changed the marks file: merge, never drop

do {
    let store = freshStore("merge")
    let doc = makePDF([["Alpha beta gamma delta.", "Epsilon zeta eta theta."]])
    let book = MarkBook(store: store)
    let a = highlight("Alpha beta", in: doc, book: book)!
    _ = highlight("Epsilon zeta", in: doc, book: book)
    // An agent appends a mark of its own to the file.
    var onDisk = store.load()
    var extra = onDisk[0]
    extra.id = "agent001"
    onDisk.append(extra)
    Thread.sleep(forTimeInterval: 1.1)
    store.write(onDisk)
    _ = highlight("gamma delta", in: doc, book: book)
    let ids = Set(store.load().map(\.id))
    check(ids.count == 4 && ids.contains("agent001") && ids.contains(a), "external addition merged with ours (\(ids.count) marks)")
    check(book.marks.contains { $0.id == "agent001" }, "external addition is in the book too")

    // A second book on the same file (a second window) with a stale list.
    let other = MarkBook(store: store)
    if let ann = book.annotation(for: a) { book.remove(ann) }
    check(!store.load().contains { $0.id == a }, "explicit delete is written")
    _ = highlight("theta", in: doc, book: other)   // `other` still holds `a` in memory
    let after2 = store.load().map(\.id)
    check(!after2.contains(a), "a stale second book does not bring back a mark deleted in the first")
    check(after2.count == 4, "a stale second book keeps everything else (\(after2.count))")
}

// MARK: 3. The archive procedure: `[]` written while the app runs is adopted

do {
    let store = freshStore("reset")
    let doc = makePDF([["Alpha beta gamma delta.", "Epsilon zeta eta theta."]])
    let book = MarkBook(store: store)
    _ = highlight("Alpha beta", in: doc, book: book)
    _ = highlight("Epsilon zeta", in: doc, book: book)
    Thread.sleep(forTimeInterval: 1.1)
    try! "[]".write(to: store.file, atomically: true, encoding: .utf8)
    Thread.sleep(forTimeInterval: 1.1)
    check(book.syncFromDisk(), "external [] noticed")
    check(book.marks.isEmpty, "external [] adopted: the archived marks are gone from the book")
    book.place(on: doc)
    check(store.load().isEmpty, "and they are not written back by the next rebuild")
    let n = highlight("gamma", in: doc, book: book)
    check(store.load().map(\.id) == [n!], "a new mark after the reset is kept on its own")
}

// MARK: 4. A book with a stale, empty list does not overwrite marks written meanwhile

do {
    let store = freshStore("stale")
    let doc = makePDF([["Alpha beta gamma delta.", "Epsilon zeta eta theta."]])
    let stale = MarkBook(store: store)          // opened while the file was empty
    let writer = MarkBook(store: store)
    _ = highlight("Alpha beta", in: doc, book: writer)
    _ = highlight("Epsilon zeta", in: doc, book: writer)
    stale.place(on: makePDF([["Alpha beta gamma delta.", "Epsilon zeta eta theta."]]))   // a rebuild saves
    check(store.load().count == 2, "a rebuild in a window with an empty list keeps the 2 marks on disk (\(store.load().count))")
    check(stale.marks.count == 2, "and that window now shows them")
}

// MARK: 5. History of every overwritten version

do {
    let store = freshStore("history")
    let doc = makePDF([["Alpha beta gamma delta.", "Epsilon zeta eta theta."]])
    let book = MarkBook(store: store)
    for w in ["Alpha", "beta", "gamma", "delta"] { _ = highlight(w, in: doc, book: book) }
    let hist = (try? FileManager.default.contentsOfDirectory(at: store.historyDir, includingPropertiesForKeys: nil)) ?? []
    check(hist.count == 3, "a copy of each previous non-empty version in history/ (\(hist.count))")
    check(hist.allSatisfy { $0.lastPathComponent.hasPrefix("04b_RelatedWork-") }, "history named <stem>-<timestamp>.json")
    MarkStore.historyLimit = 2
    _ = highlight("Epsilon", in: doc, book: book)
    let pruned = (try? FileManager.default.contentsOfDirectory(at: store.historyDir, includingPropertiesForKeys: nil)) ?? []
    check(pruned.count == 2, "history pruned to the limit (\(pruned.count))")
}

try? FileManager.default.removeItem(at: tmp)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(Int32(failures))
