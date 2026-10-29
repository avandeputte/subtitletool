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
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        guard !observations.isEmpty else { return [] }

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

        let gray: PGSDecoder.OCRPixels? = pixels ?? grayPixels(of: image)
        var lines: [OCRLine] = []
        for row in rows {
            var parts: [String] = []
            var confidence: Float = 0
            var italicVotes = 0
            var votes = 0
            for obs in row.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
                guard let pick = bestCandidate(obs, language: cleanupLanguage) else { continue }
                let t = pick.string.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                parts.append(t)
                confidence = max(confidence, pick.confidence)
                if let g = gray {
                    votes += 1
                    if isItalic(boundingBox: obs.boundingBox, in: g) { italicVotes += 1 }
                }
            }
            guard !parts.isEmpty else { continue }
            lines.append(OCRLine(text: parts.joined(separator: " "),
                                 italic: votes > 0 && italicVotes * 2 > votes,
                                 confidence: confidence))
        }
        return lines
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

    /// Estimates whether a text row is slanted: the horizontal centroid of dark pixels in the top
    /// third of the band is compared with that of the bottom third; a right shift of more than
    /// 0.12 × band height means italic. Tiny or very short bands are never italic.
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
        guard bh >= 12, bw >= 2 * bh else { return false }

        let third: Int = bh / 3
        guard third >= 3 else { return false }
        let topRows: Range<Int> = y0 ..< (y0 + third)
        let bottomRows: Range<Int> = (y1 - third) ..< y1
        let dark: UInt8 = 128

        // Centroid of dark pixels within given rows and columns; nil when too few.
        func centroid(rows: Range<Int>, cols: Range<Int>, minCount: Int) -> Double? {
            var sum: Int = 0
            var n: Int = 0
            for yy in rows {
                let base: Int = yy * p.width
                for xx in cols where p.gray[base + xx] < dark {
                    sum += xx
                    n += 1
                }
            }
            guard n >= minCount else { return nil }
            return Double(sum) / Double(n)
        }

        let cols: Range<Int> = x0 ..< x1
        guard let top = centroid(rows: topRows, cols: cols, minCount: bh),
              let bottom = centroid(rows: bottomRows, cols: cols, minCount: bh) else { return false }
        let shift: Double = top - bottom
        let threshold: Double = 0.12 * Double(bh)
        guard shift > threshold else { return false }

        // Sanity check against lopsided glyph distribution: the same shift must show up in most
        // chunks of the row (chunk width ≈ band height) when there are enough of them.
        var chunkShifts: [Double] = []
        var cx: Int = x0
        while cx + bh <= x1 {
            let range: Range<Int> = cx ..< (cx + bh)
            if let t = centroid(rows: topRows, cols: range, minCount: third),
               let b = centroid(rows: bottomRows, cols: range, minCount: third) {
                chunkShifts.append(t - b)
            }
            cx += bh
        }
        guard chunkShifts.count >= 3 else { return true }
        let sortedShifts = chunkShifts.sorted()
        let median: Double = sortedShifts[sortedShifts.count / 2]
        return median > 0.06 * Double(bh)
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
            lines.append(tokens.map { $0.text }.joined().trimmingCharacters(in: .whitespaces))
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
    private static let leadingDash: NSRegularExpression = rx("^[-\\u2013\\u2014]{1,2}[ \\t]*(?=\\S)")
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
