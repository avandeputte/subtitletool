import Foundation
import CoreGraphics

/// Decodes Presentation Graphic Stream (Blu-ray PGS, Matroska S_HDMV/PGS) subtitle
/// display sets into bitmaps, so they can be OCR'd.
///
/// Each Matroska frame normally holds one display set:
///   PCS (0x16) – composition, WDS (0x17) – windows, PDS (0x14) – palette,
///   ODS (0x15) – object bitmap (RLE), END (0x80).
/// A display set with zero composition objects clears the screen (end of a cue).
enum PGSDecoder {

    struct Palette {
        var entries = [UInt32](repeating: 0, count: 256)   // 0xAARRGGBB, straight alpha
    }

    struct ObjectData {
        var width = 0
        var height = 0
        var rle = Data()
        var expectedLength = 0
    }

    struct CompositionObject {
        let objectID: Int
        let windowID: Int
        let x: Int
        let y: Int
    }

    /// A rendered display set: nil image means "clear screen".
    struct DisplaySet {
        let timestampNs: Int64
        let image: CGImage?
        let hasObjects: Bool
    }

    /// Decoder state persists across frames because palettes/objects can be reused
    /// (palette-update-only display sets, epoch continuity).
    final class State {
        var palettes: [Int: Palette] = [:]
        var objects: [Int: ObjectData] = [:]
        var windows: [Int: (x: Int, y: Int, w: Int, h: Int)] = [:]
    }

    /// Decodes a Matroska PGS frame (a sequence of segments) into a display set.
    static func decode(frame: Data, timestampNs: Int64, state: State) -> DisplaySet {
        var i = frame.startIndex
        var compObjects: [CompositionObject] = []
        var paletteID = 0
        var sawPCS = false

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
                    if flags & 0x40 != 0 { p += 8 }   // cropping rectangle, ignored
                    compObjects.append(CompositionObject(objectID: objectID, windowID: windowID, x: x, y: y))
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
                var pal = state.palettes[id] ?? Palette()
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
                var obj = (seqFlag & 0x80 != 0) ? ObjectData() : (state.objects[id] ?? ObjectData())
                if seqFlag & 0x80 != 0 {
                    guard seg.count >= 11 else { break }
                    obj.expectedLength = Int(seg[p]) << 16 | Int(seg[p + 1]) << 8 | Int(seg[p + 2])
                    obj.width = Int(seg[p + 3]) << 8 | Int(seg[p + 4])
                    obj.height = Int(seg[p + 5]) << 8 | Int(seg[p + 6])
                    p += 7
                }
                obj.rle.append(seg[p ..< seg.endIndex])
                state.objects[id] = obj

            default: // END (0x80) and unknown
                break
            }
            i = end
        }

        guard sawPCS else { return DisplaySet(timestampNs: timestampNs, image: nil, hasObjects: false) }
        guard !compObjects.isEmpty else { return DisplaySet(timestampNs: timestampNs, image: nil, hasObjects: false) }

        let palette = state.palettes[paletteID] ?? Palette()
        let image = render(objects: compObjects, palette: palette, state: state)
        return DisplaySet(timestampNs: timestampNs, image: image, hasObjects: image != nil)
    }

    // MARK: rendering

    private static func render(objects: [CompositionObject], palette: Palette, state: State) -> CGImage? {
        // Bounding box of all objects
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        var decoded: [(obj: CompositionObject, w: Int, h: Int, px: [UInt8])] = []
        for c in objects {
            guard let od = state.objects[c.objectID], od.width > 0, od.height > 0 else { continue }
            let px = decodeRLE(od.rle, width: od.width, height: od.height)
            decoded.append((c, od.width, od.height, px))
            minX = min(minX, c.x); minY = min(minY, c.y)
            maxX = max(maxX, c.x + od.width); maxY = max(maxY, c.y + od.height)
        }
        guard !decoded.isEmpty, maxX > minX, maxY > minY else { return nil }

        let pad = 24
        let width = maxX - minX + 2 * pad
        let height = maxY - minY + 2 * pad
        var pixels = [UInt8](repeating: 0, count: width * height * 4)   // RGBX, opaque black

        for d in decoded {
            for row in 0 ..< d.h {
                let ty = d.obj.y - minY + pad + row
                guard ty >= 0, ty < height else { continue }
                for col in 0 ..< d.w {
                    let idx = Int(d.px[row * d.w + col])
                    let color = palette.entries[idx]
                    let a = Double(color >> 24 & 0xFF) / 255.0
                    guard a > 0.02 else { continue }
                    let tx = d.obj.x - minX + pad + col
                    guard tx >= 0, tx < width else { continue }
                    // Composite over black
                    let o = (ty * width + tx) * 4
                    pixels[o] = UInt8(Double(color >> 16 & 0xFF) * a)
                    pixels[o + 1] = UInt8(Double(color >> 8 & 0xFF) * a)
                    pixels[o + 2] = UInt8(Double(color & 0xFF) * a)
                    pixels[o + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PGS run-length decoding to palette indices.
    static func decodeRLE(_ d: Data, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var i = d.startIndex
        var x = 0, y = 0
        func put(_ color: UInt8, _ count: Int) {
            guard y < height else { return }
            let n = min(count, width - x)
            if n > 0 {
                let base = y * width + x
                for k in 0 ..< n { out[base + k] = color }
                x += n
            }
        }
        while i < d.endIndex, y < height {
            let b = d[i]; i += 1
            if b != 0 {
                put(b, 1)
                continue
            }
            guard i < d.endIndex else { break }
            let f = d[i]; i += 1
            if f == 0 {            // end of line
                x = 0; y += 1
                continue
            }
            let flags = f >> 6
            var count = Int(f & 0x3F)
            switch flags {
            case 0:
                put(0, count)
            case 1:
                guard i < d.endIndex else { return out }
                count = count << 8 | Int(d[i]); i += 1
                put(0, count)
            case 2:
                guard i < d.endIndex else { return out }
                let color = d[i]; i += 1
                put(color, count)
            default:
                guard i + 1 < d.endIndex else { return out }
                count = count << 8 | Int(d[i]); i += 1
                let color = d[i]; i += 1
                put(color, count)
            }
        }
        return out
    }

    /// BT.709 limited-range YCbCr -> straight RGBA packed as 0xAARRGGBB.
    private static func rgba(y: Double, cb: Double, cr: Double, alpha: UInt8) -> UInt32 {
        let yy = (y - 16) * 255 / 219
        let r = yy + 1.5748 * (cr - 128)
        let g = yy - 0.1873 * (cb - 128) - 0.4681 * (cr - 128)
        let b = yy + 1.8556 * (cb - 128)
        func clamp(_ v: Double) -> UInt32 { UInt32(max(0, min(255, v.rounded()))) }
        return UInt32(alpha) << 24 | clamp(r) << 16 | clamp(g) << 8 | clamp(b)
    }
}
