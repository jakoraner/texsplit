import AppKit

/// The LaTeX side: a plain-text view that never "improves" what is typed
/// (no smart quotes, dashes or spelling replacement), with line numbers and
/// light colouring of commands and comments.
final class SourceEditor {
    let scrollView: NSScrollView
    let textView: NSTextView
    private var colourWork: DispatchWorkItem?

    init() {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }

    var text: String {
        get { textView.string }
        set { textView.string = newValue; recolour() }
    }

    /// 1-based line of the insertion point.
    var currentLine: Int {
        let ns = textView.string as NSString
        let loc = min(textView.selectedRange().location, ns.length)
        return ns.substring(to: loc).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    func line(_ n: Int) -> String {
        let lines = textView.string.components(separatedBy: "\n")
        return n >= 1 && n <= lines.count ? lines[n - 1] : ""
    }

    /// Select line `n`, scroll it to the middle and flash it.
    func reveal(line n: Int) {
        let ns = textView.string as NSString
        var start = 0, current = 1
        while current < n, start < ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { break }
            start = r.location + 1
            current += 1
        }
        let lineRange = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        textView.scrollRangeToVisible(lineRange)
        textView.showFindIndicator(for: NSRange(location: lineRange.location, length: max(0, lineRange.length - 1)))
    }

    func scheduleRecolour() {
        colourWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.recolour() }
        colourWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// Temporary attributes: they colour the view without entering the text or the undo stack.
    func recolour() {
        guard let lm = textView.layoutManager else { return }
        let s = textView.string
        let all = NSRange(location: 0, length: (s as NSString).length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        let rules: [(String, NSColor)] = [
            (#"\\[A-Za-z@]+\*?"#, .systemPurple),
            (#"\$[^$\n]*\$"#, .systemTeal),
            (#"(?<!\\)%.*$"#, .secondaryLabelColor),
        ]
        for (pattern, colour) in rules {
            let re = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            re.enumerateMatches(in: s, range: all) { m, _, _ in
                if let r = m?.range { lm.addTemporaryAttribute(.foregroundColor, value: colour, forCharacterRange: r) }
            }
        }
    }
}

/// Line numbers in the gutter, counted by source line (a wrapped line keeps one number).
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let firstChar = lm.characterIndexForGlyph(at: glyphs.location)
        // Number of the first visible line: newlines before it, plus one.
        var number = 1
        var i = 0
        while i < firstChar {
            let r = ns.range(of: "\n", range: NSRange(location: i, length: firstChar - i))
            if r.location == NSNotFound { break }
            number += 1
            i = r.location + 1
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let inset = tv.textContainerOrigin.y
        let offset = convert(NSPoint.zero, from: tv).y
        var charIndex = firstChar
        let endChar = NSMaxRange(lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        while charIndex <= endChar && charIndex <= ns.length {
            let glyph = lm.glyphIndexForCharacter(at: min(charIndex, max(0, ns.length - 1)))
            var frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if ns.length == 0 { frag = NSRect(x: 0, y: 0, width: 0, height: 16) }
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: frag.minY + inset + offset + 1), withAttributes: attrs)
            let line = ns.lineRange(for: NSRange(location: min(charIndex, ns.length), length: 0))
            let next = NSMaxRange(line)
            if next <= charIndex || next > ns.length { break }
            if next == ns.length && ns.length > 0 && ns.character(at: ns.length - 1) != 10 { break }
            charIndex = next
            number += 1
        }
    }
}
