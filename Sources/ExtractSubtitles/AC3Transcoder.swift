import Foundation

/// Makes the AC-3 (Dolby Digital) copy of a DTS / TrueHD track with an ffmpeg helper, because
/// macOS has no decoder for those formats and no AC-3 encoder. ffmpeg decodes the one audio
/// stream and encodes AC-3 to a pipe; the frames are handed over one syncframe at a time and
/// go into the MP4 through the app's own muxer, like everything else.
final class AC3Transcoder {

    enum Failure: Error, LocalizedError {
        case ffmpegMissing
        case ffmpegFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .ffmpegMissing: return "ffmpeg was not found (brew install ffmpeg, or put an ffmpeg binary in the app's Contents/Helpers)"
            case .ffmpegFailed(let code, let msg): return "ffmpeg exited with \(code)\(msg.isEmpty ? "" : ": \(msg)")"
            }
        }
    }

    /// The ffmpeg binary: inside the app bundle first, then Homebrew / MacPorts / local installs.
    static func findFFmpeg() -> URL? {
        var candidates: [URL] = []
        if let helpers = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "Helpers") { candidates.append(helpers) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg"))
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            candidates.append(URL(fileURLWithPath: p))
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") { candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg")) }
        }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    let source: URL
    let audioStreamIndex: Int      // ffmpeg's 0:a:N
    let channels: Int
    let bitrateKbps: Int
    private var process: Process?
    private let lock = NSLock()
    private var stopped = false

    init(source: URL, audioStreamIndex: Int, sourceChannels: Int) {
        self.source = source
        self.audioStreamIndex = audioStreamIndex
        self.channels = min(6, max(1, sourceChannels))
        switch self.channels {
        case 1: bitrateKbps = 192
        case 2: bitrateKbps = 256
        default: bitrateKbps = 640
        }
    }

    var describe: String { "AC-3 \(AudioCodec.layoutName(channels: channels)) \(bitrateKbps) kbps" }

    /// Asks ffmpeg to stop (cancel).
    func stop() {
        lock.lock(); stopped = true; let p = process; lock.unlock()
        p?.terminate()
    }

    /// Runs ffmpeg synchronously; `frame` receives every complete AC-3 syncframe and returns false to stop.
    /// Returns the number of frames delivered.
    @discardableResult
    func run(frame: (Data) -> Bool) throws -> Int {
        guard let ffmpeg = AC3Transcoder.findFFmpeg() else { throw Failure.ffmpegMissing }
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", source.path,
            "-map", "0:a:\(audioStreamIndex)", "-vn", "-sn", "-dn",
            "-c:a", "ac3", "-b:a", "\(bitrateKbps)k", "-ac", "\(channels)",
            "-f", "ac3", "pipe:1",
        ]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        var errorText = Data()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errorText.append(d) }
        }
        lock.lock()
        if stopped { lock.unlock(); return 0 }
        process = p
        lock.unlock()
        try p.run()

        var buffer = Data()
        var frames = 0
        let reader = out.fileHandleForReading
        var keepGoing = true
        while keepGoing {
            let chunk = reader.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var pos = 0
            while let h = AudioCodec.parseAC3(buffer, at: pos), h.frameBytes > 0, pos + h.frameBytes <= buffer.count {
                let f = buffer.subdata(in: (buffer.startIndex + pos) ..< (buffer.startIndex + pos + h.frameBytes))
                frames += 1
                if !frame(f) { keepGoing = false; break }
                pos += h.frameBytes
            }
            if pos > 0 { buffer = Data(buffer.suffix(from: buffer.startIndex + pos)) }
            if pos == 0, buffer.count > 2, AudioCodec.parseAC3(buffer, at: 0) == nil {
                // Resync: drop bytes until a sync word.
                if let r = buffer.dropFirst().firstRange(of: Data([0x0B, 0x77])) {
                    buffer = Data(buffer.suffix(from: r.lowerBound))
                } else {
                    buffer.removeAll()
                }
            }
        }
        if !keepGoing { p.terminate() }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        let rest = err.fileHandleForReading.readDataToEndOfFile()
        errorText.append(rest)
        lock.lock(); let wasStopped = stopped; lock.unlock()
        if keepGoing, !wasStopped, p.terminationStatus != 0 {
            let msg = String(data: errorText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.ffmpegFailed(p.terminationStatus, String(msg.suffix(300)))
        }
        return frames
    }
}
