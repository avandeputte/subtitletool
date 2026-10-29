import Foundation

/// Turns demuxed frames into standalone subtitle files.
enum SubtitleWriter {

    enum Failure: Error, LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let what): return "\(what) tracks are not supported yet"
            }
        }
    }

    static func encode(track: SubtitleTrack, frames: [SubtitleFrame]) throws -> Data {
        switch track.kind {
        case .srt: return srt(frames)
        case .ass, .ssa: return ass(track: track, frames: frames)
        case .webvtt: return webvtt(track: track, frames: frames)
        case .pgs: return pgs(frames)
        default: throw Failure.unsupported(track.kind.label)
        }
    }

    // MARK: SRT

    static func srt(_ frames: [SubtitleFrame]) -> Data {
        var out = ""
        var index = 1
        for f in frames {
            let text = textOf(f.payload).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let end = f.timestampNs + (f.durationNs ?? 3_000_000_000)
            out += "\(index)\n\(srtTime(f.timestampNs)) --> \(srtTime(end))\n\(text)\n\n"
            index += 1
        }
        return Data(out.utf8)
    }

    // MARK: ASS / SSA

    static func ass(track: SubtitleTrack, frames: [SubtitleFrame]) -> Data {
        var header = textOf(track.codecPrivate)
        if header.isEmpty {
            header = "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1\n"
        }
        header = header.replacingOccurrences(of: "\r\n", with: "\n")
        if !header.hasSuffix("\n") { header += "\n" }
        if header.range(of: "[Events]", options: .caseInsensitive) == nil {
            header += "\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        }

        var out = header
        // Matroska stores: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        for f in frames {
            let line = textOf(f.payload).trimmingCharacters(in: .newlines)
            guard !line.isEmpty else { continue }
            var fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            while fields.count < 9 { fields.append("") }
            let end = f.timestampNs + (f.durationNs ?? 3_000_000_000)
            let rest = fields[2...].joined(separator: ",")
            out += "Dialogue: \(fields[1]),\(assTime(f.timestampNs)),\(assTime(end)),\(rest)\n"
        }
        return Data(out.utf8)
    }

    // MARK: WebVTT

    static func webvtt(track: SubtitleTrack, frames: [SubtitleFrame]) -> Data {
        var header = textOf(track.codecPrivate).trimmingCharacters(in: .whitespacesAndNewlines)
        if header.isEmpty { header = "WEBVTT" }
        var out = header + "\n\n"
        for f in frames {
            // Block = cue settings line, newline, cue payload.
            let body = textOf(f.payload)
            var settings = ""
            var text = body
            if let nl = body.firstIndex(of: "\n") {
                settings = String(body[..<nl]).trimmingCharacters(in: .whitespaces)
                text = String(body[body.index(after: nl)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let end = f.timestampNs + (f.durationNs ?? 3_000_000_000)
            out += "\(vttTime(f.timestampNs)) --> \(vttTime(end))"
            if !settings.isEmpty { out += " " + settings }
            out += "\n\(text)\n\n"
        }
        return Data(out.utf8)
    }

    // MARK: PGS (.sup)

    static func pgs(_ frames: [SubtitleFrame]) -> Data {
        var out = Data()
        for f in frames {
            let pts = UInt32(truncatingIfNeeded: (f.timestampNs * 9) / 100_000)  // 90 kHz clock
            let d = f.payload
            var i = d.startIndex
            while i + 3 <= d.endIndex {
                let type = d[i]
                let size = Int(d[i + 1]) << 8 | Int(d[i + 2])
                let payloadStart = i + 3
                let payloadEnd = payloadStart + size
                guard payloadEnd <= d.endIndex else { break }
                out.append(contentsOf: [0x50, 0x47])                      // "PG"
                out.append(contentsOf: be32(pts))
                out.append(contentsOf: be32(0))                            // DTS
                out.append(type)
                out.append(contentsOf: [UInt8(size >> 8), UInt8(size & 0xFF)])
                out.append(d[payloadStart ..< payloadEnd])
                i = payloadEnd
            }
        }
        return out
    }

    // MARK: helpers

    static func textOf(_ d: Data) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func split(_ ns: Int64) -> (h: Int64, m: Int64, s: Int64, ms: Int64) {
        let totalMs = max(0, ns) / 1_000_000
        return (totalMs / 3_600_000, (totalMs / 60_000) % 60, (totalMs / 1000) % 60, totalMs % 1000)
    }

    static func srtTime(_ ns: Int64) -> String {
        let t = split(ns)
        return String(format: "%02d:%02d:%02d,%03d", t.h, t.m, t.s, t.ms)
    }

    static func vttTime(_ ns: Int64) -> String {
        let t = split(ns)
        return String(format: "%02d:%02d:%02d.%03d", t.h, t.m, t.s, t.ms)
    }

    static func assTime(_ ns: Int64) -> String {
        let t = split(ns)
        return String(format: "%d:%02d:%02d.%02d", t.h, t.m, t.s, t.ms / 10)
    }
}
