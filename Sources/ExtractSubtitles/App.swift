import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers

@main
struct ExtractSubtitlesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        CommandLineMode.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Extract Subtitles") {
            ContentView()
                .environmentObject(appDelegate.runner)
                .environmentObject(appDelegate.runner.resolver)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open MKV…") { appDelegate.runner.openPanel() }
                    .keyboardShortcut("o")
                Button("Convert to H.265…") { appDelegate.runner.openPanel(kind: .convert) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runner = JobRunner()
    private var serviceProvider: ServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        serviceProvider = ServiceProvider(runner: runner)
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        NSApp.activate(ignoringOtherApps: true)

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Files opened via Finder "Open With", drag onto the Dock icon, or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        runner.enqueue(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = NSApp.windows.first { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func openPanel() { runner.openPanel() }

    /// Queues convert-only jobs (used by the "Convert to H.265" service).
    func convertToH265(_ urls: [URL]) { runner.enqueue(urls, kind: .convert) }
}

/// Receives the Finder "Extract Subtitles" service (declared under NSServices in Info.plist).
final class ServiceProvider: NSObject {
    let runner: JobRunner
    init(runner: JobRunner) { self.runner = runner }

    @objc(extractSubtitles:userData:error:)
    func extractSubtitles(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were passed to Extract Subtitles." as NSString
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.runner.enqueue(urls)
        }
    }

    /// Finder "Convert to H.265" service: converts the video only, no subtitle extraction.
    @objc(convertToH265:userData:error:)
    func convertToH265(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were passed to Convert to H.265." as NSString
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.runner.enqueue(urls, kind: .convert)
        }
    }
}

/// `Extract Subtitles.app/Contents/MacOS/Extract Subtitles --cli [--list] [--no-convert|--local] [--no-rename] [--h265] [--quality 0.9] [--no-ac3] file.mkv …`
/// runs without a window; handy for testing and scripting. Default: the mode chosen in Settings.
/// `--h265` converts the video to H.265 (MP4) only (no subtitle extraction); `--quality` is the encoder quality 0.5–1.0;
/// `--no-ac3` skips the AC-3 copies of DTS/TrueHD tracks. With IMDb renaming on, every file is identified first
/// (a numbered picker on the terminal when in doubt), then the work runs.
enum CommandLineMode {
    static func runIfRequested() {
        let args = CommandLine.arguments.dropFirst()
        guard args.contains("--cli") else { return }
        // "--quality 0.9" takes a value; everything else that does not start with "--" is a file.
        var files: [URL] = []
        var quality = UserDefaults.standard.object(forKey: JobRunner.qualityKey) as? Double ?? 0.85
        let list = Array(args)
        var skipNext = false
        for (i, a) in list.enumerated() {
            if skipNext { skipNext = false; continue }
            if a == "--quality" {
                if i + 1 < list.count, let q = Double(list[i + 1]) { quality = max(0.1, min(1.0, q)) }
                skipNext = true
                continue
            }
            if a.hasPrefix("--quality=") {
                if let q = Double(a.dropFirst("--quality=".count)) { quality = max(0.1, min(1.0, q)) }
                continue
            }
            if !a.hasPrefix("--") { files.append(URL(fileURLWithPath: a)) }
        }
        let convertOnly = args.contains("--h265")
        if args.contains("--list") {
            // Just print the subtitle tracks and the names they would get; writes nothing.
            var failures = 0
            for url in files {
                print(url.path)
                do {
                    let demuxer = try MatroskaDemuxer(url: url)
                    if !demuxer.title.isEmpty { print("  title: \"\(demuxer.title)\"") }
                    let guess = FilenameParser.parse(url.lastPathComponent)
                    print("  file name parses as: \"\(guess.title)\"\(guess.year.map { " (\($0))" } ?? "")")
                    if !args.contains("--no-rename") {
                        let mkvTitle = demuxer.title
                        let sem = DispatchSemaphore(value: 0)
                        Task.detached {
                            defer { sem.signal() }
                            do {
                                switch try await IMDbLookup.identify(guess: guess, alternateTitle: mkvTitle) {
                                case .confident(let m, _): print("  IMDb: \(m.label) \(m.imdbID) — confident, would rename to \"\(m.baseName ?? m.title).mkv\"")
                                case .ambiguous(let list, let why):
                                    print("  IMDb: \(why) — would ask:")
                                    for (i, c) in list.prefix(8).enumerated() { print("    \(i + 1). \(c.label) \(c.kind.isEmpty ? "" : "[\(c.kind)] ")\(c.stars)") }
                                case .nothing: print("  IMDb: nothing found — would ask")
                                }
                            } catch { print("  IMDb lookup failed: \(error.localizedDescription)") }
                        }
                        while sem.wait(timeout: .now()) != .success { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
                    }
                    let movie = url.deletingPathExtension().lastPathComponent
                    // Read the subtitle streams too: forced flags, cue counts and duplicates come from
                    // the content. SDH detection and Chinese script need the OCR text, so those two
                    // can still change the final name during a real run.
                    let supported = demuxer.tracks.filter { $0.kind.isSupported }
                    let frames = try demuxer.readFrames(for: supported, progress: nil)
                    var analyses: [UInt64: TrackAnalysis] = [:]
                    for track in supported {
                        analyses[track.number] = TrackAnalyzer.analyze(track: track, frames: frames[track.number] ?? [])
                    }
                    let plan = Naming.plan(movie: movie, tracks: demuxer.tracks, analyses: analyses)
                    for track in demuxer.tracks {
                        print("  track #\(track.number) \(track.codecID) \(Naming.describe(track))\(Naming.describe(analyses[track.number]))")
                        if let dup = plan[track.number]?.duplicateOf {
                            print("      -> skipped: byte-identical to track #\(dup)")
                        } else if let base = plan[track.number]?.base {
                            print("      -> \(base).\(track.kind.fileExtension)")
                        } else {
                            print("      -> skipped: \(track.kind.label) not supported")
                        }
                    }
                } catch {
                    print("  error: \(error.localizedDescription)"); failures += 1
                }
            }
            exit(failures == 0 ? 0 : 1)
        }
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("usage: ExtractSubtitles --cli [--list] [--no-convert|--local] [--no-rename|--rename] [--h265] [--quality 0.9] [--no-ac3] file.mkv …\n".utf8))
            exit(2)
        }
        var mode = ConversionMode.from(stored: UserDefaults.standard.string(forKey: ConversionMode.storageKey))
        if args.contains("--no-convert") { mode = .off }
        if args.contains("--local") || args.contains("--both") || args.contains("--api") { mode = .local }
        var rename = UserDefaults.standard.object(forKey: JobRunner.renameKey) as? Bool ?? true
        if args.contains("--no-rename") { rename = false }
        if args.contains("--rename") { rename = true }
        var ac3Copies = UserDefaults.standard.object(forKey: JobRunner.ac3CopyKey) as? Bool ?? true
        if args.contains("--no-ac3") { ac3Copies = false }
        if args.contains("--ac3") { ac3Copies = true }

        Task.detached {
            var failures = 0
            let convertAfter = UserDefaults.standard.bool(forKey: JobRunner.convertKey)
            if convertOnly {
                print("convert to H.265 (MP4) only; quality \(quality); IMDb rename: \(rename ? "on" : "off"); AC-3 copies of DTS/TrueHD: \(ac3Copies ? "on" : "off")")
            } else {
                print("conversion mode: \(mode.rawValue); IMDb rename: \(rename ? "on" : "off"); H.265 (MP4) after extracting: \(convertAfter ? "on (quality \(quality), AC-3 copies \(ac3Copies ? "on" : "off"))" : "off")")
            }
            let jobs: [Job] = await MainActor.run { files.map { Job(url: $0, kind: convertOnly ? .convert : .extract) } }

            // Phase 1: IMDb for every file first (questions on the terminal when there is one).
            if rename {
                let resolver = await MainActor.run { MovieResolver() }
                let interaction: MovieResolver.Interaction = isatty(STDIN_FILENO) != 0 ? .terminal : .none
                for job in jobs {
                    print("Identifying \(await job.url.lastPathComponent)")
                    await resolver.resolve(job: job, interaction: interaction) { line in print(line) }
                    await MainActor.run { job.state = .queued }
                }
            }

            // Phase 2: the work.
            for job in jobs {
                if convertOnly {
                    await VideoConversionStep.run(job: job, quality: quality, ac3Copies: ac3Copies) { line in
                        print(line)
                    }
                } else {
                    await SubtitleExtractor.process(job: job, mode: mode) { line in
                        print(line)
                    }
                    if convertAfter, await job.allowsConversion {
                        await VideoConversionStep.run(job: job, quality: quality, ac3Copies: ac3Copies) { line in
                            print(line)
                        }
                    }
                }
                if await job.hasFailures { failures += 1 }
            }
            exit(failures == 0 ? 0 : 1)
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }
}
