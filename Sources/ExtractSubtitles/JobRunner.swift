import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// How extracted tracks are turned into SRT.
enum ConversionMode: String, CaseIterable, Identifiable {
    case off          // extract only
    case local        // on this Mac: text formats directly, PGS via Apple Vision OCR

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off (extract only)"
        case .local: return "Locally (Apple Vision OCR)"
        }
    }
    static let storageKey = "conversionMode"

    /// Older builds stored "both" / "subtitletools"; those now mean local.
    static func from(stored raw: String?) -> ConversionMode {
        guard let raw = raw, let mode = ConversionMode(rawValue: raw) else { return .local }
        return mode
    }
}

/// One extracted track inside a job.
@MainActor
final class TrackResult: ObservableObject, Identifiable {
    let id = UUID()
    let track: SubtitleTrack
    let fileName: String
    @Published var state: State = .pending
    @Published var srtNames: [String] = []
    @Published var notes: [String] = []
    @Published var detailProgress: Double? = nil

    enum State: Equatable {
        case pending, extracted, converting, done, skipped(String), failed(String)
    }

    init(track: SubtitleTrack, fileName: String) {
        self.track = track
        self.fileName = fileName
    }

    var languageName: String { Naming.displayName(Naming.languageTag(for: track)) }
    var languageTag: String { Naming.languageTag(for: track) }
}

/// One MKV being processed.
@MainActor
final class Job: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL
    @Published var identity: MovieIdentity?
    @Published var originalName: String?
    @Published var state: State = .queued
    @Published var progress: Double = 0
    @Published var tracks: [TrackResult] = []
    @Published var outputFolder: URL?
    @Published var message: String = ""

    enum State: Equatable { case queued, scanning, extracting, converting, done, failed(String) }

    init(url: URL) { self.url = url }

    var movieName: String { url.deletingPathExtension().lastPathComponent }

    func moved(to newURL: URL) {
        if originalName == nil { originalName = url.lastPathComponent }
        url = newURL
    }

    var hasFailures: Bool {
        if case .failed = state { return true }
        return tracks.contains { if case .failed = $0.state { return true } else { return false } }
    }

    var srtCount: Int { tracks.reduce(0) { $0 + $1.srtNames.count } }
}

/// Owns the queue of jobs and runs them one after another.
@MainActor
final class JobRunner: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @AppStorage(ConversionMode.storageKey) var conversionModeRaw = ConversionMode.local.rawValue
    @AppStorage(JobRunner.renameKey) var renameFromIMDb = true

    static let renameKey = "renameFromIMDb"
    var conversionMode: ConversionMode { ConversionMode.from(stored: conversionModeRaw) }

    private var queue: [Job] = []

    func enqueue(_ urls: [URL]) {
        var added = false
        for url in urls {
            let isMKV = url.pathExtension.lowercased() == "mkv"
            let job = Job(url: url)
            if !isMKV {
                job.state = .failed("Not an MKV file")
                jobs.insert(job, at: 0)
                continue
            }
            jobs.insert(job, at: 0)
            queue.append(job)
            added = true
        }
        if added { startIfNeeded() }
    }

    /// "Open MKV…" (toolbar + and File menu).
    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = []
        if let t = UTType("org.matroska.mkv") { types.append(t) }
        if let t = UTType(filenameExtension: "mkv") { types.append(t) }
        panel.allowedContentTypes = types.isEmpty ? [.data] : types
        panel.allowsOtherFileTypes = true
        panel.message = "Choose MKV files to extract subtitles from"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }

    func clearFinished() {
        jobs.removeAll { job in
            switch job.state {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    private func startIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            while let job = queue.first {
                queue.removeFirst()
                await SubtitleExtractor.process(job: job, mode: conversionMode, rename: renameFromIMDb, log: nil)
                notify(job)
            }
            isRunning = false
        }
    }

    private func notify(_ job: Job) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Extract Subtitles"
        let done = job.tracks.filter { $0.state == .done || $0.state == .extracted }.count
        if case .failed(let why) = job.state {
            content.body = "\(job.movieName): \(why)"
        } else {
            content.body = "\(job.movieName): \(done) track(s) extracted, \(job.srtCount) SRT file(s)"
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// The actual work for one MKV. Shared by the GUI and the `--cli` mode.
enum SubtitleExtractor {

    static func process(job: Job, mode: ConversionMode, rename: Bool = true, log: ((String) -> Void)?) async {
        let startURL = await job.url
        log?("Processing \(startURL.path)")
        await MainActor.run { job.state = .scanning }

        // 0. Identify the movie on IMDb and rename the file to "Movie Name (yyyy).mkv".
        let url = rename ? await identifyAndRename(job: job, url: startURL, log: log) : startURL
        let movie = await job.movieName
        let outDir = url.deletingLastPathComponent().appendingPathComponent(movie + Naming.subfolderSuffix, isDirectory: true)
        await MainActor.run { job.outputFolder = outDir }

        // 1. Scan + demux on a background thread.
        let demuxResult: Result<([SubtitleTrack], [UInt64: [SubtitleFrame]]), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let demuxer = try MatroskaDemuxer(url: url)
                let tracks = demuxer.tracks
                let frames = try demuxer.readFrames(for: tracks.filter { $0.kind.isSupported }) { p in
                    Task { @MainActor in job.progress = p * 0.5; job.state = .extracting }
                }
                return .success((tracks, frames))
            } catch {
                return .failure(error)
            }
        }.value

        let tracks: [SubtitleTrack]
        let frames: [UInt64: [SubtitleFrame]]
        switch demuxResult {
        case .failure(let error):
            log?("  error: \(error.localizedDescription)")
            await MainActor.run { job.state = .failed(error.localizedDescription) }
            return
        case .success(let r):
            tracks = r.0
            frames = r.1
        }

        guard !tracks.isEmpty else {
            log?("  no subtitle tracks")
            await MainActor.run { job.state = .failed("No subtitle tracks in this file") }
            return
        }

        // 2. Write each track.
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            await MainActor.run { job.state = .failed("Could not create \(outDir.lastPathComponent): \(error.localizedDescription)") }
            return
        }

        var used = Set<String>()
        var results: [TrackResult] = []
        for track in tracks {
            let base = Naming.baseName(movie: movie, track: track, used: &used)
            let name = "\(base).\(track.kind.fileExtension)"
            let result = await MainActor.run { TrackResult(track: track, fileName: name) }
            results.append(result)
            log?("  track #\(track.number) \(track.codecID) \(Naming.describe(track))")

            guard track.kind.isSupported else {
                await MainActor.run { result.state = .skipped("\(track.kind.label) is not supported yet") }
                log?("    skipped: \(track.kind.label) not supported")
                continue
            }
            do {
                let data = try SubtitleWriter.encode(track: track, frames: frames[track.number] ?? [])
                try data.write(to: outDir.appendingPathComponent(name), options: .atomic)
                await MainActor.run { result.state = .extracted }
                log?("    -> \(name)")
            } catch {
                await MainActor.run { result.state = .failed(error.localizedDescription) }
                log?("    failed: \(error.localizedDescription)")
            }
        }
        let finalResults = results
        await MainActor.run { job.tracks = finalResults; job.progress = 0.5 }

        // 3. Convert to SRT.
        let candidates = results.filter { $0.track.kind.isSupported }
        if mode != .off {
            await MainActor.run { job.state = .converting }
        }
        var i = 0
        for result in results {
            let state = await MainActor.run { result.state }
            guard state == .extracted else { continue }
            let track = result.track
            let fileName = result.fileName
            let base = (fileName as NSString).deletingPathExtension

            if track.kind == .srt {
                // Already SRT: nothing to convert, no credits spent.
                await MainActor.run { result.state = .done; result.srtNames = [fileName] }
                continue
            }
            guard mode != .off else { continue }

            await MainActor.run { result.state = .converting }
            var notes: [String] = []
            var produced: [String] = []

            // 3. local conversion (text formats directly, PGS via Apple Vision OCR)
            do {
                let srtName = "\(base).srt"
                do {
                    log?("    converting \(fileName) locally\(track.kind.isTextBased ? "" : " with Apple Vision OCR") …")
                    let srt = try await LocalConverter.convertToSRT(track: track, frames: frames[track.number] ?? []) { p in
                        Task { @MainActor in result.detailProgress = p }
                    }
                    try srt.write(to: outDir.appendingPathComponent(srtName), options: .atomic)
                    produced.append(srtName)
                    log?("    -> \(srtName)")
                } catch {
                    notes.append(error.localizedDescription)
                    log?("    conversion failed: \(error.localizedDescription)")
                }
                await MainActor.run { result.detailProgress = nil }
            }

            let finalNotes = notes, finalProduced = produced
            await MainActor.run {
                result.srtNames = finalProduced
                result.notes = finalNotes
                if !finalProduced.isEmpty {
                    result.state = .done
                } else if let first = finalNotes.first {
                    result.state = track.kind.isTextBased ? .failed(first) : .skipped(first)
                } else {
                    result.state = .extracted
                }
            }
            i += 1
            let p = 0.5 + 0.5 * Double(i) / Double(max(1, candidates.count))
            await MainActor.run { job.progress = p }
        }

        await MainActor.run { job.progress = 1; job.state = .done }
        log?("Done: \(outDir.path)")
    }

    /// Looks the file up on IMDb and renames it to "Movie Name (yyyy).mkv" when a confident match
    /// with a year comes back. Returns the (possibly new) URL. Never fails the job: on any problem
    /// the original name is kept and a note is shown.
    static func identifyAndRename(job: Job, url: URL, log: ((String) -> Void)?) async -> URL {
        let guess = FilenameParser.parse(url.lastPathComponent)
        var segmentTitle = ""
        if let demuxer = try? MatroskaDemuxer(url: url) { segmentTitle = demuxer.title }
        log?("  looking up \"\(guess.title)\"\(guess.year.map { " (\($0))" } ?? "") on IMDb …")

        let identity: MovieIdentity?
        do {
            identity = try await IMDbLookup.identify(guess: guess, alternateTitle: segmentTitle)
        } catch {
            log?("  IMDb lookup failed: \(error.localizedDescription); keeping the file name")
            await MainActor.run { job.message = "IMDb lookup failed (\(error.localizedDescription)); file name kept." }
            return url
        }
        guard let found = identity else {
            log?("  no IMDb match; keeping the file name")
            await MainActor.run { job.message = "No IMDb match for \"\(guess.title)\"; file name kept." }
            return url
        }
        await MainActor.run { job.identity = found }
        log?("  IMDb: \(found.title) (\(found.year.map(String.init) ?? "no year")) \(found.imdbID)")

        guard let base = found.baseName else {
            await MainActor.run { job.message = "IMDb has no year for \(found.title); file name kept." }
            return url
        }
        let ext = url.pathExtension
        let target = url.deletingLastPathComponent().appendingPathComponent("\(base).\(ext)")
        if target.lastPathComponent == url.lastPathComponent { return url }

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            log?("  \(target.lastPathComponent) already exists; keeping the file name")
            await MainActor.run { job.message = "\(target.lastPathComponent) already exists; file name kept." }
            return url
        }
        do {
            try fm.moveItem(at: url, to: target)
            log?("  renamed -> \(target.lastPathComponent)")
            await MainActor.run { job.moved(to: target) }
            return target
        } catch {
            log?("  rename failed: \(error.localizedDescription)")
            await MainActor.run { job.message = "Could not rename: \(error.localizedDescription)" }
            return url
        }
    }
}

extension SubtitleKind: Equatable {
    static func == (lhs: SubtitleKind, rhs: SubtitleKind) -> Bool {
        lhs.fileExtension == rhs.fileExtension && lhs.label == rhs.label
    }
}
