import Foundation
import Security

/// Optional step after OCR: fetch a subtitle file for the same movie and language from
/// OpenSubtitles.com and use it to repair the OCR text. The OCR result stays the primary
/// source: timing, cue count and line breaks are kept, and only differences that look like
/// known OCR confusions (I/l/1, apostrophes, ♪ residue, punctuation) are taken from the
/// downloaded file. Genuine wording differences are left alone.
enum ReferenceSubtitles {

    typealias Cue = LocalConverter.Cue

    // MARK: - Settings (API key and login live in the Keychain, never in files)

    static let enabledKey = "compareWithOpenSubtitles"
    static let keychainService = "com.avandeputte.ExtractSubtitles.opensubtitles"
    static let apiKeyAccount = "api-key"
    static let usernameAccount = "username"
    static let passwordAccount = "password"

    struct Credentials {
        var apiKey: String
        var username: String
        var password: String
        var isComplete: Bool { !apiKey.isEmpty && !username.isEmpty && !password.isEmpty }

        static func load() -> Credentials {
            Credentials(apiKey: KeychainStore.read(service: keychainService, account: apiKeyAccount) ?? "",
                        username: KeychainStore.read(service: keychainService, account: usernameAccount) ?? "",
                        password: KeychainStore.read(service: keychainService, account: passwordAccount) ?? "")
        }

        func save() {
            KeychainStore.write(service: ReferenceSubtitles.keychainService, account: ReferenceSubtitles.apiKeyAccount, value: apiKey)
            KeychainStore.write(service: ReferenceSubtitles.keychainService, account: ReferenceSubtitles.usernameAccount, value: username)
            KeychainStore.write(service: ReferenceSubtitles.keychainService, account: ReferenceSubtitles.passwordAccount, value: password)
        }
    }

    // MARK: - Report

    struct Report {
        var candidate: Candidate?
        var alignedCues: Int = 0
        var changedCues: Int = 0
        var changedWords: Int = 0
        var samples: [String] = []        // "before → after", at most 10
        var notes: [String] = []
    }

    enum Failure: Error, LocalizedError {
        case notConfigured
        case http(Int, String)
        case badResponse(String)
        case noMatch
        case quotaExceeded(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenSubtitles API key or login missing (Settings)"
            case .http(let code, let body): return "OpenSubtitles HTTP \(code): \(body)"
            case .badResponse(let what): return "OpenSubtitles: unexpected response (\(what))"
            case .noMatch: return "OpenSubtitles has no matching subtitle for this movie and language"
            case .quotaExceeded(let reset): return "OpenSubtitles download quota exhausted (resets \(reset))"
            }
        }
    }

    /// ~/Library/Caches/com.avandeputte.ExtractSubtitles/opensubtitles
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.avandeputte.ExtractSubtitles/opensubtitles", isDirectory: true)
    }

    /// CLI helper: repairs the SRT at `srtURL` in place, taking language and SDH flag from the
    /// subtitle file name ("Movie (2020).en.sdh.srt").
    static func improveFile(_ srtURL: URL, imdbID: String, log: ((String) -> Void)? = nil) async throws -> Report {
        let stem: String = srtURL.deletingPathExtension().lastPathComponent
        var movie = ""
        if let r = stem.range(of: #"\(\d{4}\)"#, options: .regularExpression) { movie = String(stem[..<r.upperBound]) }
        let d = TimedText.describe(fileName: srtURL.lastPathComponent, movie: movie)
        let data = try Data(contentsOf: srtURL)
        let r = try await improve(srt: data, imdbID: imdbID, language: d.tag, hearingImpaired: d.sdh,
                                  credentials: Credentials.load(), cache: cacheDirectory, log: log)
        if r.report.changedCues > 0 { try r.srt.write(to: srtURL, options: .atomic) }
        return r.report
    }

    // MARK: - High-level entry point

    /// Downloads the best reference for `imdbID`/`language` and repairs `srt`. `hearingImpaired`
    /// should mirror the OCR'd track (SDH tracks compare best against SDH references).
    /// Throws when the service cannot be used; a run with no usable alignment returns the
    /// input unchanged with a note in the report.
    static func improve(srt: Data, imdbID: String, language: String?, hearingImpaired: Bool,
                        credentials: Credentials, cache: URL? = nil,
                        log: ((String) -> Void)? = nil) async throws -> (srt: Data, report: Report) {
        guard credentials.isComplete else { throw Failure.notConfigured }
        let client = OpenSubtitlesClient(apiKey: credentials.apiKey)
        var report = Report()

        let lang: String = osLanguage(language)
        let cacheFile: URL? = cache.map { $0.appendingPathComponent("\(imdbID).\(lang)\(hearingImpaired ? ".sdh" : "").srt") }
        var referenceData: Data? = nil
        if let f = cacheFile, let d = try? Data(contentsOf: f), !d.isEmpty {
            referenceData = d
            log?("  reference: cached \(f.lastPathComponent)")
        }
        if referenceData == nil {
            var candidates: [Candidate] = try await client.search(imdbID: imdbID, language: lang, hearingImpaired: hearingImpaired)
            if candidates.isEmpty && hearingImpaired {
                candidates = try await client.search(imdbID: imdbID, language: lang, hearingImpaired: false)
            }
            guard let best = pickCandidate(candidates) else { throw Failure.noMatch }
            report.candidate = best
            log?("  reference: \(best.release) (\(best.downloadCount) downloads\(best.hearingImpaired ? ", SDH" : ""))")
            try await client.login(username: credentials.username, password: credentials.password)
            let d: Data = try await client.download(fileID: best.fileID)
            referenceData = d
            if let f = cacheFile {
                try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: f, options: .atomic)
            }
        }
        guard let refData = referenceData else { throw Failure.noMatch }

        let ocr: [Cue] = parseSRT(srt)
        let reference: [Cue] = parseSRT(refData)
        guard !ocr.isEmpty, !reference.isEmpty else {
            report.notes.append("nothing to compare")
            return (srt, report)
        }
        let pairs: [Int: Int] = align(ocr: ocr, reference: reference)
        report.alignedCues = pairs.count
        guard pairs.count * 4 >= ocr.count else {
            report.notes.append("only \(pairs.count) of \(ocr.count) cues matched the reference; left unchanged")
            return (srt, report)
        }
        let fixed = correct(ocr: ocr, reference: reference, pairs: pairs, language: language)
        report.changedCues = fixed.changedCues
        report.changedWords = fixed.changedWords
        report.samples = fixed.samples
        log?("  reference: \(pairs.count)/\(ocr.count) cues aligned, \(fixed.changedCues) cues / \(fixed.changedWords) words repaired")
        return (LocalConverter.encodeSRT(fixed.cues), report)
    }

    /// OpenSubtitles wants ISO 639-1 codes ("en", "fr", "pt-br"); accept whatever the track carries.
    static func osLanguage(_ code: String?) -> String {
        let short = Naming.shortCode(code ?? "").lowercased()
        let parts = short.split(separator: "-").map(String.init)
        guard let base = parts.first, !base.isEmpty, base != "und" else { return "en" }
        if base == "pt", parts.count > 1, parts[1] == "br" { return "pt-br" }
        if base == "zh", parts.count > 1 { return parts[1] == "tw" || parts[1] == "hant" ? "zh-tw" : "zh-cn" }
        return base
    }

    static func pickCandidate(_ candidates: [Candidate]) -> Candidate? {
        // Most downloaded first, but prefer ones not flagged as machine-translated or AI-made.
        candidates.filter { !$0.machineTranslated && !$0.aiTranslated }.max { $0.downloadCount < $1.downloadCount }
            ?? candidates.max { $0.downloadCount < $1.downloadCount }
    }

    // MARK: - OpenSubtitles REST client (api.opensubtitles.com/api/v1)

    struct Candidate {
        let fileID: Int
        let release: String
        let language: String
        let hearingImpaired: Bool
        let downloadCount: Int
        let fps: Double?
        let machineTranslated: Bool
        let aiTranslated: Bool
    }

    final class OpenSubtitlesClient {
        let apiKey: String
        let base = URL(string: "https://api.opensubtitles.com/api/v1")!
        let userAgent = "ExtractSubtitles v1.0"
        private var token: String? = nil

        init(apiKey: String) { self.apiKey = apiKey }

        private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                             body: [String: Any]? = nil) throws -> URLRequest {
            var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            if let b = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: b, options: [])
            }
            req.timeoutInterval = 30
            return req
        }

        private func json(_ req: URLRequest) async throws -> [String: Any] {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            guard (200 ..< 300).contains(code) else {
                let msg: String = (obj?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
                throw Failure.http(code, msg)
            }
            guard let o = obj else { throw Failure.badResponse("not a JSON object") }
            return o
        }

        func login(username: String, password: String) async throws {
            let req = try request("login", method: "POST", body: ["username": username, "password": password])
            let o = try await json(req)
            guard let t = o["token"] as? String, !t.isEmpty else { throw Failure.badResponse("login without token") }
            token = t
        }

        /// GET /subtitles?imdb_id=…&languages=…&hearing_impaired=only|exclude
        func search(imdbID: String, language: String, hearingImpaired: Bool) async throws -> [Candidate] {
            let numeric: String = imdbID.hasPrefix("tt") ? String(imdbID.dropFirst(2)) : imdbID
            let q: [URLQueryItem] = [
                URLQueryItem(name: "imdb_id", value: numeric),
                URLQueryItem(name: "languages", value: language),
                URLQueryItem(name: "hearing_impaired", value: hearingImpaired ? "only" : "exclude"),
                URLQueryItem(name: "type", value: "movie"),
                URLQueryItem(name: "order_by", value: "download_count"),
                URLQueryItem(name: "order_direction", value: "desc"),
            ]
            let o = try await json(try request("subtitles", query: q))
            guard let rows = o["data"] as? [[String: Any]] else { throw Failure.badResponse("no data array") }
            var out: [Candidate] = []
            for row in rows {
                guard let a = row["attributes"] as? [String: Any],
                      let files = a["files"] as? [[String: Any]],
                      let first = files.first, let fid = first["file_id"] as? Int else { continue }
                let fpsValue: Double? = (a["fps"] as? Double) ?? (a["fps"] as? Int).map(Double.init)
                out.append(Candidate(fileID: fid,
                                     release: (a["release"] as? String) ?? (first["file_name"] as? String) ?? "",
                                     language: (a["language"] as? String) ?? language,
                                     hearingImpaired: (a["hearing_impaired"] as? Bool) ?? false,
                                     downloadCount: (a["download_count"] as? Int) ?? 0,
                                     fps: fpsValue,
                                     machineTranslated: (a["machine_translated"] as? Bool) ?? false,
                                     aiTranslated: (a["ai_translated"] as? Bool) ?? false))
            }
            return out
        }

        /// POST /download {file_id} → {link, remaining, reset_time}; then GET the link.
        func download(fileID: Int) async throws -> Data {
            let o = try await json(try request("download", method: "POST", body: ["file_id": fileID, "sub_format": "srt"]))
            if let remaining = o["remaining"] as? Int, remaining < 0 {
                throw Failure.quotaExceeded((o["reset_time"] as? String) ?? "later")
            }
            guard let link = o["link"] as? String, let url = URL(string: link) else {
                throw Failure.badResponse((o["message"] as? String) ?? "download without link")
            }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            let code: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(code), !data.isEmpty else { throw Failure.http(code, "subtitle file download") }
            return data
        }
    }

    // MARK: - SRT parsing

    static func parseSRT(_ data: Data) -> [Cue] {
        var text: String = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines: [String] = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let s = parseTime(parts[0]), let e = parseTime(parts[1]) else { continue }
            let body: String = lines[(timeIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(Cue(startNs: s, endNs: max(e, s), text: body))
        }
        return cues.sorted { $0.startNs < $1.startNs }
    }

    /// "00:01:02,345" (also accepts "." and missing hours) → nanoseconds.
    static func parseTime(_ raw: String) -> Int64? {
        let s = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let main = s.replacingOccurrences(of: ".", with: ",")
        let msSplit = main.split(separator: ",", omittingEmptySubsequences: false)
        let hms = msSplit[0].split(separator: ":").compactMap { Int64($0) }
        guard hms.count >= 2 else { return nil }
        let ms: Int64 = msSplit.count > 1 ? Int64(String(msSplit[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0 : 0
        let (h, m, sec): (Int64, Int64, Int64) = hms.count == 3 ? (hms[0], hms[1], hms[2]) : (0, hms[0], hms[1])
        return ((h * 3600 + m * 60 + sec) * 1000 + ms) * 1_000_000
    }

    // MARK: - Alignment

    /// Pairs OCR cue indices with reference cue indices. The reference usually comes from
    /// another release, so a constant offset and a slow drift (frame-rate differences) are
    /// estimated from confident text matches first, then every cue is matched within a
    /// narrow window around its predicted time.
    static func align(ocr: [Cue], reference: [Cue]) -> [Int: Int] {
        let ocrKeys: [String] = ocr.map { comparisonKey($0.text) }
        let refKeys: [String] = reference.map { comparisonKey($0.text) }
        let refStarts: [Int64] = reference.map { $0.startNs }

        // Pass 1: confident matches within ±90 s → samples of (ocrStart, refStart - ocrStart).
        var samples: [(t: Double, d: Double)] = []
        let wide: Int64 = 90_000_000_000
        for (i, c) in ocr.enumerated() where ocrKeys[i].count >= 12 {
            let lo: Int = lowerBound(refStarts, c.startNs - wide)
            var bestSim: Double = 0
            var bestJ: Int = -1
            var j: Int = lo
            while j < reference.count, refStarts[j] <= c.startNs + wide {
                if abs(refKeys[j].count - ocrKeys[i].count) <= max(4, ocrKeys[i].count / 3) {
                    let sim: Double = similarity(ocrKeys[i], refKeys[j])
                    if sim > bestSim { bestSim = sim; bestJ = j }
                }
                j += 1
            }
            if bestSim >= 0.9, bestJ >= 0 {
                samples.append((Double(c.startNs), Double(refStarts[bestJ] - c.startNs)))
            }
        }
        guard samples.count >= 5 else { return [:] }

        // Robust linear fit d = a + b·t: slope from the median of pairwise slopes between
        // samples far apart, intercept from the median residual.
        samples.sort { $0.t < $1.t }
        var slopes: [Double] = []
        let step: Int = max(1, samples.count / 2)
        for k in 0 ..< (samples.count - step) {
            let p = samples[k], q = samples[k + step]
            if q.t - p.t > 60_000_000_000 { slopes.append((q.d - p.d) / (q.t - p.t)) }
        }
        let b: Double = slopes.isEmpty ? 0 : median(slopes)
        let slope: Double = abs(b) < 0.05 ? b : 0     // > 5 % drift is not a frame-rate difference
        let a: Double = median(samples.map { $0.d - slope * $0.t })

        // Pass 2: every cue within ±1.5 s of its predicted reference time; best similarity wins.
        var pairs: [Int: Int] = [:]
        var usedRef = Set<Int>()
        let narrow: Int64 = 1_500_000_000
        for (i, c) in ocr.enumerated() {
            let predicted: Int64 = c.startNs + Int64(a + slope * Double(c.startNs))
            let lo: Int = lowerBound(refStarts, predicted - narrow)
            var bestScore: Double = 0
            var bestJ: Int = -1
            var j: Int = lo
            while j < reference.count, refStarts[j] <= predicted + narrow {
                if !usedRef.contains(j) {
                    let sim: Double = similarity(ocrKeys[i], refKeys[j])
                    let dt: Double = Double(abs(refStarts[j] - predicted)) / Double(narrow)
                    let score: Double = sim - 0.1 * dt
                    if score > bestScore { bestScore = score; bestJ = j }
                }
                j += 1
            }
            if bestJ >= 0, bestScore >= 0.6 {
                pairs[i] = bestJ
                usedRef.insert(bestJ)
            }
        }
        return pairs
    }

    private static func lowerBound(_ a: [Int64], _ x: Int64) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Text reduced to what OCR confusions cannot change: lowercase letters and digits, with
    /// I/l/1/| unified, apostrophes, tags, ♪ and residue removed.
    static func comparisonKey(_ text: String) -> String {
        var s: String = stripTags(text).lowercased()
        s = s.replacingOccurrences(of: "[|1]", with: "l", options: .regularExpression)
        s = s.replacingOccurrences(of: "i", with: "l")
        s = s.replacingOccurrences(of: "0", with: "o")
        s = s.replacingOccurrences(of: "[^a-z0-9\\p{L}]+", with: "", options: .regularExpression)
        return s
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "</?[A-Za-z][^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }

    /// Normalised Levenshtein similarity in 0…1 (1 = identical). Cheap bail-out on length.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        let n = x.count, m = y.count
        if n == 0 || m == 0 { return 0 }
        if abs(n - m) * 2 > max(n, m) { return 0 }
        var prev = [Int](0 ... m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1 ... n {
            cur[0] = i
            for j in 1 ... m {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[m]) / Double(max(n, m))
    }

    // MARK: - Correction

    struct Corrected {
        var cues: [Cue]
        var changedCues: Int
        var changedWords: Int
        var samples: [String]
    }

    /// Repairs each aligned OCR cue from its reference cue, word by word. OCR line breaks and
    /// tags are preserved; a word is replaced only when it is "confusable" with the reference
    /// word (see `confusable`). ♪ at the ends of the reference line replace residue in the OCR.
    static func correct(ocr: [Cue], reference: [Cue], pairs: [Int: Int], language: String?) -> Corrected {
        var out: [Cue] = ocr
        var changedCues = 0, changedWords = 0
        var samples: [String] = []
        for (i, j) in pairs.sorted(by: { $0.key < $1.key }) {
            let before: String = ocr[i].text
            let (after, n) = repairCue(before, reference: reference[j].text)
            if n > 0, after != before {
                out[i].text = after
                changedCues += 1
                changedWords += n
                if samples.count < 10 {
                    samples.append(before.replacingOccurrences(of: "\n", with: " / ") + "  →  " + after.replacingOccurrences(of: "\n", with: " / "))
                }
            }
        }
        return Corrected(cues: out, changedCues: changedCues, changedWords: changedWords, samples: samples)
    }

    /// One OCR cue against one reference cue. Returns the repaired text and the number of
    /// words changed.
    static func repairCue(_ ocrText: String, reference refText: String) -> (String, Int) {
        let refWords: [String] = stripTags(refText).replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !refWords.isEmpty else { return (ocrText, 0) }
        let refKeys: [String] = refWords.map { wordKey($0) }

        // OCR tokens keep their line and tag structure: tags and newlines are opaque tokens.
        var tokens: [Token] = tokenize(ocrText)
        let wordIdx: [Int] = tokens.indices.filter { tokens[$0].kind == .word }
        let ocrKeys: [String] = wordIdx.map { wordKey(tokens[$0].text) }

        // Align the two word sequences on their keys (LCS), then look at the gaps.
        let ops: [Op] = diff(ocrKeys, refKeys)
        var changed = 0
        for op in ops {
            switch op {
            case .equal(let a, let b):
                // Same key: take the reference spelling when the difference is a known confusion.
                let t: Int = wordIdx[a]
                let fixed: String = mergeConfusable(ocr: tokens[t].text, ref: refWords[b])
                if fixed != tokens[t].text { tokens[t].text = fixed; changed += 1 }
            case .replace(let a0, let a1, let b0, let b1):
                // Only same-length runs of confusable words are replaced, one for one.
                guard a1 - a0 == b1 - b0 else { continue }
                for k in 0 ..< (a1 - a0) {
                    let t: Int = wordIdx[a0 + k]
                    let r: String = refWords[b0 + k]
                    if confusable(ocr: tokens[t].text, ref: r) {
                        let fixed: String = mergeConfusable(ocr: tokens[t].text, ref: r)
                        if fixed != tokens[t].text { tokens[t].text = fixed; changed += 1 }
                    }
                }
            case .insert, .delete:
                continue   // wording differs: leave the OCR as it is
            }
        }
        // ♪ at the ends of the reference, residue at the ends of the OCR line → ♪.
        changed += repairNotes(&tokens, reference: refWords)
        return (tokens.map { $0.text }.joined(), changed)
    }

    // Tokens: words, whitespace/newlines, tags.
    struct Token {
        enum Kind { case word, space, tag }
        var kind: Kind
        var text: String
    }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var current: String = ""
        var kind: Token.Kind = .word
        func flush() {
            if !current.isEmpty { tokens.append(Token(kind: kind, text: current)); current = "" }
        }
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "<", let close = s[i...].firstIndex(of: ">") {
                flush()
                tokens.append(Token(kind: .tag, text: String(s[i ... close])))
                i = s.index(after: close)
                continue
            }
            let k: Token.Kind = (ch == " " || ch == "\n" || ch == "\t") ? .space : .word
            if k != kind { flush(); kind = k }
            current.append(ch)
            i = s.index(after: i)
        }
        flush()
        return tokens
    }

    /// Key of one word for the diff: letters/digits only, OCR confusions unified.
    static func wordKey(_ w: String) -> String { comparisonKey(w) }

    enum Op {
        case equal(Int, Int)
        case replace(Int, Int, Int, Int)
        case insert(Int, Int)
        case delete(Int, Int)
    }

    /// LCS-based diff of two key sequences (a = OCR, b = reference).
    static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] && !a[i].isEmpty ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        var pendA = 0, pendB = 0   // counts of pending unmatched a and b items
        func flushPending() {
            if pendA > 0 && pendB > 0 { ops.append(.replace(i - pendA, i, j - pendB, j)) }
            else if pendA > 0 { ops.append(.delete(i - pendA, i)) }
            else if pendB > 0 { ops.append(.insert(j - pendB, j)) }
            pendA = 0; pendB = 0
        }
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] && !a[i].isEmpty {
                flushPending()
                ops.append(.equal(i, j))
                i += 1; j += 1
            } else if j < m && (i >= n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                pendB += 1; j += 1
            } else {
                pendA += 1; i += 1
            }
        }
        flushPending()
        return ops
    }

    /// True when the OCR word and the reference word differ only by known OCR confusions:
    /// same key (I/l/1/|, 0/O, apostrophes, punctuation), or one letter swapped among the
    /// confusable sets (rn/m, cl/d, vv/w) in words of 4+ letters.
    static func confusable(ocr: String, ref: String) -> Bool {
        let a: String = wordKey(ocr), b: String = wordKey(ref)
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        var x: String = a, y: String = b
        for (from, to) in [("rn", "m"), ("cl", "d"), ("vv", "w"), ("ii", "u"), ("ln", "h")] {
            x = x.replacingOccurrences(of: from, with: to)
            y = y.replacingOccurrences(of: from, with: to)
        }
        if x == y { return true }
        guard b.count >= 4 else { return false }
        // One-character difference at the same length, in a word otherwise identical.
        if a.count == b.count {
            let diffs: Int = zip(a, b).filter { $0.0 != $0.1 }.count
            return diffs == 1 && b.count >= 6
        }
        return false
    }

    /// Spelling from the reference, case and surrounding punctuation style from the OCR where
    /// the keys agree; otherwise the reference word with the OCR's leading/trailing punctuation.
    static func mergeConfusable(ocr: String, ref: String) -> String {
        let (lead, coreOCR, trail) = splitPunctuation(ocr)
        let (_, coreRef, trailRef) = splitPunctuation(ref)
        guard !coreRef.isEmpty else { return ocr }
        var core: String = coreRef
        // Keep the OCR's capitalisation pattern when it is all-caps or capitalised and the
        // reference is lower-case (speaker labels, shouting).
        if coreOCR == coreOCR.uppercased(), coreOCR != coreOCR.lowercased(), coreOCR.count > 1 {
            core = coreRef.uppercased()
        } else if let f = coreOCR.first, f.isUppercase, coreRef.first?.isLowercase == true {
            core = coreRef.prefix(1).uppercased() + String(coreRef.dropFirst())
        }
        // Punctuation: trust the reference for apostrophes inside the word (handled by core),
        // keep the OCR's trailing punctuation unless the OCR has none and the reference has a
        // plain comma/period/question/exclamation mark.
        var t: String = trail
        if t.isEmpty, let last = trailRef.last, ",.?!".contains(last), trailRef.count == 1 { t = trailRef }
        return lead + core + t
    }

    static func splitPunctuation(_ w: String) -> (String, String, String) {
        let chars = Array(w)
        var s = 0, e = chars.count
        func isEdge(_ c: Character) -> Bool { !(c.isLetter || c.isNumber || c == "'" || c == "’") }
        while s < e, isEdge(chars[s]) { s += 1 }
        while e > s, isEdge(chars[e - 1]) { e -= 1 }
        return (String(chars[0 ..< s]), String(chars[s ..< e]), String(chars[e ..< chars.count]))
    }

    static let residue: Set<String> = ["&", "¿", "§", "›", "‹", "•", "~", "^", "«", "»", "s", "S", "f", "j", "d", "8", "б", "dr", "J", "of", "os", "as"]

    /// When the reference starts or ends with ♪ and the OCR line starts/ends with a residue
    /// token (or lacks the note), put the ♪ there. Returns the number of changes.
    static func repairNotes(_ tokens: inout [Token], reference: [String]) -> Int {
        guard let rf = reference.first, let rl = reference.last else { return 0 }
        let refStarts: Bool = rf.hasPrefix("♪"), refEnds: Bool = rl.hasSuffix("♪")
        guard refStarts || refEnds else { return 0 }
        var changed = 0
        // Work per OCR line.
        var lineStart = 0
        var idx = 0
        while idx <= tokens.count {
            let atEnd: Bool = idx == tokens.count || (tokens[idx].kind == .space && tokens[idx].text.contains("\n"))
            if atEnd {
                let words: [Int] = (lineStart ..< idx).filter { tokens[$0].kind == .word }
                if let w0 = words.first, refStarts, lineStart == 0 {
                    let t: String = tokens[w0].text
                    let note: String = rf.allSatisfy { $0 == "♪" } ? rf : "♪"
                    if residue.contains(t) { tokens[w0].text = note; changed += 1 }
                    else if t == "-" || t == "–", words.count > 1, residue.contains(tokens[words[1]].text) { tokens[words[1]].text = note; changed += 1 }
                }
                if let wN = words.last, refEnds, idx == tokens.count {
                    let t: String = tokens[wN].text
                    let bare: String = (t.hasSuffix(".") || t.hasSuffix(",")) ? String(t.dropLast()) : t
                    let note: String = rl.allSatisfy { $0 == "♪" } ? rl : "♪"
                    if residue.contains(bare) { tokens[wN].text = note; changed += 1 }
                }
                lineStart = idx + 1
            }
            idx += 1
        }
        return changed
    }
}

// MARK: - Keychain helper (generic passwords, this app only)

enum KeychainStore {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(service: String, account: String, value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data: Data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
