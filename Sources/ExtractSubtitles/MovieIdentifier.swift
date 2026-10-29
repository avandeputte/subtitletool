import Foundation

/// What a movie file turned out to be, after the IMDb lookup.
struct MovieIdentity: Equatable {
    let title: String
    let year: Int?
    let imdbID: String

    /// "Movie Name (yyyy)" — the base name used for the MKV and every subtitle file.
    /// Nil when IMDb gave no year, because the naming convention needs one.
    var baseName: String? {
        guard let year = year else { return nil }
        return Naming.titleSafe("\(title) (\(year))")
    }

    var imdbURL: URL { URL(string: "https://www.imdb.com/title/\(imdbID)/")! }
}

/// Turns a release-style file name such as `The.Matrix.1999.1080p.BluRay.x264-GRP`
/// into a search query ("The Matrix", 1999).
enum FilenameParser {
    struct Guess: Equatable {
        var title: String
        var year: Int?
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
        "complete", "retail", "custom", "nfo", "sample", "mkv",
    ]

    private static let yearRegex = try! NSRegularExpression(pattern: #"(?<!\d)(19[0-9]{2}|20[0-9]{2})(?!\d)"#)

    static func parse(_ fileName: String) -> Guess {
        var name = (fileName as NSString).deletingPathExtension
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
}

/// Looks a title up on IMDb (the public suggestion endpoint, no API key needed).
enum IMDbLookup {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Suggestion: Decodable {
        let id: String
        let l: String
        let q: String?
        let qid: String?
        let y: Int?
    }
    private struct Response: Decodable { let d: [Suggestion]? }

    static func search(_ query: String) async throws -> [MovieIdentity] {
        let q = query.lowercased()
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
        let allowed: Set<String> = ["movie", "tvMovie", "video", "tvSeries", "tvMiniSeries", "short", "tvSpecial", "musicVideo"]
        return (decoded.d ?? []).compactMap { s in
            guard s.id.hasPrefix("tt") else { return nil }
            if let qid = s.qid, !allowed.contains(qid) { return nil }
            return MovieIdentity(title: s.l, year: s.y, imdbID: s.id)
        }
    }

    /// Picks the best match for a parsed file name. Returns nil when nothing plausible came back.
    static func identify(guess: FilenameParser.Guess, alternateTitle: String? = nil) async throws -> MovieIdentity? {
        var queries: [String] = []
        if let y = guess.year { queries.append("\(guess.title) \(y)") }
        queries.append(guess.title)
        if let alt = alternateTitle?.trimmingCharacters(in: .whitespaces), !alt.isEmpty,
           alt.caseInsensitiveCompare(guess.title) != .orderedSame {
            let altGuess = FilenameParser.parse(alt)
            queries.append(altGuess.title)
        }

        // A result is acceptable only with real evidence: the title matches the file name
        // exactly, or the year in the file name matches (±1 for festival/release differences).
        var best: (MovieIdentity, Int)?
        for (qi, query) in queries.enumerated() {
            let results = try await search(query)
            for (i, r) in results.enumerated() {
                let exactTitle = normalized(r.title) == normalized(guess.title)
                var yearMatch = false
                var score = 10 - min(i, 9) - qi * 2
                if let y = guess.year, let ry = r.year {
                    if y == ry { score += 12; yearMatch = true }
                    else if abs(y - ry) == 1 { score += 4; yearMatch = true }
                    else { score -= 6 }
                }
                if exactTitle { score += 8 }
                if r.year == nil { score -= 5 }
                guard exactTitle || yearMatch else { continue }
                if best == nil || score > best!.1 { best = (r, score) }
            }
            // A confident hit (exact title + year) ends the search early.
            if let b = best, b.1 >= 25 { break }
        }
        return best?.0
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }
}

extension URLRequest {
    init(url: URL, timeoutValue: TimeInterval) {
        self.init(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeoutValue)
    }
}
