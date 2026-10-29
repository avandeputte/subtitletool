import Foundation

/// What a movie file turned out to be, after the IMDb lookup.
struct MovieIdentity: Equatable, Identifiable, Hashable {
    let title: String
    let year: Int?
    let imdbID: String
    /// IMDb's kind: "feature", "TV movie", "TV series", "video", "short", …
    var kind: String = ""
    /// Main cast as IMDb lists it ("Tom Hanks, Halle Berry, Jim Broadbent").
    var stars: String = ""
    var posterURL: URL? = nil

    var id: String { imdbID }

    /// "Movie Name (yyyy)" — the base name used for the MKV and every subtitle file.
    /// Nil when IMDb gave no year, because the naming convention needs one.
    var baseName: String? {
        guard let year = year else { return nil }
        return Naming.titleSafe("\(title) (\(year))")
    }

    var imdbURL: URL { URL(string: "https://www.imdb.com/title/\(imdbID)/")! }

    /// "Cloud Atlas (2012)" / "Cloud Atlas (no year)"
    var label: String { "\(title) (\(year.map(String.init) ?? "no year"))" }

    var isSeries: Bool { kind.lowercased().contains("series") || kind.lowercased().contains("episode") }

    static func == (lhs: MovieIdentity, rhs: MovieIdentity) -> Bool { lhs.imdbID == rhs.imdbID }
    func hash(into hasher: inout Hasher) { hasher.combine(imdbID) }
}

/// Turns a rip-style file name into a search query ("The Matrix", 1999):
///   `The.Matrix.1999.1080p.BluRay.x264-GRP.mkv`  -> "The Matrix", 1999
///   `Cloud Atlas_t00.mkv` (MakeMKV)                -> "Cloud Atlas"
///   `CLOUD_ATLAS_t00.mkv` (disc label)             -> "Cloud Atlas"
///   `BATMAN_1989_t01.mkv`                          -> "Batman", 1989
///   `title_t00.mkv` / `B1_t00.mkv`                 -> "" (nothing usable; the caller falls back to the MKV title)
enum FilenameParser {
    struct Guess: Equatable {
        var title: String
        var year: Int?
        var isEmpty: Bool { title.isEmpty }
    }

    private static let tagWords: Set<String> = [
        "480p", "576p", "720p", "1080p", "1080i", "2160p", "4k", "uhd", "8k",
        "bluray", "blu-ray", "bdrip", "brrip", "bdremux", "remux", "webrip", "web-dl", "webdl", "web",
        "hdtv", "dvdrip", "dvd", "dvdscr", "hdrip", "cam", "ts", "tc", "r5", "vod", "amzn", "nf", "dsnp", "hmax", "atvp",
        "x264", "x265", "h264", "h265", "h.264", "h.265", "hevc", "avc", "av1", "xvid", "divx", "10bit", "8bit",
        "hdr", "hdr10", "hdr10+", "dv", "dolby", "vision", "sdr",
        "aac", "ac3", "eac3", "dts", "dts-hd", "dtshd", "truehd", "atmos", "flac", "mp3", "dd5", "dd5.1", "ddp", "ddp5", "ddp5.1", "5.1", "7.1", "2.0",
        "proper", "repack", "rerip", "internal", "limited", "unrated", "extended", "theatrical", "remastered", "imax", "criterion",
        "directors", "director's", "cut", "edition", "multi", "dual", "vff", "vfq", "vfi", "vf", "vo", "vostfr", "truefrench", "french", "subfrench", "subbed", "dubbed",
        "complete", "retail", "custom", "nfo", "sample", "mkv", "mp4",
        "disc", "disk", "bd", "bd25", "bd50", "bd66", "bd100", "bdmv", "main", "feature", "movie",
    ]

    /// Words that mean "this is not a title at all" when they are all that is left.
    private static let placeholderTitles: Set<String> = ["title", "titles", "untitled", "movie", "video", "film", "disc", "track", "main"]

    private static let yearRegex = try! NSRegularExpression(pattern: #"(?<!\d)(19[0-9]{2}|20[0-9]{2})(?!\d)"#)

    static func parse(_ fileName: String) -> Guess {
        var name = (fileName as NSString).deletingPathExtension

        // MakeMKV / disc-rip suffixes: "_t00", " t12", "-t3", "(1)", "copy", "_title00", "title_t00"
        name = name.replacingOccurrences(of: #"(?i)[\s_\-]*t\d{1,2}$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)[\s_\-]*title[\s_]*\d*$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)\s*\(\d+\)$|\s+copy(\s+\d+)?$"#, with: "", options: .regularExpression)
        // Disc-label prefixes such as "B1_", "D2_", "A_" that MakeMKV keeps from multi-disc sets.
        name = name.replacingOccurrences(of: #"^[A-Za-z]\d?_(?=[A-Za-z])"#, with: "", options: .regularExpression)

        // Drop "[group]" / "{tags}" blocks and a trailing "-GROUP".
        name = name.replacingOccurrences(of: #"\[[^\]]*\]|\{[^}]*\}"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"-[A-Za-z0-9]+$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)

        var year: Int?
        var titlePart = name
        let matches = yearRegex.matches(in: name, range: NSRange(name.startIndex..., in: name))
        if let last = matches.last, let r = Range(last.range, in: name) {
            let before = String(name[..<r.lowerBound])
            let cleanedBefore = cleanTitle(before)
            if cleanedBefore.isEmpty {
                // The year is the whole title (e.g. "1917", "2012"); look for a later year as release year.
                if matches.count >= 2, let r2 = Range(matches[matches.count - 2].range, in: name) {
                    titlePart = String(name[..<r2.upperBound])
                    year = Int(name[r])
                } else {
                    titlePart = String(name[r])
                    year = nil
                }
            } else {
                titlePart = before
                year = Int(name[r])
            }
        }
        var title = cleanTitle(titlePart)
        if title.isEmpty { title = cleanTitle(name) }
        if placeholderTitles.contains(title.lowercased()) { title = "" }
        title = prettify(title)
        return Guess(title: title, year: year)
    }

    /// Cuts the title at the first release tag and tidies whitespace/punctuation.
    private static func cleanTitle(_ s: String) -> String {
        var words: [String] = []
        for raw in s.split(whereSeparator: { $0 == " " }) {
            let w = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "()[]-–,"))
            if w.isEmpty { continue }
            if tagWords.contains(w.lowercased()) { break }
            words.append(w)
        }
        return words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:,"))
    }

    /// Disc labels are shouted ("CLOUD_ATLAS"): turn an all-caps title into "Cloud Atlas".
    /// Mixed-case titles are left alone.
    static func prettify(_ title: String) -> String {
        let letters = title.filter { $0.isLetter }
        guard letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) else { return title }
        let small: Set<String> = ["a", "an", "the", "of", "and", "or", "in", "on", "at", "to", "for", "by", "vs", "de", "la", "le", "du", "des", "et"]
        let words = title.lowercased().split(separator: " ").map(String.init)
        return words.enumerated().map { i, w in
            if i > 0, small.contains(w) { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

/// Looks a title up on IMDb (the public suggestion endpoint, no API key needed).
enum IMDbLookup {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Suggestion: Decodable {
        struct Image: Decodable { let imageUrl: String? }
        let id: String
        let l: String
        let q: String?
        let qid: String?
        let y: Int?
        let s: String?
        let i: Image?
    }
    private struct Response: Decodable { let d: [Suggestion]? }

    /// Raw suggestion search; up to 8 titles in IMDb's order.
    static func search(_ query: String) async throws -> [MovieIdentity] {
        let q = query.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        guard !q.isEmpty else { return [] }
        let first = q.first.map(String.init) ?? "x"
        let letter = first.range(of: #"[a-z]"#, options: .regularExpression) != nil ? first : "x"
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/\(letter)/\(encoded).json") else {
            throw Failure(message: "Could not build the IMDb query")
        }
        var request = URLRequest(url: url, timeoutValue: 15)
        request.setValue("Mozilla/5.0 (Macintosh) ExtractSubtitles/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "IMDb replied with HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let allowed: Set<String> = ["movie", "tvMovie", "video", "tvSeries", "tvMiniSeries", "short", "tvSpecial", "musicVideo", "tvShort"]
        return (decoded.d ?? []).compactMap { s in
            guard s.id.hasPrefix("tt") else { return nil }
            if let qid = s.qid, !allowed.contains(qid) { return nil }
            var m = MovieIdentity(title: s.l, year: s.y, imdbID: s.id)
            m.kind = s.q ?? ""
            m.stars = s.s ?? ""
            if let u = s.i?.imageUrl { m.posterURL = URL(string: u) }
            return m
        }
    }

    /// The outcome of matching a file name against IMDb.
    enum Resolution {
        /// One title fits and nothing else comes close: rename without asking.
        case confident(MovieIdentity, candidates: [MovieIdentity])
        /// Something was found but it needs a human: several similar titles, a year that
        /// does not agree, or only loose matches. `candidates` is what the picker shows.
        case ambiguous([MovieIdentity], reason: String)
        /// Nothing plausible at all (empty candidates).
        case nothing
    }

    /// Matches a parsed file name. "Confident" needs real evidence: exactly one IMDb title whose
    /// name equals the file name (ignoring case, accents and punctuation) and, when the file name
    /// carries a year, whose year agrees (±1 for festival/release differences). Anything else is
    /// reported as ambiguous so the user can pick.
    static func identify(guess: FilenameParser.Guess, alternateTitle: String? = nil) async throws -> Resolution {
        var queries: [String] = []
        if !guess.title.isEmpty {
            if let y = guess.year { queries.append("\(guess.title) \(y)") }
            queries.append(guess.title)
        }
        var altGuess: FilenameParser.Guess?
        if let alt = alternateTitle?.trimmingCharacters(in: .whitespaces), !alt.isEmpty {
            let g = FilenameParser.parse(alt)
            if !g.title.isEmpty, g.title.caseInsensitiveCompare(guess.title) != .orderedSame {
                altGuess = g
                queries.append(g.title)
            }
        }
        guard !queries.isEmpty else { return .nothing }

        // Collect candidates from every query, keeping IMDb's order per query and the first query first.
        var candidates: [MovieIdentity] = []
        var seen: Set<String> = []
        for query in queries {
            let results = try await search(query)
            for r in results where !seen.contains(r.imdbID) {
                seen.insert(r.imdbID)
                candidates.append(r)
            }
            // Enough evidence already? An exact title with the right year ends the search.
            if let y = guess.year, candidates.contains(where: { exactTitle($0, guess.title) && yearMatches($0, y) }) { break }
        }
        guard !candidates.isEmpty else { return .nothing }

        // Rank: exact title + matching year first, then exact title, then year, then IMDb's order; films before series.
        func score(_ m: MovieIdentity) -> Int {
            var s = 0
            if exactTitle(m, guess.title) { s += 100 }
            if let alt = altGuess, exactTitle(m, alt.title) { s += 60 }
            if let y = guess.year {
                if let my = m.year, abs(my - y) <= 1 { s += 50 } else if m.year != nil { s -= 20 }
            }
            if m.year == nil { s -= 10 }
            if m.isSeries { s -= 15 }
            return s
        }
        let ranked = candidates.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map { $0.element }

        let exact = ranked.filter { exactTitle($0, guess.title) }
        if let y = guess.year {
            let strong = exact.filter { yearMatches($0, y) }
            if strong.count == 1, strong[0].year != nil { return .confident(strong[0], candidates: ranked) }
            if strong.count > 1 { return .ambiguous(ranked, reason: "Several titles called \"\(guess.title)\" match \(y).") }
            if exact.isEmpty { return .ambiguous(ranked, reason: "No IMDb title is called exactly \"\(guess.title)\".") }
            return .ambiguous(ranked, reason: "\"\(guess.title)\" was found, but not from \(y).")
        }
        // No year in the file name: a single exact title is enough ("Cloud Atlas" → 2012).
        let exactWithYear = exact.filter { $0.year != nil && !$0.isSeries }
        if exactWithYear.count == 1 {
            // … unless a same-named series or a second film could be meant.
            if exact.count == 1 { return .confident(exactWithYear[0], candidates: ranked) }
            return .ambiguous(ranked, reason: "More than one IMDb entry is called \"\(guess.title)\".")
        }
        if exactWithYear.count > 1 { return .ambiguous(ranked, reason: "Several films are called \"\(guess.title)\"; the file name has no year.") }
        if exact.count == 1 { return .ambiguous(ranked, reason: "\"\(guess.title)\" was found, but without a release year.") }
        return .ambiguous(ranked, reason: guess.title.isEmpty ? "The file name has no usable title." : "No IMDb title is called exactly \"\(guess.title)\".")
    }

    static func exactTitle(_ m: MovieIdentity, _ title: String) -> Bool {
        let a = normalized(m.title), b = normalized(title)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // "The Matrix" vs "Matrix, The" / a leading article dropped by the disc label.
        let articles = ["the", "a", "an", "le", "la", "les", "der", "die", "das", "el", "los", "las", "il"]
        for art in articles {
            if a == art + b || b == art + a { return true }
        }
        return false
    }

    static func yearMatches(_ m: MovieIdentity, _ year: Int) -> Bool {
        guard let y = m.year else { return false }
        return abs(y - year) <= 1
    }

    static func normalized(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }
}

extension URLRequest {
    init(url: URL, timeoutValue: TimeInterval) {
        self.init(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeoutValue)
    }
}
