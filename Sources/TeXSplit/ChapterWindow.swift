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
    private var lastError: (file: String, line: Int)?
    private var diskDate: Date?
    private var askedAboutDisk = false
    private var watcher: Timer?
    private var selfTested = false
    private var liveTested = false
    private var liveTestStart: Date?
    private var liveRound = 0

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
        book.refine = { [weak self] file, line, text in self?.textLine(file: file, near: line, text: text) ?? line }
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

    /// A warning that stays in front of build messages for a few seconds.
    private var notice: (text: String, until: Date)?

    private func setStatus(_ text: String, error: Bool = false) {
        if ProcessInfo.processInfo.environment["TEXSPLIT_SELFTEST"] != nil {
            FileHandle.standardError.write("STATUS \(text)\n".data(using: .utf8)!)
        }
        let line = NSMutableAttributedString()
        if let n = notice, n.until > Date(), n.text != text {
            line.append(NSAttributedString(string: n.text + "  ·  ", attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]))
        }
        line.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: error ? NSColor.systemRed : text == notice?.text ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: text == notice?.text ? .medium : .regular),
        ]))
        status.attributedTitle = line
    }

    private func showNotice(_ text: String) {
        notice = (text, Date().addingTimeInterval(10))
        setStatus(text)
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
        case #selector(toggleLivePreview(_:)): item.state = Self.livePreview ? .on : .off
        case #selector(toggleLastRound(_:)):
            item.state = showLastRound ? .on : .off
            return showLastRound || lastRoundFile != nil
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

    /// ⌘S: save now and build at once.
    @objc func saveDocument(_ sender: Any?) {
        if write() { fullBuildWork?.cancel(); rebuild() }
    }

    /// Write the buffer to disk. Returns false if it could not be written.
    @discardableResult
    private func write() -> Bool {
        autosaveWork?.cancel()
        do {
            try editor.text.write(to: fileURL, atomically: true, encoding: .utf8)
            diskDate = modDate()
            askedAboutDisk = false
            window?.isDocumentEdited = false
            return true
        } catch {
            setStatus("Could not save: \(error.localizedDescription)", error: true)
            return false
        }
    }

    // MARK: Auto-save, as in Preview

    private var autosaveWork: DispatchWorkItem?
    private var fullBuildWork: DispatchWorkItem?
    private static let autosaveDelay = 2.0
    /// The full build after an auto-save waits for a longer pause when live preview
    /// already shows the text, so typing in bursts does not queue build after build.
    private static let fullBuildDelay = 8.0

    private func scheduleAutosave() {
        // The live-preview test types into a real chapter; that must never reach the disk.
        guard ProcessInfo.processInfo.environment["TEXSPLIT_LIVETEST"] == nil else { return }
        autosaveWork?.cancel()
        fullBuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.autosave() }
        autosaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: w)
    }

    /// Save an edited buffer unless the file changed on disk since it was loaded:
    /// then nothing is written and the usual question is asked. Returns true when
    /// the buffer is (now) the same as the file.
    @discardableResult
    func autosave() -> Bool {
        autosaveWork?.cancel()
        guard window?.isDocumentEdited == true else { return true }
        if let d = modDate(), let known = diskDate, d > known {
            checkDisk()
            return false
        }
        guard write() else { return false }
        fullBuildWork?.cancel()
        if Self.livePreview {
            let w = DispatchWorkItem { [weak self] in self?.rebuild() }
            fullBuildWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fullBuildDelay, execute: w)
        } else {
            rebuild()
        }
        return true
    }

    /// Leaving the window or the app saves at once, and closes an open note or text box.
    func flushEdits() {
        pdfView.commitMarkEditing()
        autosave()
    }

    /// Not the marks here: a note's own popover takes key status when it opens.
    func windowDidResignKey(_ notification: Notification) { autosave() }

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
                else { self.diskDate = self.modDate(); self.autosave() }
            }
        }
    }

    // MARK: Last round

    private var showLastRound = false
    private var lastRoundFile: URL? {
        Resolution.latestFile(in: book.storeDir.appendingPathComponent("archive", isDirectory: true), stem: book.stem)
    }

    /// View › Show Last Round: the previous round's marks, faint, where their new text is.
    @objc func toggleLastRound(_ sender: Any?) {
        showLastRound.toggle()
        if showLastRound { ensurePDF() }
        placeLastRound()
        if showLastRound, let url = lastRoundFile {
            let found = pdfView.lastRound.filter(\.placed).count
            setStatus("Last round (\(url.lastPathComponent)): \(pdfView.lastRound.count) mark(s), \(found) found in the text")
        }
    }

    private func placeLastRound() {
        guard showLastRound, let doc = pdfView.document, let url = lastRoundFile else {
            if !pdfView.lastRound.isEmpty { pdfView.lastRound = [] }
            return
        }
        pdfView.lastRound = Resolution.place(Resolution.load(url), on: doc)
    }

    // MARK: Locked paragraphs

    /// Regions already warned about this session, by id.
    private var warnedLocks: Set<String> = []
    private var editingLocks = false

    /// Editing a locked paragraph is allowed; the first time per region the status bar says so.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !editingLocks, textView === editor.textView else { return true }
        let s = textView.string
        guard s.contains("LOCKED") else { return true }
        for r in LockedRegion.all(in: s) where NSIntersectionRange(range, r.range).length > 0
            || (range.length == 0 && range.location > r.range.location && range.location < NSMaxRange(r.range)) {
            if warnedLocks.insert(r.id).inserted {
                showNotice("Locked paragraph \(r.id) — changes will need approval")
            }
            break
        }
        return true
    }

    private var chapterPrefix: String {
        var stem = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".tex", with: "")
        if let r = stem.range(of: #"^[0-9]+[a-z]?_"#, options: .regularExpression) { stem.removeSubrange(r) }
        // RelatedWork -> rw; Introduction -> int
        let caps = stem.filter(\.isUppercase)
        let p = caps.count >= 2 ? String(caps) : String(stem.filter(\.isLetter).prefix(3))
        return p.lowercased().isEmpty ? "p" : p.lowercased()
    }

    /// <chapter prefix>-<first two words>, unique within the file.
    private func lockID(for paragraph: String, in text: String) -> String {
        var t = paragraph.replacingOccurrences(of: #"(?<!\\)%.*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\(cite[a-z]*|ref|cref|Cref|label|eqref|autoref)\*?(\[[^\]]*\])*\{[^}]*\}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\[A-Za-z@]+\*?"#, with: " ", options: .regularExpression)
        let stop: Set<String> = ["the", "and", "for", "with", "this", "that", "from", "into", "are", "was", "its", "our", "but", "not"]
        let words = t.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count >= 3 && $0.allSatisfy(\.isASCII) && !stop.contains($0) }
        let slug = String(words.prefix(2).joined().prefix(24))
        let base = chapterPrefix + "-" + (slug.isEmpty ? "para" : slug)
        let taken = Set(LockedRegion.all(in: text).map(\.id))
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// Apply one edit to the editor through the text system, so it can be undone.
    private func replace(_ range: NSRange, with text: String, actionName: String) {
        let tv = editor.textView
        editingLocks = true
        defer { editingLocks = false }
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: text)
        tv.didChangeText()
        tv.undoManager?.setActionName(actionName)
        editor.recolour()
    }

    /// ⌥⌘L: wrap the paragraph at the cursor, or every paragraph the selection touches.
    @objc func lockParagraph(_ sender: Any?) {
        if layout == .pdf { layout = .both }
        let ns = editor.text as NSString
        let sel = editor.textView.selectedRange()
        if let r = LockedRegion.at(sel.location, in: editor.text) { showNotice("Already locked: \(r.id)"); return }
        func isBlank(_ lineStart: Int) -> Bool {
            ns.substring(with: ns.lineRange(for: NSRange(location: lineStart, length: 0))).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Grow to the blank lines around the selection.
        var start = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0)).location
        var end = NSMaxRange(ns.lineRange(for: NSRange(location: min(max(sel.location, NSMaxRange(sel) - 1), ns.length), length: 0)))
        if isBlank(start) && sel.length == 0 { NSSound.beep(); setStatus("Put the cursor in a paragraph to lock it"); return }
        while start > 0 {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(prev.location) { break }
            start = prev.location
        }
        while end < ns.length && !isBlank(end) { end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0))) }
        // Leave blank lines at either edge of a selection outside.
        while start < end && isBlank(start) { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        let id = lockID(for: body, in: editor.text)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let wrapped = "% LOCKED \(id) \(f.string(from: Date()))\n" + body + (body.hasSuffix("\n") ? "" : "\n") + "% END LOCKED" + (body.hasSuffix("\n") ? "\n" : "")
        replace(NSRange(location: start, length: end - start), with: wrapped, actionName: "Lock Paragraph")
        warnedLocks.insert(id)
        editor.textView.setSelectedRange(NSRange(location: start, length: 0))
        showNotice("Locked as \(id)")
    }

    /// ⇧⌥⌘L: remove the markers around the cursor.
    @objc func unlockParagraph(_ sender: Any?) {
        let s = editor.text
        guard let r = LockedRegion.at(editor.textView.selectedRange().location, in: s) else {
            NSSound.beep(); setStatus("The cursor is not in a locked paragraph"); return
        }
        let body = (s as NSString).substring(with: r.body)
        replace(r.range, with: body, actionName: "Unlock Paragraph")
        editor.textView.setSelectedRange(NSRange(location: r.range.location, length: 0))
        showNotice("Unlocked \(r.id)")
    }

    func textDidChange(_ notification: Notification) {
        window?.isDocumentEdited = true
        editor.scheduleRecolour()
        scheduleLiveBuild()
        scheduleAutosave()
    }

    // MARK: Live preview

    /// On by default; View › Live Preview (⇧⌘L) turns it off for all windows.
    static var livePreview: Bool {
        get { UserDefaults.standard.object(forKey: "livePreview") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "livePreview") }
    }
    private var liveWork: DispatchWorkItem?

    /// A quick build of the text on screen, 0.3 s after the last keystroke.
    private func scheduleLiveBuild() {
        liveWork?.cancel()
        guard Self.livePreview else { return }
        let w = DispatchWorkItem { [weak self] in self?.rebuild(live: true) }
        liveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    @objc func toggleLivePreview(_ sender: Any?) {
        Self.livePreview.toggle()
        if Self.livePreview && window?.isDocumentEdited == true { rebuild(live: true) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        pdfView.commitMarkEditing()
        // Auto-save first; only a file that also changed on disk still asks.
        if sender.isDocumentEdited, autosave() { return true }
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
        autosaveWork?.cancel()
        fullBuildWork?.cancel()
        liveWork?.cancel()
        (NSApp.delegate as? AppDelegate)?.closed(self)
    }

    // MARK: Build

    /// A full build (on open, on save, after the whole-thesis build) or a live one
    /// (while typing). Builds never overlap; what was asked for meanwhile runs next,
    /// a pending full build winning over a live one.
    private var pendingLive: Bool?

    private func rebuild(live: Bool = false) {
        if building {
            pendingLive = (pendingLive == false || !live) ? false : true
            return
        }
        building = true
        if !live { setStatus("Building…") }
        // The editor's text, whenever it differs from the file on disk.
        let text: String? = window?.isDocumentEdited == true ? editor.text : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.builder.build(text: text, live: live)
            DispatchQueue.main.async {
                self.building = false
                if r.ok {
                    self.lastError = nil
                    self.setStatus(r.message + (self.builder.jobName == "main" ? "" : " · this chapter only"))
                    self.showPDFWhenFree()
                    if !live { self.refreshFullIfStale() }
                } else {
                    self.lastError = r.errorFile.map { ($0, r.errorLine ?? 0) }
                    // Half-typed LaTeX fails all the time; keep the last good PDF and say so quietly.
                    self.setStatus((live ? "Preview waiting: " : "") + r.message, error: !live)
                }
                if let next = self.pendingLive { self.pendingLive = nil; self.rebuild(live: next) }
            }
        }
    }

    /// Never swap the PDF under a note or text box being typed into.
    private func showPDFWhenFree() {
        if pdfView.isEditingMark {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPDFWhenFree() }
            return
        }
        showPDF()
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

    private var lastUnfound = 0

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
        if book.unfound > 0 && book.unfound != lastUnfound {
            showNotice("\(book.unfound) highlight(s) not found in the new text: shown where they were")
        }
        lastUnfound = book.unfound
        placeLastRound()
        if let id = selectedID { pdfView.selected = book.annotation(for: id) }
        pane.documentChanged()
        if let t0 = liveTestStart, let doc = pdfView.document, !doc.findString("Livepreviewcheck\(liveRound)", withOptions: []).isEmpty {
            FileHandle.standardError.write(String(format: "LIVETEST round %d: word in PDF %.1f s after typing; file on disk unchanged: %@\n",
                liveRound, Date().timeIntervalSince(t0),
                ((try? String(contentsOf: fileURL, encoding: .utf8))?.contains("Livepreviewcheck") == false) ? "yes" : "NO").data(using: .utf8)!)
            liveTestStart = nil
            if liveRound < 3 { liveTested = false }
        }
        let seedReady = builder.jobName == "main" || (builder.fullAuxDate != nil && !Self.fullRunning.contains(builder.fullDir.path))
        if ProcessInfo.processInfo.environment["TEXSPLIT_LIVETEST"] != nil && !liveTested && !building && seedReady && pendingLive == nil {
            liveTested = true
            liveRound += 1
            let round = liveRound
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Type a word at the end of the chapter's first paragraph, as a person would.
                let tv = self.editor.textView
                let ns = tv.string as NSString
                let r = ns.range(of: "\n\n", range: NSRange(location: ns.range(of: "\\chapter").location, length: ns.length - ns.range(of: "\\chapter").location))
                tv.setSelectedRange(NSRange(location: r.location, length: 0))
                tv.insertText(" Livepreviewcheck\(round)", replacementRange: tv.selectedRange())
                self.liveTestStart = Date()
                FileHandle.standardError.write("LIVETEST typed\n".data(using: .utf8)!)
            }
        }
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

    /// The source line near `line` that holds `text`: SyncTeX often answers with the
    /// blank line between two paragraphs, or a comment. Lines within 30 either way
    /// are scored by how many of the text's words they contain; ties go to the nearest.
    func textLine(file: String, near line: Int, text: String) -> Int {
        let source = file == rel || file.hasSuffix("/" + rel) ? editor.text
            : (try? String(contentsOf: thesisRoot.appendingPathComponent(file), encoding: .utf8)) ?? ""
        let lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return line }
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
        func usable(_ i: Int) -> Bool {
            let t = lines[i - 1].trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("%")
        }
        func score(_ i: Int) -> Int {
            let l = lines[i - 1].lowercased()
            return words.reduce(0) { $0 + (l.contains($1) ? 1 : 0) }
        }
        if usable(line) && (words.isEmpty || score(line) > 0) { return line }
        var best: (line: Int, score: Int, dist: Int)?
        for d in 0...30 {
            for i in Set([line - d, line + d]) where i >= 1 && i <= lines.count && usable(i) {
                let sc = score(i)
                if best == nil || sc > best!.score { best = (i, sc, d) }
            }
        }
        return best?.line ?? line
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
