import Foundation
import SwiftUI

/// The IMDb step of a job: turns "Cloud Atlas_t00.mkv" into "Cloud Atlas (2012).mkv".
/// Runs for every queued file *before* any subtitle or video work starts, so that all the
/// questions ("which Batman?") are asked up front and answered in one go.
///
/// Confident matches are renamed silently. Anything doubtful (several similar titles, a year
/// that does not agree, only loose matches, nothing found) is put to the user: in the app as a
/// picker sheet with the candidates, an editable search and a "keep the file name" way out;
/// on the command line as a numbered list (when stdin is a terminal), otherwise the name is kept.
@MainActor
final class MovieResolver: ObservableObject {

    enum Interaction {
        case gui        // picker sheet
        case terminal   // numbered list on stdin/stdout
        case none       // never ask: keep the file name on doubt
    }

    enum Outcome {
        case picked(MovieIdentity)
        case keepName
        case search(String)
    }

    /// What the picker shows.
    struct Prompt: Identifiable {
        let id = UUID()
        let job: Job
        let fileName: String
        var query: String
        var candidates: [MovieIdentity]
        var reason: String
        var searching = false
        var error: String?
    }

    @Published var prompt: Prompt?
    private var continuation: CheckedContinuation<Outcome, Never>?

    // MARK: - Entry point

    /// Identifies the job's file and renames it to "Movie Name (yyyy).mkv". Never fails the job:
    /// on any problem the original name is kept and `job.message` says why.
    func resolve(job: Job, interaction: Interaction, log: ((String) -> Void)?) async {
        let url = job.url
        job.state = .identifying
        let guess = FilenameParser.parse(url.lastPathComponent)
        var segmentTitle = ""
        if let demuxer = try? MatroskaDemuxer(url: url) { segmentTitle = demuxer.title }
        let described = guess.title.isEmpty ? "(no title in the file name)" : "\"\(guess.title)\"\(guess.year.map { " (\($0))" } ?? "")"
        log?("  file name parses as \(described)\(segmentTitle.isEmpty ? "" : "; MKV title \"\(segmentTitle)\""); looking it up on IMDb …")

        let resolution: IMDbLookup.Resolution
        do {
            resolution = try await IMDbLookup.identify(guess: guess, alternateTitle: segmentTitle)
        } catch {
            log?("  IMDb lookup failed: \(error.localizedDescription); keeping the file name")
            job.message = "IMDb lookup failed (\(error.localizedDescription)); file name kept."
            return
        }

        var candidates: [MovieIdentity] = []
        var reason = ""
        switch resolution {
        case .confident(let found, _):
            log?("  IMDb: \(found.label) \(found.imdbID) — confident match")
            rename(job: job, to: found, log: log)
            return
        case .ambiguous(let list, let why):
            candidates = list
            reason = why
        case .nothing:
            reason = guess.title.isEmpty ? "The file name has no usable title." : "Nothing on IMDb matches \"\(guess.title)\"."
        }
        log?("  IMDb: \(reason)")
        for (i, c) in candidates.prefix(8).enumerated() {
            log?("    \(i + 1). \(c.label) \(c.kind.isEmpty ? "" : "[\(c.kind)] ")\(c.stars)")
        }

        var query = guess.title
        if let y = guess.year { query += " \(y)" }
        if query.isEmpty { query = FilenameParser.parse(segmentTitle).title }
        if query.isEmpty { query = (url.lastPathComponent as NSString).deletingPathExtension }

        switch interaction {
        case .none:
            job.message = "IMDb: \(reason) File name kept."
            log?("  keeping the file name")
            return
        case .terminal:
            await resolveInTerminal(job: job, query: query, candidates: candidates, reason: reason, log: log)
        case .gui:
            await resolveWithSheet(job: job, query: query, candidates: candidates, reason: reason, log: log)
        }
    }

    // MARK: - GUI

    private func resolveWithSheet(job: Job, query: String, candidates: [MovieIdentity], reason: String, log: ((String) -> Void)?) async {
        prompt = Prompt(job: job, fileName: job.url.lastPathComponent, query: query, candidates: candidates, reason: reason)
        job.message = "Waiting for you to pick the film on IMDb…"
        defer { prompt = nil }
        while true {
            let outcome = await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
                continuation = c
            }
            continuation = nil
            switch outcome {
            case .picked(let m):
                job.message = ""
                log?("  you picked \(m.label) \(m.imdbID)")
                rename(job: job, to: m, log: log)
                return
            case .keepName:
                job.message = "IMDb: file name kept."
                log?("  keeping the file name")
                return
            case .search(let q):
                prompt?.searching = true
                prompt?.error = nil
                prompt?.query = q
                do {
                    let results = try await IMDbLookup.search(q)
                    prompt?.candidates = results
                    if results.isEmpty { prompt?.error = "IMDb found nothing for \"\(q)\"." }
                } catch {
                    prompt?.error = "IMDb search failed: \(error.localizedDescription)"
                }
                prompt?.searching = false
            }
        }
    }

    /// Called by the picker sheet.
    func choose(_ outcome: Outcome) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: outcome)
    }

    // MARK: - Terminal

    private func resolveInTerminal(job: Job, query: String, candidates list: [MovieIdentity], reason: String, log: ((String) -> Void)?) async {
        var candidates = list
        var query = query
        while true {
            print("")
            print("? \(job.url.lastPathComponent): \(reason)")
            if candidates.isEmpty {
                print("  (no candidates)")
            }
            for (i, c) in candidates.enumerated() {
                let extra = [c.kind, c.stars].filter { !$0.isEmpty }.joined(separator: " · ")
                print("  \(i + 1). \(c.label)\(extra.isEmpty ? "" : "  — \(extra)")")
            }
            print("  Enter a number to pick, 's' to keep the file name, or type a new search [\(query)]: ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
                job.message = "IMDb: file name kept."
                return
            }
            if line.lowercased() == "s" || line.lowercased() == "skip" {
                job.message = "IMDb: file name kept."
                log?("  keeping the file name")
                return
            }
            if let n = Int(line), n >= 1, n <= candidates.count {
                rename(job: job, to: candidates[n - 1], log: log)
                return
            }
            let q = line.isEmpty ? query : line
            query = q
            do {
                candidates = try await IMDbLookup.search(q)
            } catch {
                print("  IMDb search failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Rename

    /// Renames the job's file to "Movie Name (yyyy).<ext>" next to itself. Keeps the name (with a
    /// note) when IMDb has no year, the target exists, or the move fails.
    func rename(job: Job, to found: MovieIdentity, log: ((String) -> Void)?) {
        job.identity = found
        let url = job.url
        guard let base = found.baseName else {
            job.message = "IMDb has no year for \(found.title); file name kept."
            log?("  IMDb has no year for \(found.title); keeping the file name")
            return
        }
        let ext = url.pathExtension
        let target = url.deletingLastPathComponent().appendingPathComponent("\(base).\(ext)")
        if target.lastPathComponent == url.lastPathComponent { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            log?("  \(target.lastPathComponent) already exists; keeping the file name")
            job.message = "\(target.lastPathComponent) already exists; file name kept."
            return
        }
        do {
            try fm.moveItem(at: url, to: target)
            log?("  renamed -> \(target.lastPathComponent)")
            job.moved(to: target)
        } catch {
            log?("  rename failed: \(error.localizedDescription)")
            job.message = "Could not rename: \(error.localizedDescription)"
        }
    }
}

/// The picker: "Which film is Batman_t00.mkv?" with IMDb's candidates, an editable search and a way out.
struct IMDbPickerSheet: View {
    @EnvironmentObject private var resolver: MovieResolver
    let prompt: MovieResolver.Prompt
    @State private var query: String
    @State private var selection: String?

    init(prompt: MovieResolver.Prompt) {
        self.prompt = prompt
        _query = State(initialValue: prompt.query)
        _selection = State(initialValue: prompt.candidates.first?.imdbID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which film is “\(prompt.fileName)”?")
                .font(.headline)
            Text(prompt.reason + " Pick the right title, refine the search (add the year), or keep the file name.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Title and year", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(prompt.searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                if prompt.searching { ProgressView().controlSize(.small) }
            }
            if let e = prompt.error {
                Text(e).font(.caption).foregroundStyle(.orange)
            }

            List(selection: $selection) {
                ForEach(prompt.candidates) { m in
                    CandidateRow(movie: m)
                        .tag(m.imdbID)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { resolver.choose(.picked(m)) }
                }
            }
            .frame(minHeight: 220)
            .overlay {
                if prompt.candidates.isEmpty && !prompt.searching {
                    Text("No candidates. Try another search.").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Keep file name") { resolver.choose(.keepName) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let id = selection, let m = prompt.candidates.first(where: { $0.imdbID == id }) {
                    Link("Open on IMDb", destination: m.imdbURL)
                    Button("Use “\(m.label)”") { resolver.choose(.picked(m)) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Use selected title") {}.disabled(true)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .onChange(of: prompt.candidates.map { $0.imdbID }) { ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !prompt.searching else { return }
        resolver.choose(.search(q))
    }
}

struct CandidateRow: View {
    let movie: MovieIdentity

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url = movie.posterURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 36, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(movie.title).fontWeight(.medium)
                    Text(movie.year.map(String.init) ?? "no year").foregroundStyle(.secondary)
                    if !movie.kind.isEmpty {
                        Text(movie.kind).font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                }
                if !movie.stars.isEmpty {
                    Text(movie.stars).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(movie.imdbID).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
