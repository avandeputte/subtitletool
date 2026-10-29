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
        /// PCS object flag 0x40 ("forced on"). Defaults to false so existing
        /// `CompositionObject(objectID:windowID:x:y:)` calls keep compiling.
        var isForced: Bool = false
    }

    /// Grayscale pixels of the image handed to OCR: 0 = black … 255 = white,
    /// row-major, top row first, `width * height` bytes. Dark text on a white background.
    struct OCRPixels {
        let width: Int
        let height: Int
        let gray: [UInt8]
        /// Upscale factor applied to the original bitmap (1, 2 or 3).
        let scale: Int
    }

    /// A rendered display set: nil image means "clear screen".
    struct DisplaySet {
        let timestampNs: Int64
        let image: CGImage?
        let hasObjects: Bool
        /// True when every composition object of the set carries the forced flag.
        var isForced: Bool = false
        /// The OCR-ready pixels behind `image` (nil for clear-screen sets).
        var ocrPixels: OCRPixels? = nil
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
                    // Per the PGS spec / ffmpeg pgssubdec: 0x80 = object cropped (8 bytes of
                    // cropping rectangle follow), 0x40 = forced on.
                    if flags & 0x80 != 0 { p += 8 }   // cropping rectangle, ignored
                    let forced: Bool = (flags & 0x40) != 0
                    compObjects.append(CompositionObject(objectID: objectID, windowID: windowID,
                                                         x: x, y: y, isForced: forced))
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

        let allForced: Bool = compObjects.allSatisfy { $0.isForced }
        let palette = state.palettes[paletteID] ?? Palette()
        guard let pixels = renderForOCR(objects: compObjects, palette: palette, state: state),
              let image = makeImage(pixels) else {
            return DisplaySet(timestampNs: timestampNs, image: nil, hasObjects: false, isForced: allForced)
        }
        return DisplaySet(timestampNs: timestampNs, image: image, hasObjects: true,
                          isForced: allForced, ocrPixels: pixels)
    }

    // MARK: rendering for OCR

    /// Renders the composition objects into an OCR-friendly grayscale bitmap:
    /// cropped to the visible pixels (8 px margin), dark text on an opaque white
    /// background (light text is inverted), and upscaled 2x/3x when the text is small.
    static func renderForOCR(objects: [CompositionObject], palette: Palette, state: State) -> OCRPixels? {
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

        let canvasW: Int = maxX - minX
        let canvasH: Int = maxY - minY
        guard canvasW > 0, canvasH > 0, canvasW * canvasH < 64_000_000 else { return nil }

        // Straight luminance and alpha of every pixel on the canvas.
        var lum = [UInt8](repeating: 0, count: canvasW * canvasH)
        var alpha = [UInt8](repeating: 0, count: canvasW * canvasH)
        for d in decoded {
            for row in 0 ..< d.h {
                let ty: Int = d.obj.y - minY + row
                guard ty >= 0, ty < canvasH else { continue }
                for col in 0 ..< d.w {
                    let idx = Int(d.px[row * d.w + col])
                    let color: UInt32 = palette.entries[idx]
                    let a: UInt8 = UInt8(color >> 24 & 0xFF)
                    guard a > 5 else { continue }
                    let tx: Int = d.obj.x - minX + col
                    guard tx >= 0, tx < canvasW else { continue }
                    let r = Double(color >> 16 & 0xFF)
                    let g = Double(color >> 8 & 0xFF)
                    let b = Double(color & 0xFF)
                    let y: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let o: Int = ty * canvasW + tx
                    lum[o] = UInt8(max(0, min(255, y.rounded())))
                    alpha[o] = a
                }
            }
        }

        // Bounding box of the non-transparent pixels, and the tallest run of rows with ink
        // (an estimate of one line's height when the set holds several lines).
        let visible: UInt8 = 25
        var bx0 = Int.max, by0 = Int.max, bx1 = -1, by1 = -1
        var longestRun = 0, run = 0
        for yy in 0 ..< canvasH {
            var rowHasInk = false
            let base = yy * canvasW
            for xx in 0 ..< canvasW where alpha[base + xx] > visible {
                rowHasInk = true
                if xx < bx0 { bx0 = xx }
                if xx > bx1 { bx1 = xx }
            }
            if rowHasInk {
                if yy < by0 { by0 = yy }
                by1 = yy
                run += 1
                if run > longestRun { longestRun = run }
            } else {
                run = 0
            }
        }
        guard bx1 >= bx0, by1 >= by0 else { return nil }
        let textW: Int = bx1 - bx0 + 1
        let textH: Int = by1 - by0 + 1

        // Is the text light (white/yellow on a dark outline, the usual case)?
        // Judge from the opaque pixels that are not on the edge of the ink (erosion by one
        // pixel), so the thin dark outline weighs less than the glyph fill.
        var sumEroded: Int = 0, nEroded: Int = 0
        var sumAll: Int = 0, nAll: Int = 0
        for yy in by0 ... by1 {
            for xx in bx0 ... bx1 {
                let o: Int = yy * canvasW + xx
                guard alpha[o] >= 128 else { continue }
                sumAll += Int(lum[o]); nAll += 1
                guard yy > 0, yy < canvasH - 1, xx > 0, xx < canvasW - 1 else { continue }
                var interior = true
                for dy in -1 ... 1 where interior {
                    for dx in -1 ... 1 where alpha[(yy + dy) * canvasW + (xx + dx)] < 128 {
                        interior = false
                        break
                    }
                }
                if interior { sumEroded += Int(lum[o]); nEroded += 1 }
            }
        }
        let meanLum: Double
        if nEroded >= 16 {
            meanLum = Double(sumEroded) / Double(nEroded)
        } else if nAll > 0 {
            meanLum = Double(sumAll) / Double(nAll)
        } else {
            meanLum = 255
        }
        // Biased towards "light": PGS text is almost always white on a dark outline.
        let lightText: Bool = meanLum >= 100

        // Crop with an 8 px margin and composite onto opaque white (dark ink).
        let margin = 8
        let outW: Int = textW + 2 * margin
        let outH: Int = textH + 2 * margin
        var gray = [UInt8](repeating: 255, count: outW * outH)
        for oy in 0 ..< outH {
            let sy: Int = by0 - margin + oy
            guard sy >= 0, sy < canvasH else { continue }
            for ox in 0 ..< outW {
                let sx: Int = bx0 - margin + ox
                guard sx >= 0, sx < canvasW else { continue }
                let o: Int = sy * canvasW + sx
                let a: Double = Double(alpha[o]) / 255.0
                guard a > 0 else { continue }
                let l: Double = Double(lum[o])
                let v: Double
                if lightText {
                    // Composite over black, then invert: text -> dark, outline/background -> white.
                    v = 255.0 - a * l
                } else {
                    // Dark text: composite over white.
                    v = a * l + (1.0 - a) * 255.0
                }
                gray[oy * outW + ox] = UInt8(max(0, min(255, v.rounded())))
            }
        }

        let lineH: Int = longestRun > 0 ? min(longestRun, textH) : textH
        let scale: Int = lineH < 30 ? 3 : (lineH < 60 ? 2 : 1)
        let base = OCRPixels(width: outW, height: outH, gray: gray, scale: 1)
        guard scale > 1 else { return base }
        return upscale(base, by: scale) ?? base
    }

    /// Scales grayscale pixels up by an integer factor with Core Graphics' high-quality interpolation.
    private static func upscale(_ src: OCRPixels, by factor: Int) -> OCRPixels? {
        let w: Int = src.width * factor
        let h: Int = src.height * factor
        guard w > 0, h > 0, w * h < 64_000_000 else { return nil }
        guard let srcImage = makeGrayImage(src) else { return nil }
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let stride: Int = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var out = [UInt8](repeating: 255, count: w * h)
        for yy in 0 ..< h {
            let rowBase: Int = yy * stride
            for xx in 0 ..< w {
                out[yy * w + xx] = ptr[rowBase + xx]
            }
        }
        return OCRPixels(width: w, height: h, gray: out, scale: factor)
    }

    /// 8-bit grayscale CGImage from OCR pixels.
    private static func makeGrayImage(_ p: OCRPixels) -> CGImage? {
        guard p.gray.count == p.width * p.height, p.width > 0, p.height > 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(p.gray) as CFData) else { return nil }
        return CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: p.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Opaque RGBX CGImage (the format handed to Vision) from OCR pixels.
    static func makeImage(_ p: OCRPixels) -> CGImage? {
        guard p.gray.count == p.width * p.height, p.width > 0, p.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: p.width * p.height * 4)
        for i in 0 ..< p.gray.count {
            let v: UInt8 = p.gray[i]
            let o: Int = i * 4
            pixels[o] = v
            pixels[o + 1] = v
            pixels[o + 2] = v
            pixels[o + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: p.width * 4, space: CGColorSpaceCreateDeviceRGB(),
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
