import Foundation

struct BuildResult {
    let ok: Bool
    let seconds: Double
    let pdf: URL
    let synctex: URL
    let message: String
    /// First LaTeX error, if tectonic reported one with a location.
    let errorFile: String?
    let errorLine: Int?
}

/// Compiles the chapter a window shows, the way `scripts/pdf_review.py build`
/// compiles the thesis: a scratch copy of `thesis/`, biblatex switched to the
/// bibtex backend in that copy only, `tectonic --synctex`. A chapter window
/// builds a wrapper of `main.tex` in which every other chapter `\input` is
/// commented out (about 15 s instead of 52 s for the whole thesis); references
/// into other chapters then show as ??. The tracked source is never touched.
final class Builder {
    let thesisRoot: URL      // folder that holds main.tex
    let rel: String          // the window's file, relative to thesisRoot
    let buildDir: URL
    let jobName: String      // "main" or "only-05_Methods"

    init(thesisRoot: URL, rel: String) {
        self.thesisRoot = thesisRoot
        self.rel = rel
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Stable across launches (String.hashValue is seeded per process): FNV-1a.
        let key = String(thesisRoot.path.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }, radix: 16)
        buildDir = caches.appendingPathComponent("TeXSplit/\(key)", isDirectory: true)
        let main = (try? String(contentsOf: thesisRoot.appendingPathComponent("main.tex"), encoding: .utf8)) ?? ""
        let stem = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".tex", with: "")
        // Only files main.tex inputs directly can be built alone; anything else
        // (Setup/, main.tex itself, sub-inputs) builds the whole thesis.
        let alone = rel.hasPrefix("Chapters/") || rel.hasPrefix("Backmatter/") || rel.hasPrefix("Frontmatter/")
        jobName = alone && main.contains("\\input{\(rel)}") ? "only-\(stem)" : "main"
    }

    var pdfURL: URL { buildDir.appendingPathComponent("\(jobName).pdf") }
    var synctexURL: URL { buildDir.appendingPathComponent("\(jobName).synctex.gz") }

    /// `text`: the editor's current text, compiled in place of the file on disk (which
    /// stays untouched until you save). `live`: one TeX pass reusing the last run's
    /// .aux and .toc, about 4 s instead of 9; references to labels added since the last
    /// full build may show ?? until the next save.
    func build(text: String? = nil, live: Bool = false) -> BuildResult {
        let start = Date()
        let fm = FileManager.default
        if let free = Builder.freeSpace(), free < 300_000_000 {
            return fail(start, "Disk almost full (\(free / 1_000_000) MB free): preview paused")
        }
        try? fm.createDirectory(at: buildDir, withIntermediateDirectories: true)

        if let err = prepare(buildDir) { return fail(start, err) }
        if let text {
            try? text.write(to: buildDir.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }

        if jobName != "main" {
            let seed = Seed(aux: fullDir.appendingPathComponent("main.aux"), source: thesisRoot.appendingPathComponent(rel))
            try? (seed?.labels ?? "").write(to: buildDir.appendingPathComponent("texsplit-labels.tex"), atomically: true, encoding: .utf8)
            let main = (try? String(contentsOf: buildDir.appendingPathComponent("main.tex"), encoding: .utf8)) ?? ""
            let wrapped = main.components(separatedBy: "\n").map { line -> String in
                guard let r = line.range(of: #"\\input\{(Chapters|Backmatter|Frontmatter)/[^}]+\}"#, options: .regularExpression)
                else { return line }
                guard line[r].contains("{\(rel)}") else { return "%" + line }
                // Number the chapter and its pages as in the whole thesis.
                return (seed?.counters ?? "") + line
            }.joined(separator: "\n")
            .replacingOccurrences(of: "\\begin{document}",
                                  with: "\\makeatletter\\input{texsplit-labels.tex}\\makeatother\n\\begin{document}", options: [], range: nil)
            // Live passes leave out what only the full build needs: the contents and
            // the lists of figures and tables before the chapter, the bibliography after it.
            // The chapter's own pages are numbered by \setcounter{page} just before it.
            let live = live && fm.fileExists(atPath: buildDir.appendingPathComponent("\(jobName).aux").path)
            let text = live ? wrapped.replacingOccurrences(of: #"\\(tableofcontents|listoffigures|listoftables)\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\\printbibliography(\[[^\]]*\])?"#, with: "", options: .regularExpression) : wrapped
            try? text.write(to: buildDir.appendingPathComponent("\(jobName).tex"), atomically: true, encoding: .utf8)
        }

        guard let tectonic = Builder.findTool("tectonic") else {
            return fail(start, "tectonic not found (brew install tectonic)")
        }
        let canBeQuick = live && fm.fileExists(atPath: buildDir.appendingPathComponent("\(jobName).aux").path)
        let tex = run(tectonic, ["-k"] + (canBeQuick ? ["-r", "0"] : []) + ["--synctex", "\(jobName).tex"], cwd: buildDir)
        let secs = Date().timeIntervalSince(start)
        if tex.status != 0 {
            let all = tex.err + "\n" + tex.out
            let pattern = #"error: (.+?\.tex):(\d+): (.*)"#
            if let r = all.range(of: pattern, options: .regularExpression) {
                let hit = String(all[r])
                let re = try! NSRegularExpression(pattern: pattern)
                if let m = re.firstMatch(in: hit, range: NSRange(hit.startIndex..., in: hit)) {
                    let f = (hit as NSString).substring(with: m.range(at: 1))
                    let l = Int((hit as NSString).substring(with: m.range(at: 2))) ?? 0
                    let msg = (hit as NSString).substring(with: m.range(at: 3))
                    return BuildResult(ok: false, seconds: secs, pdf: pdfURL, synctex: synctexURL,
                                       message: "\(f):\(l): \(msg)", errorFile: f, errorLine: l)
                }
            }
            let last = all.split(separator: "\n").last(where: { $0.lowercased().contains("error") }) ?? "build failed"
            return BuildResult(ok: false, seconds: secs, pdf: pdfURL, synctex: synctexURL,
                               message: String(last), errorFile: nil, errorLine: nil)
        }
        return BuildResult(ok: true, seconds: secs, pdf: pdfURL, synctex: synctexURL,
                           message: String(format: canBeQuick ? "Live preview · %.1f s" : "Built in %.1f s", secs),
                           errorFile: nil, errorLine: nil)
    }


    /// Copy the thesis into `dir` and switch biblatex to the bibtex backend there.
    private func prepare(_ dir: URL) -> String? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Build outputs at the top of the copy survive --delete; the sources (main.tex) are copied.
        let keep = ["/only-*", "/texsplit-*", "/*.pdf", "/*.aux", "/*.synctex.gz", "/*.log", "/*.toc", "/*.lof",
                    "/*.lot", "/*.out", "/*.bbl", "/*.blg", "/*.bcf", "/*.run.xml"]
        let sync = run("/usr/bin/rsync", ["-a", "--delete"] + keep.flatMap { ["--exclude", $0] }
                                          + [thesisRoot.path + "/", dir.path + "/"], cwd: dir)
        guard sync.status == 0 else { return "copy failed: \(sync.err)" }
        let preamble = dir.appendingPathComponent("Setup/Preamble.tex")
        if let text = try? String(contentsOf: preamble, encoding: .utf8), text.contains("backend=biber") {
            try? text.replacingOccurrences(of: "backend=biber", with: "backend=bibtex")
                .write(to: preamble, atomically: true, encoding: .utf8)
        }
        return nil
    }

    /// The whole thesis, built once in its own folder; chapter builds take their
    /// chapter number, first page and every other chapter's labels from its main.aux.
    var fullDir: URL { buildDir.deletingLastPathComponent().appendingPathComponent(buildDir.lastPathComponent + "-full") }
    var fullAuxDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fullDir.appendingPathComponent("main.aux").path))?[.modificationDate] as? Date
    }

    func buildFull() -> Bool {
        guard prepare(fullDir) == nil, let tectonic = Builder.findTool("tectonic") else { return false }
        return run(tectonic, ["-k", "--synctex", "main.tex"], cwd: fullDir).status == 0
    }

    private func fail(_ start: Date, _ msg: String) -> BuildResult {
        BuildResult(ok: false, seconds: Date().timeIntervalSince(start), pdf: pdfURL, synctex: synctexURL,
                    message: msg, errorFile: nil, errorLine: nil)
    }

    static func freeSpace() -> Int64? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    static func findTool(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/Library/TeX/texbin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ tool: String, _ args: [String], cwd: URL) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error)") }
        // Read both pipes concurrently so a chatty build cannot fill one and stall.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

/// What a chapter build borrows from the full build's main.aux.
struct Seed {
    let counters: String   // \setcounter lines placed just before the chapter's \input
    let labels: String     // \newlabel lines of every OTHER file

    init?(aux: URL, source: URL) {
        guard let auxText = try? String(contentsOf: aux, encoding: .utf8),
              let src = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        // Labels the open file defines come from the live build, not the seed.
        let code = src.components(separatedBy: "\n").map { line -> String in
            guard let r = line.range(of: #"(?<!\\)%"#, options: .regularExpression) else { return line }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
        let own = Set(Seed.matches(#"\\label\{([^}]+)\}"#, in: code))
        labels = auxText.components(separatedBy: "\n").filter { line in
            guard line.hasPrefix("\\newlabel{"), let name = Seed.matches(#"^\\newlabel\{([^}]+)\}"#, in: line).first else { return false }
            let base = name.hasSuffix("@cref") ? String(name.dropLast(5)) : name
            return !own.contains(base)
        }.joined(separator: "\n") + "\n"

        // The chapter's number and first page: its first \label after \chapter, looked up in the full build.
        var counters = ""
        if let ch = code.range(of: #"\\chapter\*?[\[{]"#, options: .regularExpression),
           let first = Seed.matches(#"\\label\{([^}]+)\}"#, in: String(code[ch.lowerBound...])).first,
           let entry = auxText.components(separatedBy: "\n").first(where: { $0.hasPrefix("\\newlabel{\(first)}{{") }) {
            let fields = Seed.matches(#"\{([^{}]*)\}"#, in: String(entry.dropFirst("\\newlabel{\(first)}".count)))
            if fields.count >= 2 {
                let number = fields[0], page = fields[1]
                let n = Int(number) ?? (number.count == 1 ? Int(number.unicodeScalars.first!.value) - 64 : 0)
                if n > 0 { counters += "\\setcounter{chapter}{\(n - 1)}" }
                if let p = Int(page) { counters += "\\setcounter{page}{\(p)}" }
                if !counters.isEmpty { counters += "%\n" }
            }
        }
        self.counters = counters
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
