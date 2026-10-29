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
    @Published var fileName: String
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
    /// What the job does: extract subtitles (then convert to H.265 when the setting is on), or convert only.
    enum Kind { case extract, convert }

    /// Live progress of the H.265 conversion.
    struct ConversionStatus: Equatable {
        var fraction: Double
        var fps: Double
        var etaSeconds: Double?
    }

    let id = UUID()
    let kind: Kind
    let cancelToken = CancelToken()
    @Published private(set) var url: URL
    @Published var identity: MovieIdentity?
    @Published var originalName: String?
    @Published var state: State = .queued
    @Published var progress: Double = 0
    @Published var tracks: [TrackResult] = []
    @Published var outputFolder: URL?
    @Published var message: String = ""
    @Published var conversion: ConversionStatus?
    @Published var conversionOutput: URL?
    @Published var conversionSummary: String = ""
    @Published var cancelRequested = false

    enum State: Equatable { case queued, identifying, scanning, extracting, converting, encoding, done, failed(String) }

    init(url: URL, kind: Kind = .extract) {
        self.url = url
        self.kind = kind
    }

    /// Asks the running H.265 conversion to stop (the partial output file is deleted).
    func cancelConversion() {
        cancelRequested = true
        cancelToken.cancel()
    }

    /// After extraction, conversion still makes sense when the only problem was "no subtitle tracks".
    var allowsConversion: Bool {
        if case .failed(let why) = state { return why == "No subtitle tracks in this file" }
        return true
    }

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

/// Owns the queue of jobs and runs them in two phases: first every new file is matched on IMDb
/// (and renamed, asking when in doubt), then — once no question is pending — the subtitle and
/// video work runs one job after another.
@MainActor
final class JobRunner: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @AppStorage(ConversionMode.storageKey) var conversionModeRaw = ConversionMode.local.rawValue
    @AppStorage(JobRunner.renameKey) var renameFromIMDb = true
    @AppStorage(JobRunner.convertKey) var convertToH265 = false
    @AppStorage(JobRunner.qualityKey) var h265Quality = 0.85
    @AppStorage(JobRunner.ac3CopyKey) var addAC3Copies = true

    nonisolated static let renameKey = "renameFromIMDb"
    nonisolated static let convertKey = "convertToH265"
    nonisolated static let qualityKey = "h265Quality"
    nonisolated static let ac3CopyKey = "addAC3Copies"
    var conversionMode: ConversionMode { ConversionMode.from(stored: conversionModeRaw) }

    let resolver = MovieResolver()

    private var identifyQueue: [Job] = []
    private var workQueue: [Job] = []
    private var isIdentifying = false

    func enqueue(_ urls: [URL], kind: Job.Kind = .extract) {
        var added = false
        for url in urls {
            let isMKV = url.pathExtension.lowercased() == "mkv"
            let job = Job(url: url, kind: kind)
            if !isMKV {
                job.state = .failed("Not an MKV file")
                jobs.insert(job, at: 0)
                continue
            }
            jobs.insert(job, at: 0)
            if renameFromIMDb {
                identifyQueue.append(job)
            } else {
                workQueue.append(job)
            }
            added = true
        }
        if added {
            startIdentifyingIfNeeded()
            startWorkIfNeeded()
        }
    }

    /// "Open MKV…" (toolbar + and File menu); kind .convert for "Convert to H.265…".
    func openPanel(kind: Job.Kind = .extract) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = []
        if let t = UTType("org.matroska.mkv") { types.append(t) }
        if let t = UTType(filenameExtension: "mkv") { types.append(t) }
        panel.allowedContentTypes = types.isEmpty ? [.data] : types
        panel.allowsOtherFileTypes = true
        panel.message = kind == .convert ? "Choose MKV files to convert to H.265 (MP4)" : "Choose MKV files to extract subtitles from"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { enqueue(panel.urls, kind: kind) }
    }

    func clearFinished() {
        jobs.removeAll { job in
            switch job.state {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    /// Phase 1: IMDb for every new file, in order, one question at a time.
    private func startIdentifyingIfNeeded() {
        guard !isIdentifying, !identifyQueue.isEmpty else { return }
        isIdentifying = true
        Task {
            while let job = identifyQueue.first {
                identifyQueue.removeFirst()
                await resolver.resolve(job: job, interaction: .gui, log: nil)
                job.state = .queued
                workQueue.append(job)
            }
            isIdentifying = false
            startWorkIfNeeded()
        }
    }

    /// Phase 2: the actual work, only once every queued file has been through IMDb.
    private func startWorkIfNeeded() {
        guard !isRunning, !isIdentifying, !workQueue.isEmpty else { return }
        isRunning = true
        Task {
            while let job = workQueue.first {
                workQueue.removeFirst()
                switch job.kind {
                case .extract:
                    await SubtitleExtractor.process(job: job, mode: conversionMode, log: nil)
                    if convertToH265, job.allowsConversion {
                        await VideoConversionStep.run(job: job, quality: h265Quality, ac3Copies: addAC3Copies, log: nil)
                    }
                case .convert:
                    await VideoConversionStep.run(job: job, quality: h265Quality, ac3Copies: addAC3Copies, log: nil)
                }
                notify(job)
            }
            isRunning = false
            // Files identified while we were busy are already in workQueue; a new batch that is
            // still being identified restarts us when it is done.
            startWorkIfNeeded()
        }
    }

    private func notify(_ job: Job) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Extract Subtitles"
        let done = job.tracks.filter { $0.state == .done || $0.state == .extracted }.count
        if case .failed(let why) = job.state {
            content.body = "\(job.movieName): \(why)"
        } else if job.kind == .convert {
            content.body = "\(job.movieName): converted to H.265 — \(job.conversionSummary)"
        } else {
            content.body = "\(job.movieName): \(done) track(s) extracted, \(job.srtCount) SRT file(s)"
            if !job.conversionSummary.isEmpty { content.body += "; converted to H.265" }
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// The actual work for one MKV. Shared by the GUI and the `--cli` mode.
enum SubtitleExtractor {

    static func process(job: Job, mode: ConversionMode, log: ((String) -> Void)?) async {
        // The IMDb lookup and rename already happened (MovieResolver), so the name is final.
        let url = await job.url
        log?("Processing \(url.path)")
        await MainActor.run { job.state = .scanning }
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

        // 2. Make the output folder, analyse the content (cue counts, PGS forced flags, duplicate
        //    streams) and give every track a provisional name. Nothing is written yet: the final
        //    names can only be decided once the text is known (SDH captions, Chinese script).
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            await MainActor.run { job.state = .failed("Could not create \(outDir.lastPathComponent): \(error.localizedDescription)") }
            return
        }

        var analyses: [UInt64: TrackAnalysis] = [:]
        for track in tracks where track.kind.isSupported {
            analyses[track.number] = TrackAnalyzer.analyze(track: track, frames: frames[track.number] ?? [])
        }
        var plan = Naming.plan(movie: movie, tracks: tracks, analyses: analyses)

        var results: [TrackResult] = []
        var rawData: [UInt64: Data] = [:]
        var srtData: [UInt64: Data] = [:]
        for track in tracks {
            let entry = plan[track.number]
            let provisional = entry?.base ?? "\(Naming.safe(movie)).track\(track.number)"
            let name = "\(provisional).\(track.kind.fileExtension)"
            let result = await MainActor.run { TrackResult(track: track, fileName: name) }
            results.append(result)
            log?("  track #\(track.number) \(track.codecID) \(Naming.describe(track))\(Naming.describe(analyses[track.number]))")

            guard track.kind.isSupported else {
                await MainActor.run { result.state = .skipped("\(track.kind.label) is not supported yet") }
                log?("    skipped: \(track.kind.label) not supported")
                continue
            }
            if let dup = entry?.duplicateOf {
                await MainActor.run { result.state = .skipped("identical to track #\(dup)") }
                log?("    skipped: byte-identical to track #\(dup)")
                continue
            }
            do {
                rawData[track.number] = try SubtitleWriter.encode(track: track, frames: frames[track.number] ?? [])
                await MainActor.run { result.state = .extracted }
            } catch {
                await MainActor.run { result.state = .failed(error.localizedDescription) }
                log?("    failed: \(error.localizedDescription)")
            }
        }
        let finalResults = results
        await MainActor.run { job.tracks = finalResults; job.progress = 0.5 }

        // 3. Convert to SRT (in memory).
        let candidates = results.filter { $0.track.kind.isSupported }
        if mode != .off {
            await MainActor.run { job.state = .converting }
        }
        var i = 0
        for result in results {
            let state = await MainActor.run { result.state }
            guard state == .extracted else { continue }
            let track = result.track
            let fileName = await MainActor.run { result.fileName }

            if track.kind == .srt {
                // Already SRT: nothing to convert.
                srtData[track.number] = rawData[track.number]
                await MainActor.run { result.state = .done }
                continue
            }
            guard mode != .off else { continue }

            await MainActor.run { result.state = .converting }
            var notes: [String] = []
            var produced = false

            // Local conversion: text formats directly, PGS via Apple Vision OCR.
            do {
                log?("    converting \(fileName) locally\(track.kind.isTextBased ? "" : " with Apple Vision OCR") …")
                let srt = try await LocalConverter.convertToSRT(track: track, frames: frames[track.number] ?? []) { p in
                    Task { @MainActor in result.detailProgress = p }
                }
                srtData[track.number] = srt
                analyses[track.number]?.text = String(data: srt, encoding: .utf8)
                produced = true
            } catch {
                notes.append(error.localizedDescription)
                log?("    conversion failed: \(error.localizedDescription)")
            }
            await MainActor.run { result.detailProgress = nil }

            let finalNotes = notes, finalProduced = produced
            await MainActor.run {
                result.notes = finalNotes
                if finalProduced {
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

        // 4. Final names now that the text is known, then write every file.
        plan = Naming.plan(movie: movie, tracks: tracks, analyses: analyses)
        for result in results {
            let n = result.track.number
            guard rawData[n] != nil, let base = plan[n]?.base else { continue }
            let rawName = "\(base).\(result.track.kind.fileExtension)"
            var srtNames: [String] = []
            do {
                if let raw = rawData[n] {
                    try raw.write(to: outDir.appendingPathComponent(rawName), options: .atomic)
                    log?("    -> \(rawName)")
                }
                if let srt = srtData[n] {
                    if result.track.kind == .srt {
                        srtNames = [rawName]
                    } else {
                        let srtName = "\(base).srt"
                        try srt.write(to: outDir.appendingPathComponent(srtName), options: .atomic)
                        srtNames = [srtName]
                        log?("    -> \(srtName)")
                    }
                }
            } catch {
                log?("    write failed: \(error.localizedDescription)")
                await MainActor.run { result.state = .failed(error.localizedDescription) }
            }
            let finalSRTNames = srtNames
            await MainActor.run { result.fileName = rawName; result.srtNames = finalSRTNames }
        }

        await MainActor.run { job.progress = 1; job.state = .done }
        log?("Done: \(outDir.path)")
    }
}

extension SubtitleKind: Equatable {
    static func == (lhs: SubtitleKind, rhs: SubtitleKind) -> Bool {
        lhs.fileExtension == rhs.fileExtension && lhs.label == rhs.label
    }
}
