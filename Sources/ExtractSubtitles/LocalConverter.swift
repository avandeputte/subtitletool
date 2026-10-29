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

    static func ocrPGS(frames: [SubtitleFrame], language: String,
                       progress: ((Double) -> Void)?) async throws -> [Cue] {
        let state = PGSDecoder.State()
        let sorted = frames.sorted { $0.timestampNs < $1.timestampNs }
        let languages = visionLanguages(for: language)

        var cues: [Cue] = []
        var open: (startNs: Int64, image: CGImage, durationNs: Int64?)?
        var processed = 0

        func close(at endNs: Int64) async {
            guard let o = open else { return }
            open = nil
            let text = (try? recognize(o.image, languages: languages)) ?? ""
            if !text.isEmpty {
                cues.append(Cue(startNs: o.startNs, endNs: max(endNs, o.startNs + 200_000_000), text: text))
            }
        }

        for f in sorted {
            let set = PGSDecoder.decode(frame: f.payload, timestampNs: f.timestampNs, state: state)
            if set.hasObjects, let img = set.image {
                // A new picture replaces the current one.
                await close(at: f.timestampNs)
                open = (f.timestampNs, img, f.durationNs)
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

    /// Runs Vision text recognition on one subtitle bitmap and returns the lines joined with "\n".
    static func recognize(_ image: CGImage, languages: [String]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let obs = request.results ?? []
        // Sort top-to-bottom (Vision's origin is bottom-left), then left-to-right.
        let lines = obs
            .sorted { a, b in
                let dy = a.boundingBox.midY - b.boundingBox.midY
                if abs(dy) > min(a.boundingBox.height, b.boundingBox.height) * 0.5 { return dy > 0 }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    /// Picks Vision recognition languages for a track language ("eng", "fr", "pt-BR", ...).
    static func visionLanguages(for code: String) -> [String] {
        let short = Naming.shortCode(code)
        let base = short.split(separator: "-").first.map(String.init) ?? short
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
        if picks.isEmpty, let any = supported.first(where: { $0.lowercased().hasPrefix(base.lowercased()) }) { picks.append(any) }
        if base != "en", supported.contains("en-US") { picks.append("en-US") }   // fallback for names/latin text
        return picks
    }
}
