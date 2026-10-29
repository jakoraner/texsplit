import Foundation

/// One typeset record: where on a page some material sits, and the source line
/// that produced it. Coordinates are PDF points from the page's TOP-left corner.
struct SyncRecord {
    let x: Double
    let y: Double
    let tag: Int
    let line: Int
}

/// A parsed `.synctex.gz`, the same reading as `scripts/pdf_review.py`:
/// 65781.76 scaled points per PDF point, origin at the top-left of the page.
final class SyncTeX {
    static let spPerPt = 65781.76

    private(set) var inputs: [Int: String] = [:]
    /// 1-based page -> records on that page
    private(set) var pages: [Int: [SyncRecord]] = [:]

    init?(url: URL) {
        guard let text = SyncTeX.gunzip(url) else { return nil }
        var unit = 1.0, xOff = 0.0, yOff = 0.0
        var inContent = false
        var page: Int?
        text.enumerateLines { raw, _ in
            let line = Substring(raw)
            // Input records also appear inside Content, each time TeX opens a file.
            if line.hasPrefix("Input:") {
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, let tag = Int(parts[1]), !parts[2].isEmpty {
                    self.inputs[tag] = String(parts[2])
                }
                return
            }
            if !inContent {
                if line.hasPrefix("Unit:") { unit = Double(line.dropFirst(5)) ?? 1 }
                else if line.hasPrefix("X Offset:") { xOff = Double(line.dropFirst(9)) ?? 0 }
                else if line.hasPrefix("Y Offset:") { yOff = Double(line.dropFirst(9)) ?? 0 }
                else if line.hasPrefix("Content:") { inContent = true }
                return
            }
            if line.hasPrefix("{") { page = Int(line.dropFirst()); return }
            if line.hasPrefix("}") { page = nil; return }
            guard let p = page, let rec = SyncTeX.record(line, unit: unit, xOff: xOff, yOff: yOff) else { return }
            self.pages[p, default: []].append(rec)
        }
    }

    /// `[(hvxkg$]?tag,line:x,y...`
    private static func record(_ s: Substring, unit: Double, xOff: Double, yOff: Double) -> SyncRecord? {
        var body = s
        if let c = body.first, !c.isNumber {
            guard "[(hvxkg$".contains(c) else { return nil }
            body = body.dropFirst()
        }
        let halves = body.split(separator: ":", maxSplits: 2)
        guard halves.count >= 2 else { return nil }
        let tl = halves[0].split(separator: ","), xy = halves[1].split(separator: ",")
        guard tl.count >= 2, xy.count >= 2,
              let tag = Int(tl[0]), let ln = Int(tl[1]),
              let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
        return SyncRecord(x: (x * unit + xOff) / spPerPt, y: (y * unit + yOff) / spPerPt, tag: tag, line: ln)
    }

    private static func gunzip(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Does SyncTeX input `path` refer to source file `rel` (e.g. `Chapters/05_Methods.tex`)?
    private func matches(_ path: String, _ rel: String) -> Bool {
        let clean = path.replacingOccurrences(of: "/./", with: "/")
        return clean == rel || clean == "./" + rel || clean.hasSuffix("/" + rel)
    }

    /// PDF -> source: the line whose typeset material is closest to (x, y) on `page`.
    /// Vertical distance is weighted 3x, as in pdf_review.py, so the right baseline wins.
    func source(page: Int, x: Double, y: Double) -> (path: String, line: Int)? {
        guard let recs = pages[page], !recs.isEmpty else { return nil }
        var best: SyncRecord?
        var bestD = Double.infinity
        // Tectonic's bundled files carry tags with no file name; only real sources count.
        for r in recs where r.line > 0 && inputs[r.tag] != nil {
            let dx = r.x - x, dy = (r.y - y) * 3
            let d = dx * dx + dy * dy
            if d < bestD { bestD = d; best = r }
        }
        guard let b = best, let path = inputs[b.tag] else { return nil }
        return (path, b.line)
    }

    /// Source -> PDF: first typeset position of `line` in `rel`, or of the nearest
    /// line that produced output (blank and comment lines produce none).
    func position(rel: String, line: Int) -> (page: Int, x: Double, y: Double)? {
        let tags = Set(inputs.filter { matches($0.value, rel) }.keys)
        guard !tags.isEmpty else { return nil }
        var best: (page: Int, rec: SyncRecord)?
        var bestGap = Int.max
        for p in pages.keys.sorted() {
            for r in pages[p]! where tags.contains(r.tag) && r.line > 0 {
                let gap = abs(r.line - line) * 2 + (r.line < line ? 1 : 0)
                if gap < bestGap { bestGap = gap; best = (p, r) }
            }
            if bestGap == 0 { break }
        }
        guard let b = best else { return nil }
        return (b.page, b.rec.x, b.rec.y)
    }
}
