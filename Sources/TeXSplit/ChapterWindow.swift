import AppKit
import PDFKit

enum Layout: Int { case source = 0, both = 1, pdf = 2 }

/// One window per .tex file: source on the left, its compiled PDF on the right.
final class ChapterWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSToolbarDelegate, NSMenuItemValidation, MarkupHost {
    let fileURL: URL
    let thesisRoot: URL
    let rel: String
    fileprivate let builder: Builder
    let book: MarkBook

    private let editor = SourceEditor()
    private let pane = PreviewPane()
    private var pdfView: MarkupPDFView { pane.pdfView }
    private let split = NSSplitView()
    private let layoutControl = NSSegmentedControl(labels: ["LaTeX", "Both", "PDF"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSButton(title: "", target: nil, action: nil)

    private var sync: SyncTeX?
    private var building = false
    private var buildAgain = false
    private var lastError: (file: String, line: Int)?
    private var diskDate: Date?
    private var askedAboutDisk = false
    private var watcher: Timer?
    private var selfTested = false

    var layout: Layout = .both { didSet { applyLayout() } }

    init?(fileURL: URL) {
        // The thesis folder is the nearest ancestor holding main.tex.
        var dir = fileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("main.tex").path) {
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return nil }
            dir = up
        }
        self.fileURL = fileURL.standardizedFileURL
        thesisRoot = dir.standardizedFileURL
        rel = String(self.fileURL.path.dropFirst(thesisRoot.path.count + 1))
        builder = Builder(thesisRoot: thesisRoot, rel: rel)
        let stem = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".tex", with: "")
        book = MarkBook(store: MarkStore(repoRoot: ChapterWindow.mainCheckout(of: thesisRoot.deletingLastPathComponent()), stem: stem))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = (rel as NSString).lastPathComponent
        window.subtitle = thesisRoot.lastPathComponent + "/" + (rel as NSString).deletingLastPathComponent
        window.representedURL = self.fileURL
        window.setFrameAutosaveName("TeXSplit " + self.fileURL.path)
        super.init(window: window)
        window.delegate = self
        buildUI()
        load()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        if FileManager.default.fileExists(atPath: builder.pdfURL.path) { showPDF() }
        rebuild()
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkDisk() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Review PDFs live in the main checkout's render/review/, also when the file
    /// is opened from a worktree, so the marks land beside them.
    static func mainCheckout(of repo: URL) -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return repo }
        p.waitUntilExit()
        let dir = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && dir.hasSuffix("/.git") ? URL(fileURLWithPath: String(dir.dropLast(5))) : repo
    }

    // MARK: UI

    private func buildUI() {
        guard let window else { return }
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(editor.scrollView)
        split.addArrangedSubview(pane)
        window.contentView = split
        editor.textView.delegate = self

        pdfView.host = self
        pane.book = book
        pane.bookmarksKey = "bookmarks " + fileURL.path
        pane.shareURL = { [weak self] in
            guard let self, let doc = self.pdfView.document else { return nil }
            self.pdfView.endTextEditing()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(self.window?.title.replacingOccurrences(of: ".tex", with: "") ?? "chapter").pdf")
            writeShowingNotes(doc, to: url)
            return url
        }
        book.locate = { [weak self] page, point in self?.sourceLine(page: page, point: point) }
        book.position = { [weak self] file, line in
            guard let pos = self?.sync?.position(rel: file, line: line) else { return nil }
            return (pos.page, pos.y)
        }
        book.onChange = { [weak self] in self?.pane.reloadMarks() }
        book.refresh = { [weak self] page in self?.pdfView.annotationsChanged(on: page); self?.pdfView.needsDisplay = true }

        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged(_:))
        layoutControl.selectedSegment = layout.rawValue
        status.isBordered = false
        status.target = self
        status.action = #selector(goToError(_:))
        status.lineBreakMode = .byTruncatingTail
        status.alignment = .left

        let toolbar = NSToolbar(identifier: "TeXSplit")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        DispatchQueue.main.async { self.split.setPosition(window.frame.width / 2, ofDividerAt: 0) }
    }

    private static let items: [NSToolbarItem.Identifier] = [
        .init("layout"), .flexibleSpace, .init("status"), .flexibleSpace, .init("send"), .init("preview"),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        func button(_ symbol: String, _ tip: String, _ action: Selector) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            item.label = tip
            item.toolTip = tip
            item.target = self
            item.action = action
            item.isBordered = true
        }
        switch id.rawValue {
        case "layout": item.view = layoutControl; item.label = "Layout"
        case "status":
            item.view = status
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
            item.label = "Build"
        case "send": button("tray.and.arrow.up", "Send marks to review queue (⇧⌘E)", #selector(sendMarks(_:)))
        case "preview": button("eye", "Open this PDF in Preview (⇧⌘P)", #selector(openInPreview(_:)))
        default: return nil
        }
        return item
    }

    private func applyLayout() {
        layoutControl.selectedSegment = layout.rawValue
        editor.scrollView.isHidden = layout == .pdf
        pane.isHidden = layout == .source
        split.adjustSubviews()
        if layout == .both, let w = window { split.setPosition(w.frame.width / 2, ofDividerAt: 0) }
    }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) { layout = Layout(rawValue: sender.selectedSegment) ?? .both }
    @objc func showSourceOnly(_ sender: Any?) { layout = .source }
    @objc func showBoth(_ sender: Any?) { layout = .both }
    @objc func showPDFOnly(_ sender: Any?) { layout = .pdf }
    @objc func pdfZoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func pdfZoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func pdfZoomFit(_ sender: Any?) { pdfView.autoScales = true }
    @objc func pdfActualSize(_ sender: Any?) { pdfView.scaleFactor = 1 }

    private func setStatus(_ text: String, error: Bool = false) {
        if ProcessInfo.processInfo.environment["TEXSPLIT_SELFTEST"] != nil {
            FileHandle.standardError.write("STATUS \(text)\n".data(using: .utf8)!)
        }
        status.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: error ? NSColor.systemRed : NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12),
        ])
    }

    // MARK: Preview's menus (Tools › Annotate, View › sidebar, Edit › Find)

    private func ensurePDF() { if layout == .source { layout = .both } }

    @objc func highlight(_ sender: Any?) { ensurePDF(); markup("Highlight", Palette.highlights[0].1) }
    @objc func underline(_ sender: Any?) { ensurePDF(); markup("Underline", .systemRed) }
    @objc func strikethrough(_ sender: Any?) { ensurePDF(); markup("StrikeOut", .systemRed) }

    private func markup(_ kind: String, _ colour: NSColor) {
        let colour = kind == "Highlight" ? pdfView.style.markupColor : colour
        if !pdfView.applyMarkup(kind, color: colour) {
            pdfView.style.markup = kind
            pane.toggleHighlight()
        }
    }

    @objc func comment(_ sender: Any?) {
        ensurePDF()
        if let s = pdfView.currentSelection, !(s.string ?? "").isEmpty { pdfView.highlightWithNote() }
        else { pdfView.addNoteAtLastClick() }
    }

    @objc func toolRectangle(_ sender: Any?) { ensurePDF(); pane.choose(.rectangle) }
    @objc func toolOval(_ sender: Any?) { ensurePDF(); pane.choose(.oval) }
    @objc func toolLine(_ sender: Any?) { ensurePDF(); pane.choose(.line) }
    @objc func toolArrow(_ sender: Any?) { ensurePDF(); pane.choose(.arrow) }
    @objc func toolText(_ sender: Any?) { ensurePDF(); pane.choose(.text) }
    @objc func toolNote(_ sender: Any?) { ensurePDF(); pane.choose(.note) }
    @objc func toolSketch(_ sender: Any?) { ensurePDF(); pane.choose(.sketch) }
    @objc func toolDraw(_ sender: Any?) { ensurePDF(); pane.choose(.draw) }
    @objc func toolTextSelect(_ sender: Any?) { pane.choose(.textSelect) }
    @objc func toolRectSelect(_ sender: Any?) { ensurePDF(); pane.choose(.rectSelect) }
    @objc func toggleMarkupToolbar(_ sender: Any?) { ensurePDF(); pane.toggleMarkupBar(nil) }
    @objc func deleteMark(_ sender: Any?) { pdfView.deleteSelected() }

    @objc func sidebarHide(_ sender: Any?) { pane.setSidebar(.hidden) }
    @objc func sidebarThumbnails(_ sender: Any?) { ensurePDF(); pane.setSidebar(.thumbnails) }
    @objc func sidebarContents(_ sender: Any?) { ensurePDF(); pane.setSidebar(.contents) }
    @objc func sidebarNotes(_ sender: Any?) { ensurePDF(); pane.setSidebar(.notes) }
    @objc func sidebarToggle(_ sender: Any?) { ensurePDF(); pane.toggleSidebar() }
    @objc func findInPDF(_ sender: Any?) { ensurePDF(); pane.focusSearch() }
    @objc func findNextInPDF(_ sender: Any?) { pane.findNext(false) }
    @objc func findPreviousInPDF(_ sender: Any?) { pane.findNext(true) }

    @objc func goToPage(_ sender: Any?) {
        guard let doc = pdfView.document else { return }
        let a = NSAlert()
        a.messageText = "Go to Page"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "1–\(doc.pageCount)"
        a.accessoryView = field
        a.addButton(withTitle: "Go")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn, let n = Int(field.stringValue), let page = doc.page(at: max(0, min(doc.pageCount - 1, n - 1))) else { return }
        ensurePDF()
        pdfView.go(to: page)
    }

    @objc func sidebarBookmarks(_ sender: Any?) { ensurePDF(); pane.setSidebar(.bookmarks) }
    @objc func contactSheet(_ sender: Any?) { ensurePDF(); pane.setSidebar(.contactSheet) }
    @objc func addBookmark(_ sender: Any?) { ensurePDF(); pane.toggleBookmark() }
    @objc func rotateLeft(_ sender: Any?) { ensurePDF(); pane.rotateLeft(sender) }
    @objc func rotateRight(_ sender: Any?) { ensurePDF(); pane.rotateRight(sender) }
    @objc func displayContinuous(_ sender: Any?) { pdfView.displayMode = .singlePageContinuous }
    @objc func displaySingle(_ sender: Any?) { pdfView.displayMode = .singlePage }
    @objc func displayTwoPages(_ sender: Any?) { pdfView.displayMode = .twoUpContinuous }

    @objc func printDocument(_ sender: Any?) {
        guard let doc = pdfView.document, let w = window else { return }
        pdfView.endTextEditing()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("texsplit-print.pdf")
        writeShowingNotes(doc, to: url)
        guard let copy = PDFDocument(url: url),
              let op = copy.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let doc = pdfView.document, let w = window else { return }
        pdfView.endTextEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".tex", with: ".pdf")
        panel.beginSheetModal(for: w) { r in
            if r == .OK, let url = panel.url { writeShowingNotes(doc, to: url) }
        }
    }

    @objc func nextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func previousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMarkupToolbar(_:)): item.title = pane.markupBarVisible ? "Hide Markup Toolbar" : "Show Markup Toolbar"
        case #selector(sidebarHide(_:)): item.state = pane.sidebarMode == .hidden ? .on : .off
        case #selector(sidebarThumbnails(_:)): item.state = pane.sidebarMode == .thumbnails ? .on : .off
        case #selector(sidebarContents(_:)): item.state = pane.sidebarMode == .contents ? .on : .off
        case #selector(sidebarNotes(_:)): item.state = pane.sidebarMode == .notes ? .on : .off
        case #selector(showSourceOnly(_:)): item.state = layout == .source ? .on : .off
        case #selector(showBoth(_:)): item.state = layout == .both ? .on : .off
        case #selector(showPDFOnly(_:)): item.state = layout == .pdf ? .on : .off
        case #selector(deleteMark(_:)): return pdfView.selected != nil
        case #selector(sidebarBookmarks(_:)): item.state = pane.sidebarMode == .bookmarks ? .on : .off
        case #selector(contactSheet(_:)): item.state = pane.sidebarMode == .contactSheet ? .on : .off
        case #selector(addBookmark(_:)): item.title = pane.currentPageBookmarked ? "Remove Bookmark" : "Add Bookmark"
        case #selector(displayContinuous(_:)): item.state = pdfView.displayMode == .singlePageContinuous ? .on : .off
        case #selector(displaySingle(_:)): item.state = pdfView.displayMode == .singlePage ? .on : .off
        case #selector(displayTwoPages(_:)): item.state = pdfView.displayMode == .twoUpContinuous ? .on : .off
        default: break
        }
        return true
    }

    // MARK: File

    private func load() {
        editor.text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        diskDate = modDate()
        window?.isDocumentEdited = false
    }

    private func modDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    @objc func saveDocument(_ sender: Any?) {
        do {
            try editor.text.write(to: fileURL, atomically: true, encoding: .utf8)
            diskDate = modDate()
            askedAboutDisk = false
            window?.isDocumentEdited = false
            rebuild()
        } catch {
            setStatus("Could not save: \(error.localizedDescription)", error: true)
        }
    }

    @objc func rebuildNow(_ sender: Any?) { rebuild() }

    /// Agents edit these files too. An unedited buffer follows the disk; an edited one asks once.
    private func checkDisk() {
        guard let d = modDate(), let known = diskDate, d > known else { return }
        if window?.isDocumentEdited == false {
            let sel = editor.textView.selectedRange()
            let origin = editor.scrollView.contentView.bounds.origin
            load()
            editor.textView.setSelectedRange(NSRange(location: min(sel.location, (editor.text as NSString).length), length: 0))
            editor.scrollView.contentView.scroll(to: origin)
            setStatus("Reloaded: the file changed on disk")
            rebuild()
        } else if !askedAboutDisk {
            askedAboutDisk = true
            let a = NSAlert()
            a.messageText = "\(window?.title ?? "This file") changed on disk"
            a.informativeText = "Someone else (an agent?) saved this file while you have unsaved edits."
            a.addButton(withTitle: "Keep My Version")
            a.addButton(withTitle: "Load Disk Version")
            a.beginSheetModal(for: window!) { r in
                if r == .alertSecondButtonReturn { self.load(); self.rebuild() }
                else { self.diskDate = self.modDate() }
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        window?.isDocumentEdited = true
        editor.scheduleRecolour()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        pdfView.endTextEditing()
        guard sender.isDocumentEdited else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to \(sender.title)?"
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        switch a.runModal() {
        case .alertFirstButtonReturn: saveDocument(nil); return true
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.invalidate()
        (NSApp.delegate as? AppDelegate)?.closed(self)
    }

    // MARK: Build

    private func rebuild() {
        if building { buildAgain = true; return }
        building = true
        setStatus("Building…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.builder.build()
            DispatchQueue.main.async {
                self.building = false
                if r.ok {
                    self.lastError = nil
                    self.setStatus(r.message + (self.builder.jobName == "main" ? "" : " · this chapter only"))
                    self.showPDF()
                    self.refreshFullIfStale()
                } else {
                    self.lastError = r.errorFile.map { ($0, r.errorLine ?? 0) }
                    self.setStatus(r.message, error: true)
                }
                if self.buildAgain { self.buildAgain = false; self.rebuild() }
            }
        }
    }

    /// Chapter numbers, page numbers and references into other chapters come from one
    /// build of the whole thesis. It runs in the background when missing or older than
    /// an hour, once per thesis, and the chapter is rebuilt when it is done.
    private static var fullRunning: Set<String> = []
    private static var fullFailed: [String: Date] = [:]

    private func refreshFullIfStale(force: Bool = false) {
        guard builder.jobName != "main" else { return }
        let key = builder.fullDir.path
        let stale = builder.fullAuxDate.map { Date().timeIntervalSince($0) > 3600 } ?? true
        let failedRecently = Self.fullFailed[key].map { Date().timeIntervalSince($0) < 3600 } ?? false
        guard force || (stale && !failedRecently), !Self.fullRunning.contains(key) else { return }
        Self.fullRunning.insert(key)
        let first = builder.fullAuxDate == nil
        if first { setStatus("Numbering chapters: building the whole thesis once (about a minute)…") }
        DispatchQueue.global(qos: .utility).async {
            let ok = self.builder.buildFull()
            DispatchQueue.main.async {
                Self.fullRunning.remove(key)
                if !ok { Self.fullFailed[key] = Date(); self.setStatus("Whole-thesis build failed; numbers may be off (⇧⌘B retries)", error: true); return }
                Self.fullFailed[key] = nil
                for w in (NSApp.delegate as? AppDelegate)?.openWindows ?? [] where w.builder.fullDir.path == key {
                    w.rebuild()
                }
            }
        }
    }

    @objc func refreshWholeThesis(_ sender: Any?) { refreshFullIfStale(force: true) }

    /// Load the new PDF where the old one was being read, then put the marks back.
    private func showPDF() {
        guard let data = try? Data(contentsOf: builder.pdfURL), let doc = PDFDocument(data: data) else { return }
        pdfView.endTextEditing()
        // Where the top-left corner of the view sits, in page space, to come back to it.
        let corner = NSPoint(x: pdfView.bounds.minX + 1, y: pdfView.bounds.maxY - 1)
        let topPage = pdfView.page(for: corner, nearest: true)
        let pageIndex = topPage.flatMap { pdfView.document?.index(for: $0) }
        let point = topPage.map { pdfView.convert(corner, to: $0) }
        let scale = pdfView.scaleFactor
        let auto = pdfView.autoScales || pdfView.document == nil
        let selectedID = pdfView.selected.flatMap { book.mark(for: $0)?.id }
        pdfView.selected = nil
        pdfView.document = doc
        sync = SyncTeX(url: builder.synctexURL)
        if !auto { pdfView.scaleFactor = scale }
        if let i = pageIndex, let page = doc.page(at: min(i, doc.pageCount - 1)) {
            pdfView.go(to: PDFDestination(page: page, at: point ?? NSPoint(x: 0, y: page.bounds(for: .mediaBox).height)))
        }
        if pane.rotation != 0 { pane.applyRotation() }
        book.place(on: doc)
        if let id = selectedID { pdfView.selected = book.annotation(for: id) }
        pane.documentChanged()
        if ProcessInfo.processInfo.environment["TEXSPLIT_SELFTEST"] != nil && !selfTested {
            selfTested = true
            runSelfTest()
        }
    }

    @objc private func goToError(_ sender: Any?) {
        guard let e = lastError else { return }
        if e.file.hasSuffix(rel) || rel.hasSuffix(e.file) {
            if layout == .pdf { layout = .both }
            editor.reveal(line: e.line)
        } else {
            (NSApp.delegate as? AppDelegate)?.open(thesisRoot.appendingPathComponent(e.file), line: e.line)
        }
    }

    // MARK: SyncTeX

    private func topY(_ page: PDFPage, _ p: NSPoint) -> Double { Double(page.bounds(for: .mediaBox).height - p.y) }

    /// The source file (relative to the thesis folder) and line under a point of the PDF.
    private func sourceLine(page: PDFPage, point: NSPoint) -> (String, Int)? {
        guard let doc = pdfView.document, let sync,
              let hit = sync.source(page: doc.index(for: page) + 1, x: Double(point.x), y: topY(page, point)) else { return nil }
        var path = hit.path.replacingOccurrences(of: "/./", with: "/")
        if let r = path.range(of: builder.buildDir.path + "/") { path = String(path[r.upperBound...]) }
        else if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        // The chapter-only wrapper is main.tex line for line, with other chapters commented out.
        if path == "\(builder.jobName).tex" { path = "main.tex" }
        return (path, hit.line)
    }

    func commandClick(page: PDFPage, point: NSPoint) {
        guard let (file, line) = sourceLine(page: page, point: point) else { return }
        if file == rel || file.hasSuffix("/" + rel) {
            if layout == .pdf { layout = .both }
            editor.reveal(line: line)
        } else {
            (NSApp.delegate as? AppDelegate)?.open(thesisRoot.appendingPathComponent(file), line: line)
        }
    }

    func selectionChanged() { pane.syncControls() }

    /// ⌘J: show the line at the cursor in the PDF.
    @objc func showInPDF(_ sender: Any?) {
        guard let doc = pdfView.document, let sync, let pos = sync.position(rel: rel, line: editor.currentLine),
              let page = doc.page(at: pos.page - 1) else { return }
        if layout == .source { layout = .both }
        let h = page.bounds(for: .mediaBox).height
        let y = h - CGFloat(pos.y)
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: min(h, y + 120))))
        let flash = PDFAnnotation(bounds: NSRect(x: 40, y: y - 4, width: page.bounds(for: .mediaBox).width - 80, height: 16),
                                  forType: .highlight, withProperties: nil)
        flash.color = NSColor.systemBlue.withAlphaComponent(0.35)
        page.addAnnotation(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { page.removeAnnotation(flash) }
    }

    // MARK: Marks out

    /// Write the marks as a review queue the agents already read, and a marked copy of the PDF.
    @objc func sendMarks(_ sender: Any?) {
        pdfView.endTextEditing()
        guard let doc = pdfView.document, !book.marks.isEmpty else { setStatus("No marks to send"); return }
        let url = book.export(pdf: doc, thesisFolder: thesisRoot.lastPathComponent) { m in
            m.file == self.rel ? self.editor.line(m.line).trimmingCharacters(in: .whitespaces) : ""
        }
        if let url {
            setStatus("Sent \(book.marks.count) mark(s) → render/review/live/\(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// The same PDF, marks included, in Preview itself.
    @objc func openInPreview(_ sender: Any?) {
        pdfView.endTextEditing()
        guard let doc = pdfView.document else { return }
        try? FileManager.default.createDirectory(at: book.storeDir, withIntermediateDirectories: true)
        let url = book.storeDir.appendingPathComponent("\(builder.jobName)-preview.pdf")
        writeShowingNotes(doc, to: url)
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    var selfTestPDFView: MarkupPDFView { pdfView }
    func selfTestSetUp() {
        pane.toggleMarkupBar(nil)
        let env = ProcessInfo.processInfo.environment
        switch env["TEXSPLIT_SIDEBAR"] {
        case "contents": pane.setSidebar(.contents)
        case "thumbnails": pane.setSidebar(.thumbnails)
        default: pane.setSidebar(.notes)
        }
        if let q = env["TEXSPLIT_SEARCH"] { pane.selfTestSearch(q) }
        if let doc = pdfView.document, let page = doc.page(at: min(6, doc.pageCount - 1)) { pdfView.go(to: page) }
    }
    func selfTestExport() -> URL? {
        book.export(pdf: pdfView.document!, thesisFolder: thesisRoot.lastPathComponent) { m in m.file == self.rel ? self.editor.line(m.line) : "" }
    }

    func reveal(line: Int) {
        if layout == .pdf { layout = .both }
        editor.reveal(line: line)
    }
}
