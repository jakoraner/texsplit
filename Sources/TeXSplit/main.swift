import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [ChapterWindow] = []
    var openWindows: [ChapterWindow] { windows }
    private let chaptersMenu = NSMenu(title: "Open Chapter")
    private var launchedWithFiles = false
    private static let openKey = "openFiles"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let args = CommandLine.arguments.dropFirst().filter { $0.hasSuffix(".tex") }
        for a in args { open(URL(fileURLWithPath: a)) }
        if args.isEmpty && !launchedWithFiles {
            // Reopen what was open last time, else ask.
            let previous = UserDefaults.standard.stringArray(forKey: Self.openKey) ?? []
            for p in previous where FileManager.default.fileExists(atPath: p) { open(URL(fileURLWithPath: p)) }
            if windows.isEmpty { openDocument(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        launchedWithFiles = true
        for u in urls { open(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {}

    /// Quitting asks about every window with unsaved LaTeX, as closing does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        remember()
        terminating = true
        for w in windows {
            guard let win = w.window, win.isDocumentEdited else { continue }
            win.makeKeyAndOrderFront(nil)
            if !w.windowShouldClose(win) { terminating = false; return .terminateCancel }
        }
        return .terminateNow
    }

    private func remember() {
        UserDefaults.standard.set(windows.map { $0.fileURL.path }, forKey: Self.openKey)
    }

    @discardableResult
    func open(_ url: URL, line: Int? = nil) -> ChapterWindow? {
        let url = url.standardizedFileURL
        if let w = windows.first(where: { $0.fileURL == url }) {
            w.showWindow(nil)
            if let line { w.reveal(line: line) }
            return w
        }
        guard let w = ChapterWindow(fileURL: url) else {
            let a = NSAlert()
            a.messageText = "No main.tex above \(url.lastPathComponent)"
            a.informativeText = "TeX Split opens files that belong to a LaTeX project with a main.tex."
            a.runModal()
            return nil
        }
        windows.append(w)
        // Cascade new windows so several chapters can sit side by side.
        if let last = windows.dropLast().last?.window, let win = w.window, win.frameAutosaveName.isEmpty == false,
           UserDefaults.standard.string(forKey: "NSWindow Frame " + win.frameAutosaveName) == nil {
            win.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 30, y: last.frame.maxY - 30))
        } else if windows.count == 1 {
            w.window?.center()
        }
        w.showWindow(nil)
        if let line { w.reveal(line: line) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        remember()
        return w
    }

    private var terminating = false

    func closed(_ w: ChapterWindow) {
        windows.removeAll { $0 === w }
        // While quitting, windows close one by one; keep the list saved just before.
        if !terminating { remember() }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.message = "Choose chapter files; each opens in its own window."
        if let root = windows.last?.thesisRoot { panel.directoryURL = root.appendingPathComponent("Chapters") }
        if panel.runModal() == .OK { for u in panel.urls { open(u) } }
    }

    // MARK: "Open Chapter" lists the \input lines of main.tex of the project in front.

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let root = (NSApp.keyWindow?.windowController as? ChapterWindow)?.thesisRoot ?? windows.last?.thesisRoot,
              let main = try? String(contentsOf: root.appendingPathComponent("main.tex"), encoding: .utf8) else {
            menu.addItem(withTitle: "Open a chapter first", action: nil, keyEquivalent: "")
            return
        }
        let re = try! NSRegularExpression(pattern: #"^\s*\\input\{((?:Chapters|Backmatter)/[^}]+)\}"#, options: .anchorsMatchLines)
        for m in re.matches(in: main, range: NSRange(main.startIndex..., in: main)) {
            let rel = (main as NSString).substring(with: m.range(at: 1))
            let item = NSMenuItem(title: rel, action: #selector(openChapter(_:)), keyEquivalent: "")
            item.representedObject = root.appendingPathComponent(rel)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let whole = NSMenuItem(title: "main.tex (whole thesis)", action: #selector(openChapter(_:)), keyEquivalent: "")
        whole.representedObject = root.appendingPathComponent("main.tex")
        whole.target = self
        menu.addItem(whole)
    }

    @objc private func openChapter(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { open(u) }
    }

    // MARK: Menus

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        sub("TeX Split", [
            item("About TeX Split", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide TeX Split", #selector(NSApplication.hide(_:)), "h"),
            item("Quit TeX Split", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let chapters = NSMenuItem(title: "Open Chapter", action: nil, keyEquivalent: "")
        chaptersMenu.delegate = self
        chapters.submenu = chaptersMenu
        sub("File", [
            item("Open…", #selector(openDocument(_:)), "o"),
            chapters,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save and Build", #selector(ChapterWindow.saveDocument(_:)), "s"),
            item("Build Again", #selector(ChapterWindow.rebuildNow(_:)), "b"),
            .separator(),
            item("Export as PDF…", #selector(ChapterWindow.exportPDF(_:)), ""),
            item("Print…", #selector(ChapterWindow.printDocument(_:)), "p"),
            .separator(),
            item("Refresh Whole Thesis (numbers, references)", #selector(ChapterWindow.refreshWholeThesis(_:)), "b", [.command, .shift]),
        ])
        sub("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            { let f = item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f"); f.tag = Int(NSFindPanelAction.showFindPanel.rawValue); return f }(),
            { let f = item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g"); f.tag = Int(NSFindPanelAction.next.rawValue); return f }(),
        ])
        let ctrlCmd: NSEvent.ModifierFlags = [.command, .control]
        let optCmd: NSEvent.ModifierFlags = [.command, .option]
        sub("View", [
            item("LaTeX Only", #selector(ChapterWindow.showSourceOnly(_:)), "1"),
            item("LaTeX and PDF", #selector(ChapterWindow.showBoth(_:)), "2"),
            item("PDF Only", #selector(ChapterWindow.showPDFOnly(_:)), "3"),
            .separator(),
            item("Hide Sidebar", #selector(ChapterWindow.sidebarHide(_:)), "1", optCmd),
            item("Thumbnails", #selector(ChapterWindow.sidebarThumbnails(_:)), "2", optCmd),
            item("Table of Contents", #selector(ChapterWindow.sidebarContents(_:)), "3", optCmd),
            item("Highlights and Notes", #selector(ChapterWindow.sidebarNotes(_:)), "4", optCmd),
            item("Bookmarks", #selector(ChapterWindow.sidebarBookmarks(_:)), "5", optCmd),
            item("Contact Sheet", #selector(ChapterWindow.contactSheet(_:)), "6", optCmd),
            item("Toggle Sidebar", #selector(ChapterWindow.sidebarToggle(_:)), "s", [.command, .control, .option]),
            .separator(),
            item("Show Markup Toolbar", #selector(ChapterWindow.toggleMarkupToolbar(_:)), "a", [.command, .shift]),
            item("Show Line in PDF", #selector(ChapterWindow.showInPDF(_:)), "j"),
            item("Live Preview", #selector(ChapterWindow.toggleLivePreview(_:)), "l", [.command, .shift]),
            .separator(),
            item("Continuous Scroll", #selector(ChapterWindow.displayContinuous(_:)), ""),
            item("Single Page", #selector(ChapterWindow.displaySingle(_:)), ""),
            item("Two Pages", #selector(ChapterWindow.displayTwoPages(_:)), ""),
            .separator(),
            item("Actual Size", #selector(ChapterWindow.pdfActualSize(_:)), "0"),
            item("Zoom to Fit", #selector(ChapterWindow.pdfZoomFit(_:)), "9"),
            item("Zoom In", #selector(ChapterWindow.pdfZoomIn(_:)), "+"),
            item("Zoom Out", #selector(ChapterWindow.pdfZoomOut(_:)), "-"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", ctrlCmd),
        ])
        sub("Go", [
            item("Previous Page", #selector(ChapterWindow.previousPage(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), optCmd),
            item("Next Page", #selector(ChapterWindow.nextPage(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), optCmd),
            item("Go to Page…", #selector(ChapterWindow.goToPage(_:)), "g", optCmd),
            .separator(),
            item("Add Bookmark", #selector(ChapterWindow.addBookmark(_:)), "d"),
        ])
        let annotate = NSMenuItem(title: "Annotate", action: nil, keyEquivalent: "")
        let am = NSMenu(title: "Annotate")
        for i in [
            item("Highlight Text", #selector(ChapterWindow.highlight(_:)), "h", ctrlCmd),
            item("Underline Text", #selector(ChapterWindow.underline(_:)), "u", ctrlCmd),
            item("Strike Through Text", #selector(ChapterWindow.strikethrough(_:)), "s", ctrlCmd),
            .separator(),
            item("Rectangle", #selector(ChapterWindow.toolRectangle(_:)), "r", ctrlCmd),
            item("Oval", #selector(ChapterWindow.toolOval(_:)), "o", ctrlCmd),
            item("Line", #selector(ChapterWindow.toolLine(_:)), "l", ctrlCmd),
            item("Arrow", #selector(ChapterWindow.toolArrow(_:)), "a", ctrlCmd),
            item("Text", #selector(ChapterWindow.toolText(_:)), "t", ctrlCmd),
            item("Note", #selector(ChapterWindow.comment(_:)), "n", ctrlCmd),
            item("Sketch", #selector(ChapterWindow.toolSketch(_:)), "k", ctrlCmd),
            item("Draw", #selector(ChapterWindow.toolDraw(_:)), "d", ctrlCmd),
        ] { am.addItem(i) }
        annotate.submenu = am
        sub("Tools", [
            item("Text Selection", #selector(ChapterWindow.toolTextSelect(_:)), ""),
            item("Rectangular Selection", #selector(ChapterWindow.toolRectSelect(_:)), ""),
            .separator(),
            annotate,
            item("Delete Selected Mark", #selector(ChapterWindow.deleteMark(_:)), ""),
            .separator(),
            item("Rotate Left", #selector(ChapterWindow.rotateLeft(_:)), "l"),
            item("Rotate Right", #selector(ChapterWindow.rotateRight(_:)), "r"),
            .separator(),
            item("Find in PDF…", #selector(ChapterWindow.findInPDF(_:)), "f", optCmd),
            item("Find Next in PDF", #selector(ChapterWindow.findNextInPDF(_:)), "g", [.command, .control]),
            item("Find Previous in PDF", #selector(ChapterWindow.findPreviousInPDF(_:)), "g", [.command, .control, .shift]),
            .separator(),
            item("Send Marks to Review Queue", #selector(ChapterWindow.sendMarks(_:)), "e", [.command, .shift]),
            item("Open PDF in Preview", #selector(ChapterWindow.openInPreview(_:)), "p", [.command, .shift]),
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Tile Window to Left of Screen", Selector(("_zoomLeft:")), ""))
        windowMenu.addItem(item("Tile Window to Right of Screen", Selector(("_zoomRight:")), ""))
        let wm = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        wm.submenu = windowMenu
        main.addItem(wm)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
