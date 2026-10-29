import Foundation

/// Thread-safe cancellation flag shared between the UI (main actor) and the converter thread.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Finds the ffmpeg / ffprobe binaries: inside the app bundle first, then Homebrew, /usr/local,
/// MacPorts and $PATH.
enum FFmpegTool {
    static func find(_ name: String) -> URL? {
        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"))
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") { candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(name)) }
        }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static var ffmpeg: URL? { find("ffmpeg") }
    static var ffprobe: URL? { find("ffprobe") }
}

/// Converts an MKV to an MP4 with HEVC video, the way HandBrake does it: ffmpeg drives the Mac's
/// VideoToolbox HEVC encoder (`hevc_videotoolbox`, constant quality, same resolution and frame rate,
/// `hvc1` tag), copies every audio track untouched, adds an AC-3 copy of each DTS / TrueHD track so
/// Apple's players have something to play, burns the forced PGS track into the picture with the
/// `overlay` filter, turns text subtitles into `mov_text` tracks and keeps chapters and languages.
final class VideoConverter {

    struct Options {
        var quality: Double = 0.85          // 0...1 → hevc_videotoolbox -q:v 1...100
        var burnInSubtitles: Bool = true     // burn the forced PGS subtitle track, if any
        var ac3Copies: Bool = true           // AC-3 copy of every DTS / TrueHD track
        /// SRT files to embed as subtitle tracks (the ones this job just extracted); when empty,
        /// the MKV's own text subtitle tracks are embedded instead.
        var extraSubtitleFiles: [URL] = []
    }

    struct Progress {
        var fraction: Double
        var fps: Double
        var etaSeconds: Double?
        var framesEncoded: Int
    }

    /// One stream of the source, as ffprobe describes it.
    struct StreamInfo {
        var index: Int                 // absolute stream index
        var typeIndex: Int             // index among streams of the same type (ffmpeg's 0:a:N / 0:s:N)
        var codecType: String          // video / audio / subtitle / attachment
        var codecName: String          // hevc, h264, dts, truehd, ac3, subrip, hdmv_pgs_subtitle, …
        var profile: String            // "DTS-HD MA", "Main 10", …
        var pixFmt: String
        var width: Int
        var height: Int
        var channels: Int
        var channelLayout: String
        var sampleRate: Int
        var language: String           // ISO 639-2 ("fre"), "und" when absent
        var title: String
        var isDefault: Bool
        var isForced: Bool
        var colorPrimaries: String
        var colorTransfer: String
        var colorSpace: String
        var colorRange: String
        var avgFrameRate: Double
        var bitRate: Int

        var languageTag: String { language.isEmpty ? "und" : language }
        var isTenBit: Bool { pixFmt.contains("10") || pixFmt.contains("12") || pixFmt.contains("p010") }
        var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" }
        /// Apple's players (QuickTime, Apple TV, iOS) decode these.
        var appleCanPlay: Bool {
            switch codecName {
            case "aac", "mp3", "mp2", "ac3", "eac3", "flac", "alac", "opus", "pcm_s16le", "pcm_s24le": return true
            default: return false
            }
        }
        /// Audio that MP4 cannot carry as-is and ffmpeg has to re-encode (Vorbis, PCM variants, …).
        var needsTranscodeForMP4: Bool {
            switch codecName {
            case "aac", "mp3", "mp2", "ac3", "eac3", "dts", "truehd", "mlp", "flac", "alac", "opus": return false
            default: return true
            }
        }
        var isTextSubtitle: Bool { ["subrip", "srt", "ass", "ssa", "webvtt", "text", "mov_text"].contains(codecName) }
        var isPGS: Bool { codecName == "hdmv_pgs_subtitle" }
        var describe: String {
            var parts = ["#\(index)", codecName]
            if !profile.isEmpty { parts.append("(\(profile))") }
            if codecType == "video" { parts.append("\(width)x\(height) \(pixFmt)") }
            if codecType == "audio" { parts.append(channelLayout.isEmpty ? "\(channels)ch" : channelLayout) }
            parts.append(language)
            if !title.isEmpty { parts.append("\"\(title)\"") }
            if isForced { parts.append("forced") }
            if isDefault { parts.append("default") }
            return parts.joined(separator: " ")
        }
        var codecLabel: String {
            switch codecName {
            case "dts": return profile.isEmpty ? "DTS" : profile
            case "truehd": return "TrueHD"
            case "mlp": return "MLP"
            case "ac3": return "AC-3"
            case "eac3": return "E-AC-3"
            case "aac": return "AAC"
            case "flac": return "FLAC"
            case "opus": return "Opus"
            case "alac": return "ALAC"
            case "mp3": return "MP3"
            default: return codecName.uppercased()
            }
        }
    }

    struct Result {
        var outputURL: URL
        var framesEncoded: Int
        var outputBytes: Int64
        var videoBitrate: Double        // bit/s of the HEVC track
        var durationSeconds: Double
        var burnedTrack: StreamInfo?
        var audioTracks: Int
        var ac3Copies: Int
        var subtitleTracks: Int
        var notes: [String]
    }

    enum Failure: Error, LocalizedError {
        case ffmpegMissing
        case probeFailed(String)
        case noVideoTrack
        case ffmpegFailed(Int32, String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing: return "ffmpeg was not found (brew install ffmpeg, or put ffmpeg and ffprobe in the app's Contents/Helpers)"
            case .probeFailed(let m): return "ffprobe could not read the file: \(m)"
            case .noVideoTrack: return "the file has no video track"
            case .ffmpegFailed(let code, let msg): return "ffmpeg exited with \(code)\(msg.isEmpty ? "" : ": \(msg)")"
            case .cancelled: return "cancelled"
            }
        }
    }

    // MARK: - Entry point

    static func convert(source: URL, options: Options, cancel: CancelToken,
                        log: @escaping (String) -> Void, progress: @escaping (Progress) -> Void) throws -> Result {
        let c = VideoConverter(source: source, options: options, cancel: cancel, log: log, progress: progress)
        return try c.run()
    }

    private let source: URL
    private let options: Options
    private let cancel: CancelToken
    private let log: (String) -> Void
    private let progress: (Progress) -> Void
    private var notes: [String] = []

    private init(source: URL, options: Options, cancel: CancelToken,
                 log: @escaping (String) -> Void, progress: @escaping (Progress) -> Void) {
        self.source = source
        self.options = options
        self.cancel = cancel
        self.log = log
        self.progress = progress
    }

    /// "<folder>/<basename>.mp4", never the source, never an existing file.
    static func outputURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent("\(base).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).mp4")
            n += 1
        }
        return url
    }

    private func run() throws -> Result {
        guard let ffmpeg = FFmpegTool.ffmpeg, let ffprobe = FFmpegTool.ffprobe else { throw Failure.ffmpegMissing }
        let probe = try Probe.read(source, ffprobe: ffprobe)
        guard let video = probe.streams.first(where: { $0.codecType == "video" && !["mjpeg", "png", "bmp", "gif"].contains($0.codecName) }) else {
            throw Failure.noVideoTrack
        }
        log("  source: \(probe.streams.count) streams, \(String(format: "%.1f", probe.duration / 60)) min, \(probe.chapters) chapter(s)")
        log("  video: \(video.describe)\(video.isHDR ? " HDR (\(video.colorTransfer))" : "")")

        let finalURL = VideoConverter.outputURL(for: source)
        let tempURL = finalURL.deletingPathExtension().appendingPathExtension("part.mp4")
        let title = source.deletingPathExtension().lastPathComponent

        // Short, plain-ASCII paths for ffmpeg's filter graph: a temp folder with symlinks.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ExtractSubtitles-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var plan = Plan(video: video)
        try buildPlan(&plan, probe: probe, title: title, work: work)

        var attempt = 1
        var lastFrames = 0
        while true {
            let args = arguments(plan: plan, probe: probe, title: title, output: tempURL, bitrateMode: attempt > 1)
            log("  ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
            let outcome = try runFFmpeg(ffmpeg, args: args, duration: probe.duration)
            lastFrames = outcome.frames
            if cancel.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                throw Failure.cancelled
            }
            if outcome.status == 0 { break }
            try? FileManager.default.removeItem(at: tempURL)
            // The encoder may refuse constant-quality mode (Intel Macs): try once more with a bitrate.
            if attempt == 1, outcome.frames < 5 {
                attempt = 2
                let n = "the encoder refused constant-quality mode; using an average bitrate instead"
                log("  \(n) (\(outcome.errorText))")
                notes.append(n)
                continue
            }
            throw Failure.ffmpegFailed(outcome.status, outcome.errorText)
        }

        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        var videoBitrate = 0.0
        if let out = try? Probe.read(finalURL, ffprobe: ffprobe), let v = out.streams.first(where: { $0.codecType == "video" }) {
            videoBitrate = Double(v.bitRate)
            log("  output: " + out.streams.map { $0.describe }.joined(separator: " | "))
        }
        if videoBitrate <= 0, probe.duration > 0 { videoBitrate = Double(size) * 8 / probe.duration }
        log(String(format: "  wrote %@ (%.2f GB, video %.1f Mbit/s)", finalURL.lastPathComponent, Double(size) / 1e9, videoBitrate / 1e6))
        return Result(outputURL: finalURL, framesEncoded: lastFrames, outputBytes: size, videoBitrate: videoBitrate,
                      durationSeconds: probe.duration, burnedTrack: plan.burned, audioTracks: plan.audioOutputs.count,
                      ac3Copies: plan.audioOutputs.filter { $0.isCopy }.count, subtitleTracks: plan.subtitleOutputs.count, notes: notes)
    }

    // MARK: - Plan

    struct AudioOutput {
        var stream: StreamInfo
        var isCopy: Bool           // AC-3 copy made from `stream`
        var transcode: String?     // "aac" when the source codec cannot go into an MP4
        var isDefault: Bool
        var title: String
    }

    struct SubtitleOutput {
        var inputIndex: Int        // ffmpeg input number (0 = the MKV, 1… = SRT files)
        var streamSpec: String     // "0:s:3" or "1:0"
        var language: String
        var title: String
        var forced: Bool
    }

    struct Plan {
        var video: StreamInfo
        var burned: StreamInfo?
        var extraInputs: [URL] = []
        var audioOutputs: [AudioOutput] = []
        var subtitleOutputs: [SubtitleOutput] = []
    }

    private func buildPlan(_ plan: inout Plan, probe: Probe.Info, title: String, work: URL) throws {
        let audio = probe.streams.filter { $0.codecType == "audio" }
        let subs = probe.streams.filter { $0.codecType == "subtitle" }

        // Which subtitle track to burn in: a forced PGS track, preferring the default audio's language, then English.
        if options.burnInSubtitles {
            let forced = subs.filter { $0.isForced || $0.title.lowercased().contains("forced") }
            let defaultAudio = audio.first(where: { $0.isDefault }) ?? audio.first
            func base(_ tag: String) -> String { Naming.shortCode(tag).split(separator: "-").first.map(String.init) ?? tag }
            let pick = forced.first(where: { $0.isPGS && base($0.languageTag) == base(defaultAudio?.languageTag ?? "") })
                ?? forced.first(where: { $0.isPGS && base($0.languageTag) == "en" })
                ?? forced.first(where: { $0.isPGS })
            if let p = pick {
                plan.burned = p
                log("  burn-in: forced subtitle track \(p.describe)")
            } else if let t = forced.first(where: { $0.isTextSubtitle }) {
                let n = "the forced subtitle track is text (\(t.codecName)); it is added as a forced subtitle track instead of being burned in"
                log("  \(n)")
                notes.append(n)
            } else {
                log("  no forced subtitle track; converting without burn-in")
            }
        }

        // Audio: everything passed through; DTS / TrueHD also get an AC-3 copy; odd codecs become AAC.
        let defaultAudio = audio.first(where: { $0.isDefault }) ?? audio.first
        for a in audio {
            let langName = Naming.displayName(a.languageTag)
            let wantsCopy = options.ac3Copies && !a.appleCanPlay && !a.needsTranscodeForMP4
                && !audio.contains(where: { $0.index != a.index && ($0.codecName == "ac3" || $0.codecName == "eac3") && $0.language == a.language })
            let isDefault = a.index == defaultAudio?.index
            if a.needsTranscodeForMP4 {
                plan.audioOutputs.append(AudioOutput(stream: a, isCopy: false, transcode: "aac", isDefault: isDefault,
                                                     title: a.title.isEmpty ? "\(langName) AAC" : a.title))
                let n = "audio \(a.describe) cannot go into an MP4 as-is; re-encoded as AAC"
                log("  \(n)"); notes.append(n)
                continue
            }
            if wantsCopy {
                // The copy comes first and is the default track, so Apple players start with sound.
                plan.audioOutputs.append(AudioOutput(stream: a, isCopy: true, transcode: nil, isDefault: isDefault,
                                                     title: "\(langName) AC-3 \(a.channels >= 6 ? "5.1" : (a.channels == 2 ? "stereo" : "\(min(a.channels, 6))ch")) (from \(a.codecLabel))"))
                plan.audioOutputs.append(AudioOutput(stream: a, isCopy: false, transcode: nil, isDefault: false,
                                                     title: a.title.isEmpty ? "\(langName) \(a.codecLabel)" : a.title))
                log("  audio: \(a.describe) → passthrough + AC-3 copy")
            } else {
                plan.audioOutputs.append(AudioOutput(stream: a, isCopy: false, transcode: nil, isDefault: isDefault,
                                                     title: a.title.isEmpty ? "\(langName) \(a.codecLabel)" : a.title))
                log("  audio: \(a.describe) → passthrough\(a.appleCanPlay ? "" : " (not decodable by Apple players; no ffmpeg copy wanted or an AC-3 track exists)")")
            }
        }

        // Subtitles: the SRTs this job just made, otherwise the MKV's text tracks. PGS cannot be a track in an MP4.
        if !options.extraSubtitleFiles.isEmpty {
            for (i, srt) in options.extraSubtitleFiles.enumerated() where FileManager.default.fileExists(atPath: srt.path) {
                let link = work.appendingPathComponent("sub\(i).srt")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: srt)
                plan.extraInputs.append(link)
                let d = TimedText.describe(fileName: srt.lastPathComponent, movie: title)
                let lang = MP4Language.code(d.tag)
                let name = TimedText.trackName(tag: d.tag, name: d.name, forced: d.forced, sdh: d.sdh, commentary: d.commentary)
                if d.forced, plan.burned != nil { continue }
                plan.subtitleOutputs.append(SubtitleOutput(inputIndex: plan.extraInputs.count, streamSpec: "\(plan.extraInputs.count):0",
                                                           language: lang, title: name, forced: d.forced))
            }
        } else {
            for s in subs where s.isTextSubtitle && s.index != plan.burned?.index {
                let name = s.title.isEmpty ? Naming.displayName(s.languageTag) + (s.isForced ? " (forced)" : "") : s.title
                plan.subtitleOutputs.append(SubtitleOutput(inputIndex: 0, streamSpec: "0:s:\(s.typeIndex)",
                                                           language: s.language, title: name, forced: s.isForced))
            }
        }
        if !plan.subtitleOutputs.isEmpty {
            log("  subtitles: " + plan.subtitleOutputs.map { "\($0.title) [\($0.language)]" }.joined(separator: ", "))
        }
        let pgsLeft = subs.filter { $0.isPGS && $0.index != plan.burned?.index }.count
        if pgsLeft > 0 { log("  \(pgsLeft) PGS subtitle track(s) left out (MP4 cannot carry bitmap subtitles)") }
    }

    // MARK: - ffmpeg command line

    private func arguments(plan: Plan, probe: Probe.Info, title: String, output: URL, bitrateMode: Bool) -> [String] {
        var a: [String] = ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y"]
        a += ["-i", source.path]
        for u in plan.extraInputs { a += ["-i", u.path] }

        // Video
        let v = plan.video
        if let b = plan.burned {
            let graph = "[0:v:\(v.typeIndex)][0:s:\(b.typeIndex)]overlay=eof_action=pass:format=\(v.isTenBit ? "yuv420p10" : "yuv420")[v]"
            a += ["-filter_complex", graph, "-map", "[v]"]
        } else {
            a += ["-map", "0:v:\(v.typeIndex)"]
        }
        a += ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-allow_sw", "1"]
        if v.isTenBit {
            a += ["-profile:v", "main10", "-pix_fmt", "p010le"]
        } else {
            a += ["-profile:v", "main", "-pix_fmt", "nv12"]
        }
        if bitrateMode {
            let pixels = Double(v.width * v.height)
            let base = pixels >= 3_500_000 ? 30.0 : (pixels >= 1_500_000 ? 12.0 : 5.0)   // Mbit/s at quality 0.85
            let mbps = base * max(0.4, options.quality / 0.85)
            a += ["-b:v", "\(Int(mbps * 1000))k"]
        } else {
            a += ["-q:v", "\(max(1, min(100, Int((options.quality * 100).rounded()))))"]
        }
        for (flag, value) in [("-color_primaries", v.colorPrimaries), ("-color_trc", v.colorTransfer), ("-colorspace", v.colorSpace), ("-color_range", v.colorRange)]
            where !value.isEmpty && value != "unknown" {
            a += [flag, value]
        }

        // Audio
        for (i, out) in plan.audioOutputs.enumerated() {
            a += ["-map", "0:a:\(out.stream.typeIndex)"]
            if out.isCopy {
                let ch = min(6, max(1, out.stream.channels))
                let kbps = ch >= 6 ? 640 : (ch >= 3 ? 448 : (ch == 2 ? 256 : 192))
                a += ["-c:a:\(i)", "ac3", "-b:a:\(i)", "\(kbps)k", "-ac:a:\(i)", "\(ch)"]
            } else if let codec = out.transcode {
                a += ["-c:a:\(i)", codec, "-b:a:\(i)", out.stream.channels >= 6 ? "384k" : "192k"]
            } else {
                a += ["-c:a:\(i)", "copy"]
            }
            a += ["-metadata:s:a:\(i)", "language=\(out.stream.language)", "-metadata:s:a:\(i)", "title=\(out.title)"]
            a += ["-disposition:a:\(i)", out.isDefault ? "default" : "0"]
        }

        // Subtitles
        for (i, out) in plan.subtitleOutputs.enumerated() {
            a += ["-map", out.streamSpec, "-c:s:\(i)", "mov_text"]
            a += ["-metadata:s:s:\(i)", "language=\(out.language)", "-metadata:s:s:\(i)", "title=\(out.title)"]
            a += ["-disposition:s:\(i)", out.forced ? "forced" : "0"]
        }

        // Chapters, title, container
        a += ["-map_chapters", "0", "-map_metadata", "-1", "-metadata", "title=\(title)"]
        a += ["-strict", "experimental", "-max_muxing_queue_size", "4096", "-f", "mp4", output.path]
        return a
    }

    // MARK: - Running ffmpeg

    private struct Outcome {
        var status: Int32
        var frames: Int
        var errorText: String
    }

    private func runFFmpeg(_ ffmpeg: URL, args: [String], duration: Double) throws -> Outcome {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let state = ProgressState()
        let errLock = NSLock()
        var errorText = Data()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            errLock.lock(); errorText.append(d); if errorText.count > 8192 { errorText = errorText.suffix(4096) }; errLock.unlock()
        }
        let started = Date()
        let progressCB = progress
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            state.feed(d) { frame, fps, outTime, speed in
                let fraction = duration > 0 ? max(0, min(0.999, outTime / duration)) : 0
                var eta: Double?
                if speed > 0, duration > 0 { eta = max(0, duration - outTime) / speed }
                else if fraction > 0.01 { let el = Date().timeIntervalSince(started); eta = el * (1 - fraction) / fraction }
                progressCB(Progress(fraction: fraction, fps: fps, etaSeconds: eta, framesEncoded: frame))
            }
        }
        try p.run()
        while p.isRunning {
            if cancel.isCancelled { p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let restOut = out.fileHandleForReading.readDataToEndOfFile()
        if !restOut.isEmpty { state.feed(restOut) { _, _, _, _ in } }
        let restErr = err.fileHandleForReading.readDataToEndOfFile()
        errLock.lock(); errorText.append(restErr); let errData = errorText; errLock.unlock()
        let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let elapsed = Date().timeIntervalSince(started)
        if p.terminationStatus == 0 {
            log(String(format: "  encoded %d frames in %.0f s (%.1f fps)", state.frames, elapsed, elapsed > 0 ? Double(state.frames) / elapsed : 0))
        }
        return Outcome(status: p.terminationStatus, frames: state.frames, errorText: String(text.suffix(400)))
    }

    /// Parses ffmpeg's `-progress` key=value stream.
    private final class ProgressState {
        private var buffer = Data()
        private(set) var frames = 0
        private var fps = 0.0
        private var outTime = 0.0
        private var speed = 0.0

        func feed(_ data: Data, report: (Int, Double, Double, Double) -> Void) {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex ..< nl], as: UTF8.self)
                buffer = Data(buffer[(nl + 1)...])
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "frame": frames = Int(value) ?? frames
                case "fps": fps = Double(value) ?? fps
                case "out_time_us": outTime = (Double(value) ?? 0) / 1_000_000
                case "out_time_ms": if outTime == 0 { outTime = (Double(value) ?? 0) / 1_000_000 }  // older ffmpeg: microseconds despite the name
                case "speed": speed = Double(value.replacingOccurrences(of: "x", with: "")) ?? speed
                case "progress": report(frames, fps, outTime, speed)
                default: break
                }
            }
        }
    }

    // MARK: - ffprobe

    enum Probe {
        struct Info {
            var streams: [StreamInfo]
            var duration: Double
            var chapters: Int
        }

        static func read(_ url: URL, ffprobe: URL) throws -> Info {
            let p = Process()
            p.executableURL = ffprobe
            p.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.probeFailed(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var streams: [StreamInfo] = []
            var typeCounts: [String: Int] = [:]
            for s in root["streams"] as? [[String: Any]] ?? [] {
                let type = s["codec_type"] as? String ?? ""
                let tags = s["tags"] as? [String: Any] ?? [:]
                let disp = s["disposition"] as? [String: Any] ?? [:]
                let typeIndex = typeCounts[type, default: 0]
                typeCounts[type] = typeIndex + 1
                func str(_ k: String) -> String { (s[k] as? String) ?? "" }
                func int(_ k: String) -> Int { (s[k] as? Int) ?? Int((s[k] as? String) ?? "") ?? 0 }
                var rate = 0.0
                let fr = str("avg_frame_rate").split(separator: "/")
                if fr.count == 2, let n = Double(fr[0]), let d = Double(fr[1]), d > 0 { rate = n / d }
                streams.append(StreamInfo(
                    index: int("index"), typeIndex: typeIndex, codecType: type, codecName: str("codec_name"),
                    profile: str("profile"), pixFmt: str("pix_fmt"), width: int("width"), height: int("height"),
                    channels: int("channels"), channelLayout: str("channel_layout"), sampleRate: int("sample_rate"),
                    language: (tags["language"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "und",
                    title: tags["title"] as? String ?? "",
                    isDefault: (disp["default"] as? Int ?? 0) != 0, isForced: (disp["forced"] as? Int ?? 0) != 0,
                    colorPrimaries: str("color_primaries"), colorTransfer: str("color_transfer"),
                    colorSpace: str("color_space"), colorRange: str("color_range"),
                    avgFrameRate: rate, bitRate: int("bit_rate")))
            }
            let format = root["format"] as? [String: Any] ?? [:]
            let duration = Double(format["duration"] as? String ?? "") ?? 0
            let chapters = (root["chapters"] as? [[String: Any]])?.count ?? 0
            return Info(streams: streams, duration: duration, chapters: chapters)
        }
    }
}

/// ISO 639-2/B codes for ffmpeg's `language=` metadata from the app's IETF-style tags.
enum MP4Language {
    private static let map: [String: String] = [
        "en": "eng", "fr": "fre", "de": "ger", "es": "spa", "it": "ita", "nl": "dut", "pt": "por", "ru": "rus",
        "ja": "jpn", "zh": "chi", "ko": "kor", "sv": "swe", "da": "dan", "no": "nor", "nb": "nob", "fi": "fin",
        "pl": "pol", "cs": "cze", "hu": "hun", "tr": "tur", "el": "gre", "he": "heb", "ar": "ara", "hi": "hin",
        "th": "tha", "vi": "vie", "id": "ind", "ms": "may", "ro": "rum", "uk": "ukr", "bg": "bul", "hr": "hrv",
        "sr": "srp", "sk": "slo", "sl": "slv", "et": "est", "lv": "lav", "lt": "lit", "is": "ice", "ga": "gle",
        "ca": "cat", "eu": "baq", "gl": "glg", "fa": "per", "ta": "tam", "te": "tel", "bn": "ben", "ur": "urd",
        "tl": "tgl", "sw": "swa", "af": "afr", "la": "lat", "cy": "wel", "mk": "mac", "sq": "alb", "hy": "arm",
        "ka": "geo", "mn": "mon", "ne": "nep", "si": "sin", "km": "khm", "lo": "lao", "my": "bur", "am": "amh",
    ]

    /// "fr-CA" → "fre", "eng" → "eng", "" → "und".
    static func code(_ tag: String) -> String {
        let base = tag.split(separator: "-").first.map { String($0).lowercased() } ?? ""
        if base.count == 3 { return base }
        return map[base] ?? "und"
    }
}
