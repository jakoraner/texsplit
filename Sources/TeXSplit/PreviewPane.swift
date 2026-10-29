import AppKit
import PDFKit

enum SidebarMode: Int { case hidden, thumbnails, contents, notes, bookmarks, contactSheet, search }

/// The PDF half of a window, laid out like Preview: its toolbar (sidebar,
/// page, zoom, highlight, markup, search), the Markup toolbar below it, the
/// sidebar (thumbnails, table of contents, highlights and notes, search
/// results) and the page view.
final class PreviewPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let pdfView = MarkupPDFView()
    weak var book: MarkBook?

    private let header = NSVisualEffectView()
    private let markupBar = NSVisualEffectView()
    private let body = NSSplitView()
    private let sidebar = NSView()
    private let thumbnails = PDFThumbnailView()
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let sidebarTitle = NSTextField(labelWithString: "")

    private let sidebarButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let pageLabel = NSTextField(labelWithString: "")
    private let highlightControl = NSSegmentedControl()
    private let markupToggle = NSButton()
    private let search = NSSearchField()
    private var toolButtons: [Tool: NSButton] = [:]
    private let shapesButton = NSButton()
    private let lineButton = NSButton()
    private let strokeButton = NSButton()
    private let fillButton = NSButton()
    private let textStyleButton = NSButton()

    private let contactSheet = PDFThumbnailView()
    var bookmarksKey = "bookmarks"
    private var bookmarks: [Int] {
        get { UserDefaults.standard.array(forKey: bookmarksKey) as? [Int] ?? [] }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: bookmarksKey) }
    }
    private(set) var sidebarMode: SidebarMode = .hidden
    private var lastSidebar: SidebarMode = .thumbnails
    private var contactReturn: SidebarMode = .hidden
    private var results: [PDFSelection] = []
    private var resultIndex = -1
    private var shapeTool: Tool = .rectangle
    private var markupBarHeight: NSLayoutConstraint!
    var markupBarVisible: Bool { !markupBar.isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: layout

    private func symbol(_ name: String, _ tip: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    private func toolbarButton(_ name: String, _ tip: String, _ action: Selector, toggle: Bool = false) -> NSButton {
        let b = NSButton(image: symbol(name, tip) ?? NSImage(), target: self, action: action)
        b.bezelStyle = .toolbar
        b.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
        b.toolTip = tip
        b.imagePosition = .imageOnly
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return b
    }

    private func build() {
        for v in [header, markupBar, body] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        header.material = .titlebar
        header.blendingMode = .withinWindow
        markupBar.material = .titlebar
        markupBar.blendingMode = .withinWindow
        markupBarHeight = markupBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),
            markupBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            markupBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            markupBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            markupBarHeight,
            body.topAnchor.constraint(equalTo: markupBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        markupBar.isHidden = true
        addLine(below: header)

        // --- Preview's toolbar
        sidebarButton.bezelStyle = .toolbar
        sidebarButton.isBordered = true
        let sm = sidebarButton.menu!
        let icon = NSMenuItem(title: "", action: nil, keyEquivalent: ""); icon.image = symbol("sidebar.left", "Sidebar"); sm.addItem(icon)
        for (title, mode, key) in [("Hide Sidebar", SidebarMode.hidden, "1"), ("Thumbnails", .thumbnails, "2"),
                                   ("Table of Contents", .contents, "3"), ("Highlights and Notes", .notes, "4"),
                                   ("Bookmarks", .bookmarks, "5"), ("Contact Sheet", .contactSheet, "6")] {
            let i = NSMenuItem(title: title, action: #selector(sidebarMenu(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = [.command, .option]
            i.tag = mode.rawValue
            i.target = self
            sm.addItem(i)
        }
        sidebarButton.toolTip = "Sidebar"
        (sidebarButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom

        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.lineBreakMode = .byTruncatingTail

        let zoomOut = toolbarButton("minus.magnifyingglass", "Zoom Out (⌘-)", #selector(zoomOutAction(_:)))
        let zoomIn = toolbarButton("plus.magnifyingglass", "Zoom In (⌘+)", #selector(zoomInAction(_:)))

        highlightControl.segmentCount = 2
        highlightControl.trackingMode = .momentary
        highlightControl.segmentStyle = .separated
        highlightControl.setImage(symbol("highlighter", "Highlight"), forSegment: 0)
        highlightControl.setWidth(30, forSegment: 0)
        highlightControl.setWidth(14, forSegment: 1)
        highlightControl.setMenu(highlightMenu(), forSegment: 1)
        highlightControl.setShowsMenuIndicator(true, forSegment: 1)
        highlightControl.target = self
        highlightControl.action = #selector(highlightClicked(_:))
        highlightControl.toolTip = "Highlight (⌃⌘H)"

        markupToggle.image = symbol("pencil.tip.crop.circle", "Show Markup Toolbar")
        markupToggle.alternateImage = symbol("pencil.tip.crop.circle.fill", "Hide Markup Toolbar")
        markupToggle.bezelStyle = .toolbar
        markupToggle.setButtonType(.toggle)
        markupToggle.imagePosition = .imageOnly
        markupToggle.target = self
        markupToggle.action = #selector(toggleMarkupBar(_:))
        markupToggle.toolTip = "Show Markup Toolbar (⇧⌘A)"

        search.placeholderString = "Search"
        search.sendsSearchStringImmediately = false
        search.sendsWholeSearchString = true
        search.target = self
        search.action = #selector(searchAction(_:))
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let share = toolbarButton("square.and.arrow.up", "Share", #selector(shareClicked(_:)))
        let rotate = toolbarButton("rotate.left", "Rotate Left (⌘L)", #selector(rotateLeft(_:)))
        let row = NSStackView(views: [sidebarButton, pageLabel, spacer, zoomOut, zoomIn, share, highlightControl, rotate, markupToggle, search])
        row.spacing = 6
        row.setCustomSpacing(2, after: zoomOut)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        pin(row, in: header)

        // --- Preview's Markup toolbar
        let tools: [(Tool, String, String)] = [
            (.textSelect, "character.cursor.ibeam", "Text Selection"),
            (.rectSelect, "rectangle.dashed", "Rectangular Selection"),
            (.sketch, "scribble", "Sketch"),
            (.draw, "pencil.tip", "Draw"),
        ]
        var items: [NSView] = []
        for (t, icon, tip) in tools {
            let b = toolbarButton(icon, tip, #selector(toolClicked(_:)), toggle: true)
            b.tag = t.rawValue
            toolButtons[t] = b
            items.append(b)
        }
        shapesButton.image = symbol("square.on.circle", "Shapes")
        shapesButton.bezelStyle = .toolbar
        shapesButton.setButtonType(.pushOnPushOff)
        shapesButton.imagePosition = .imageOnly
        shapesButton.toolTip = "Shapes"
        shapesButton.target = self
        shapesButton.action = #selector(shapesClicked(_:))
        shapesButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
        items.append(shapesButton)
        let textButton = toolbarButton("character.textbox", "Text", #selector(toolClicked(_:)), toggle: true)
        textButton.tag = Tool.text.rawValue
        toolButtons[.text] = textButton
        items.append(textButton)
        items.append(toolbarButton("signature", "Sign", #selector(signClicked(_:))))
        let noteButton = toolbarButton("note.text", "Note", #selector(toolClicked(_:)), toggle: true)
        noteButton.tag = Tool.note.rawValue
        toolButtons[.note] = noteButton
        items.append(noteButton)
        items.append(divider())
        for (b, icon, tip, action) in [(lineButton, "lineweight", "Shape Style", #selector(lineClicked(_:))),
                                       (strokeButton, "", "Border Color", #selector(strokeClicked(_:))),
                                       (fillButton, "", "Fill Color", #selector(fillClicked(_:))),
                                       (textStyleButton, "textformat", "Text Style", #selector(textStyleClicked(_:)))] {
            if !icon.isEmpty { b.image = symbol(icon, tip) }
            b.bezelStyle = .toolbar
            b.imagePosition = .imageOnly
            b.toolTip = tip
            b.target = self
            b.action = action
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            items.append(b)
        }
        let markupSpacer = NSView()
        markupSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        items.append(markupSpacer)
        let markupRow = NSStackView(views: items)
        markupRow.spacing = 4
        markupRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        pin(markupRow, in: markupBar)

        // --- sidebar and pages
        body.isVertical = true
        body.dividerStyle = .thin
        sidebar.translatesAutoresizingMaskIntoConstraints = true
        body.addArrangedSubview(sidebar)
        body.addArrangedSubview(pdfView)
        body.setHoldingPriority(.init(260), forSubviewAt: 0)
        sidebar.isHidden = true

        sidebarTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        sidebarTitle.textColor = .secondaryLabelColor
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnails.backgroundColor = .clear
        let column = NSOutlineView.column("t")
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.style = .sourceList
        outline.target = self
        outline.action = #selector(outlineClicked(_:))
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false
        table.addTableColumn(NSTableView.column("m"))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        table.usesAutomaticRowHeights = true
        table.target = self
        table.action = #selector(tableClicked(_:))
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        for v in [sidebarTitle, thumbnails, outlineScroll, tableScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarTitle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
        ])
        for v in [thumbnails, outlineScroll, tableScroll] as [NSView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 6),
                v.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            ])
        }

        // Contact sheet: Preview's grid of every page, in place of the page view.
        contactSheet.pdfView = pdfView
        contactSheet.thumbnailSize = NSSize(width: 170, height: 220)
        contactSheet.backgroundColor = .underPageBackgroundColor
        contactSheet.isHidden = true
        contactSheet.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contactSheet)
        NSLayoutConstraint.activate([
            contactSheet.topAnchor.constraint(equalTo: body.topAnchor),
            contactSheet.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            contactSheet.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            contactSheet.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        let pick = NSClickGestureRecognizer(target: self, action: #selector(contactSheetPicked(_:)))
        pick.delaysPrimaryMouseButtonEvents = false
        contactSheet.addGestureRecognizer(pick)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.onToolChange = { [weak self] in self?.syncControls() }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        syncControls()
    }

    private func pin(_ row: NSStackView, in v: NSView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .centerY
        v.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            row.topAnchor.constraint(equalTo: v.topAnchor),
            row.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
    }

    private func addLine(below v: NSView) {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: v.bottomAnchor),
        ])
    }

    private func divider() -> NSView {
        let d = NSBox()
        d.boxType = .separator
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 1).isActive = true
        d.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return d
    }

    // MARK: document

    func documentChanged() {
        outline.reloadData()
        outline.expandItem(nil, expandChildren: false)
        reloadMarks()
        pageChanged()
        if !search.stringValue.isEmpty { runSearch(search.stringValue, jump: false) }
    }

    func reloadMarks() {
        if sidebarMode == .notes || sidebarMode == .search { table.reloadData() }
        updateSidebarTitle()
    }

    @objc private func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { pageLabel.stringValue = ""; return }
        let label = page.label.map { $0 != "\(doc.index(for: page) + 1)" ? " (\($0))" : "" } ?? ""
        pageLabel.stringValue = "Page \(doc.index(for: page) + 1)\(label) of \(doc.pageCount)"
    }

    // MARK: toolbar actions

    @objc func zoomInAction(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOutAction(_ sender: Any?) { pdfView.zoomOut(sender) }

    private func highlightMenu() -> NSMenu {
        let m = NSMenu()
        for (name, c) in Palette.highlights {
            let i = NSMenuItem(title: name, action: #selector(highlightStyleChosen(_:)), keyEquivalent: "")
            i.image = Palette.swatch(c)
            i.representedObject = ("Highlight", c)
            i.target = self
            m.addItem(i)
        }
        m.addItem(.separator())
        for (title, kind) in [("Underline", "Underline"), ("Strikethrough", "StrikeOut")] {
            let i = NSMenuItem(title: title, action: #selector(highlightStyleChosen(_:)), keyEquivalent: "")
            i.representedObject = (kind, NSColor.systemRed)
            i.target = self
            m.addItem(i)
        }
        return m
    }

    /// Preview: clicking the highlighter marks the selection, or turns highlight mode on/off.
    @objc private func highlightClicked(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment == 0 else { return }
        toggleHighlight()
    }

    func toggleHighlight() {
        if pdfView.applyMarkup(nil) { return }
        pdfView.highlightMode.toggle()
        if pdfView.highlightMode { pdfView.tool = .textSelect }
        syncControls()
    }

    @objc private func highlightStyleChosen(_ i: NSMenuItem) {
        guard let (k, c) = i.representedObject as? (String, NSColor) else { return }
        pdfView.style.markup = k
        if k == "Highlight" { pdfView.style.markupColor = c }
        if let a = pdfView.selected, Mark.textMarkups.contains(subtypeName(a)) { pdfView.restyle(a, kind: k, color: c) }
        else if !pdfView.applyMarkup(k, color: c) { pdfView.highlightMode = true; pdfView.tool = .textSelect }
        syncControls()
    }

    @objc func toggleMarkupBar(_ sender: Any?) {
        let show = markupBar.isHidden
        markupBar.isHidden = !show
        markupBarHeight.constant = show ? 34 : 0
        if !show { pdfView.tool = .textSelect }
        syncControls()
    }

    @objc private func toolClicked(_ b: NSButton) { choose(Tool(rawValue: b.tag) ?? .textSelect) }

    func choose(_ t: Tool) {
        if markupBar.isHidden { toggleMarkupBar(nil) }
        pdfView.tool = (pdfView.tool == t && t != .textSelect) ? .textSelect : t
        if pdfView.tool != .textSelect { pdfView.highlightMode = false }
        if t.isShape { shapeTool = t }
        syncControls()
    }

    @objc private func shapesClicked(_ b: NSButton) {
        let m = NSMenu()
        for (t, title, icon) in [(Tool.rectangle, "Rectangle", "rectangle"), (.oval, "Oval", "circle"),
                                 (.line, "Line", "line.diagonal"), (.arrow, "Arrow", "arrow.up.right")] {
            let i = NSMenuItem(title: title, action: #selector(shapeChosen(_:)), keyEquivalent: "")
            i.image = symbol(icon, title)
            i.tag = t.rawValue
            i.target = self
            i.state = pdfView.tool == t ? .on : .off
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
        syncControls()
    }

    @objc private func shapeChosen(_ i: NSMenuItem) { choose(Tool(rawValue: i.tag) ?? .rectangle) }

    @objc private func lineClicked(_ b: NSButton) {
        let m = NSMenu()
        for w: CGFloat in [0.5, 1, 2, 3, 4, 6, 8, 12] {
            let i = NSMenuItem(title: w == 0.5 ? "½ pt" : "\(Int(w)) pt", action: #selector(lineChosen(_:)), keyEquivalent: "")
            i.image = NSImage(size: NSSize(width: 40, height: 14), flipped: false) { r in
                NSColor.labelColor.setFill()
                NSRect(x: 0, y: r.midY - w / 2, width: r.width, height: max(w, 0.5)).fill()
                return true
            }
            i.representedObject = w
            i.state = pdfView.style.lineWidth == w ? .on : .off
            i.target = self
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }

    @objc private func lineChosen(_ i: NSMenuItem) {
        if let w = i.representedObject as? CGFloat { pdfView.setLineWidth(w); syncControls() }
    }

    private func colourMenu(_ action: Selector, none: Bool) -> NSMenu {
        let m = NSMenu()
        if none {
            let i = NSMenuItem(title: "None", action: action, keyEquivalent: "")
            i.image = Palette.swatch(nil)
            i.target = self
            m.addItem(i)
        }
        for (name, c) in Palette.shapes {
            let i = NSMenuItem(title: name, action: action, keyEquivalent: "")
            i.image = Palette.swatch(c)
            i.representedObject = c
            i.target = self
            m.addItem(i)
        }
        m.addItem(.separator())
        let more = NSMenuItem(title: "Show Colors…", action: #selector(showColours(_:)), keyEquivalent: "")
        more.representedObject = NSStringFromSelector(action)
        more.target = self
        m.addItem(more)
        return m
    }

    @objc private func strokeClicked(_ b: NSButton) {
        colourMenu(#selector(strokeChosen(_:)), none: false).popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }
    @objc private func fillClicked(_ b: NSButton) {
        colourMenu(#selector(fillChosen(_:)), none: true).popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }
    @objc private func strokeChosen(_ i: NSMenuItem) { if let c = i.representedObject as? NSColor { pdfView.setStroke(c); syncControls() } }
    @objc private func fillChosen(_ i: NSMenuItem) { pdfView.setFill(i.representedObject as? NSColor); syncControls() }
    @objc private func textColourChosen(_ i: NSMenuItem) { if let c = i.representedObject as? NSColor { pdfView.setTextColor(c); syncControls() } }

    private var colourTarget: Selector?
    @objc private func showColours(_ i: NSMenuItem) {
        colourTarget = (i.representedObject as? String).map(NSSelectorFromString)
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colourPanelChanged(_:)))
        panel.showsAlpha = true
        panel.orderFront(nil)
    }

    @objc private func colourPanelChanged(_ p: NSColorPanel) {
        switch colourTarget {
        case #selector(strokeChosen(_:)): pdfView.setStroke(p.color)
        case #selector(fillChosen(_:)): pdfView.setFill(p.color)
        case #selector(textColourChosen(_:)): pdfView.setTextColor(p.color)
        default: break
        }
        syncControls()
    }

    @objc private func textStyleClicked(_ b: NSButton) {
        let m = NSMenu()
        let fonts = NSMenuItem(title: "Show Fonts…", action: #selector(showFonts(_:)), keyEquivalent: "")
        fonts.target = self
        m.addItem(fonts)
        m.addItem(.separator())
        for size: CGFloat in [9, 10, 12, 14, 18, 24, 36, 48] {
            let i = NSMenuItem(title: "\(Int(size)) pt", action: #selector(sizeChosen(_:)), keyEquivalent: "")
            i.representedObject = size
            i.state = pdfView.style.font.pointSize == size ? .on : .off
            i.target = self
            m.addItem(i)
        }
        m.addItem(.separator())
        let colour = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        colour.submenu = colourMenu(#selector(textColourChosen(_:)), none: false)
        m.addItem(colour)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }

    @objc private func sizeChosen(_ i: NSMenuItem) {
        guard let s = i.representedObject as? CGFloat else { return }
        pdfView.setFont(NSFont(descriptor: pdfView.style.font.fontDescriptor, size: s) ?? .systemFont(ofSize: s))
    }

    @objc private func showFonts(_ i: NSMenuItem) {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(pdfView.style.font, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let fm = sender else { return }
        pdfView.setFont(fm.convert(pdfView.style.font))
    }

    /// Keep the toolbar showing the current tool, highlight mode and style.
    func syncControls() {
        for (t, b) in toolButtons { b.state = pdfView.tool == t ? .on : .off }
        shapesButton.state = pdfView.tool.isShape ? .on : .off
        let shapeIcon = ["rectangle", "circle", "line.diagonal", "arrow.up.right"][[Tool.rectangle, .oval, .line, .arrow].firstIndex(of: shapeTool) ?? 0]
        shapesButton.image = symbol(pdfView.tool.isShape ? shapeIcon : "square.on.circle", "Shapes")
        markupToggle.state = markupBar.isHidden ? .off : .on
        highlightControl.setSelected(pdfView.highlightMode, forSegment: 0)
        let s = pdfView.style
        let hlColour = s.markup == "Highlight" ? s.markupColor : NSColor.systemRed
        highlightControl.setImage(NSImage(size: NSSize(width: 20, height: 18), flipped: false) { r in
            if let base = self.symbol("highlighter", "Highlight") {
                let tinted = base.copy() as! NSImage
                tinted.isTemplate = true
                NSColor.labelColor.set()
                tinted.draw(in: NSRect(x: 2, y: 4, width: 16, height: 14))
            }
            hlColour.withAlphaComponent(1).setFill()
            NSRect(x: 3, y: 0, width: 14, height: 3).fill()
            if self.pdfView.highlightMode {
                NSColor.controlAccentColor.setStroke()
                NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            }
            return true
        }, forSegment: 0)
        strokeButton.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: 2, yRadius: 2)
            p.lineWidth = 2.5
            s.stroke.setStroke()
            p.stroke()
            return true
        }
        fillButton.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: 2, yRadius: 2)
            if let f = s.fill { f.setFill(); p.fill() } else {
                NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 1; p.stroke()
                let slash = NSBezierPath(); slash.move(to: NSPoint(x: 4, y: 4)); slash.line(to: NSPoint(x: 14, y: 14))
                NSColor.systemRed.setStroke(); slash.stroke()
            }
            return true
        }
    }

    // MARK: share, sign, rotate, bookmarks, display

    var shareURL: (() -> URL?)?

    @objc private func shareClicked(_ b: NSButton) {
        guard let url = shareURL?() else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    @objc private func signClicked(_ b: NSButton) {
        let m = NSMenu()
        for sig in Signatures.all() {
            let i = NSMenuItem(title: "", action: #selector(signatureChosen(_:)), keyEquivalent: "")
            i.image = Signatures.image(sig)
            i.representedObject = sig.url
            i.target = self
            m.addItem(i)
        }
        if !m.items.isEmpty { m.addItem(.separator()) }
        let create = NSMenuItem(title: "Create Signature…", action: #selector(createSignature(_:)), keyEquivalent: "")
        create.target = self
        m.addItem(create)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }

    @objc private func signatureChosen(_ i: NSMenuItem) {
        guard let url = i.representedObject as? URL, let s = Signatures.all().first(where: { $0.url == url }) else { return }
        pdfView.placeSignature(s.paths, aspect: s.aspect)
    }

    @objc private func createSignature(_ i: NSMenuItem) {
        guard let w = window else { return }
        SignaturePad.create(in: w) { [weak self] paths, aspect in self?.pdfView.placeSignature(paths, aspect: aspect) }
    }

    /// Rotation is a view setting (the PDF is regenerated on every build) and is
    /// re-applied after each rebuild.
    private(set) var rotation = 0
    @objc func rotateLeft(_ sender: Any?) { rotate(by: -90) }
    @objc func rotateRight(_ sender: Any?) { rotate(by: 90) }
    private func rotate(by d: Int) { rotation = (rotation + d + 360) % 360; applyRotation() }
    func applyRotation() {
        guard let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation = rotation }
        pdfView.layoutDocumentView()
    }

    /// The last table-of-contents entry starting on or before page `i`.
    private func section(at i: Int) -> String? {
        guard let doc = pdfView.document, let root = doc.outlineRoot else { return nil }
        var best: (Int, String)?
        func walk(_ o: PDFOutline) {
            for k in 0..<o.numberOfChildren {
                guard let c = o.child(at: k) else { continue }
                if let p = c.destination?.page.map({ doc.index(for: $0) }), p <= i, p >= (best?.0 ?? -1) { best = (p, c.label ?? "") }
                walk(c)
            }
        }
        walk(root)
        return best?.1
    }

    func toggleBookmark() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let i = doc.index(for: page)
        var b = bookmarks
        if let k = b.firstIndex(of: i) { b.remove(at: k) } else { b.append(i) }
        bookmarks = b
        if sidebarMode == .bookmarks { table.reloadData(); updateSidebarTitle() }
    }

    var currentPageBookmarked: Bool {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return false }
        return bookmarks.contains(doc.index(for: page))
    }

    // MARK: search

    @objc private func searchAction(_ sender: NSSearchField) {
        let q = sender.stringValue
        if q.isEmpty { clearSearch(); return }
        if q == lastQuery, !results.isEmpty {
            let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            step(back ? -1 : 1)
        } else {
            runSearch(q, jump: true)
        }
    }

    private var lastQuery = ""

    private func runSearch(_ q: String, jump: Bool) {
        guard let doc = pdfView.document else { return }
        lastQuery = q
        results = doc.findString(q, withOptions: [.caseInsensitive])
        pdfView.highlightedSelections = results.map { s in let c = s.copy() as! PDFSelection; c.color = NSColor.systemYellow.withAlphaComponent(0.6); return c }
        resultIndex = -1
        if sidebarMode != .search { lastSidebar = sidebarMode == .hidden ? lastSidebar : sidebarMode }
        setSidebar(.search)
        if jump { step(1) }
    }

    private func step(_ d: Int) {
        guard !results.isEmpty else { NSSound.beep(); return }
        resultIndex = (resultIndex + d + results.count) % results.count
        let s = results[resultIndex]
        pdfView.setCurrentSelection(s, animate: true)
        pdfView.go(to: s)
        table.selectRowIndexes([resultIndex], byExtendingSelection: false)
        table.scrollRowToVisible(resultIndex)
        updateSidebarTitle()
    }

    private func clearSearch() {
        results = []
        lastQuery = ""
        pdfView.highlightedSelections = nil
        if sidebarMode == .search { setSidebar(lastSidebar) }
    }

    func controlTextDidChange(_ obj: Notification) { if search.stringValue.isEmpty { clearSearch() } }

    func selfTestSearch(_ q: String) { search.stringValue = q; runSearch(q, jump: true) }

    func focusSearch() { window?.makeFirstResponder(search) }
    func findNext(_ back: Bool) { if results.isEmpty { focusSearch() } else { step(back ? -1 : 1) } }

    // MARK: sidebar

    @objc private func sidebarMenu(_ i: NSMenuItem) { setSidebar(SidebarMode(rawValue: i.tag) ?? .hidden) }

    func toggleSidebar() { setSidebar(sidebarMode == .hidden ? lastSidebar : .hidden) }

    @objc private func contactSheetPicked(_ g: NSClickGestureRecognizer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.setSidebar(self.lastSidebar == .contactSheet ? .hidden : self.lastSidebar) }
    }

    func setSidebar(_ mode: SidebarMode) {
        if mode == .contactSheet {
            if sidebarMode != .contactSheet { contactReturn = sidebarMode }
            sidebarMode = .contactSheet
            contactSheet.isHidden = false
            updateSidebarTitle()
            return
        }
        if !contactSheet.isHidden {
            contactSheet.isHidden = true
            if sidebarMode == .contactSheet { sidebarMode = contactReturn }
        }
        if mode != .hidden && mode != .search { lastSidebar = mode }
        let wasHidden = sidebarMode == .hidden
        sidebarMode = mode
        sidebar.isHidden = mode == .hidden
        thumbnails.isHidden = mode != .thumbnails
        outlineScroll.isHidden = mode != .contents
        tableScroll.isHidden = !(mode == .notes || mode == .search || mode == .bookmarks)
        if mode == .notes || mode == .search || mode == .bookmarks { table.reloadData() }
        if mode == .contents { outline.reloadData() }
        body.adjustSubviews()
        if wasHidden && mode != .hidden {
            DispatchQueue.main.async { self.body.setPosition(230, ofDividerAt: 0) }
        }
        updateSidebarTitle()
        for item in sidebarButton.menu!.items where item.action == #selector(sidebarMenu(_:)) {
            item.state = item.tag == mode.rawValue ? .on : .off
        }
    }

    private func updateSidebarTitle() {
        switch sidebarMode {
        case .thumbnails: sidebarTitle.stringValue = "THUMBNAILS"
        case .contents: sidebarTitle.stringValue = "TABLE OF CONTENTS"
        case .notes: sidebarTitle.stringValue = "HIGHLIGHTS AND NOTES · \(book?.marks.count ?? 0)"
        case .search:
            sidebarTitle.stringValue = results.isEmpty ? "NO RESULTS" :
                "\(resultIndex >= 0 ? "\(resultIndex + 1) OF " : "")\(results.count) RESULT\(results.count == 1 ? "" : "S")"
        case .bookmarks: sidebarTitle.stringValue = bookmarks.isEmpty ? "BOOKMARKS · ⌘D ADDS ONE" : "BOOKMARKS"
        case .contactSheet: sidebarTitle.stringValue = ""
        case .hidden: sidebarTitle.stringValue = ""
        }
    }

    // table of contents
    func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? pdfView.document?.outlineRoot)?.numberOfChildren ?? 0
    }
    func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? pdfView.document!.outlineRoot!).child(at: index)!
    }
    func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool { ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0 }
    func outlineView(_ v: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let o = item as? PDFOutline
        let page = o?.destination?.page.flatMap { pdfView.document?.index(for: $0) }.map { "\($0 + 1)" } ?? ""
        return Cell.make(v, title: o?.label ?? "", detail: nil, trailing: page)
    }
    @objc private func outlineClicked(_ v: NSOutlineView) {
        if let o = v.item(atRow: v.clickedRow) as? PDFOutline, let d = o.destination { pdfView.go(to: d) }
    }

    // highlights and notes / search results
    private var sortedMarks: [Mark] { (book?.marks ?? []).sorted { ($0.page, $0.y) < ($1.page, $1.y) } }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch sidebarMode {
        case .search: return results.count
        case .bookmarks: return bookmarks.count
        default: return sortedMarks.count
        }
    }

    func tableView(_ t: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if sidebarMode == .search {
            let s = results[row]
            let page = s.pages.first.flatMap { pdfView.document?.index(for: $0) }.map { "\($0 + 1)" } ?? ""
            let ctx = s.copy() as! PDFSelection
            ctx.extend(atStart: 30)
            ctx.extend(atEnd: 40)
            let text = (ctx.string ?? "").replacingOccurrences(of: "\n", with: " ")
            return Cell.make(t, title: text, detail: nil, trailing: page)
        }
        if sidebarMode == .bookmarks {
            let i = bookmarks[row]
            let label = pdfView.document?.page(at: i)?.label ?? "\(i + 1)"
            let heading = section(at: i) ?? "Page \(i + 1)"
            return Cell.make(t, title: heading, detail: nil, trailing: label)
        }
        let m = sortedMarks[row]
        let what: String
        switch m.kind {
        case "Highlight", "Underline", "StrikeOut": what = m.quoted
        case "Text", "FreeText": what = m.comment
        default: what = MarkBook.label(book?.annotation(for: m.id) ?? PDFAnnotation(bounds: .zero, forType: .square, withProperties: nil))
        }
        let note = m.isTextMarkup && !m.comment.isEmpty ? m.comment : nil
        let colour = book?.annotation(for: m.id)?.color
        return Cell.make(t, title: what, detail: note, trailing: "\(m.page)", swatch: colour, source: "\((m.file as NSString).lastPathComponent):\(m.line)")
    }

    @objc private func tableClicked(_ t: NSTableView) {
        let row = t.clickedRow
        guard row >= 0 else { return }
        if sidebarMode == .search { resultIndex = row - 1; step(1); return }
        if sidebarMode == .bookmarks {
            if let page = pdfView.document?.page(at: bookmarks[row]) { pdfView.go(to: page) }
            return
        }
        let m = sortedMarks[row]
        guard let a = book?.annotation(for: m.id), let page = a.page else { return }
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: a.bounds.minX, y: a.bounds.maxY + 60)))
        pdfView.selected = a
    }
}

private extension NSTableView {
    static func column(_ id: String) -> NSTableColumn {
        let c = NSTableColumn(identifier: .init(id))
        c.resizingMask = .autoresizingMask
        return c
    }
}

/// One sidebar row: colour, text (two lines), an optional note, page number on the right.
private enum Cell {
    static func make(_ t: NSTableView, title: String, detail: String?, trailing: String, swatch: NSColor? = nil, source: String? = nil) -> NSView {
        let v = NSTableCellView()
        let titleField = NSTextField(wrappingLabelWithString: title.isEmpty ? "—" : title)
        titleField.font = .systemFont(ofSize: 12)
        titleField.maximumNumberOfLines = 3
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let page = NSTextField(labelWithString: trailing)
        page.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        page.textColor = .secondaryLabelColor
        page.setContentHuggingPriority(.required, for: .horizontal)
        var col: [NSView] = [titleField]
        if let detail {
            let d = NSTextField(wrappingLabelWithString: "✎ " + detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.maximumNumberOfLines = 3
            col.append(d)
        }
        if let source {
            let s = NSTextField(labelWithString: source)
            s.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            s.textColor = .tertiaryLabelColor
            col.append(s)
        }
        let text = NSStackView(views: col)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var row: [NSView] = []
        if let swatch {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = swatch.withAlphaComponent(1).cgColor
            bar.layer?.cornerRadius = 1.5
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            row.append(bar)
        }
        row += [text, page]
        let h = NSStackView(views: row)
        h.alignment = .top
        h.spacing = 6
        h.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            h.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            h.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            h.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
        ])
        if let bar = row.first, swatch != nil { bar.heightAnchor.constraint(equalTo: h.heightAnchor).isActive = true }
        return v
    }
}
