import AppKit
import PDFKit

/// Preview's markup tools, in the order of its Markup toolbar.
enum Tool: Int {
    case textSelect, rectSelect, sketch, draw, rectangle, oval, line, arrow, text, note
    var isShape: Bool { [.rectangle, .oval, .line, .arrow].contains(self) }
}

/// Colours as Preview offers them: the five highlight colours, and the shape palette.
enum Palette {
    static let highlights: [(String, NSColor)] = [
        ("Yellow", NSColor(srgbRed: 1.00, green: 0.88, blue: 0.30, alpha: 0.55)),
        ("Green", NSColor(srgbRed: 0.49, green: 0.85, blue: 0.40, alpha: 0.55)),
        ("Blue", NSColor(srgbRed: 0.42, green: 0.70, blue: 1.00, alpha: 0.55)),
        ("Pink", NSColor(srgbRed: 1.00, green: 0.50, blue: 0.66, alpha: 0.55)),
        ("Purple", NSColor(srgbRed: 0.72, green: 0.55, blue: 0.95, alpha: 0.55)),
    ]
    static let shapes: [(String, NSColor)] = [
        ("Black", .black), ("Gray", .systemGray), ("White", .white), ("Red", .systemRed),
        ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Pink", .systemPink), ("Brown", .systemBrown),
    ]
    static let note = NSColor(srgbRed: 1.0, green: 0.92, blue: 0.45, alpha: 1)

    static func swatch(_ c: NSColor?, size: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            if let c { c.withAlphaComponent(1).setFill(); p.fill() } else {
                NSColor.white.setFill(); p.fill()
                NSColor.systemRed.setStroke()
                let s = NSBezierPath(); s.move(to: NSPoint(x: 2, y: 2)); s.line(to: NSPoint(x: r.maxX - 2, y: r.maxY - 2)); s.stroke()
            }
            NSColor.black.withAlphaComponent(0.25).setStroke(); p.stroke()
            return true
        }
    }
}

struct MarkupStyle {
    var markup = "Highlight"                         // Highlight, Underline, StrikeOut
    var markupColor = Palette.highlights[0].1
    var stroke: NSColor = .systemRed
    var fill: NSColor? = nil
    var lineWidth: CGFloat = 2
    var font = NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)
    var textColor: NSColor = .black
}

protocol MarkupHost: AnyObject {
    var book: MarkBook { get }
    func commandClick(page: PDFPage, point: NSPoint)
    func selectionChanged()
}

/// PDFKit's view (the engine Preview uses) with Preview's markup behaviour:
/// tools, selecting, moving and resizing marks, inline text boxes, note popovers,
/// highlight mode, rectangular selection, and the context menus.
final class MarkupPDFView: PDFView, NSTextViewDelegate, NSPopoverDelegate {
    weak var host: MarkupHost?
    var onToolChange: (() -> Void)?
    var tool: Tool = .textSelect {
        didSet {
            if tool != .textSelect { selected = nil }
            if tool != .rectSelect { rectSelection = nil }
            window?.invalidateCursorRects(for: self)
            onToolChange?()
        }
    }
    var highlightMode = false { didSet { onToolChange?() } }
    var style = MarkupStyle()
    var selected: PDFAnnotation? {
        didSet { if oldValue !== selected { needsDisplay = true; host?.selectionChanged() } }
    }
    private(set) var lastClick: (page: PDFPage, point: NSPoint)?
    private var rectSelection: (page: PDFPage, rect: NSRect)? { didSet { needsDisplay = true } }
    private let pdfUndo = UndoManager()
    override var undoManager: UndoManager? { host?.book.undo ?? pdfUndo }

    private enum Drag {
        case move(PDFAnnotation, start: NSPoint, orig: NSRect, before: Data?)
        case resize(PDFAnnotation, corner: Int, orig: NSRect, before: Data?, paths: [NSBezierPath])
        case endpoint(PDFAnnotation, isStart: Bool, before: Data?)
        case create(PDFAnnotation, start: NSPoint)
        case ink(PDFAnnotation, path: NSBezierPath, points: [NSPoint])
        case rect(start: NSPoint)
    }
    private var drag: Drag?
    private var dragPage: PDFPage?
    private var textEditor: (view: NSTextView, annotation: PDFAnnotation, before: Data?)?
    private var notePopover: (popover: NSPopover, annotation: PDFAnnotation, text: NSTextView, before: Data?)?

    private var book: MarkBook? { host?.book }

    // MARK: geometry helpers

    private func archive(_ a: PDFAnnotation) -> Data? { try? NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: false) }
    private func refresh(_ page: PDFPage?) { if let page { annotationsChanged(on: page) }; needsDisplay = true }
    private var author: String { NSFullUserName() }

    private func handles(_ a: PDFAnnotation) -> [NSPoint] {
        if subtypeName(a) == "Line" {
            let o = a.bounds.origin
            return [NSPoint(x: o.x + a.startPoint.x, y: o.y + a.startPoint.y), NSPoint(x: o.x + a.endPoint.x, y: o.y + a.endPoint.y)]
        }
        let b = a.bounds
        return [NSPoint(x: b.minX, y: b.minY), NSPoint(x: b.maxX, y: b.minY), NSPoint(x: b.maxX, y: b.maxY), NSPoint(x: b.minX, y: b.maxY)]
    }

    private var handleRadius: CGFloat { 5 / max(scaleFactor, 0.1) }

    private func handle(at p: NSPoint, of a: PDFAnnotation) -> Int? {
        guard !isTextMarkup(a), subtypeName(a) != "Text" else { return nil }
        return handles(a).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= handleRadius * 1.6 }
    }

    private func isTextMarkup(_ a: PDFAnnotation) -> Bool { Mark.textMarkups.contains(subtypeName(a)) }

    private func badgeRect(_ a: PDFAnnotation) -> NSRect {
        NSRect(x: a.bounds.minX - 15, y: a.bounds.maxY - 11, width: 11, height: 11)
    }

    func ownedAnnotation(at p: NSPoint, on page: PDFPage) -> PDFAnnotation? {
        guard let book else { return nil }
        for a in page.annotations.reversed() where book.owns(a) {
            if subtypeName(a) == "Line" {
                let h = handles(a)
                if distance(p, h[0], h[1]) <= max(6 / scaleFactor, a.border?.lineWidth ?? 1) { return a }
                continue
            }
            if a.bounds.insetBy(dx: -3, dy: -3).contains(p) { return a }
            if isTextMarkup(a), !(a.contents ?? "").isEmpty, badgeRect(a).insetBy(dx: -2, dy: -2).contains(p) { return a }
        }
        return nil
    }

    private func distance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: drawing on top of pages

    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        guard let book else { return }
        // Notes look like Preview's: a small yellow square, PDFKit's speech bubble hidden.
        for a in page.annotations where book.owns(a) && subtypeName(a) == "Text" {
            if a.shouldDisplay { a.shouldDisplay = false }
            MarkupPDFView.drawNote(in: a.bounds, colour: a.color, context: context, scale: scaleFactor)
        }
        // Preview shows a small note square beside a highlight that has a note.
        for a in page.annotations where book.owns(a) && isTextMarkup(a) && !(a.contents ?? "").isEmpty {
            let r = badgeRect(a)
            context.setFillColor(Palette.note.cgColor)
            context.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(0.5)
            context.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.strokePath()
        }
        if let a = selected, a.page == page {
            let accent = NSColor.controlAccentColor.cgColor
            context.setStrokeColor(accent)
            context.setLineWidth(1 / scaleFactor)
            if subtypeName(a) != "Line" {
                context.setLineDash(phase: 0, lengths: [3 / scaleFactor, 2 / scaleFactor])
                context.stroke(a.bounds.insetBy(dx: -1, dy: -1))
                context.setLineDash(phase: 0, lengths: [])
            }
            if !isTextMarkup(a), subtypeName(a) != "Text" {
                for h in handles(a) {
                    let r = NSRect(x: h.x - handleRadius, y: h.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
                    context.setFillColor(NSColor.white.cgColor)
                    context.fillEllipse(in: r)
                    context.setStrokeColor(accent)
                    context.strokeEllipse(in: r)
                }
            }
        }
        if let rs = rectSelection, rs.page == page {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
            context.setLineWidth(1 / scaleFactor)
            context.setLineDash(phase: 0, lengths: [4 / scaleFactor, 3 / scaleFactor])
            context.fill(rs.rect)
            context.stroke(rs.rect)
        }
    }

    // MARK: cursors

    /// Preview's closed note: a yellow square with a darker rim, a soft shadow and a folded corner.
    static func drawNote(in r: NSRect, colour: NSColor, context: CGContext, scale: CGFloat) {
        let base = colour.usingColorSpace(.sRGB) ?? Palette.note
        let box = NSRect(x: r.midX - 9, y: r.midY - 9, width: 18, height: 18)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(base.withAlphaComponent(1).cgColor)
        let fold: CGFloat = 5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - fold, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY + fold))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(base.shadow(withLevel: 0.35)?.cgColor ?? NSColor.systemOrange.cgColor)
        context.setLineWidth(0.75)
        context.addPath(path)
        context.strokePath()
        // folded corner
        context.setFillColor((base.shadow(withLevel: 0.15) ?? base).cgColor)
        context.move(to: CGPoint(x: box.maxX - fold, y: box.minY))
        context.addLine(to: CGPoint(x: box.maxX - fold, y: box.minY + fold))
        context.addLine(to: CGPoint(x: box.maxX, y: box.minY + fold))
        context.closePath()
        context.fillPath()
        // text lines
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(0.8)
        for i in 0..<3 {
            let y = box.maxY - 5 - CGFloat(i) * 3.6
            context.move(to: CGPoint(x: box.minX + 3.5, y: y))
            context.addLine(to: CGPoint(x: box.maxX - (i == 2 ? 8 : 3.5), y: y))
        }
        context.strokePath()
    }

    override func resetCursorRects() {
        if tool == .textSelect { super.resetCursorRects() } else { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseMoved(with event: NSEvent) {
        if tool != .textSelect { NSCursor.crosshair.set(); return }
        let vp = convert(event.locationInWindow, from: nil)
        if let page = page(for: vp, nearest: false) {
            let p = convert(vp, to: page)
            if let a = selected, a.page == page, handle(at: p, of: a) != nil { NSCursor.crosshair.set(); return }
            if let a = ownedAnnotation(at: p, on: page), !isTextMarkup(a) { NSCursor.openHand.set(); return }
        }
        super.mouseMoved(with: event)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        endTextEditing()
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        guard let page = page(for: vp, nearest: true) else { super.mouseDown(with: event); return }
        let p = convert(vp, to: page)
        lastClick = (page, p)
        dragPage = page

        if event.modifierFlags.contains(.command), tool == .textSelect {
            host?.commandClick(page: page, point: p)
            return
        }
        switch tool {
        case .textSelect:
            if let a = selected, a.page == page, let i = handle(at: p, of: a) {
                if subtypeName(a) == "Line" { drag = .endpoint(a, isStart: i == 0, before: archive(a)) }
                else { drag = .resize(a, corner: i, orig: a.bounds, before: archive(a), paths: a.paths ?? []) }
                return
            }
            if let a = ownedAnnotation(at: p, on: page) {
                selected = a
                clearSelection()
                if event.clickCount == 2 || (isTextMarkup(a) && badgeRect(a).insetBy(dx: -2, dy: -2).contains(p)) {
                    edit(a)
                    return
                }
                if !isTextMarkup(a) {
                    var target = a
                    if event.modifierFlags.contains(.option), let data = archive(a),
                       let copy = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? PDFAnnotation {
                        copy.border = border(a.border?.lineWidth ?? 1)
                        book?.add(copy, to: page)
                        selected = copy
                        target = copy
                    }
                    drag = .move(target, start: p, orig: target.bounds, before: archive(target))
                }
                return
            }
            selected = nil
            super.mouseDown(with: event)
        case .rectSelect:
            rectSelection = nil
            drag = .rect(start: p)
        case .sketch, .draw:
            let path = NSBezierPath()
            path.move(to: p)
            path.lineWidth = style.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let a = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
            a.color = style.stroke
            a.border = border(style.lineWidth)
            a.add(path)
            page.addAnnotation(a)
            drag = .ink(a, path: path, points: [p])
        case .rectangle, .oval, .line, .arrow:
            let a = makeShape(tool, from: p, to: p)
            page.addAnnotation(a)
            drag = .create(a, start: p)
        case .text:
            let a = PDFAnnotation(bounds: NSRect(x: p.x, y: p.y - style.font.pointSize - 6, width: 140, height: style.font.pointSize + 8),
                                  forType: .freeText, withProperties: nil)
            a.contents = ""
            a.font = style.font
            a.fontColor = style.textColor
            a.color = .clear
            a.border = border(0)
            a.userName = author
            book?.add(a, to: page)
            selected = a
            tool = .textSelect
            beginTextEditing(a)
        case .note:
            let a = PDFAnnotation(bounds: NSRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
            a.iconType = .comment
            a.color = Palette.note
            a.userName = author
            a.contents = ""
            book?.add(a, to: page)
            selected = a
            tool = .textSelect
            editNote(a)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let page = dragPage else { super.mouseDragged(with: event); return }
        autoscroll(with: event)
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        switch drag {
        case let .move(a, start, orig, _):
            a.bounds = orig.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
        case let .resize(a, corner, orig, _, paths):
            let fixed = handlesOf(orig)[(corner + 2) % 4]
            var r = NSRect(x: min(fixed.x, p.x), y: min(fixed.y, p.y), width: max(4, abs(p.x - fixed.x)), height: max(4, abs(p.y - fixed.y)))
            if event.modifierFlags.contains(.shift) { let s = max(r.width, r.height); r.size = NSSize(width: s, height: s) }
            a.bounds = r
            if subtypeName(a) == "Ink", !paths.isEmpty {
                // Scale the drawing with its box.
                for old in a.paths ?? [] { a.remove(old) }
                let t = AffineTransform(scaleByX: r.width / max(orig.width, 1), byY: r.height / max(orig.height, 1))
                for path in paths { let c = path.copy() as! NSBezierPath; c.transform(using: t); a.add(c) }
            }
        case let .endpoint(a, isStart, _):
            let h = handles(a)
            setLine(a, from: isStart ? p : h[0], to: isStart ? h[1] : p)
        case let .create(a, start):
            var end = p
            if event.modifierFlags.contains(.shift) {
                if tool.isShape && (tool == .line || tool == .arrow) {
                    // Snap lines to 45 degrees.
                    let ang = (atan2(p.y - start.y, p.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                    let len = hypot(p.x - start.x, p.y - start.y)
                    end = NSPoint(x: start.x + cos(ang) * len, y: start.y + sin(ang) * len)
                } else {
                    let s = max(abs(p.x - start.x), abs(p.y - start.y))
                    end = NSPoint(x: start.x + (p.x >= start.x ? s : -s), y: start.y + (p.y >= start.y ? s : -s))
                }
            }
            reshape(a, from: start, to: end)
        case let .ink(a, path, points):
            a.remove(path)
            path.line(to: p)
            a.add(path)
            self.drag = .ink(a, path: path, points: points + [p])
        case let .rect(start):
            rectSelection = (page, NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)))
        }
        refresh(page)
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag, let page = dragPage else {
            super.mouseUp(with: event)
            if highlightMode { applyMarkup(nil) }
            return
        }
        drag = nil
        switch d {
        case let .move(a, _, orig, before):
            if a.bounds != orig { book?.changed(a, before: before) }
            else if subtypeName(a) == "Text" { editNote(a) }   // a click without a drag opens the note
        case let .resize(a, _, _, before, _), let .endpoint(a, _, before):
            book?.changed(a, before: before)
        case let .create(a, start):
            page.removeAnnotation(a)
            let end = convert(convert(event.locationInWindow, from: nil), to: page)
            if hypot(end.x - start.x, end.y - start.y) < 4 {
                // A click without a drag gives a default-sized shape, as in Preview.
                reshape(a, from: start, to: NSPoint(x: start.x + 90, y: start.y - (tool == .line || tool == .arrow ? 0 : 60)))
            }
            a.userName = author
            book?.add(a, to: page)
            selected = a
            tool = .textSelect
        case let .ink(a, _, points):
            page.removeAnnotation(a)
            if tool == .sketch, let shape = recognise(points) {
                shape.userName = author
                book?.add(shape, to: page)
                selected = shape
            } else if points.count > 1 {
                let ink = inkAnnotation(points)
                ink.userName = author
                book?.add(ink, to: page)
            }
        case .rect:
            break
        }
        refresh(page)
    }

    override func rightMouseDown(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        if let page = page(for: vp, nearest: true) {
            let p = convert(vp, to: page)
            lastClick = (page, p)
            if let a = ownedAnnotation(at: p, on: page) { selected = a }
        }
        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let a = selected {
            switch event.keyCode {
            case 51, 117: book?.remove(a); selected = nil; return
            case 36, 76:
                edit(a); return
            case 123, 124, 125, 126:
                guard !isTextMarkup(a) else { break }
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let before = archive(a)
                let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
                let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
                a.bounds = a.bounds.offsetBy(dx: dx, dy: dy)
                book?.changed(a, before: before)
                refresh(a.page)
                return
            default: break
            }
        }
        if event.keyCode == 53 {   // escape
            selected = nil
            rectSelection = nil
            if tool != .textSelect { tool = .textSelect }
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        endTextEditing()
        super.scrollWheel(with: event)
    }

    // MARK: building shapes

    private func border(_ w: CGFloat) -> PDFBorder { let b = PDFBorder(); b.lineWidth = w; return b }

    private func handlesOf(_ b: NSRect) -> [NSPoint] {
        [NSPoint(x: b.minX, y: b.minY), NSPoint(x: b.maxX, y: b.minY), NSPoint(x: b.maxX, y: b.maxY), NSPoint(x: b.minX, y: b.maxY)]
    }

    private func makeShape(_ t: Tool, from s: NSPoint, to e: NSPoint) -> PDFAnnotation {
        let type: PDFAnnotationSubtype = t == .rectangle ? .square : t == .oval ? .circle : .line
        let a = PDFAnnotation(bounds: NSRect(origin: s, size: .zero), forType: type, withProperties: nil)
        a.color = style.stroke
        a.border = border(style.lineWidth)
        if t == .rectangle || t == .oval { a.interiorColor = style.fill }
        if t == .arrow { a.endLineStyle = .openArrow }
        reshape(a, from: s, to: e)
        return a
    }

    private func reshape(_ a: PDFAnnotation, from s: NSPoint, to e: NSPoint) {
        if subtypeName(a) == "Line" { setLine(a, from: s, to: e); return }
        a.bounds = NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: max(1, abs(e.x - s.x)), height: max(1, abs(e.y - s.y)))
    }

    private func setLine(_ a: PDFAnnotation, from s: NSPoint, to e: NSPoint) {
        let pad = max(8, (a.border?.lineWidth ?? 1) * 4)
        let r = NSRect(x: min(s.x, e.x) - pad, y: min(s.y, e.y) - pad, width: abs(e.x - s.x) + pad * 2, height: abs(e.y - s.y) + pad * 2)
        a.bounds = r
        a.startPoint = NSPoint(x: s.x - r.minX, y: s.y - r.minY)
        a.endPoint = NSPoint(x: e.x - r.minX, y: e.y - r.minY)
    }

    private func inkAnnotation(_ points: [NSPoint]) -> PDFAnnotation {
        let pad = style.lineWidth + 2
        let xs = points.map(\.x), ys = points.map(\.y)
        let r = NSRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + pad * 2, height: ys.max()! - ys.min()! + pad * 2)
        let a = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: points[0].x - r.minX, y: points[0].y - r.minY))
        for q in points.dropFirst() { path.line(to: NSPoint(x: q.x - r.minX, y: q.y - r.minY)) }
        a.add(path)
        a.color = style.stroke
        a.border = border(style.lineWidth)
        return a
    }

    /// Sketch: a stroke that is clearly a line, oval or rectangle becomes that shape.
    private func recognise(_ pts: [NSPoint]) -> PDFAnnotation? {
        guard pts.count > 8 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let box = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let size = max(box.width, box.height)
        guard size > 12 else { return nil }
        let first = pts.first!, last = pts.last!
        let closed = hypot(last.x - first.x, last.y - first.y) < size * 0.25
        if !closed {
            let dev = pts.map { distance($0, first, last) }.max() ?? .infinity
            if dev < hypot(last.x - first.x, last.y - first.y) * 0.06 {
                return makeShape(.line, from: first, to: last)
            }
            return nil
        }
        let c = NSPoint(x: box.midX, y: box.midY)
        let rx = max(box.width / 2, 1), ry = max(box.height / 2, 1)
        let ellipseErr = pts.map { p -> CGFloat in
            let d = sqrt(pow((p.x - c.x) / rx, 2) + pow((p.y - c.y) / ry, 2))
            return abs(d - 1)
        }.reduce(0, +) / CGFloat(pts.count)
        let rectErr = pts.map { p -> CGFloat in
            min(abs(p.x - box.minX), abs(p.x - box.maxX), abs(p.y - box.minY), abs(p.y - box.maxY)) / size
        }.reduce(0, +) / CGFloat(pts.count)
        if rectErr < 0.05 && rectErr * 2 < ellipseErr { return makeShape(.rectangle, from: box.origin, to: NSPoint(x: box.maxX, y: box.maxY)) }
        if ellipseErr < 0.14 { return makeShape(.oval, from: box.origin, to: NSPoint(x: box.maxX, y: box.maxY)) }
        if rectErr < 0.07 { return makeShape(.rectangle, from: box.origin, to: NSPoint(x: box.maxX, y: box.maxY)) }
        return nil
    }

    // MARK: text markup

    /// Highlight / underline / strike the current text selection. Returns false if nothing is selected.
    @discardableResult
    func applyMarkup(_ kind: String?, color: NSColor? = nil, comment: String? = nil) -> Bool {
        guard let sel = currentSelection, let s = sel.string,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let k = kind ?? style.markup
        let c = color ?? (k == "Highlight" ? style.markupColor : .systemRed)
        var last: PDFAnnotation?
        for page in sel.pages {
            let parts = sel.selectionsByLine().filter { $0.pages.first == page }
            let quoted = parts.compactMap(\.string).joined(separator: " ")
            let a = MarkBook.markup(kind: k, selection: sel, page: page, color: c)
            a.userName = author
            if let comment { a.contents = comment }
            book?.add(a, to: page, quoted: quoted)
            last = a
        }
        clearSelection()
        _ = last
        return true
    }

    /// Change a text markup's colour or kind in place, as Preview's context menu does.
    func restyle(_ a: PDFAnnotation, kind: String, color: NSColor) {
        guard let page = a.page, isTextMarkup(a) else { return }
        if subtypeName(a) == kind {
            let before = archive(a)
            a.color = color
            book?.changed(a, before: before)
            refresh(page)
            return
        }
        let quoted = book?.mark(for: a)?.quoted
        let comment = a.contents
        let b = PDFAnnotation(bounds: a.bounds, forType: kind == "Underline" ? .underline : kind == "StrikeOut" ? .strikeOut : .highlight,
                              withProperties: nil)
        b.quadrilateralPoints = a.quadrilateralPoints
        b.color = color
        b.contents = comment
        b.userName = author
        book?.undo.beginUndoGrouping()
        book?.remove(a)
        book?.add(b, to: page, quoted: quoted)
        book?.undo.endUndoGrouping()
        selected = b
        refresh(page)
    }

    // MARK: style of the selected mark

    private func applyToSelected(_ change: (PDFAnnotation) -> Void) -> Bool {
        guard let a = selected, let page = a.page else { return false }
        let before = archive(a)
        change(a)
        book?.changed(a, before: before)
        refresh(page)
        return true
    }

    func setStroke(_ c: NSColor) {
        style.stroke = c
        _ = applyToSelected { a in
            if subtypeName(a) == "FreeText" { a.fontColor = c } else { a.color = c }
        }
    }

    func setFill(_ c: NSColor?) {
        style.fill = c
        _ = applyToSelected { a in
            if subtypeName(a) == "FreeText" { a.color = c ?? .clear } else { a.interiorColor = c }
        }
    }

    func setLineWidth(_ w: CGFloat) {
        style.lineWidth = w
        _ = applyToSelected { a in a.border = border(w) }
    }

    func setFont(_ f: NSFont) {
        style.font = f
        _ = applyToSelected { a in if subtypeName(a) == "FreeText" { a.font = f; fitText(a) } }
    }

    func setTextColor(_ c: NSColor) {
        style.textColor = c
        _ = applyToSelected { a in if subtypeName(a) == "FreeText" { a.fontColor = c } }
    }

    // MARK: editing text boxes and notes

    func edit(_ a: PDFAnnotation) {
        switch subtypeName(a) {
        case "FreeText": beginTextEditing(a)
        default: editNote(a)
        }
    }

    private func fitText(_ a: PDFAnnotation) {
        let font = a.font ?? style.font
        let text = (a.contents ?? "").isEmpty ? " " : a.contents!
        let size = (text as NSString).boundingRect(with: NSSize(width: max(a.bounds.width - 6, 40), height: 10_000),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font]).size
        let h = ceil(size.height) + 8
        a.bounds = NSRect(x: a.bounds.minX, y: a.bounds.maxY - h, width: a.bounds.width, height: h)
    }

    func beginTextEditing(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        endTextEditing()
        let r = convert(a.bounds, from: page)
        let tv = NSTextView(frame: r.insetBy(dx: -2, dy: -2))
        let f = a.font ?? style.font
        tv.font = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * scaleFactor) ?? f
        tv.textColor = a.fontColor ?? style.textColor
        tv.string = a.contents ?? ""
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.white.withAlphaComponent(0.92)
        tv.textContainerInset = NSSize(width: 1, height: 2)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.wantsLayer = true
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tv.layer?.borderWidth = 1
        tv.delegate = self
        a.shouldDisplay = false
        refresh(page)
        addSubview(tv)
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        textEditor = (tv, a, archive(a))
    }

    func textDidChange(_ notification: Notification) {
        guard let (tv, _, _) = textEditor, notification.object as? NSTextView === tv,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + 6
        if h > tv.frame.height { tv.frame = NSRect(x: tv.frame.minX, y: tv.frame.maxY - h, width: tv.frame.width, height: h) }
    }

    func textDidEndEditing(_ notification: Notification) {
        if let (tv, _, _) = textEditor, notification.object as? NSTextView === tv { endTextEditing() }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { endTextEditing(); return true }
        return false
    }

    func endTextEditing() {
        guard let (tv, a, before) = textEditor else { return }
        textEditor = nil
        a.contents = tv.string
        a.shouldDisplay = true
        tv.removeFromSuperview()
        if tv.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book?.remove(a)
            if selected === a { selected = nil }
        } else {
            fitText(a)
            book?.changed(a, before: before)
        }
        refresh(a.page)
        window?.makeFirstResponder(self)
    }

    /// A note opens as Preview's yellow note: author and date on top, the text below.
    func editNote(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        notePopover?.popover.close()
        let vc = NSViewController()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        box.wantsLayer = true
        box.layer?.backgroundColor = Palette.note.cgColor
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let header = NSTextField(labelWithString: "\(a.userName ?? author)  ·  \(df.string(from: a.modificationDate ?? Date()))")
        header.font = .systemFont(ofSize: 10, weight: .medium)
        header.textColor = NSColor.black.withAlphaComponent(0.55)
        header.frame = NSRect(x: 10, y: 158, width: 240, height: 14)
        let scroll = NSScrollView(frame: NSRect(x: 6, y: 6, width: 248, height: 148))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds)
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .black
        tv.insertionPointColor = .black
        tv.isRichText = false
        tv.string = a.contents ?? ""
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        box.addSubview(header)
        box.addSubview(scroll)
        vc.view = box
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .aqua)
        pop.delegate = self
        let anchor = isTextMarkup(a) && !(a.contents ?? "").isEmpty ? badgeRect(a) : a.bounds
        pop.show(relativeTo: convert(anchor, from: page), of: self, preferredEdge: .maxX)
        notePopover = (pop, a, tv, archive(a))
        vc.view.window?.makeFirstResponder(tv)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let (pop, a, tv, before) = notePopover, notification.object as? NSPopover === pop else { return }
        notePopover = nil
        let text = tv.string
        if subtypeName(a) == "Text" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book?.remove(a)
            if selected === a { selected = nil }
        } else if text != (a.contents ?? "") {
            a.contents = text
            a.modificationDate = Date()
            book?.changed(a, before: before)
        }
        refresh(a.page)
    }

    // MARK: rectangular selection: copy as image

    static let pasteType = NSPasteboard.PasteboardType("dk.jacobhoffmann.texsplit.annotation")

    @objc func paste(_ sender: Any?) {
        guard let data = NSPasteboard.general.data(forType: Self.pasteType),
              let a = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? PDFAnnotation,
              let page = lastClick?.page ?? currentPage else { NSSound.beep(); return }
        a.bounds = a.bounds.offsetBy(dx: 12, dy: -12)
        if let w = NSPasteboard.general.string(forType: .init("dk.jacobhoffmann.texsplit.linewidth")).flatMap(Double.init) {
            a.border = border(CGFloat(w))
        }
        book?.add(a, to: page)
        selected = a
        refresh(page)
    }

    @objc func duplicate(_ sender: Any?) {
        guard let a = selected, !isTextMarkup(a), let page = a.page, let data = archive(a),
              let b = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? PDFAnnotation else { NSSound.beep(); return }
        b.bounds = a.bounds.offsetBy(dx: 12, dy: -12)
        b.border = border(a.border?.lineWidth ?? 1)
        book?.add(b, to: page)
        selected = b
        refresh(page)
    }

    @objc func cut(_ sender: Any?) {
        guard let a = selected, !isTextMarkup(a) else { NSSound.beep(); return }
        copy(sender)
        book?.remove(a)
        selected = nil
    }

    @objc override func copy(_ sender: Any?) {
        if let a = selected, !isTextMarkup(a), let data = archive(a) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: Self.pasteType)
            NSPasteboard.general.setString("\(a.border?.lineWidth ?? 1)", forType: .init("dk.jacobhoffmann.texsplit.linewidth"))
            if let text = a.contents, !text.isEmpty { NSPasteboard.general.setString(text, forType: .string) }
            return
        }
        guard let rs = rectSelection, rs.rect.width > 2, rs.rect.height > 2 else { super.copy(sender); return }
        let scale: CGFloat = 3
        let w = Int(rs.rect.width * scale), h = Int(rs.rect.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rs.rect.minX, y: -rs.rect.minY)
        rs.page.draw(with: .mediaBox, to: ctx)
        let img = NSImage(size: rs.rect.size)
        img.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    // MARK: context menus

    override func menu(for event: NSEvent) -> NSMenu? {
        let vp = convert(event.locationInWindow, from: nil)
        guard let page = page(for: vp, nearest: true) else { return super.menu(for: event) }
        let p = convert(vp, to: page)
        lastClick = (page, p)
        let menu = NSMenu()
        if let a = ownedAnnotation(at: p, on: page) {
            selected = a
            if isTextMarkup(a) {
                for (name, c) in Palette.highlights {
                    let i = NSMenuItem(title: name, action: #selector(menuRestyle(_:)), keyEquivalent: "")
                    i.image = Palette.swatch(c); i.representedObject = ("Highlight", c); i.target = self
                    if subtypeName(a) == "Highlight" && a.color.withAlphaComponent(1) == c.withAlphaComponent(1) { i.state = .on }
                    menu.addItem(i)
                }
                for (title, kind) in [("Underline", "Underline"), ("Strikethrough", "StrikeOut")] {
                    let i = NSMenuItem(title: title, action: #selector(menuRestyle(_:)), keyEquivalent: "")
                    i.representedObject = (kind, NSColor.systemRed); i.target = self
                    if subtypeName(a) == kind { i.state = .on }
                    menu.addItem(i)
                }
                menu.addItem(.separator())
                menu.addItem(withTitle: (a.contents ?? "").isEmpty ? "Add Note" : "Edit Note", action: #selector(menuEdit(_:)), keyEquivalent: "").target = self
                menu.addItem(withTitle: "Remove \(MarkBook.label(a))", action: #selector(menuDelete(_:)), keyEquivalent: "").target = self
            } else {
                if ["FreeText", "Text"].contains(subtypeName(a)) {
                    menu.addItem(withTitle: subtypeName(a) == "Text" ? "Open Note" : "Edit Text", action: #selector(menuEdit(_:)), keyEquivalent: "").target = self
                }
                let colour = NSMenuItem(title: subtypeName(a) == "FreeText" ? "Text Color" : "Border Color", action: nil, keyEquivalent: "")
                colour.submenu = swatchMenu(Palette.shapes, action: #selector(menuStroke(_:)), none: false)
                menu.addItem(colour)
                if ["Square", "Circle", "FreeText"].contains(subtypeName(a)) {
                    let fill = NSMenuItem(title: "Fill Color", action: nil, keyEquivalent: "")
                    fill.submenu = swatchMenu(Palette.shapes, action: #selector(menuFill(_:)), none: true)
                    menu.addItem(fill)
                }
                menu.addItem(.separator())
                menu.addItem(withTitle: "Delete", action: #selector(menuDelete(_:)), keyEquivalent: "").target = self
            }
            return menu
        }
        if let sel = currentSelection, !(sel.string ?? "").isEmpty {
            for (name, c) in Palette.highlights {
                let i = NSMenuItem(title: "Highlight \(name)", action: #selector(menuMarkup(_:)), keyEquivalent: "")
                i.image = Palette.swatch(c); i.representedObject = ("Highlight", c); i.target = self
                menu.addItem(i)
            }
            for (title, kind) in [("Underline", "Underline"), ("Strikethrough", "StrikeOut")] {
                let i = NSMenuItem(title: title, action: #selector(menuMarkup(_:)), keyEquivalent: "")
                i.representedObject = (kind, NSColor.systemRed); i.target = self
                menu.addItem(i)
            }
            menu.addItem(withTitle: "Highlight with Note…", action: #selector(menuHighlightNote(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Add Note Here", action: #selector(menuNoteHere(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in LaTeX Source", action: #selector(menuSource(_:)), keyEquivalent: "").target = self
        if let base = super.menu(for: event), base.items.contains(where: { !$0.isSeparatorItem }) {
            menu.addItem(.separator())
            for item in base.items { base.removeItem(item); menu.addItem(item) }
        }
        return menu
    }

    private func swatchMenu(_ colours: [(String, NSColor)], action: Selector, none: Bool) -> NSMenu {
        let m = NSMenu()
        if none {
            let i = NSMenuItem(title: "None", action: action, keyEquivalent: "")
            i.image = Palette.swatch(nil); i.representedObject = nil; i.target = self
            m.addItem(i)
        }
        for (name, c) in colours {
            let i = NSMenuItem(title: name, action: action, keyEquivalent: "")
            i.image = Palette.swatch(c); i.representedObject = c; i.target = self
            m.addItem(i)
        }
        return m
    }

    @objc private func menuRestyle(_ i: NSMenuItem) {
        guard let a = selected, let (k, c) = i.representedObject as? (String, NSColor) else { return }
        restyle(a, kind: k, color: c)
    }
    @objc private func menuMarkup(_ i: NSMenuItem) {
        guard let (k, c) = i.representedObject as? (String, NSColor) else { return }
        applyMarkup(k, color: c)
    }
    @objc private func menuHighlightNote(_ i: NSMenuItem) { highlightWithNote() }
    @objc private func menuEdit(_ i: NSMenuItem) { if let a = selected { edit(a) } }
    @objc private func menuDelete(_ i: NSMenuItem) { if let a = selected { book?.remove(a); selected = nil } }
    @objc private func menuStroke(_ i: NSMenuItem) { if let c = i.representedObject as? NSColor { setStroke(c) } }
    @objc private func menuFill(_ i: NSMenuItem) { setFill(i.representedObject as? NSColor) }
    @objc private func menuNoteHere(_ i: NSMenuItem) { addNoteAtLastClick() }
    @objc private func menuSource(_ i: NSMenuItem) { if let c = lastClick { host?.commandClick(page: c.page, point: c.point) } }

    func highlightWithNote() {
        guard let sel = currentSelection, let page = sel.pages.first else { return }
        let before = Set(page.annotations.map(ObjectIdentifier.init))
        guard applyMarkup("Highlight") else { return }
        if let a = page.annotations.first(where: { !before.contains(ObjectIdentifier($0)) }) {
            selected = a
            editNote(a)
        }
    }

    func addNoteAtLastClick() {
        guard let c = lastClick else { NSSound.beep(); return }
        let a = PDFAnnotation(bounds: NSRect(x: c.point.x - 10, y: c.point.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
        a.iconType = .comment
        a.color = Palette.note
        a.userName = author
        a.contents = ""
        book?.add(a, to: c.page)
        selected = a
        editNote(a)
    }

    /// Place a signature (paths in a 0...1 box) on the page, centred where you last clicked.
    func placeSignature(_ paths: [NSBezierPath], aspect: CGFloat) {
        guard let page = lastClick?.page ?? currentPage else { return }
        let w: CGFloat = 150, h = w / max(aspect, 0.1)
        let c = lastClick?.point ?? NSPoint(x: page.bounds(for: .mediaBox).midX, y: page.bounds(for: .mediaBox).midY)
        let r = NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let a = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil)
        for p in paths {
            let q = p.copy() as! NSBezierPath
            q.transform(using: AffineTransform(scaleByX: w, byY: h))
            q.lineWidth = 1.6
            q.lineCapStyle = .round
            q.lineJoinStyle = .round
            a.add(q)
        }
        a.color = .black
        a.border = border(1.6)
        a.userName = author
        book?.add(a, to: page)
        selected = a
        tool = .textSelect
    }

    func deleteSelected() {
        guard let a = selected else { NSSound.beep(); return }
        book?.remove(a)
        selected = nil
    }
}
