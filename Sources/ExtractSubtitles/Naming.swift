import Foundation

/// Language code handling and output file naming.
enum Naming {
    static let subfolderSuffix = " Subtitles"

    /// ISO 639-2 (bibliographic and terminologic) -> ISO 639-1
    private static let iso2to1: [String: String] = [
        "eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es",
        "ita": "it", "dut": "nl", "nld": "nl", "por": "pt", "rus": "ru", "jpn": "ja",
        "chi": "zh", "zho": "zh", "kor": "ko", "ara": "ar", "swe": "sv", "nor": "no",
        "nob": "nb", "nno": "nn", "dan": "da", "fin": "fi", "pol": "pl", "tur": "tr",
        "cze": "cs", "ces": "cs", "hun": "hu", "gre": "el", "ell": "el", "heb": "he",
        "tha": "th", "vie": "vi", "ind": "id", "may": "ms", "msa": "ms", "ukr": "uk",
        "ron": "ro", "rum": "ro", "hrv": "hr", "srp": "sr", "bul": "bg", "slv": "sl",
        "slo": "sk", "slk": "sk", "lit": "lt", "lav": "lv", "est": "et", "hin": "hi",
        "ben": "bn", "tam": "ta", "tel": "te", "urd": "ur", "per": "fa", "fas": "fa",
        "cat": "ca", "glg": "gl", "baq": "eu", "eus": "eu", "ice": "is", "isl": "is",
        "gle": "ga", "wel": "cy", "cym": "cy", "mac": "mk", "mkd": "mk", "alb": "sq",
        "sqi": "sq", "bos": "bs", "fil": "fil", "tgl": "tl", "lat": "la", "und": "und",
    ]

    private static let names: [String: String] = [
        "en": "English", "fr": "French", "de": "German", "es": "Spanish", "it": "Italian",
        "nl": "Dutch", "pt": "Portuguese", "ru": "Russian", "ja": "Japanese", "zh": "Chinese",
        "ko": "Korean", "ar": "Arabic", "sv": "Swedish", "no": "Norwegian", "nb": "Norwegian",
        "nn": "Norwegian", "da": "Danish", "fi": "Finnish", "pl": "Polish", "tr": "Turkish",
        "cs": "Czech", "hu": "Hungarian", "el": "Greek", "he": "Hebrew", "th": "Thai",
        "vi": "Vietnamese", "id": "Indonesian", "ms": "Malay", "uk": "Ukrainian",
        "ro": "Romanian", "hr": "Croatian", "sr": "Serbian", "bg": "Bulgarian",
        "sl": "Slovenian", "sk": "Slovak", "lt": "Lithuanian", "lv": "Latvian",
        "et": "Estonian", "hi": "Hindi", "bn": "Bengali", "ta": "Tamil", "te": "Telugu",
        "ur": "Urdu", "fa": "Persian", "ca": "Catalan", "gl": "Galician", "eu": "Basque",
        "is": "Icelandic", "ga": "Irish", "cy": "Welsh", "mk": "Macedonian", "sq": "Albanian",
        "bs": "Bosnian", "fil": "Filipino", "tl": "Tagalog", "la": "Latin", "und": "Unknown",
    ]

    /// "eng" -> "en", "pt-BR" -> "pt-BR", "fre" -> "fr"
    static func shortCode(_ code: String) -> String {
        let lower = code.lowercased()
        if let mapped = iso2to1[lower] { return mapped }
        // IETF tag such as "pt-BR" or "zh-Hant": keep region/script, normalize case
        let parts = code.split(separator: "-").map(String.init)
        guard let first = parts.first else { return "und" }
        let base = iso2to1[first.lowercased()] ?? first.lowercased()
        return ([base] + parts.dropFirst()).joined(separator: "-")
    }

    static func displayName(_ code: String) -> String {
        let short = shortCode(code)
        let base = short.split(separator: "-").first.map(String.init) ?? short
        if let n = names[base] {
            return short.contains("-") ? "\(n) (\(short))" : n
        }
        if let n = Locale.current.localizedString(forLanguageCode: base) { return n }
        return code
    }

    static func safe(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"[/\\:*?"<>|]+"#, with: "-", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return out.isEmpty ? "untitled" : out
    }

    /// Like `safe` but turns "Mission: Impossible" into "Mission - Impossible" instead of "Mission- Impossible".
    static func titleSafe(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"\s*:\s*"#, with: " - ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s*/\s*"#, with: " - ", options: .regularExpression)
        return safe(out)
    }

    /// Region hints found in track names when the file has no IETF tag ("French (Canada)" → fr-CA).
    private static let regionHints: [(base: String, keywords: [String], tag: String)] = [
        ("fr", ["canad", "québec", "quebec", "vfq"], "fr-CA"),
        ("fr", ["france", "parisian", "vff", "européen", "europeen", "european"], "fr-FR"),
        ("fr", ["belg"], "fr-BE"),
        ("es", ["latin", "latino", "mexic", "argentin", "neutral"], "es-419"),
        ("es", ["spain", "castilian", "castellano", "españa", "espana", "european"], "es-ES"),
        ("pt", ["brazil", "brasil"], "pt-BR"),
        ("pt", ["portugal", "european"], "pt-PT"),
        ("zh", ["traditional", "taiwan", "hong kong", "cantonese", "繁"], "zh-Hant"),
        ("zh", ["simplified", "mandarin", "prc", "简"], "zh-Hans"),
        ("en", ["british", "uk"], "en-GB"),
        ("de", ["austria", "österreich"], "de-AT"),
        ("de", ["swiss", "schweiz"], "de-CH"),
        ("nl", ["flemish", "vlaams", "belg"], "nl-BE"),
    ]

    /// The language tag used in file names: the file's IETF tag when present (fr-CA),
    /// otherwise the ISO code, refined with a region when the track name says so.
    static func languageTag(for track: SubtitleTrack) -> String {
        let short = shortCode(track.language)
        if short.contains("-") { return short }
        let lowerName = track.name.lowercased()
        for hint in regionHints where hint.base == short {
            if hint.keywords.contains(where: { lowerName.contains($0) }) { return hint.tag }
        }
        return short
    }

    /// True for SDH / closed-caption tracks: the Matroska flag or a tell-tale name.
    static func isSDH(_ track: SubtitleTrack) -> Bool {
        if track.isHearingImpaired { return true }
        let n = track.name.lowercased()
        return n.contains("sdh") || n.contains("hearing") || n.contains("closed caption") || n == "cc" || n.hasSuffix(" cc") || n.contains("(cc)")
    }

    /// Words in a track name that only repeat what the language tag already says.
    private static func isRedundantName(_ name: String, tag: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return true }
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        var redundant: Set<String> = [tag.lowercased(), base, "full", "complete", "subtitles", "subtitle", "subs", "sub", "regular", "normal", "default"]
        if let display = names[base]?.lowercased() { redundant.insert(display) }
        if let display = Locale.current.localizedString(forLanguageCode: base)?.lowercased() { redundant.insert(display) }
        for hint in regionHints where hint.tag == tag { redundant.formUnion(hint.keywords) }
        // "French (Canada)", "French - Canada", "Français" …
        let words = n.replacingOccurrences(of: #"[()\[\]/,\-–:]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return words.allSatisfy { w in redundant.contains(w) || redundant.contains(where: { $0.hasPrefix(w) && w.count >= 4 }) || ["sdh", "forced", "cc", "the", "and", "&"].contains(w) }
    }

    /// Builds `<movie>.<lang-tag>[.<track name>][.forced][.sdh][.commentary]` and keeps names unique.
    /// Examples: `Batman (1989).fr-CA.srt`, `Batman (1989).fr-FR.srt`, `Batman (1989).en.sdh.srt`,
    /// `Batman (1989).en.forced.srt`, `Batman (1989).en.Director Commentary.commentary.srt`.
    static func baseName(movie: String, track: SubtitleTrack, used: inout Set<String>) -> String {
        let tag = languageTag(for: track)
        var parts = [safe(movie), tag]
        let lowerName = track.name.lowercased()
        if !isRedundantName(track.name, tag: tag) { parts.append(safe(track.name)) }
        if track.isForced, !lowerName.contains("forced") { parts.append("forced") }
        if isSDH(track), !lowerName.contains("sdh"), !lowerName.contains("hearing") { parts.append("sdh") }
        if track.isCommentary, !lowerName.contains("commentar") { parts.append("commentary") }
        var base = parts.joined(separator: ".")
        if used.contains(base) { base += ".track\(track.number)" }
        used.insert(base)
        return base
    }

    /// A track's final name, decided from metadata *and* content.
    struct Plan {
        /// Base file name without extension; nil when the track is a byte-identical copy of `duplicateOf`.
        var base: String?
        var duplicateOf: UInt64?
        var tag: String
        var forced: Bool
        var sdh: Bool
    }

    private static func baseLanguage(_ tag: String) -> String {
        tag.split(separator: "-").first.map(String.init) ?? tag
    }

    /// Names every track as `<movie>.<lang>[.<name>][.forced][.sdh][.commentary]`, using what the
    /// content says when the metadata is silent (typical for MakeMKV rips):
    ///  - a stream byte-identical to an earlier track is skipped (`duplicateOf`),
    ///  - `.forced` when the flag is set, when every PGS cue is flagged forced in the stream, or when the
    ///    track has under 10% of the cues of the fullest track in the same language,
    ///  - `.sdh` when the flag/name says so or more than 5% of the cues carry `[sound]` / `NAME:` captions,
    ///  - Chinese gets `zh-Hans` / `zh-Hant` from the characters in the text,
    ///  - names that still collide get the track number appended (`zh-Hant.10`, `zh-Hant.12`).
    /// Region subtags (fr-CA / fr-FR) come only from the IETF tag or the track name, never from guessing.
    static func plan(movie: String, tracks: [SubtitleTrack], analyses: [UInt64: TrackAnalysis]) -> [UInt64: Plan] {
        var plans: [UInt64: Plan] = [:]
        var seenHashes: [String: UInt64] = [:]

        // The fullest non-forced track per language, to spot "signs only" tracks by cue count.
        var fullCues: [String: Int] = [:]
        for t in tracks {
            let a = analyses[t.number]
            let flaggedForced = t.isForced || t.name.lowercased().contains("forced") || (a?.allCuesForced ?? false)
            if !flaggedForced {
                let base = baseLanguage(languageTag(for: t))
                fullCues[base] = max(fullCues[base] ?? 0, a?.cueCount ?? 0)
            }
        }

        for t in tracks {
            let a = analyses[t.number] ?? TrackAnalysis()
            var tag = languageTag(for: t)
            if !a.contentHash.isEmpty, let first = seenHashes[a.contentHash] {
                plans[t.number] = Plan(base: nil, duplicateOf: first, tag: tag, forced: false, sdh: false)
                continue
            }
            if !a.contentHash.isEmpty { seenHashes[a.contentHash] = t.number }

            let base = baseLanguage(tag)
            if base == "zh", !tag.contains("-"), let script = a.chineseScript { tag = "zh-\(script)" }

            let lowerName = t.name.lowercased()
            var forced = t.isForced || lowerName.contains("forced") || a.allCuesForced
            if !forced, let full = fullCues[base], full >= 50, a.cueCount > 0, Double(a.cueCount) < Double(full) * 0.10 {
                forced = true
            }
            let sdh = isSDH(t) || a.sdhRatio > 0.05

            var parts = [safe(movie), tag]
            if !isRedundantName(t.name, tag: tag) { parts.append(safe(t.name)) }
            if forced, !lowerName.contains("forced") { parts.append("forced") }
            if sdh, !lowerName.contains("sdh"), !lowerName.contains("hearing") { parts.append("sdh") }
            if t.isCommentary, !lowerName.contains("commentar") { parts.append("commentary") }
            plans[t.number] = Plan(base: parts.joined(separator: "."), duplicateOf: nil, tag: tag, forced: forced, sdh: sdh)
        }

        // Names that still collide get the track number so both files survive.
        var byName: [String: [UInt64]] = [:]
        for (n, p) in plans { if let b = p.base { byName[b, default: []].append(n) } }
        for (b, numbers) in byName where numbers.count > 1 {
            for n in numbers { plans[n]?.base = "\(b).\(n)" }
        }
        return plans
    }

    /// Short summary of a content analysis for the log: " cues=16 pgs-forced=16 sdh=18%".
    static func describe(_ analysis: TrackAnalysis?) -> String {
        guard let a = analysis else { return "" }
        var bits: [String] = [" cues=\(a.cueCount)"]
        if a.pgsForcedCues > 0 { bits.append("pgs-forced=\(a.pgsForcedCues)") }
        if a.text != nil {
            bits.append("sdh=\(Int((a.sdhRatio * 100).rounded()))%")
            if let s = a.chineseScript { bits.append("script=\(s)") }
        }
        return bits.joined(separator: " ")
    }

    /// One-line description of what makes a track distinct, for the window and the CLI log.
    static func describe(_ track: SubtitleTrack) -> String {
        var bits: [String] = [languageTag(for: track)]
        if track.language != track.isoLanguage, !track.isoLanguage.isEmpty { bits.append("iso=\(track.isoLanguage)") }
        if !track.name.isEmpty { bits.append("name=\"\(track.name)\"") }
        if track.isForced { bits.append("forced") }
        if isSDH(track) { bits.append("sdh") }
        if track.isCommentary { bits.append("commentary") }
        if track.isOriginal { bits.append("original") }
        if track.isDefault { bits.append("default") }
        return bits.joined(separator: " ")
    }
}
