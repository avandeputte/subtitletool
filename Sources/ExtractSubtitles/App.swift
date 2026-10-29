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
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open MKV…") { appDelegate.runner.openPanel() }
                    .keyboardShortcut("o")
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
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.runner.enqueue(urls)
        }
    }
}

/// `Extract Subtitles.app/Contents/MacOS/Extract Subtitles --cli [--list] [--no-convert|--local] [--no-rename] file.mkv …`
/// runs without a window; handy for testing and scripting. Default: the mode chosen in Settings.
enum CommandLineMode {
    static func runIfRequested() {
        let args = CommandLine.arguments.dropFirst()
        guard args.contains("--cli") else { return }
        let files = args.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
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
                    var used = Set<String>()
                    let movie = url.deletingPathExtension().lastPathComponent
                    for track in demuxer.tracks {
                        let base = Naming.baseName(movie: movie, track: track, used: &used)
                        print("  track #\(track.number) \(track.codecID) \(Naming.describe(track))")
                        print("      -> \(base).\(track.kind.fileExtension)")
                    }
                } catch {
                    print("  error: \(error.localizedDescription)"); failures += 1
                }
            }
            exit(failures == 0 ? 0 : 1)
        }
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("usage: ExtractSubtitles --cli [--list] [--no-convert|--local] [--no-rename|--rename] file.mkv …\n".utf8))
            exit(2)
        }
        var mode = ConversionMode.from(stored: UserDefaults.standard.string(forKey: ConversionMode.storageKey))
        if args.contains("--no-convert") { mode = .off }
        if args.contains("--local") || args.contains("--both") || args.contains("--api") { mode = .local }
        var rename = UserDefaults.standard.object(forKey: JobRunner.renameKey) as? Bool ?? true
        if args.contains("--no-rename") { rename = false }
        if args.contains("--rename") { rename = true }

        Task.detached {
            var failures = 0
            print("conversion mode: \(mode.rawValue); IMDb rename: \(rename ? "on" : "off")")
            for url in files {
                let job = await MainActor.run { Job(url: url) }
                await SubtitleExtractor.process(job: job, mode: mode, rename: rename) { line in
                    print(line)
                }
                if await job.hasFailures { failures += 1 }
            }
            exit(failures == 0 ? 0 : 1)
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }
}
