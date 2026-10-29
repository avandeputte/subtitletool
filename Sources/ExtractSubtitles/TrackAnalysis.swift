import Foundation
import CryptoKit

/// What the *content* of a subtitle track says, beyond its Matroska metadata.
/// Blu-ray rips often carry several tracks of one language with no name, no IETF tag and
/// no forced/SDH flag (MakeMKV output is typical). These numbers tell them apart.
struct TrackAnalysis {
    /// Cues with a picture (PGS display sets that show objects) or non-empty text frames.
    var cueCount: Int = 0
    /// PGS display sets whose composition objects all carry the "forced" flag (0x40).
    var pgsForcedCues: Int = 0
    /// SHA-256 over timestamps and payloads: identical tracks hash the same.
    var contentHash: String = ""
    /// Plain text of the track (SRT text, or the OCR result) when it is known.
    var text: String? = nil

    /// Every picture cue is marked forced in the stream itself.
    var allCuesForced: Bool { cueCount > 0 && pgsForcedCues == cueCount }

    /// Share of cues that look like SDH captions: `[SIRENS]`, `(laughs)`, `♪`, `KNOX:` speaker labels.
    var sdhRatio: Double {
        guard let text = text else { return 0 }
        let cues = TrackAnalyzer.cues(in: text)
        guard !cues.isEmpty else { return 0 }
        let hits = cues.filter { TrackAnalyzer.sdhRegex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.count
        return Double(hits) / Double(cues.count)
    }

    /// "Hans" or "Hant" when the text is clearly simplified or traditional Chinese, else nil.
    var chineseScript: String? {
        guard let text = text else { return nil }
        var hans = 0, hant = 0
        for ch in text.unicodeScalars {
            if TrackAnalyzer.simplifiedOnly.contains(ch) { hans += 1 }
            else if TrackAnalyzer.traditionalOnly.contains(ch) { hant += 1 }
        }
        guard hans + hant >= 5 else { return nil }
        if hans > hant * 3 { return "Hans" }
        if hant > hans * 3 { return "Hant" }
        return nil
    }
}

enum TrackAnalyzer {

    /// Hash, cue count and PGS forced flags; no OCR, so this is cheap.
    static func analyze(track: SubtitleTrack, frames: [SubtitleFrame]) -> TrackAnalysis {
        var a = TrackAnalysis()
        var hasher = SHA256()
        for f in frames {
            var ts = f.timestampNs
            withUnsafeBytes(of: &ts) { hasher.update(bufferPointer: $0) }
            hasher.update(data: f.payload)
        }
        a.contentHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        switch track.kind {
        case .pgs:
            let stats = pgsStats(frames)
            a.cueCount = stats.cues
            a.pgsForcedCues = stats.forced
        case .srt, .ass, .ssa, .webvtt:
            a.cueCount = frames.filter { !SubtitleWriter.textOf($0.payload).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            if track.kind == .srt {
                a.text = frames.map { SubtitleWriter.textOf($0.payload) }.joined(separator: "\n\n")
            }
        default:
            a.cueCount = frames.count
        }
        return a
    }

    /// Counts PGS display sets that show something, and how many of those are flagged forced.
    /// Only the PCS segment (0x16) is read: palette ID, object count, then per object
    /// object ID (2), window ID (1), flags (1: 0x80 cropped, 0x40 forced), x (2), y (2) [+ 8 crop bytes].
    static func pgsStats(_ frames: [SubtitleFrame]) -> (cues: Int, forced: Int) {
        var cues = 0, forced = 0
        for f in frames {
            let d = f.payload
            var i = d.startIndex
            while i + 3 <= d.endIndex {
                let type = d[i]
                let size = Int(d[i + 1]) << 8 | Int(d[i + 2])
                let start = i + 3
                let end = start + size
                guard end <= d.endIndex else { break }
                if type == 0x16, size >= 11 {
                    let count = Int(d[start + 10])
                    var p = start + 11
                    var objects = 0, forcedObjects = 0
                    for _ in 0 ..< count {
                        guard p + 8 <= end else { break }
                        let flags = d[p + 3]
                        objects += 1
                        if flags & 0x40 != 0 { forcedObjects += 1 }
                        p += 8
                        if flags & 0x80 != 0 { p += 8 }
                    }
                    if objects > 0 {
                        cues += 1
                        if forcedObjects == objects { forced += 1 }
                    }
                }
                i = end
            }
        }
        return (cues, forced)
    }

    /// Splits SRT-like text into cue bodies (timing lines and counters removed).
    static func cues(in text: String) -> [String] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
                .filter { !$0.contains("-->") && Int($0.trimmingCharacters(in: .whitespaces)) == nil }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
    }

    static let sdhRegex = try! NSRegularExpression(
        pattern: #"\[[^\]\n]{2,}\]|\([^)\n]{3,}\)|♪|^(?:<i>)?[A-Z][A-Z0-9 .'\-]{1,30}:(?:\s|$)"#,
        options: [.anchorsMatchLines])

    // Characters that exist only in one of the two Chinese scripts (common words).
    static let simplifiedOnly: Set<Unicode.Scalar> = Set("们这国说时会来对为学开关东车长见门马鸟鱼语读书点么从两里样经还号发现实际没过应该问题让给动电话钱爱觉记听觉关系头发间观业务员医检历进场够吗与".unicodeScalars)
    static let traditionalOnly: Set<Unicode.Scalar> = Set("們這國說時會來對為學開關東車長見門馬鳥魚語讀書點麼從兩裡樣經還號發現實際沒過應該問題讓給動電話錢愛覺記聽關係頭髮間觀業務員醫檢歷進場夠嗎與妳".unicodeScalars)
}
