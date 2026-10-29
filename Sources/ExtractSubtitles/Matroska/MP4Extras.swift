import Foundation

/// Chapters of a Matroska file, read from the raw Chapters element the media reader keeps.
enum MKVChapters {
    struct Chapter {
        var startNs: Int64
        var endNs: Int64?
        var title: String
    }

    private static let editionEntry: UInt32 = 0x45B9
    private static let editionFlagDefault: UInt32 = 0x45DB
    private static let chapterAtom: UInt32 = 0xB6
    private static let chapterTimeStart: UInt32 = 0x91
    private static let chapterTimeEnd: UInt32 = 0x92
    private static let chapterFlagHidden: UInt32 = 0x98
    private static let chapterDisplay: UInt32 = 0x80
    private static let chapString: UInt32 = 0x85
    private static let chapLanguage: UInt32 = 0x437C

    /// Walks EBML elements inside `data[range]`; the closure gets (id, payload range).
    private static func children(_ data: Data, _ range: Range<Int>, _ body: (UInt32, Range<Int>) -> Void) {
        var pos = range.lowerBound
        while pos < range.upperBound {
            guard let id = vint(data, &pos, keepMarker: true),
                  let size = vint(data, &pos, keepMarker: false) else { return }
            let end = size.allOnes ? range.upperBound : min(range.upperBound, pos + Int(size.value))
            body(UInt32(truncatingIfNeeded: id.value), pos ..< end)
            pos = end
        }
    }

    private static func vint(_ data: Data, _ pos: inout Int, keepMarker: Bool) -> (value: UInt64, allOnes: Bool)? {
        guard pos < data.count else { return nil }
        let first = data[data.startIndex + pos]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, pos + length <= data.count else { return nil }
        var value: UInt64 = keepMarker ? UInt64(first) : UInt64(first & (0xFF >> UInt8(length)))
        var allOnes = (first & (0xFF >> UInt8(length))) == (0xFF >> UInt8(length))
        for i in 1 ..< length {
            let b = data[data.startIndex + pos + i]
            value = (value << 8) | UInt64(b)
            if b != 0xFF { allOnes = false }
        }
        pos += length
        return (value, allOnes)
    }

    private static func uint(_ data: Data, _ r: Range<Int>) -> UInt64 {
        var v: UInt64 = 0
        for i in r { v = (v << 8) | UInt64(data[data.startIndex + i]) }
        return v
    }

    private static func string(_ data: Data, _ r: Range<Int>) -> String {
        let s = data.startIndex
        return String(decoding: data[(s + r.lowerBound) ..< (s + r.upperBound)], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }

    /// Top-level chapters of the default (or first) edition, hidden ones skipped, in time order.
    static func parse(_ raw: Data) -> [Chapter] {
        // raw = the whole Chapters element (header + payload): skip its header.
        var pos = 0
        guard vint(raw, &pos, keepMarker: true) != nil, let size = vint(raw, &pos, keepMarker: false) else { return [] }
        let payload = pos ..< (size.allOnes ? raw.count : min(raw.count, pos + Int(size.value)))

        var editions: [(isDefault: Bool, chapters: [Chapter])] = []
        children(raw, payload) { id, r in
            guard id == editionEntry else { return }
            var isDefault = false
            var chapters: [Chapter] = []
            children(raw, r) { cid, cr in
                switch cid {
                case editionFlagDefault: isDefault = uint(raw, cr) != 0
                case chapterAtom:
                    var start: Int64 = 0
                    var end: Int64?
                    var hidden = false
                    var title = ""
                    var titleLang = ""
                    children(raw, cr) { aid, ar in
                        switch aid {
                        case chapterTimeStart: start = Int64(uint(raw, ar))
                        case chapterTimeEnd: end = Int64(uint(raw, ar))
                        case chapterFlagHidden: hidden = uint(raw, ar) != 0
                        case chapterDisplay:
                            var s = "", lang = ""
                            children(raw, ar) { did, dr in
                                if did == chapString { s = string(raw, dr) }
                                if did == chapLanguage { lang = string(raw, dr) }
                            }
                            // Prefer an English display when there are several.
                            if title.isEmpty || (lang == "eng" && titleLang != "eng") { title = s; titleLang = lang }
                        default: break
                        }
                    }
                    if !hidden { chapters.append(Chapter(startNs: start, endNs: end, title: title)) }
                default: break
                }
            }
            editions.append((isDefault, chapters))
        }
        let chosen = editions.first(where: { $0.isDefault }) ?? editions.first
        var list = (chosen?.chapters ?? []).sorted { $0.startNs < $1.startNs }
        for i in list.indices where list[i].title.isEmpty { list[i].title = "Chapter \(i + 1)" }
        return list
    }
}

/// A subtitle cue bound for a tx3g track.
struct TextCue {
    var startNs: Int64
    var endNs: Int64
    /// Text with only <i>…</i> tags left in it.
    var text: String
}

/// SRT files and SRT-style text → tx3g samples.
enum TimedText {

    private static let timing = try! NSRegularExpression(
        pattern: #"(\d+):(\d\d):(\d\d)[,.](\d{1,3})\s*-->\s*(\d+):(\d\d):(\d\d)[,.](\d{1,3})"#)

    /// Parses an SRT file (UTF-8, BOM tolerated).
    static func parseSRT(_ data: Data) -> [TextCue] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [TextCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { timing.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) else { continue }
            let line = lines[ti]
            guard let m = timing.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func num(_ i: Int) -> Int64 { Int64(line[Range(m.range(at: i), in: line)!]) ?? 0 }
            func ms(_ i: Int) -> Int64 {
                let raw = String(line[Range(m.range(at: i), in: line)!])
                return Int64((raw + "000").prefix(3)) ?? 0
            }
            let start = ((num(1) * 60 + num(2)) * 60 + num(3)) * 1000 + ms(4)
            let end = ((num(5) * 60 + num(6)) * 60 + num(7)) * 1000 + ms(8)
            let body = lines[(ti + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(TextCue(startNs: start * 1_000_000, endNs: end * 1_000_000, text: body))
        }
        return cues.sorted { $0.startNs < $1.startNs }
    }

    /// Plain text and italic ranges (UTF-16 offsets) from SRT-style markup.
    static func styled(_ raw: String) -> (text: String, italics: [(start: Int, end: Int)]) {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
        var out = ""
        var italics: [(start: Int, end: Int)] = []
        var italicStart: Int? = nil
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
                let tag = s[s.index(after: i) ..< close].lowercased().trimmingCharacters(in: .whitespaces)
                if tag == "i" || tag.hasPrefix("i ") {
                    if italicStart == nil { italicStart = out.utf16.count }
                } else if tag == "/i" {
                    if let st = italicStart { italics.append((start: st, end: out.utf16.count)); italicStart = nil }
                } else if tag == "br" || tag == "br/" || tag == "br /" {
                    out += "\n"
                }
                // every other tag (<b>, <font>, <u>, …) is dropped
                i = s.index(after: close)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        if let st = italicStart, out.utf16.count > st { italics.append((start: st, end: out.utf16.count)) }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // Re-trim can shift offsets; keep it simple: only trim when nothing is italic.
        let final = italics.isEmpty ? lines.filter { !$0.isEmpty }.joined(separator: "\n") : out.trimmingCharacters(in: .newlines)
        return (final, italics.filter { $0.1 > $0.0 })
    }

    /// Reads the language and flags out of a subtitle file name made by this app:
    /// `<movie>.<lang>[.<name>][.forced][.sdh][.commentary].srt`.
    static func describe(fileName: String, movie: String) -> (tag: String, name: String, forced: Bool, sdh: Bool, commentary: Bool) {
        var base = (fileName as NSString).deletingPathExtension
        let prefix = Naming.safe(movie) + "."
        if base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
        } else if let dot = base.firstIndex(of: ".") {
            base = String(base[base.index(after: dot)...])
        } else {
            return ("und", "", false, false, false)
        }
        var parts = base.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return ("und", "", false, false, false) }
        let tag = parts.removeFirst()
        var forced = false, sdh = false, commentary = false
        var names: [String] = []
        for p in parts {
            switch p.lowercased() {
            case "forced": forced = true
            case "sdh": sdh = true
            case "commentary": commentary = true
            default:
                if Int(p) == nil { names.append(p) }   // ".10" collision suffixes are dropped
            }
        }
        return (tag, names.joined(separator: " "), forced, sdh, commentary)
    }

    /// A human track name: "English", "French (Canada) SDH", "English Director Commentary".
    static func trackName(tag: String, name: String, forced: Bool, sdh: Bool, commentary: Bool) -> String {
        var s = Naming.displayName(tag)
        if !name.isEmpty { s += " " + name }
        if sdh, !name.lowercased().contains("sdh") { s += " SDH" }
        if forced, !name.lowercased().contains("forced") { s += " (forced)" }
        if commentary, !name.lowercased().contains("commentar") { s += " Commentary" }
        return s
    }
}
