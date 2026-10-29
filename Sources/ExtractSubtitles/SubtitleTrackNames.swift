import Foundation

/// Names for the subtitle tracks of an MP4, read back from the subtitle file names this app writes.
enum TimedText {

    /// Reads the language and flags out of a subtitle file name made by this app:
    /// `<movie>.<lang>[.<name>][.forced][.sdh][.commentary].srt`.
    static func describe(fileName: String, movie: String) -> (tag: String, name: String, forced: Bool, sdh: Bool, commentary: Bool) {
        var base = (fileName as NSString).deletingPathExtension
        let prefix = Naming.safe(movie) + "."
        if base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
        } else if let dot = base.firstIndex(of: ".") {
            base = String(base[base.index(after: dot)...])
        } else {
            return ("und", "", false, false, false)
        }
        var parts = base.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return ("und", "", false, false, false) }
        let tag = parts.removeFirst()
        var forced = false, sdh = false, commentary = false
        var names: [String] = []
        for p in parts {
            switch p.lowercased() {
            case "forced": forced = true
            case "sdh": sdh = true
            case "commentary": commentary = true
            default:
                if Int(p) == nil { names.append(p) }   // ".10" collision suffixes are dropped
            }
        }
        return (tag, names.joined(separator: " "), forced, sdh, commentary)
    }

    /// A human track name: "English", "French (Canada) SDH", "English Director Commentary".
    static func trackName(tag: String, name: String, forced: Bool, sdh: Bool, commentary: Bool) -> String {
        var s = Naming.displayName(tag)
        if !name.isEmpty { s += " " + name }
        if sdh, !name.lowercased().contains("sdh") { s += " SDH" }
        if forced, !name.lowercased().contains("forced") { s += " (forced)" }
        if commentary, !name.lowercased().contains("commentar") { s += " Commentary" }
        return s
    }
}
