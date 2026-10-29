import AppKit
import PDFKit

/// Write a document with notes visible to other viewers. On screen we draw notes
/// ourselves (Preview's yellow square) and hide PDFKit's icon; a written file must not
/// carry that hidden flag, or Preview would not show the notes.
func writeShowingNotes(_ doc: PDFDocument, to url: URL) {
    var hidden: [PDFAnnotation] = []
    for i in 0..<doc.pageCount {
        for a in doc.page(at: i)?.annotations ?? [] where subtypeName(a) == "Text" && !a.shouldDisplay {
            a.shouldDisplay = true
            hidden.append(a)
        }
    }
    doc.write(to: url)
    hidden.forEach { $0.shouldDisplay = false }
}

/// Saved signatures, as Preview keeps them: drawn once, reused. Stored as paths in a
/// unit box under Application Support/TeX Split/signatures.
enum Signatures {
    struct Saved { let url: URL; let paths: [NSBezierPath]; let aspect: CGFloat }

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeX Split/signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func all() -> [Saved] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "sig" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let obj = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? [String: Any],
                  let paths = obj["paths"] as? [NSBezierPath], let aspect = obj["aspect"] as? CGFloat else { return nil }
            return Saved(url: url, paths: paths, aspect: aspect)
        }
    }

    static func save(_ paths: [NSBezierPath], aspect: CGFloat) {
        let obj: [String: Any] = ["paths": paths, "aspect": aspect]
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: obj, requiringSecureCoding: false) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        try? data.write(to: dir.appendingPathComponent("\(f.string(from: Date())).sig"))
    }

    static func image(_ s: Saved, height: CGFloat = 22) -> NSImage {
        let w = height * s.aspect
        return NSImage(size: NSSize(width: w, height: height), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            for p in s.paths {
                let q = p.copy() as! NSBezierPath
                q.transform(using: AffineTransform(scaleByX: w, byY: height))
                q.lineWidth = 1.2
                q.stroke()
            }
            return true
        }
    }
}

/// Draw a signature with the trackpad or mouse, as in Preview's "Create Signature".
final class SignaturePad: NSView {
    private(set) var strokes: [[NSPoint]] = []

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 20, y: 40))
        base.line(to: NSPoint(x: bounds.maxX - 20, y: 40))
        base.lineWidth = 0.5
        base.stroke()
        let hint = "Sign on the line with your trackpad or mouse" as NSString
        hint.draw(at: NSPoint(x: 20, y: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSColor.black.setStroke()
        for s in strokes where s.count > 1 {
            let p = NSBezierPath()
            p.lineWidth = 2
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: s[0])
            s.dropFirst().forEach { p.line(to: $0) }
            p.stroke()
        }
    }

    override func mouseDown(with e: NSEvent) { strokes.append([convert(e.locationInWindow, from: nil)]); needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { strokes[strokes.count - 1].append(convert(e.locationInWindow, from: nil)); needsDisplay = true }

    func clear() { strokes = []; needsDisplay = true }

    /// Paths normalised to a unit box, and the box's width/height.
    func normalised() -> (paths: [NSBezierPath], aspect: CGFloat)? {
        let pts = strokes.flatMap { $0 }
        guard pts.count > 2 else { return nil }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let paths = strokes.filter { $0.count > 1 }.map { s -> NSBezierPath in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: (s[0].x - minX) / w, y: (s[0].y - minY) / h))
            s.dropFirst().forEach { p.line(to: NSPoint(x: ($0.x - minX) / w, y: ($0.y - minY) / h)) }
            return p
        }
        return (paths, w / h)
    }

    /// Run the sheet; calls back with the new signature.
    static func create(in window: NSWindow, done: @escaping ([NSBezierPath], CGFloat) -> Void) {
        let pad = SignaturePad(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        let a = NSAlert()
        a.messageText = "Create Signature"
        a.informativeText = "It is kept on this Mac for reuse, under Application Support/TeX Split."
        a.accessoryView = pad
        a.addButton(withTitle: "Done")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Clear")
        a.buttons[2].target = pad
        a.buttons[2].action = #selector(clearAction(_:))
        a.window.initialFirstResponder = pad
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn, let n = pad.normalised() {
                Signatures.save(n.paths, aspect: n.aspect)
                done(n.paths, n.aspect)
            }
        }
    }

    @objc private func clearAction(_ sender: Any?) { clear() }
}
