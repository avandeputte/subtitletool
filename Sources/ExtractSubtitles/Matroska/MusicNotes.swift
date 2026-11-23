import Foundation

/// Finds ♪ glyphs in an OCR bitmap. Vision has no ♪ in its character set and reads it as `&`, `¿`,
/// `s`, `f`…, so the notes are painted out before OCR and put back as text afterwards.
enum MusicNotes {

    /// One row of text in the bitmap and the notes found at its ends.
    struct Band {
        let y0: Int
        let y1: Int        // exclusive
        var leadingCount = 0
        var trailingCount = 0
        var leading: Bool { leadingCount > 0 }
        var trailing: Bool { trailingCount > 0 }
        /// A dash stands before the leading note ("-♪ Just you wait ♪").
        var dash = false
        /// The row holds nothing but notes.
        var notesOnly = false
        var hasNotes: Bool { leading || trailing }
    }

    struct Result {
        let pixels: PGSDecoder.OCRPixels
        let bands: [Band]

        /// The band containing (or nearest to) a pixel row.
        func bandIndex(forY y: Double) -> Int? {
            var best: Int?
            var bestDistance = Double.infinity
            for (i, b) in bands.enumerated() {
                let d: Double = y < Double(b.y0) ? Double(b.y0) - y : (y >= Double(b.y1) ? y - Double(b.y1) : 0)
                if d < bestDistance { bestDistance = d; best = i }
            }
            return best
        }
    }

    private struct Component {
        let label: Int32
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        var area: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// Pixels darker than this are ink (text is dark on white in OCR bitmaps).
    private static let inkLevel: UInt8 = 128

    /// Returns the bitmap with its notes painted out, or nil when it has no notes.
    static func mask(_ p: PGSDecoder.OCRPixels) -> Result? {
        let w = p.width, h = p.height
        guard w > 0, h > 0, p.gray.count == w * h else { return nil }

        var ranges: [(Int, Int)] = []
        var start: Int?
        for y in 0 ..< h {
            var ink = false
            for x in 0 ..< w where p.gray[y * w + x] < inkLevel { ink = true; break }
            if ink { if start == nil { start = y } }
            else if let s = start { ranges.append((s, y)); start = nil }
        }
        if let s = start { ranges.append((s, h)) }
        var merged: [(Int, Int)] = []
        for r in ranges {
            if let l = merged.last, (r.0 - l.1) * 4 < min(l.1 - l.0, r.1 - r.0) {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }

        var out = p.gray
        var labels = [Int32](repeating: 0, count: w * h)
        var nextLabel: Int32 = 1
        var bands: [Band] = []
        var found = false

        for (y0, y1) in merged {
            var band = Band(y0: y0, y1: y1)
            let bandHeight = y1 - y0
            let minArea = max(4, bandHeight * bandHeight / 400)
            var comps: [Component] = []
            for y in y0 ..< y1 {
                for x in 0 ..< w where p.gray[y * w + x] < inkLevel && labels[y * w + x] == 0 {
                    let c = flood(p, x: x, y: y, y0: y0, y1: y1, label: nextLabel, labels: &labels)
                    nextLabel += 1
                    if c.area >= minArea { comps.append(c) }
                }
            }
            comps.sort { $0.minX < $1.minX }
            guard let firstComp = comps.first else { bands.append(band); continue }

            // Consecutive notes at each end of the row ("♪♪ Title ♪♪").
            var notes: [Component] = []
            var next = (comps.count > 1 && isDash(firstComp, bandHeight: bandHeight)) ? 1 : 0
            let hadDash = next == 1
            while next < comps.count, isNote(comps[next], in: p, labels: labels, bandHeight: bandHeight) {
                notes.append(comps[next])
                band.leadingCount += 1
                next += 1
            }
            band.dash = hadDash && band.leading
            var last = comps.count - 1
            while last >= next, isNote(comps[last], in: p, labels: labels, bandHeight: bandHeight) {
                notes.append(comps[last])
                band.trailingCount += 1
                last -= 1
            }
            band.notesOnly = band.hasNotes && next > last
            for n in notes { paintOut(n, pixels: &out, labels: labels, width: w, height: h, scale: p.scale) }
            if !notes.isEmpty { found = true }
            bands.append(band)
        }
        guard found else { return nil }
        return Result(pixels: PGSDecoder.OCRPixels(width: w, height: h, gray: out, scale: p.scale), bands: bands)
    }

    /// 8-connected flood fill limited to one text row.
    private static func flood(_ p: PGSDecoder.OCRPixels, x: Int, y: Int, y0: Int, y1: Int, label: Int32,
                              labels: inout [Int32]) -> Component {
        let w = p.width
        var c = Component(label: label, minX: x, maxX: x, minY: y, maxY: y, area: 0)
        var stack: [Int] = [y * w + x]
        labels[y * w + x] = label
        while let o = stack.popLast() {
            let py = o / w, px = o % w
            c.area += 1
            c.minX = min(c.minX, px); c.maxX = max(c.maxX, px)
            c.minY = min(c.minY, py); c.maxY = max(c.maxY, py)
            for dy in -1 ... 1 {
                let ny = py + dy
                guard ny >= y0, ny < y1 else { continue }
                for dx in -1 ... 1 {
                    let nx = px + dx
                    guard nx >= 0, nx < w else { continue }
                    let n = ny * w + nx
                    if labels[n] == 0, p.gray[n] < inkLevel {
                        labels[n] = label
                        stack.append(n)
                    }
                }
            }
        }
        return c
    }

    private static func isDash(_ c: Component, bandHeight: Int) -> Bool {
        c.width >= c.height * 2 && c.height * 4 <= bandHeight
    }

    /// A ♪: a filled head at the bottom left, a thin stem, a flag at the top right. The ratios were
    /// measured on real PGS glyphs and do not depend on the upscale factor.
    private static func isNote(_ c: Component, in p: PGSDecoder.OCRPixels, labels: [Int32], bandHeight: Int) -> Bool {
        let cw = c.width, ch = c.height
        guard ch >= 9, cw >= 4 else { return false }
        let heightRatio = Double(ch) / Double(bandHeight)
        let aspect = Double(cw) / Double(ch)
        guard heightRatio >= 0.6, heightRatio <= 1.1, aspect >= 0.55, aspect <= 0.85 else { return false }

        // Ink per third of the height, split into the left and right half of the width.
        var left = [0, 0, 0], right = [0, 0, 0]
        for r in 0 ..< ch {
            let third = min(2, r * 3 / ch)
            let base = (c.minY + r) * p.width + c.minX
            for k in 0 ..< cw where labels[base + k] == c.label {
                if k * 2 < cw { left[third] += 1 } else { right[third] += 1 }
            }
        }
        let top = left[0] + right[0], middle = left[1] + right[1], bottom = left[2] + right[2]
        guard top > 0, middle > 0, bottom > 0 else { return false }
        let rowsInThird = Double(ch) / 3
        let midFill = Double(middle) / (rowsInThird * Double(cw))
        let bottomFill = Double(bottom) / (rowsInThird * Double(cw))
        return Double(left[2]) / Double(bottom) >= 0.85
            && Double(right[0]) / Double(top) >= 0.65
            && Double(right[1]) / Double(middle) >= 0.4
            && midFill <= 0.2
            && bottomFill >= 0.3 && bottomFill <= 0.6
    }

    /// Whitens the note and its soft edge, leaving the pixels of neighbouring glyphs alone.
    private static func paintOut(_ c: Component, pixels: inout [UInt8], labels: [Int32],
                                 width w: Int, height h: Int, scale: Int) {
        let pad = 2 * max(1, scale)
        for y in max(0, c.minY - pad) ..< min(h, c.maxY + pad + 1) {
            for x in max(0, c.minX - pad) ..< min(w, c.maxX + pad + 1) {
                let o = y * w + x
                if labels[o] == 0 || labels[o] == c.label { pixels[o] = 255 }
            }
        }
    }

    /// True when the strokes of a text row stand upright best after shearing it back by a clear
    /// rightward angle: the column histogram is peakiest at the row's true slant.
    static func isSlanted(_ p: PGSDecoder.OCRPixels, x0: Int, x1: Int, y0: Int, y1: Int) -> Bool {
        let height = y1 - y0
        guard height >= 12, x1 > x0 else { return false }
        let yMid = Double(y0 + y1 - 1) / 2
        let reach = Int((Double(height) * 0.6).rounded(.up)) + 1
        var bestAngle = 0, bestScore = 0.0, uprightScore = 0.0
        for angle in stride(from: -8, through: 30, by: 2) {
            let t = tan(Double(angle) * .pi / 180)
            var columns = [Int](repeating: 0, count: x1 - x0 + 2 * reach)
            for y in y0 ..< y1 {
                let offset = Int(((Double(y) - yMid) * t).rounded())
                let base = y * p.width
                for x in x0 ..< x1 where p.gray[base + x] < inkLevel {
                    columns[x - x0 + reach + offset] += 1
                }
            }
            let score = columns.reduce(0.0) { $0 + Double($1 * $1) }
            if angle == 0 { uprightScore = score }
            if score > bestScore { bestScore = score; bestAngle = angle }
        }
        return uprightScore > 0 && bestAngle >= 8 && bestScore / uprightScore >= 1.12
    }

    /// Puts the notes of a band back around the recognised text.
    static func decorate(_ text: String, band: Band) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        var prefix = ""
        let notes = String(repeating: "♪", count: band.leadingCount)
        if band.leading {
            let dashes: Set<Character> = ["-", "\u{2013}", "\u{2014}"]
            if let f = body.first, dashes.contains(f) {
                body = String(body.drop { dashes.contains($0) || $0 == " " })
                prefix = "- " + notes + " "
            } else {
                prefix = (band.dash ? "- " : "") + notes + " "
            }
        }
        return prefix + body + (band.trailing ? " " + String(repeating: "♪", count: band.trailingCount) : "")
    }
}
