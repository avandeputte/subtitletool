import Foundation
import Vision
import CoreGraphics

/// Converts subtitle tracks to SRT on this Mac, without any web service:
///  - text formats (ASS/SSA/WebVTT) by stripping styling,
///  - image formats (PGS) by rendering each display set and running Apple Vision OCR.
enum LocalConverter {

    enum Failure: Error, LocalizedError {
        case unsupported(String)
        case noText
        var errorDescription: String? {
            switch self {
            case .unsupported(let k): return "local conversion does not support \(k) yet"
            case .noText: return "OCR did not recognise any text"
            }
        }
    }

    struct Cue {
        var startNs: Int64
        var endNs: Int64
        var text: String
    }

    /// One recognised line of a subtitle bitmap, in reading order.
    struct OCRLine {
        var text: String
        var italic: Bool
        var confidence: Float
    }

    // MARK: - Entry point

    /// Converts an already-demuxed track to SRT bytes.
    static func convertToSRT(track: SubtitleTrack, frames: [SubtitleFrame],
                             progress: ((Double) -> Void)? = nil) async throws -> Data {
        let cues: [Cue]
        switch track.kind {
        case .srt:
            cues = frames.compactMap { f in
                let t = SubtitleWriter.textOf(f.payload).trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : Cue(startNs: f.timestampNs, endNs: f.timestampNs + (f.durationNs ?? 3_000_000_000), text: t)
            }
        case .ass, .ssa:
            cues = frames.compactMap { f in
                let line = SubtitleWriter.textOf(f.payload)
                let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 9 else { return nil }
                let text = assToSRTText(fields[8])
                guard !text.isEmpty else { return nil }
                return Cue(startNs: f.timestampNs, endNs: f.timestampNs + (f.durationNs ?? 3_000_000_000), text: text)
            }
        case .webvtt:
            cues = frames.compactMap { f in
                var body = SubtitleWriter.textOf(f.payload)
                if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
                let text = vttToSRTText(body)
                guard !text.isEmpty else { return nil }
                return Cue(startNs: f.timestampNs, endNs: f.timestampNs + (f.durationNs ?? 3_000_000_000), text: text)
            }
        case .pgs:
            cues = try await ocrPGS(frames: frames, language: track.language, progress: progress)
        default:
            throw Failure.unsupported(track.kind.label)
        }
        return encodeSRT(cues)
    }

    // MARK: - SRT output

    static func encodeSRT(_ input: [Cue]) -> Data {
        var cues = input.sorted { $0.startNs < $1.startNs }
        // Merge cues that share identical timing (ASS often splits styled fragments).
        var merged: [Cue] = []
        for c in cues {
            if var last = merged.last, last.startNs == c.startNs, last.endNs == c.endNs {
                last.text += "\n" + c.text
                merged[merged.count - 1] = last
            } else {
                merged.append(c)
            }
        }
        cues = merged
        var out = ""
        for (i, c) in cues.enumerated() {
            let end = max(c.endNs, c.startNs + 100_000_000)
            out += "\(i + 1)\n\(SubtitleWriter.srtTime(c.startNs)) --> \(SubtitleWriter.srtTime(end))\n\(c.text)\n\n"
        }
        return Data(out.utf8)
    }

    // MARK: - Text formats

    /// ASS dialogue text -> SRT text: keeps italic/bold/underline, drops other override tags.
    static func assToSRTText(_ raw: String) -> String {
        var s = raw
        // Line breaks and hard spaces
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")

        // Translate simple style toggles inside override blocks, then drop the rest of the block.
        var out = ""
        var italic = false, bold = false, underline = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "{", let close = s[i...].firstIndex(of: "}") {
                let block = s[s.index(after: i) ..< close]
                for tag in block.split(separator: "\\") {
                    let t = tag.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("i") && t.count <= 2 { let on = !t.hasSuffix("0"); if on != italic { out += on ? "<i>" : "</i>"; italic = on } }
                    else if t.hasPrefix("b") && t.count <= 4, t.dropFirst().allSatisfy(\.isNumber) { let on = !(t == "b0"); if on != bold { out += on ? "<b>" : "</b>"; bold = on } }
                    else if t.hasPrefix("u") && t.count <= 2 { let on = !t.hasSuffix("0"); if on != underline { out += on ? "<u>" : "</u>"; underline = on } }
                }
                i = s.index(after: close)
                continue
            }
            out.append(ch)
            i = s.index(after: i)
        }
        if italic { out += "</i>" }
        if bold { out += "</b>" }
        if underline { out += "</u>" }
        // Drop drawing commands / empty tags artifacts
        out = out.replacingOccurrences(of: #"<(i|b|u)></\1>"#, with: "", options: .regularExpression)
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                  .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// WebVTT cue payload -> SRT text: keeps <i>/<b>/<u>, strips class/voice/timestamp tags.
    static func vttToSRTText(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: #"</?c(\.[^>]*)?>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<v[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "</v>", with: "")
        s = s.replacingOccurrences(of: #"<\d{2}:\d{2}[:.\d]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</?(ruby|rt|lang)[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - PGS via Vision OCR

    /// OCRs every PGS display set into cues. `language` is the track language ("eng", "fr-CA", …);
    /// nil or "" means unknown (Vision's default languages, English clean-up rules).
    static func ocrPGS(frames: [SubtitleFrame], language: String? = nil,
                       progress: ((Double) -> Void)?) async throws -> [Cue] {
        let state = PGSDecoder.State()
        let sorted = frames.sorted { $0.timestampNs < $1.timestampNs }
        let languages: [String] = visionLanguages(for: language ?? "")
        let cleanupLanguage: String? = cleanupLanguageCode(language)

        var cues: [Cue] = []
        var open: (startNs: Int64, image: CGImage, pixels: PGSDecoder.OCRPixels?, durationNs: Int64?)?
        var processed = 0

        func close(at endNs: Int64) async {
            guard let o = open else { return }
            open = nil
            let lines: [OCRLine] = (try? recognizeLines(o.image, languages: languages,
                                                        cleanupLanguage: cleanupLanguage,
                                                        pixels: o.pixels)) ?? []
            let text: String = finishCueText(lines, language: cleanupLanguage)
            if !text.isEmpty {
                cues.append(Cue(startNs: o.startNs, endNs: max(endNs, o.startNs + 200_000_000), text: text))
            }
        }

        for f in sorted {
            let set = PGSDecoder.decode(frame: f.payload, timestampNs: f.timestampNs, state: state)
            if set.hasObjects, let img = set.image {
                // A new picture replaces the current one.
                await close(at: f.timestampNs)
                open = (f.timestampNs, img, set.ocrPixels, f.durationNs)
            } else {
                await close(at: f.timestampNs)
            }
            processed += 1
            if processed % 10 == 0 { progress?(Double(processed) / Double(max(1, sorted.count))) }
        }
        if let o = open { await close(at: o.startNs + (o.durationNs ?? 3_000_000_000)) }
        progress?(1)
        guard !cues.isEmpty else { throw Failure.noText }
        return cues
    }

    /// Italic tagging (`<i>line</i>` per italic line) followed by the OCR clean-up pass.
    static func finishCueText(_ lines: [OCRLine], language: String?) -> String {
        let tagged: [String] = lines.map { line in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            return line.italic ? "<i>" + t + "</i>" : t
        }
        return OCRCleanup.clean(tagged.joined(separator: "\n"), language: language)
    }

    /// Runs Vision text recognition on one subtitle bitmap and returns the lines joined with "\n"
    /// (plain text, no italic tags; kept for existing callers).
    static func recognize(_ image: CGImage, languages: [String]) throws -> String {
        let lines = try recognizeLines(image, languages: languages, cleanupLanguage: nil, pixels: nil)
        return lines.map { $0.text }.joined(separator: "\n")
    }

    /// Runs Vision text recognition on one subtitle bitmap for a track language ("eng", "fr", nil =
    /// unknown) and returns the cleaned, italic-tagged text, one line per text line.
    static func recognize(_ image: CGImage, language: String? = nil) throws -> String {
        let languages: [String] = visionLanguages(for: language ?? "")
        let code: String? = cleanupLanguageCode(language)
        let lines = try recognizeLines(image, languages: languages, cleanupLanguage: code, pixels: nil)
        return finishCueText(lines, language: code)
    }

    /// Runs Vision on one OCR bitmap. Observations are ordered top-to-bottom, pieces of the same
    /// text row are joined with a space, each row gets the candidate needing the fewest clean-up
    /// fixes, and the slant of the row's ink decides `italic`.
    static func recognizeLines(_ image: CGImage, languages: [String], cleanupLanguage: String? = nil,
                               pixels: PGSDecoder.OCRPixels? = nil) throws -> [OCRLine] {
        // ♪ is not in Vision's character set: hide the notes, put them back on the recognised rows.
        let source: PGSDecoder.OCRPixels? = pixels ?? grayPixels(of: image)
        let notes: MusicNotes.Result? = source.flatMap { MusicNotes.mask($0) }
        let visionImage: CGImage = notes.flatMap { PGSDecoder.makeImage($0.pixels) } ?? image

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cgImage: visionImage, options: [:])
        try handler.perform([request])
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        guard !observations.isEmpty || notes != nil else { return [] }

        // Sort top-to-bottom (Vision's origin is bottom-left), then left-to-right.
        let sorted: [VNRecognizedTextObservation] = observations.sorted { a, b in
            let dy = a.boundingBox.midY - b.boundingBox.midY
            if abs(dy) > min(a.boundingBox.height, b.boundingBox.height) * 0.5 { return dy > 0 }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        // Group observations that share a text row.
        var rows: [[VNRecognizedTextObservation]] = []
        for obs in sorted {
            if let last = rows.last, let ref = last.first {
                let dy = abs(ref.boundingBox.midY - obs.boundingBox.midY)
                if dy <= min(ref.boundingBox.height, obs.boundingBox.height) * 0.5 {
                    rows[rows.count - 1].append(obs)
                    continue
                }
            }
            rows.append([obs])
        }

        // Slant is measured without the upright notes.
        let gray: PGSDecoder.OCRPixels? = notes?.pixels ?? source
        var placed: [(y: Double, line: OCRLine)] = []
        var usedBands = Set<Int>()
        for row in rows {
            var parts: [String] = []
            var confidence: Float = 0
            for obs in row.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
                guard let pick = bestCandidate(obs, language: cleanupLanguage) else { continue }
                let t = pick.string.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                parts.append(t)
                confidence = max(confidence, pick.confidence)
            }
            guard !parts.isEmpty else { continue }
            var text: String = parts.joined(separator: " ")
            // One slant verdict for the whole row.
            let rowBox: CGRect = row.dropFirst().reduce(row[0].boundingBox) { $0.union($1.boundingBox) }
            let rowItalic: Bool = gray.map { isItalic(boundingBox: rowBox, in: $0) } ?? false
            let midY: Double = 1.0 - row.map { Double($0.boundingBox.midY) }.reduce(0, +) / Double(row.count)
            let rowY: Double = midY * Double(visionImage.height)
            if let n = notes, let b = n.bandIndex(forY: rowY), !usedBands.contains(b) {
                usedBands.insert(b)
                text = MusicNotes.decorate(text, band: n.bands[b])
            }
            placed.append((rowY, OCRLine(text: text,
                                         italic: rowItalic,
                                         confidence: confidence)))
        }
        // Rows that held nothing but notes left no text for Vision to find.
        if let n = notes {
            for (i, b) in n.bands.enumerated() where b.notesOnly && !usedBands.contains(i) {
                placed.append((Double(b.y0 + b.y1) / 2, OCRLine(text: String(repeating: "♪", count: b.leadingCount + b.trailingCount), italic: false, confidence: 1)))
            }
        }
        return placed.sorted { $0.y < $1.y }.map { $0.line }
    }

    // MARK: - Re-OCR of an extracted .sup

    /// Reads a `.sup` file into one frame per display set, in the form the MKV demuxer produces.
    static func readSUP(_ url: URL) throws -> [SubtitleFrame] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var frames: [SubtitleFrame] = []
        var current = Data()
        var timestampNs: Int64 = 0
        var i = data.startIndex
        while i + 13 <= data.endIndex {
            guard data[i] == 0x50, data[i + 1] == 0x47 else { throw Failure.unsupported("this .sup file") }
            let pts = UInt64(data[i + 2]) << 24 | UInt64(data[i + 3]) << 16 | UInt64(data[i + 4]) << 8 | UInt64(data[i + 5])
            let type = data[i + 10]
            let size = Int(data[i + 11]) << 8 | Int(data[i + 12])
            let end = i + 13 + size
            guard end <= data.endIndex else { break }
            if current.isEmpty { timestampNs = Int64(pts) * 1_000_000_000 / 90_000 }
            current.append(data[(i + 10) ..< end])
            if type == 0x80 {
                frames.append(SubtitleFrame(timestampNs: timestampNs, durationNs: nil, payload: current))
                current = Data()
            }
            i = end
        }
        return frames
    }

    /// OCRs `<name>.sup` to `<name>.srt` next to it. An existing SRT is only replaced with `force`;
    /// otherwise the result goes to `<name> 2.srt` (or the next free number).
    static func ocrSUPFile(_ url: URL, force: Bool, compareIMDb: String? = nil, log: ((String) -> Void)? = nil,
                           progress: ((Double) -> Void)? = nil) async throws -> URL {
        let stem: String = url.deletingPathExtension().lastPathComponent
        var movie = ""
        if let r = stem.range(of: #"\(\d{4}\)"#, options: .regularExpression) { movie = String(stem[..<r.upperBound]) }
        let info = TimedText.describe(fileName: url.lastPathComponent, movie: movie)
        let tag: String = info.tag
        let cues = try await ocrPGS(frames: try readSUP(url), language: tag, progress: progress)

        let folder = url.deletingLastPathComponent()
        var out = folder.appendingPathComponent(stem + ".srt")
        if !force {
            var n = 2
            while FileManager.default.fileExists(atPath: out.path) {
                out = folder.appendingPathComponent("\(stem) \(n).srt")
                n += 1
            }
        }
        var srt: Data = encodeSRT(cues)
        if let imdbID = compareIMDb {
            if info.forced || info.commentary {
                log?("  comparison skipped: forced and commentary tracks have no comparable file")
            } else {
                do {
                    let compared = try await ReferenceSubtitles.improve(
                        srt: srt, imdbID: imdbID, language: tag, hearingImpaired: info.sdh,
                        credentials: .load(), cache: ReferenceSubtitles.cacheFolder, log: log)
                    srt = compared.srt
                    log?("  " + ReferenceSubtitles.summary(compared.report, cueCount: cues.count))
                } catch {
                    log?("  comparison skipped, OCR result kept: \(error.localizedDescription)")
                }
            }
        }
        try srt.write(to: out, options: .atomic)
        return out
    }

    /// Of the top 3 candidates, the one that needs the fewest clean-up fixes; ties go to confidence.
    static func bestCandidate(_ obs: VNRecognizedTextObservation, language: String?) -> VNRecognizedText? {
        let candidates: [VNRecognizedText] = obs.topCandidates(3)
        guard var best = candidates.first else { return nil }
        let minConfidence: Float = best.confidence * 0.5
        var bestIssues: Int = OCRCleanup.issueCount(best.string, language: language)
        for c in candidates.dropFirst() where c.confidence >= minConfidence {
            let n: Int = OCRCleanup.issueCount(c.string, language: language)
            if n < bestIssues || (n == bestIssues && c.confidence > best.confidence) {
                best = c
                bestIssues = n
            }
        }
        return best
    }

    // MARK: Italic detection

    /// Whether a text row is slanted. Tiny or very short bands are never italic.
    static func isItalic(boundingBox box: CGRect, in p: PGSDecoder.OCRPixels) -> Bool {
        guard p.width > 0, p.height > 0, p.gray.count == p.width * p.height else { return false }
        let w = Double(p.width), h = Double(p.height)
        var x0 = Int((Double(box.minX) * w).rounded(.down))
        var x1 = Int((Double(box.maxX) * w).rounded(.up))
        var y0 = Int(((1.0 - Double(box.maxY)) * h).rounded(.down))
        var y1 = Int(((1.0 - Double(box.minY)) * h).rounded(.up))
        x0 = max(0, min(p.width, x0)); x1 = max(0, min(p.width, x1))
        y0 = max(0, min(p.height, y0)); y1 = max(0, min(p.height, y1))
        let bw: Int = x1 - x0
        let bh: Int = y1 - y0
        guard bh >= 12, bw >= bh else { return false }

        return MusicNotes.isSlanted(p, x0: x0, x1: x1, y0: y0, y1: y1)
    }

    /// Grayscale pixels of any CGImage (top row first), used when the decoder did not supply them.
    static func grayPixels(of image: CGImage) -> PGSDecoder.OCRPixels? {
        let w: Int = image.width
        let h: Int = image.height
        guard w > 0, h > 0, w * h < 64_000_000 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let stride: Int = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var out = [UInt8](repeating: 255, count: w * h)
        for yy in 0 ..< h {
            let rowBase: Int = yy * stride
            for xx in 0 ..< w {
                out[yy * w + xx] = ptr[rowBase + xx]
            }
        }
        return PGSDecoder.OCRPixels(width: w, height: h, gray: out, scale: 1)
    }

    // MARK: Languages

    /// Base language for the clean-up rules ("en", "fr", …) or nil when unknown.
    static func cleanupLanguageCode(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return nil }
        let short = Naming.shortCode(code)
        let base = short.split(separator: "-").first.map(String.init) ?? short
        if base.isEmpty || base == "und" { return nil }
        return base.lowercased()
    }

    /// Picks Vision recognition languages for a track language ("eng", "fr", "pt-BR", ...).
    /// An empty or unknown code returns [] (Vision's default).
    static func visionLanguages(for code: String) -> [String] {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let short = Naming.shortCode(trimmed)
        let base = short.split(separator: "-").first.map(String.init) ?? short
        guard !base.isEmpty, base != "und" else { return [] }
        let preferred: [String: String] = [
            "en": "en-US", "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT", "pt": "pt-BR",
            "nl": "nl-NL", "sv": "sv-SE", "da": "da-DK", "no": "nb-NO", "nb": "nb-NO", "fi": "fi-FI",
            "pl": "pl-PL", "cs": "cs-CZ", "tr": "tr-TR", "ru": "ru-RU", "uk": "uk-UA", "zh": "zh-Hans",
            "ja": "ja-JP", "ko": "ko-KR", "ar": "ar-SA", "th": "th-TH", "vi": "vi-VT", "id": "id-ID",
            "ms": "ms-MY", "ro": "ro-RO", "hu": "hu-HU", "el": "el-GR", "he": "he-IL", "hr": "hr-HR",
            "sk": "sk-SK", "sl": "sl-SI", "bg": "bg-BG", "ca": "ca-ES", "gl": "gl-ES", "eu": "eu-ES",
        ]
        let supported: Set<String> = {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            return Set((try? req.supportedRecognitionLanguages()) ?? [])
        }()
        var picks: [String] = []
        if let p = preferred[base], supported.contains(p) { picks.append(p) }
        if base == "zh", supported.contains("zh-Hant") { picks.append("zh-Hant") }
        if picks.isEmpty, let any = supported.first(where: { $0.lowercased().hasPrefix(base.lowercased()) }) { picks.append(any) }
        if base != "en", supported.contains("en-US") { picks.append("en-US") }   // fallback for names/latin text
        return picks
    }
}

// MARK: - OCR clean-up

/// Text fixes for Vision OCR output of subtitle bitmaps. Pure string functions, so they can be
/// unit-tested. `<i>`, `<b>` and `<u>` tags are preserved untouched.
enum OCRCleanup {

    /// Cleans one cue (lines separated by "\n"). `language` is a base code ("en", "fr") or nil
    /// (unknown, treated as English for the I/l fixes).
    static func clean(_ text: String, language: String?) -> String {
        let english: Bool = isEnglish(language)
        var lines: [String] = []
        let rawLines: [String] = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for rawLine in rawLines {
            var tokens: [Token] = tokenize(rawLine)
            for i in tokens.indices where !tokens[i].isTag {
                tokens[i].text = cleanRun(tokens[i].text, english: english)
            }
            // Leading dash normalisation on the first text run of the line.
            if let fi = tokens.firstIndex(where: { !$0.isTag }) {
                var t = tokens[fi].text
                t = replace(t, leadingSpace, with: "")
                t = replace(t, leadingDash, with: "- ")
                tokens[fi].text = t
            }
            if let li = tokens.lastIndex(where: { !$0.isTag }) {
                tokens[li].text = replace(tokens[li].text, trailingSpace, with: "")
            }
            let content: String = tokens.filter { !$0.isTag }.map { $0.text }.joined()
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append(restoreNotes(tokens.map { $0.text }.joined().trimmingCharacters(in: .whitespaces),
                                      english: english))
        }
        return fixQuotes(lines.joined(separator: "\n"))
    }

    /// How many clean-up fixes would fire on `text` (used to rank OCR candidates).
    static func issueCount(_ text: String, language: String?) -> Int {
        let english: Bool = isEnglish(language)
        var n: Int = 0
        for token in tokenize(text) where !token.isTag {
            let s: String = token.text
            if english {
                for fix in englishFixes { n += count(s, fix.regex) }
            }
            n += s.filter { $0 == "…" }.count
            n += count(s, spacedDots)
            n += count(s, manyDots)
            n += count(s, twoDots)
            n += midWordCapitalCount(s)
            n += s.components(separatedBy: "''").count - 1
            n += s.filter { $0 == "`" }.count
        }
        return n
    }

    // MARK: ♪ misreads

    private static let noteSymbols: Set<String> = ["&", "¿", "§", ">", "<", "›", "«", "»", "•", "~", "^", "б"]
    private static let noteLetters: Set<String> = ["s", "S", "f", "j", "d", "8"]
    /// Real words: only trusted at the start of a line whose end is also a misread note.
    private static let noteWords: Set<String> = ["of", "os", "as"]

    /// Safety net for notes the bitmap detector missed: a line with a misread ♪ at both ends, or at
    /// one end with a real ♪ at the other, gets real notes.
    static func restoreNotes(_ line: String, english: Bool) -> String {
        var body = Substring(line)
        var open = "", close = ""
        while body.hasPrefix("<"), let r = body.range(of: #"^</?[ibu]>"#, options: .regularExpression) {
            open += body[r]
            body = body[r.upperBound...]
        }
        while body.hasSuffix(">"), let r = body.range(of: #"</?[ibu]>$"#, options: .regularExpression) {
            close = body[r] + close
            body = body[..<r.lowerBound]
        }
        var dash = ""
        if body.hasPrefix("- ") { dash = "- "; body = body.dropFirst(2) }
        // A pair of notes before a sound description reads as "dr [".
        if english, body.hasPrefix("dr [") || body.hasPrefix("d [") {
            return open + dash + "♪♪ " + body[body.firstIndex(of: "[")!...] + close
        }
        // A note right after a speaker label: "[company] & Alex got better".
        if let r = body.range(of: #"^\[[^\]]+\] "#, options: .regularExpression) {
            let rest = body[r.upperBound...]
            if let space = rest.firstIndex(of: " "), noteSymbols.contains(String(rest[..<space])) {
                let fixed = String(body[..<r.upperBound]) + "♪" + String(rest[space...])
                return open + dash + fixed + close
            }
        }
        var words: [String] = body.components(separatedBy: " ")
        guard words.count >= 3, let first = words.first, let last = words.last else { return line }

        func misread(_ w: String) -> Bool { noteSymbols.contains(w) || (english && noteLetters.contains(w)) }
        let lastMisread: Bool = misread(last)
        let firstMisread: Bool = misread(first) || (english && lastMisread && noteWords.contains(first))
        guard firstMisread || lastMisread,
              firstMisread || first == "♪", lastMisread || last == "♪" else { return line }
        words[0] = "♪"
        words[words.count - 1] = "♪"
        return open + dash + words.joined(separator: " ") + close
    }

    // MARK: Internals

    struct Token {
        var isTag: Bool
        var text: String
    }

    private struct Fix {
        let regex: NSRegularExpression
        let template: String
    }

    static func isEnglish(_ language: String?) -> Bool {
        guard let l = language?.lowercased(), !l.isEmpty else { return true }
        let base = l.split(separator: "-").first.map(String.init) ?? l
        return base == "en" || base == "eng" || base == "und"
    }

    /// Splits text into `<i>`/`<b>`/`<u>` tags and text runs. Joining the tokens gives the input back.
    static func tokenize(_ s: String) -> [Token] {
        let ns = s as NSString
        var tokens: [Token] = []
        var last: Int = 0
        for m in tagRegex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                tokens.append(Token(isTag: false, text: ns.substring(with: NSRange(location: last, length: m.range.location - last))))
            }
            tokens.append(Token(isTag: true, text: ns.substring(with: m.range)))
            last = m.range.location + m.range.length
        }
        if last < ns.length || tokens.isEmpty {
            tokens.append(Token(isTag: false, text: ns.substring(from: last)))
        }
        return tokens
    }

    /// Character-level fixes for one run of text (no tags inside).
    private static func cleanRun(_ input: String, english: Bool) -> String {
        var s: String = input
        if english {
            for fix in englishFixes { s = replace(s, fix.regex, with: fix.template) }
        }
        // Ellipses
        s = s.replacingOccurrences(of: "…", with: "...")
        s = replace(s, spacedDots, with: "...")
        s = replace(s, manyDots, with: "...")
        s = replace(s, twoDots, with: "...")
        // Odd capitals inside words
        s = fixMidWordCapitals(s)
        // Quote characters
        s = s.replacingOccurrences(of: "''", with: "\"")
        s = s.replacingOccurrences(of: "`", with: "'")
        // Spacing
        s = replace(s, multiSpace, with: " ")
        s = replace(s, spaceBeforeCommaDot, with: "")
        if english { s = replace(s, spaceBeforePunct, with: "") }
        s = replace(s, spaceAfterOpen, with: "(")
        s = replace(s, spaceBeforeClose, with: ")")
        s = replace(s, manyDots, with: "...")
        return s
    }

    // Regular expressions (built once; an invalid pattern degrades to "never matches").
    private static func rx(_ pattern: String) -> NSRegularExpression {
        if let r = try? NSRegularExpression(pattern: pattern, options: []) { return r }
        return try! NSRegularExpression(pattern: "(?!)", options: [])
    }

    private static let tagRegex: NSRegularExpression = rx("</?[ibu]>")
    private static let leadingSpace: NSRegularExpression = rx("^[ \\t]+")
    private static let trailingSpace: NSRegularExpression = rx("[ \\t]+$")
    private static let leadingDash: NSRegularExpression = rx("^(?:[-\\u2013\\u2014][ \\t]*){1,2}(?=\\S)")
    private static let spacedDots: NSRegularExpression = rx("\\.(?:[ \\t]+\\.){2,}")
    private static let manyDots: NSRegularExpression = rx("\\.{4,}")
    private static let twoDots: NSRegularExpression = rx("(?<!\\.)\\.\\.(?!\\.)")
    private static let multiSpace: NSRegularExpression = rx("[ \\t]{2,}")
    private static let spaceBeforeCommaDot: NSRegularExpression = rx("[ \\t]+(?=[,.])")
    private static let spaceBeforePunct: NSRegularExpression = rx("[ \\t]+(?=[!?:;])")
    private static let spaceAfterOpen: NSRegularExpression = rx("\\([ \\t]+")
    private static let spaceBeforeClose: NSRegularExpression = rx("[ \\t]+\\)")
    private static let wordRegex: NSRegularExpression = rx("\\p{L}{3,}")

    /// English-only fixes for capital I misread as l, | or 1. Order matters.
    private static let englishFixes: [Fix] = [
        // standalone l, and l'm / l'll / l've / l'd  -> I …
        Fix(regex: rx("\\bl\\b"), template: "I"),
        // lt / lts / lt's at word start -> It …
        Fix(regex: rx("\\blt(s|'s)?\\b"), template: "It$1"),
        // 'Il -> 'll  (I'Il -> I'll, you'Il -> you'll)
        Fix(regex: rx("'Il\\b"), template: "'ll"),
        // standalone Il -> I'll
        Fix(regex: rx("(?<!')\\bIl\\b"), template: "I'll"),
        // | -> I unless next to a digit
        Fix(regex: rx("(?<!\\d)\\|(?!\\d)"), template: "I"),
        // 1'm / 1'll / 1've / 1'd -> I'm …
        Fix(regex: rx("(?<![\\p{L}\\p{N}])1(?='(m|ll|ve|d)\\b)"), template: "I"),
        // Pronoun forms that lost the apostrophe or start with l
        Fix(regex: rx("\\b(?:Im|lm|lim)\\b"), template: "I'm"),
        Fix(regex: rx("\\blam\\b"), template: "I am"),
        Fix(regex: rx("\\b(?:lve|Ive)\\b"), template: "I've"),
        Fix(regex: rx("\\b(?:ld|Id)\\b"), template: "I'd"),
        Fix(regex: rx("\\blll\\b"), template: "I'll"),
        Fix(regex: rx("\\blf\\b"), template: "If"),
        Fix(regex: rx("\\bWeill\\b"), template: "We'll"),
        Fix(regex: rx("\\bMil\\b"), template: "I'll"),
        // "1" before a lowercase word is the pronoun, unless it counts something ("1 mile", "$1 bill")
        Fix(regex: rx("(?<![\\d$.,:])(?<!at )\\b1 (?=[a-z])(?!(?:pm|st|nd|rd|th|of|in|out|or|and|to|more|mile|miles|day|week|month|year|hour|minute|second|inch|foot|yard|acre|percent|dollar|cent|buck|million|billion|thousand|hundred)\\b)"), template: "I "),
        Fix(regex: rx("\"(?=cause\\b)"), template: "'"),
        // Contractions that lost the apostrophe ("lets" is a real word and stays)
        Fix(regex: rx("\\b([Cc])ant\\b"), template: "$1an't"),
        Fix(regex: rx("\\b([Dd])ont\\b"), template: "$1on't"),
        Fix(regex: rx("\\b([Ww])ont\\b"), template: "$1on't"),
        Fix(regex: rx("\\b([Aa])int\\b"), template: "$1in't"),
        Fix(regex: rx("\\b([Ii])snt\\b"), template: "$1sn't"),
        Fix(regex: rx("\\b([Dd])idnt\\b"), template: "$1idn't"),
        Fix(regex: rx("\\b([Yy])oure\\b"), template: "$1ou're"),
        Fix(regex: rx("\\b([Tt])heyre\\b"), template: "$1hey're"),
        Fix(regex: rx("\\b([Ww])hats\\b"), template: "$1hat's"),
        Fix(regex: rx("\\b([Tt])hats\\b"), template: "$1hat's"),
        // Smaller misreads: it'il, 1am (not "at 1am"), tellas, a bullet in mid-sentence
        Fix(regex: rx("(?<=\\p{L})'il\\b"), template: "'ll"),
        Fix(regex: rx("(?<![\\d:])(?<!at )\\b1am\\b"), template: "I am"),
        Fix(regex: rx("\\b([Tt])ellas\\b"), template: "fellas"),
        Fix(regex: rx("(?<=\\p{L}) • (?=\\p{L})"), template: " "),
        // A lone slash, or "1 am" opening a line, is the pronoun
        Fix(regex: rx("(?<!\\S)/(?=\\s)"), template: "I"),
        Fix(regex: rx("(?<!\\S)/(?=[a-z])"), template: "I "),
        Fix(regex: rx("^((?:-\\s*)?(?:♪\\s*)?)1 am\\b"), template: "$1I am"),
    ]

    private static func replace(_ s: String, _ regex: NSRegularExpression, with template: String) -> String {
        let ns = s as NSString
        return regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
    }

    private static func count(_ s: String, _ regex: NSRegularExpression) -> Int {
        let ns = s as NSString
        return regex.numberOfMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
    }

    // MARK: Mid-word capitals

    private static let mixedCaseAllowlist: Set<String> = [
        "McDonald", "MacGregor", "iPhone", "DeVito", "LaRue", "iPad", "YouTube", "PlayStation",
    ]

    /// True for words like "BOo" or "heLLo": 3+ letters, not all caps, an uppercase letter after
    /// position 0 that follows a lowercase letter. Known mixed-case names and Mc-names are kept.
    static func needsCapitalFix(_ word: String) -> Bool {
        let chars: [Character] = Array(word)
        guard chars.count >= 3 else { return false }
        if mixedCaseAllowlist.contains(word) { return false }
        if word.hasPrefix("Mc"), chars[2].isUppercase { return false }
        if chars.allSatisfy({ $0.isUppercase }) { return false }
        for i in 1 ..< chars.count where chars[i].isUppercase && chars[i - 1].isLowercase {
            return true
        }
        return false
    }

    private static func lowercaseTail(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first) + String(word.dropFirst()).lowercased()
    }

    private static func fixMidWordCapitals(_ s: String) -> String {
        let ns = s as NSString
        let matches = wordRegex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out: String = ""
        var last: Int = 0
        for m in matches {
            let word: String = ns.substring(with: m.range)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += needsCapitalFix(word) ? lowercaseTail(word) : word
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func midWordCapitalCount(_ s: String) -> Int {
        let ns = s as NSString
        var n: Int = 0
        for m in wordRegex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            if needsCapitalFix(ns.substring(with: m.range)) { n += 1 }
        }
        return n
    }

    // MARK: Quotes (per cue)

    /// Curly double quotes without a partner at the start or end of the cue become straight quotes;
    /// balanced ones are left alone. Straight quotes are never added or removed.
    private static func fixQuotes(_ cue: String) -> String {
        var tokens: [Token] = tokenize(cue)
        let textIndices: [Int] = tokens.indices.filter {
            !tokens[$0].isTag && !tokens[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let first = textIndices.first, let last = textIndices.last else { return cue }
        let allText: String = tokens.filter { !$0.isTag }.map { $0.text }.joined()
        let curly: Int = allText.filter { $0 == "\u{201C}" || $0 == "\u{201D}" }.count
        if curly % 2 == 1 {
            let f: String = tokens[first].text
            let l: String = tokens[last].text
            if let c = f.first, c == "\u{201C}" || c == "\u{201D}" {
                tokens[first].text = "\"" + String(f.dropFirst())
            } else if let c = l.last, c == "\u{201C}" || c == "\u{201D}" {
                tokens[last].text = String(l.dropLast()) + "\""
            }
        }
        return tokens.map { $0.text }.joined()
    }
}
