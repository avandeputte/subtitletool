import Foundation

/// Where finished work goes: next to the source file (the default) or in one folder chosen in Settings.
enum OutputLocation {
    static let useCustomKey = "saveToCustomFolder"
    static let pathKey = "outputFolderPath"
    /// Set by `--output-folder` for one command-line run; never stored.
    static var commandLineFolder: String?

    enum Failure: Error, LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let path):
                return "The save folder \(path) is not available. Connect its disk or choose another folder in Settings."
            }
        }
    }

    static var customFolder: URL? {
        if let path = commandLineFolder { return URL(fileURLWithPath: path, isDirectory: true) }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: useCustomKey),
              let path = defaults.string(forKey: pathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The folder results of `source` go to. A missing custom folder is an error: creating it could
    /// quietly fill the startup disk when the NAS or external drive is simply not mounted.
    static func folder(for source: URL) throws -> URL {
        let sourceFolder = source.deletingLastPathComponent()
        guard let custom = customFolder else { return sourceFolder }
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: custom.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isWritableFile(atPath: custom.path) else {
            throw Failure.unavailable(custom.path)
        }
        return custom
    }

    private static func isSourceFolder(_ folder: URL, of source: URL) -> Bool {
        folder.resolvingSymlinksInPath().standardizedFileURL.path
            == source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// "<folder>/<movie> Subtitles". A shared save folder can hold a same-named movie from another
    /// place, so there an existing folder is never reused: the new one becomes "<movie> Subtitles 2".
    static func subtitleFolder(for source: URL, movie: String) throws -> URL {
        let folder = try folder(for: source)
        let name = movie + Naming.subfolderSuffix
        var url = folder.appendingPathComponent(name, isDirectory: true)
        guard !isSourceFolder(folder, of: source) else { return url }
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// Folders that may hold subtitles from an earlier run, the save folder first.
    static func earlierSubtitleFolders(for source: URL) -> [URL] {
        let name = source.deletingPathExtension().lastPathComponent + Naming.subfolderSuffix
        var folders = [source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)]
        if let custom = customFolder, !isSourceFolder(custom, of: source) {
            folders.insert(custom.appendingPathComponent(name, isDirectory: true), at: 0)
        }
        return folders
    }
}
