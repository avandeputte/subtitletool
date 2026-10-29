import Foundation
import CoreGraphics
import CoreImage
import AppKit

/// Decodes PGS display sets into full-canvas RGBA bitmaps (with alpha, objects at their
/// composition positions) for burning into video. Shares the palette/RLE code of PGSDecoder;
/// PGSDecoder.decode itself is left untouched because it renders for OCR (cropped, over black).
enum PGSOverlayDecoder {

    struct Overlay {
        let canvasWidth: Int       // video size declared in the PCS
        let canvasHeight: Int
        let image: CGImage?        // nil = clear screen
    }

    static func decode(frame: Data, state: PGSDecoder.State) -> Overlay? {
        var i = frame.startIndex
        var compObjects: [PGSDecoder.CompositionObject] = []
        var paletteID = 0
        var sawPCS = false
        var canvasW = 0, canvasH = 0

        while i + 3 <= frame.endIndex {
            let type = frame[i]
            let size = Int(frame[i + 1]) << 8 | Int(frame[i + 2])
            let start = i + 3
            let end = start + size
            guard end <= frame.endIndex else { break }
            let seg = frame[start ..< end]

            switch type {
            case 0x16: // PCS
                sawPCS = true
                var p = seg.startIndex
                guard seg.count >= 11 else { break }
                canvasW = Int(seg[p]) << 8 | Int(seg[p + 1])
                canvasH = Int(seg[p + 2]) << 8 | Int(seg[p + 3])
                paletteID = Int(seg[p + 9])
                let count = Int(seg[p + 10])
                p += 11
                for _ in 0 ..< count {
                    guard p + 8 <= seg.endIndex else { break }
                    let objectID = Int(seg[p]) << 8 | Int(seg[p + 1])
                    let windowID = Int(seg[p + 2])
                    let flags = seg[p + 3]
                    let x = Int(seg[p + 4]) << 8 | Int(seg[p + 5])
                    let y = Int(seg[p + 6]) << 8 | Int(seg[p + 7])
                    p += 8
                    if flags & 0x80 != 0 { p += 8 }   // 0x80 = cropped (8 more bytes), 0x40 = forced
                    compObjects.append(PGSDecoder.CompositionObject(objectID: objectID, windowID: windowID, x: x, y: y))
                }

            case 0x17: // WDS
                guard let n = seg.first else { break }
                var p = seg.startIndex + 1
                for _ in 0 ..< Int(n) {
                    guard p + 9 <= seg.endIndex else { break }
                    let id = Int(seg[p])
                    let x = Int(seg[p + 1]) << 8 | Int(seg[p + 2])
                    let y = Int(seg[p + 3]) << 8 | Int(seg[p + 4])
                    let w = Int(seg[p + 5]) << 8 | Int(seg[p + 6])
                    let h = Int(seg[p + 7]) << 8 | Int(seg[p + 8])
                    state.windows[id] = (x, y, w, h)
                    p += 9
                }

            case 0x14: // PDS
                guard seg.count >= 2 else { break }
                let id = Int(seg[seg.startIndex])
                var pal = state.palettes[id] ?? PGSDecoder.Palette()
                var p = seg.startIndex + 2
                while p + 5 <= seg.endIndex {
                    let idx = Int(seg[p])
                    let y = Double(seg[p + 1]), cr = Double(seg[p + 2]), cb = Double(seg[p + 3])
                    let a = seg[p + 4]
                    pal.entries[idx] = rgba(y: y, cb: cb, cr: cr, alpha: a)
                    p += 5
                }
                state.palettes[id] = pal

            case 0x15: // ODS
                guard seg.count >= 4 else { break }
                let id = Int(seg[seg.startIndex]) << 8 | Int(seg[seg.startIndex + 1])
                let seqFlag = seg[seg.startIndex + 3]
                var p = seg.startIndex + 4
                var obj = (seqFlag & 0x80 != 0) ? PGSDecoder.ObjectData() : (state.objects[id] ?? PGSDecoder.ObjectData())
                if seqFlag & 0x80 != 0 {
                    guard seg.count >= 11 else { break }
                    obj.expectedLength = Int(seg[p]) << 16 | Int(seg[p + 1]) << 8 | Int(seg[p + 2])
                    obj.width = Int(seg[p + 3]) << 8 | Int(seg[p + 4])
                    obj.height = Int(seg[p + 5]) << 8 | Int(seg[p + 6])
                    p += 7
                }
                obj.rle.append(seg[p ..< seg.endIndex])
                state.objects[id] = obj

            default:
                break
            }
            i = end
        }

        guard sawPCS else { return nil }
        guard !compObjects.isEmpty, canvasW > 0, canvasH > 0 else {
            return Overlay(canvasWidth: max(canvasW, 1), canvasHeight: max(canvasH, 1), image: nil)
        }
        let palette = state.palettes[paletteID] ?? PGSDecoder.Palette()
        let image = render(objects: compObjects, palette: palette, state: state, width: canvasW, height: canvasH)
        return Overlay(canvasWidth: canvasW, canvasHeight: canvasH, image: image)
    }

    /// Full-canvas premultiplied RGBA bitmap; transparent where nothing is drawn.
    private static func render(objects: [PGSDecoder.CompositionObject], palette: PGSDecoder.Palette,
                               state: PGSDecoder.State, width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var drewSomething = false
        for c in objects {
            guard let od = state.objects[c.objectID], od.width > 0, od.height > 0 else { continue }
            let px = PGSDecoder.decodeRLE(od.rle, width: od.width, height: od.height)
            for row in 0 ..< od.height {
                let ty = c.y + row
                guard ty >= 0, ty < height else { continue }
                for col in 0 ..< od.width {
                    let tx = c.x + col
                    guard tx >= 0, tx < width else { continue }
                    let color = palette.entries[Int(px[row * od.width + col])]
                    let a = Int(color >> 24 & 0xFF)
                    guard a > 0 else { continue }
                    let o = (ty * width + tx) * 4
                    pixels[o] = UInt8((Int(color >> 16 & 0xFF) * a + 127) / 255)
                    pixels[o + 1] = UInt8((Int(color >> 8 & 0xFF) * a + 127) / 255)
                    pixels[o + 2] = UInt8((Int(color & 0xFF) * a + 127) / 255)
                    pixels[o + 3] = UInt8(a)
                    drewSomething = true
                }
            }
        }
        guard drewSomething else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// BT.709 limited-range YCbCr -> straight RGBA packed as 0xAARRGGBB (same as PGSDecoder).
    private static func rgba(y: Double, cb: Double, cr: Double, alpha: UInt8) -> UInt32 {
        let yy = (y - 16) * 255 / 219
        let r = yy + 1.5748 * (cr - 128)
        let g = yy - 0.1873 * (cb - 128) - 0.4681 * (cr - 128)
        let b = yy + 1.8556 * (cb - 128)
        func clamp(_ v: Double) -> UInt32 { UInt32(max(0, min(255, v.rounded()))) }
        return UInt32(alpha) << 24 | clamp(r) << 16 | clamp(g) << 8 | clamp(b)
    }
}

/// Renders text subtitles (SRT / ASS / SSA / WebVTT cues) into a video-sized RGBA bitmap:
/// white, bold, black outline and shadow, bottom-centred, size ~ height / 22.
enum TextOverlayRenderer {

    static func render(text: String, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, !text.isEmpty else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize = CGFloat(height) / 22.0
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowOffset = NSSize(width: fontSize / 14, height: -fontSize / 14)
        shadow.shadowBlurRadius = fontSize / 10
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.5,            // negative = fill and stroke
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)

        let margin = CGFloat(width) * 0.08
        let maxWidth = CGFloat(width) - 2 * margin
        let bounds = attributed.boundingRect(with: NSSize(width: maxWidth, height: CGFloat(height)),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        let bottomMargin = CGFloat(height) / 18.0
        let rect = NSRect(x: margin, y: bottomMargin,
                          width: maxWidth, height: ceil(bounds.height) + fontSize * 0.3)

        let previous = NSGraphicsContext.current
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = gc
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        gc.flushGraphics()
        NSGraphicsContext.current = previous

        return ctx.makeImage()
    }

    /// Plain text of a subtitle payload: ASS/SSA dialogue line, SRT or WebVTT cue, tags removed.
    static func plainText(payload: Data, kind: SubtitleKind) -> String {
        let raw = SubtitleWriter.textOf(payload)
        var text: String
        switch kind {
        case .ass, .ssa:
            let fields = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 9 else { return "" }
            text = LocalConverter.assToSRTText(fields[8])
        case .webvtt:
            var body = raw
            if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
            text = LocalConverter.vttToSRTText(body)
        default:
            text = raw
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)   // stray ASS tags
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)      // <i>, <font …>
        text = text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                   .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                   .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Collects the forced subtitle track's blocks as they are read and answers
/// "which overlay is on screen at this PTS" for the compositor. Thread safe.
final class SubtitleOverlayTrack {

    struct Event {
        let startNs: Int64
        var endNs: Int64?          // nil = until the next event (PGS)
        let image: CIImage?        // nil = nothing on screen
    }

    let track: MediaTrack
    let kind: SubtitleKind
    private let videoWidth: Int
    private let videoHeight: Int
    private let lock = NSLock()
    private var events: [Event] = []
    private let pgsState = PGSDecoder.State()
    private(set) var eventCount = 0

    init(track: MediaTrack, videoWidth: Int, videoHeight: Int) {
        self.track = track
        self.kind = track.subtitleKind
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
    }

    /// Feeds one (decompressed) subtitle block. Called from the reader thread.
    func add(payload: Data, timestampNs: Int64, durationNs: Int64?) {
        switch kind {
        case .pgs:
            guard let overlay = PGSOverlayDecoder.decode(frame: payload, state: pgsState) else { return }
            var image: CIImage?
            if let cg = overlay.image {
                var ci = CIImage(cgImage: cg)
                // Scale the PGS canvas to the video size (normally identical).
                if overlay.canvasWidth != videoWidth || overlay.canvasHeight != videoHeight {
                    let sx = CGFloat(videoWidth) / CGFloat(overlay.canvasWidth)
                    let sy = CGFloat(videoHeight) / CGFloat(overlay.canvasHeight)
                    ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                }
                image = ci
            }
            lock.lock()
            if let last = events.indices.last, events[last].endNs == nil {
                events[last].endNs = timestampNs
            }
            events.append(Event(startNs: timestampNs, endNs: nil, image: image))
            if image != nil { eventCount += 1 }
            lock.unlock()

        case .srt, .ass, .ssa, .webvtt:
            let text = TextOverlayRenderer.plainText(payload: payload, kind: kind)
            guard !text.isEmpty else { return }
            guard let cg = TextOverlayRenderer.render(text: text, width: videoWidth, height: videoHeight) else { return }
            let end = timestampNs + (durationNs ?? 3_000_000_000)
            lock.lock()
            events.append(Event(startNs: timestampNs, endNs: end, image: CIImage(cgImage: cg)))
            eventCount += 1
            lock.unlock()

        default:
            break
        }
    }

    /// The overlay visible at `ptsNs`, or nil. Called from the decoder's output thread.
    func image(at ptsNs: Int64) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        // Drop events that ended well before this frame (frames arrive roughly in order).
        let horizon = ptsNs - 60_000_000_000
        if events.count > 64 {
            events.removeAll { e in
                if let end = e.endNs { return end < horizon }
                return false
            }
        }
        var found: CIImage?
        for e in events.reversed() {
            guard e.startNs <= ptsNs else { continue }
            if let end = e.endNs, ptsNs >= end { continue }
            found = e.image
            break
        }
        return found
    }
}
