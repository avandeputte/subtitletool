import Foundation

enum DamageSeverity: Int, Comparable, Sendable {
    case ok = 0, warning = 1, damaged = 2
    static func < (a: DamageSeverity, b: DamageSeverity) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Check"
        case .damaged: return "Damaged"
        }
    }
}

struct DamageFinding: Identifiable, Sendable {
    let id = UUID()
    let severity: DamageSeverity
    let text: String
}

struct DamageReport: Sendable {
    let url: URL
    let size: Int
    let format: String
    var duration: Double?
    var lastFrame: Double?
    var findings: [DamageFinding]
    var readEveryByte: Bool
    var elapsed: Double

    var severity: DamageSeverity { findings.map(\.severity).max() ?? .ok }
    var headline: String {
        if let worst = findings.max(by: { $0.severity < $1.severity }) { return worst.text }
        var parts = [format]
        if let duration { parts.append(DamageFormat.time(duration)) }
        parts.append(readEveryByte ? "every byte read" : "structure checked")
        return parts.joined(separator: " · ")
    }
}

enum DamageFormat {
    static func time(_ seconds: Double) -> String {
        let t = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Read-only checker for MKV and MP4 files. Files are opened O_RDONLY and nothing is ever written.
///
/// The quick check follows the container structure, so it jumps from cluster to cluster (or chunk
/// to chunk) and reads a few MB of a 70 GB file. The full check also reads every byte to find
/// read errors and zero-filled runs that sit entirely inside a cluster.
enum MediaDamageScanner {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v"]
    /// A run of zeros this long cannot occur in compressed audio/video that is interleaved.
    static let zeroRunThreshold = 1 << 20
    /// Missing playback time that is reported as damage, and as worth a look.
    static let damagedShortfall = 30.0
    static let warningShortfall = 5.0

    struct Cancelled: Error {}

    final class Context {
        let file: MKVFile
        let isCancelled: () -> Bool
        let progress: (Double) -> Void
        private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 4096)
        private var lastProgress = -1.0

        init(file: MKVFile, isCancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) {
            self.file = file
            self.isCancelled = isCancelled
            self.progress = progress
        }
        deinit { buffer.deallocate() }

        func tick(_ fraction: Double) throws {
            if isCancelled() { throw Cancelled() }
            if fraction - lastProgress >= 0.005 {
                lastProgress = fraction
                progress(min(1, fraction))
            }
        }

        func isZero(at offset: Int, length: Int) -> Bool {
            let n = min(length, 1 << 20)
            guard n > 0, file.read(into: buffer, offset: offset, length: n) == n else { return false }
            return MediaDamageScanner.allZero(buffer, n)
        }

        /// Share of `range` that is zero-filled, from evenly spaced 4 KB samples.
        func zeroFraction(_ range: Range<Int>) -> Double {
            guard range.count >= 4096 else { return 0 }
            let samples = min(512, max(1, range.count / (1 << 20)))
            let step = max(1, (range.count - 4096) / max(1, samples - 1))
            var zero = 0
            for i in 0 ..< samples where isZero(at: range.lowerBound + i * step, length: 4096) { zero += 1 }
            return Double(zero) / Double(samples)
        }

        /// If the 4 KB at `offset` are zero and belong to a run of at least 1 MB, returns that run.
        func zeroRun(around offset: Int, within bounds: Range<Int>) -> Range<Int>? {
            let mib = MediaDamageScanner.zeroRunThreshold
            guard isZero(at: offset, length: 4096) else { return nil }
            var lo = offset, hi = offset + 4096
            // Grow in 1 MB steps, then halve the step to land on the exact first and last zero byte.
            var step = mib
            while step > 0 {
                let n = min(step, lo - bounds.lowerBound)
                if n > 0, isZero(at: lo - n, length: n) { lo -= n } else { step /= 2 }
            }
            step = mib
            while step > 0 {
                let n = min(step, bounds.upperBound - hi)
                if n > 0, isZero(at: hi, length: n) { hi += n } else { step /= 2 }
            }
            return hi - lo >= mib ? lo ..< hi : nil
        }
    }

    static func allZero(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        guard n > 0, p.load(as: UInt8.self) == 0 else { return false }
        return n == 1 || memcmp(p, p + 1, n - 1) == 0
    }

    /// Every MKV/MP4 in the given files and folders, subfolders included, sorted by path.
    static func collectFiles(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = walker?.nextObject() as? URL {
                    if isVideo(item) { found.append(item) }
                }
            } else if isVideo(url) {
                found.append(url)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix("._")
    }

    static func scan(url: URL, readEveryByte: Bool,
                     isCancelled: @escaping () -> Bool = { false },
                     progress: @escaping (Double) -> Void = { _ in }) throws -> DamageReport {
        let started = Date()
        let file = try MKVFile(url: url)
        let context = Context(file: file, isCancelled: isCancelled, progress: progress)
        // With a full read the structure pass is a small part of the work.
        let structureShare = readEveryByte ? 0.03 : 1.0
        let structural = Context(file: file, isCancelled: isCancelled) { progress($0 * structureShare) }

        var result: ContainerResult
        if url.pathExtension.lowercased() == "mkv" {
            result = try MKVDamageCheck(context: structural).run()
        } else {
            result = try MP4DamageCheck(context: structural).run()
        }
        if readEveryByte {
            try fullRead(context: context, result: &result, start: structureShare)
        }
        if file.failed, !result.findings.contains(where: { $0.text.contains("could not be read") }) {
            result.findings.append(.init(severity: .damaged, text: "Part of the file could not be read (disk error or disconnected)."))
        }
        progress(1)
        // A file another app is still writing (a rip in progress) looks truncated: don't call it damaged.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) < 120, result.findings.contains(where: { $0.severity == .damaged }) {
            result.findings = [.init(severity: .warning, text: "Still being written by another app. Check again when it has finished.")]
        }
        let ordered = result.findings.sorted { $0.severity > $1.severity }
        return DamageReport(url: url, size: file.size, format: result.format, duration: result.duration,
                            lastFrame: result.lastFrame, findings: ordered, readEveryByte: readEveryByte,
                            elapsed: Date().timeIntervalSince(started))
    }

    /// Reads the whole file in order, reporting read errors and zero runs not already reported.
    private static func fullRead(context: Context, result: inout ContainerResult, start: Double) throws {
        let file = context.file
        let chunk = 8 << 20, page = 4096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: page)
        defer { buffer.deallocate() }
        var offset = 0, runStart: Int?, unreadable = 0, firstUnreadable: Int?

        func finish(_ end: Int) {
            defer { runStart = nil }
            guard let s = runStart, end - s >= zeroRunThreshold else { return }
            let run = s ..< end
            if result.knownRanges.contains(where: { $0.overlaps(run) }) { return }
            result.knownRanges.append(run)
            var text = "\(DamageFormat.bytes(run.count)) of zeros at byte \(run.lowerBound)"
            if let t = result.timeAt(run.lowerBound) { text += ", around \(DamageFormat.time(t))" }
            result.findings.append(.init(severity: .damaged, text: text + "."))
        }

        while offset < file.size {
            try context.tick(start + (1 - start) * Double(offset) / Double(max(1, file.size)))
            let want = min(chunk, file.size - offset)
            let got = file.read(into: buffer, offset: offset, length: want)
            if got < want {
                finish(offset + got - got % page)
                firstUnreadable = firstUnreadable ?? offset + got
                let skip = max(got + page, 1 << 20)
                unreadable += min(skip, file.size - offset) - got
                offset += skip
                continue
            }
            var p = 0
            while p < got {
                let n = min(page, got - p)
                if allZero(buffer + p, n) {
                    if runStart == nil { runStart = offset + p }
                } else if runStart != nil {
                    finish(offset + p)
                }
                p += n
            }
            offset += got
        }
        finish(file.size)
        if let firstUnreadable {
            file.failed = false
            result.findings.append(.init(severity: .damaged,
                text: "About \(DamageFormat.bytes(unreadable)) could not be read, starting at byte \(firstUnreadable)."))
        }
    }
}

struct ContainerResult {
    var format: String
    var duration: Double?
    var lastFrame: Double?
    var findings: [DamageFinding] = []
    /// Byte ranges already explained (reported damage, or padding such as Void and free boxes).
    var knownRanges: [Range<Int>] = []
    var timeAt: (Int) -> Double? = { _ in nil }
}

// MARK: - Matroska

private final class MKVDamageCheck {
    private static let duration: UInt32 = 0x4489
    private static let prevSize: UInt32 = 0xAB
    private static let position: UInt32 = 0xA7
    private static let silentTracks: UInt32 = 0x5854

    private let context: MediaDamageScanner.Context
    private var r: EBMLReader
    private var result = ContainerResult(format: "MKV")
    private var scale = 1_000_000.0
    private var segmentStart = 0
    private var limit = 0
    private var trackNumbers = Set<UInt64>()
    private var cuePositions: [Int] = []
    private var cuesOffset: Int?
    private var clusterOffsets: [Int] = []
    private var clusterTimes: [Double] = []
    private var damage: [Range<Int>] = []
    private var damageEntries: [(range: Range<Int>, time: Double?, kind: String)] = []
    private var firstBreakTime: Double?

    init(context: MediaDamageScanner.Context) {
        self.context = context
        r = EBMLReader(file: context.file, windowSize: 16 * 1024)
    }

    private var size: Int { context.file.size }

    private func add(_ severity: DamageSeverity, _ text: String) {
        result.findings.append(.init(severity: severity, text: text))
    }

    func run() throws -> ContainerResult {
        guard let ebml = try? r.readElementHeader(), ebml.id == MKV.ebml, let headerEnd = ebml.dataEnd, headerEnd < size else {
            add(.damaged, "The Matroska header is missing or unreadable.")
            return result
        }
        r.pos = headerEnd
        guard let segment = try? r.readElementHeader(), segment.id == MKV.segment else {
            add(.damaged, "The Matroska segment is missing or unreadable.")
            return result
        }
        segmentStart = segment.dataOffset
        let declaredEnd = segment.dataEnd ?? size
        limit = min(declaredEnd, size)
        if declaredEnd > size {
            add(.damaged, "Truncated: the file is \(DamageFormat.bytes(declaredEnd - size)) shorter than its header says.")
        }

        try walkSegment()
        finish(declaredEnd: declaredEnd)
        let offsets = clusterOffsets, times = clusterTimes
        result.timeAt = { offset in
            var lo = 0, hi = offsets.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if offsets[mid] <= offset { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? times[lo - 1] : nil
        }
        result.knownRanges += damage
        return result
    }

    private func walkSegment() throws {
        var pos = segmentStart
        var previous: (offset: Int, end: Int, time: Double)?
        while pos < limit {
            try context.tick(Double(pos) / Double(max(1, size)))
            r.pos = pos
            guard let e = try? r.readElementHeader(), isTopLevel(e.id) else {
                guard let next = try recover(at: pos, previous: previous) else { return }
                pos = next
                previous = nil
                continue
            }
            if e.id == MKV.void, let end = e.dataEnd { result.knownRanges.append(e.dataOffset ..< min(end, size)) }

            if e.id == MKV.cluster {
                guard let timestamp = clusterTimestamp(e) else {
                    guard let next = try recover(at: pos, previous: previous) else { return }
                    pos = next
                    previous = nil
                    continue
                }
                let time = Double(timestamp) * scale / 1e9
                if let previous { checkTimeline(from: previous.time, to: time, offset: pos) }
                clusterOffsets.append(pos)
                clusterTimes.append(time)

                var end = e.dataEnd
                if end == nil {
                    let walk = walkBlocks(e, clusterTime: timestamp)
                    if let bad = walk.badOffset {
                        guard let next = try recover(at: bad, previous: nil) else { return }
                        pos = next
                        previous = nil
                        continue
                    }
                    end = walk.end
                }
                guard let clusterEnd = end else { return }
                if clusterEnd > size {
                    let walk = walkBlocks(e, clusterTime: timestamp)
                    let from = walk.badOffset ?? walk.end
                    recordDamage(from ..< size, at: walk.lastEnd ?? time, kind: "Truncated inside the last cluster")
                    return
                }
                probeInside(e, end: clusterEnd)
                previous = (pos, clusterEnd, time)
                pos = clusterEnd
                continue
            }

            guard let end = e.dataEnd, end <= size else {
                add(.damaged, "A \(name(e.id)) element runs past the end of the file.")
                return
            }
            switch e.id {
            case MKV.info: parseInfo(e)
            case MKV.tracks: parseTracks(e)
            case MKV.seekHead: parseSeekHead(e)
            case MKV.cues:
                cuesOffset = e.headerStart
                if cuePositions.isEmpty { parseCues(e) }
            default: break
            }
            pos = end
        }
    }

    /// The structure stopped making sense at `pos`: measure the damage and find where it resumes.
    private func recover(at pos: Int, previous: (offset: Int, end: Int, time: Double)?) throws -> Int? {
        var start = pos
        var lastGood = clusterTimes.last
        if let previous, previous.end == pos {
            r.pos = previous.offset
            if let e = try? r.readElementHeader(), let ts = clusterTimestamp(e) {
                let walk = walkBlocks(e, clusterTime: ts)
                if let bad = walk.badOffset { start = bad }
                lastGood = walk.lastEnd ?? lastGood
            }
        }
        let next = try findResume(after: pos)
        recordDamage(start ..< (next ?? limit), at: lastGood, kind: "Damaged data")
        return next
    }

    private func recordDamage(_ range: Range<Int>, at time: Double?, kind: String) {
        guard !range.isEmpty else { return }
        damage.append(range)
        if firstBreakTime == nil { firstBreakTime = time }
        damageEntries.append((range, time, kind))
    }

    /// One finding per damaged area: overlapping or touching reports are merged first.
    private func reportDamage() {
        var merged: [(range: Range<Int>, time: Double?, kind: String)] = []
        for entry in damageEntries.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = merged.last, entry.range.lowerBound <= last.range.upperBound + (1 << 20) {
                let upper = max(last.range.upperBound, entry.range.upperBound)
                merged[merged.count - 1].range = last.range.lowerBound ..< upper
                merged[merged.count - 1].time = [last.time, entry.time].compactMap { $0 }.min()
            } else {
                merged.append(entry)
            }
        }
        damage = merged.map(\.range)
        firstBreakTime = merged.first?.time ?? firstBreakTime
        for entry in merged {
            let share = context.zeroFraction(entry.range)
            var text = "\(entry.kind): \(DamageFormat.bytes(entry.range.count))"
            if share >= 0.5 { text += " (\(Int((share * 100).rounded()))% zero-filled)" }
            text += " at byte \(entry.range.lowerBound)"
            if let time = entry.time { text += ", after \(DamageFormat.time(time))" }
            add(.damaged, text + ".")
        }
    }

    /// Next intact element after damage, from the Cues if they survive, otherwise by searching.
    private func findResume(after pos: Int) throws -> Int? {
        var cueIndex = lowerBound(cuePositions, pos + 1)
        let minimum = clusterTimes.last ?? 0
        while cueIndex < cuePositions.count {
            if isPlausibleCluster(at: cuePositions[cueIndex], minimumTime: minimum) { return cuePositions[cueIndex] }
            cueIndex += 1
        }
        let cueCandidate = cuesOffset.flatMap { $0 > pos ? $0 : nil }
        let chunk = 4 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buffer.deallocate() }
        var offset = pos
        let end = cueCandidate ?? limit
        while offset < end {
            try context.tick(Double(offset) / Double(max(1, size)))
            let want = min(chunk, end - offset)
            let got = context.file.read(into: buffer, offset: offset, length: want)
            guard got >= 4 else { break }
            let bytes = UnsafeRawBufferPointer(start: buffer, count: got)
            var i = 0
            while i <= got - 4, let hit = memchr(buffer + i, 0x1F, got - 3 - i) {
                i = hit - UnsafeMutableRawPointer(buffer)
                if bytes[i + 1] == 0x43, bytes[i + 2] == 0xB6, bytes[i + 3] == 0x75,
                   isPlausibleCluster(at: offset + i, minimumTime: minimum) {
                    return offset + i
                }
                i += 1
            }
            if got < want { break }
            offset += got - 3
        }
        return cueCandidate
    }

    private func isPlausibleCluster(at offset: Int, minimumTime: Double) -> Bool {
        guard offset >= segmentStart, offset < limit else { return false }
        var probe = r
        probe.pos = offset
        guard let e = try? probe.readElementHeader(), e.id == MKV.cluster,
              (e.dataEnd ?? offset) <= size, let ts = clusterTimestamp(e) else { return false }
        return Double(ts) * scale / 1e9 >= minimumTime
    }

    private func probeInside(_ e: EBMLReader.Element, end: Int) {
        guard end - e.dataOffset >= 2 << 20 else { return }
        let middle = (e.dataOffset + end) / 2 & ~4095
        guard let run = context.zeroRun(around: middle, within: e.dataOffset ..< end),
              !damage.contains(where: { $0.overlaps(run) }) else { return }
        recordDamage(run, at: clusterTimes.last, kind: "Zero-filled data inside a cluster")
    }

    private func checkTimeline(from previous: Double, to time: Double, offset: Int) {
        if time - previous > MediaDamageScanner.damagedShortfall {
            add(.warning, "Timestamp gap of \(DamageFormat.time(time - previous)) after \(DamageFormat.time(previous)).")
        } else if previous - time > 1 {
            add(.warning, "Timestamps jump backward at \(DamageFormat.time(time)).")
        }
    }

    private func finish(declaredEnd: Int) {
        reportDamage()
        if clusterOffsets.isEmpty {
            add(.damaged, "No video data (clusters) could be found.")
            return
        }
        // The real end of playback comes from the blocks of the last intact cluster.
        r.pos = clusterOffsets[clusterOffsets.count - 1]
        var lastFrame = clusterTimes.last
        if let e = try? r.readElementHeader(), let ts = clusterTimestamp(e) {
            lastFrame = walkBlocks(e, clusterTime: ts).lastEnd ?? lastFrame
        }
        result.lastFrame = lastFrame
        if let duration = result.duration, let lastFrame {
            let missing = duration - lastFrame
            if missing >= MediaDamageScanner.damagedShortfall {
                add(.damaged, "Playback stops at \(DamageFormat.time(lastFrame)) of \(DamageFormat.time(duration)) (\(DamageFormat.time(missing)) missing).")
            } else if missing >= MediaDamageScanner.warningShortfall {
                add(.warning, "The last frame is \(Int(missing)) seconds before the stated duration.")
            }
        }
        if let first = firstBreakTime, let duration = result.duration, damage.count > 0,
           !result.findings.contains(where: { $0.text.hasPrefix("Playback stops") }), duration - first >= MediaDamageScanner.damagedShortfall {
            add(.damaged, "Playback is interrupted at \(DamageFormat.time(first)) of \(DamageFormat.time(duration)).")
        }
        if !cuePositions.isEmpty {
            let known = Set(clusterOffsets)
            let dangling = cuePositions.filter { p in !known.contains(p) && !damage.contains { $0.contains(p) } }
            if !dangling.isEmpty {
                add(.warning, "\(dangling.count) seek index entries point to places that are not clusters.")
            }
        }
    }

    private func isTopLevel(_ id: UInt32) -> Bool {
        MKV.level1.contains(id) || id == MKV.void || id == MKV.crc32
    }

    private func name(_ id: UInt32) -> String {
        switch id {
        case MKV.info: return "Info"
        case MKV.tracks: return "Tracks"
        case MKV.cues: return "Cues"
        case MKV.tags: return "Tags"
        case MKV.chapters: return "Chapters"
        case MKV.attachments: return "Attachments"
        case MKV.seekHead: return "SeekHead"
        default: return "Matroska"
        }
    }

    private func clusterTimestamp(_ e: EBMLReader.Element) -> UInt64? {
        var probe = r
        var p = e.dataOffset
        let end = e.dataEnd ?? min(p + 4096, size)
        for _ in 0 ..< 4 where p < end {
            probe.pos = p
            guard let c = try? probe.readElementHeader(), let childEnd = c.dataEnd, childEnd <= size else { return nil }
            if c.id == MKV.clusterTimestamp { return c.dataSize.map { $0 <= 8 } == true ? probe.uint(c) : nil }
            guard c.id == MKV.void || c.id == MKV.crc32 else { return nil }
            p = childEnd
        }
        return nil
    }

    /// Follows the blocks of one cluster. `badOffset` is where they stop being valid.
    private func walkBlocks(_ e: EBMLReader.Element, clusterTime: UInt64) -> (end: Int, badOffset: Int?, lastEnd: Double?) {
        var probe = r
        var p = e.dataOffset
        let end = min(e.dataEnd ?? size, size)
        var lastEnd: Double?

        func note(_ block: EBMLReader.Element, duration: UInt64) -> Bool {
            guard let blockEnd = block.dataEnd, blockEnd <= size else { return false }
            probe.pos = block.dataOffset
            guard let track = try? probe.readVInt(keepMarker: false),
                  trackNumbers.isEmpty || trackNumbers.contains(track.value),
                  probe.pos + 3 <= blockEnd else { return false }
            let raw = Int16(bitPattern: UInt16(probe.byte(at: probe.pos)) << 8 | UInt16(probe.byte(at: probe.pos + 1)))
            let stop = (Double(clusterTime) + Double(raw) + Double(duration)) * scale / 1e9
            lastEnd = max(lastEnd ?? stop, stop)
            return true
        }

        while p < end {
            probe.pos = p
            guard let c = try? probe.readElementHeader() else { return (p, p, lastEnd) }
            if e.dataSize == nil, MKV.level1.contains(c.id) { return (p, nil, lastEnd) }
            guard let childEnd = c.dataEnd, childEnd <= end else { return (p, p, lastEnd) }
            switch c.id {
            case MKV.simpleBlock:
                if !note(c, duration: 0) { return (p, p, lastEnd) }
            case MKV.blockGroup:
                var q = c.dataOffset
                var block: EBMLReader.Element?
                var duration: UInt64 = 0
                while q < childEnd {
                    probe.pos = q
                    guard let g = try? probe.readElementHeader(), let groupEnd = g.dataEnd, groupEnd <= childEnd else {
                        return (p, p, lastEnd)
                    }
                    if g.id == MKV.block { block = g }
                    if g.id == MKV.blockDuration { duration = probe.uint(g) }
                    q = groupEnd
                }
                guard let block, note(block, duration: duration) else { return (p, p, lastEnd) }
            case MKV.clusterTimestamp, MKV.void, MKV.crc32, Self.prevSize, Self.position, Self.silentTracks:
                break
            default:
                return (p, p, lastEnd)
            }
            p = childEnd
        }
        return (p, nil, lastEnd)
    }

    private func children(_ e: EBMLReader.Element, _ body: (EBMLReader.Element) -> Void) {
        guard let end = e.dataEnd, end <= size else { return }
        var probe = r
        var p = e.dataOffset
        while p < end {
            probe.pos = p
            guard let c = try? probe.readElementHeader(), let childEnd = c.dataEnd, childEnd <= end else { return }
            body(c)
            p = childEnd
        }
    }

    private func parseInfo(_ e: EBMLReader.Element) {
        var rawDuration: Double?
        children(e) { c in
            if c.id == MKV.timestampScale {
                let v = r.uint(c)
                if v > 0 { scale = Double(v) }
            } else if c.id == Self.duration {
                let d = r.binary(c)
                let bits = d.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                if d.count == 4 { rawDuration = Double(Float(bitPattern: UInt32(bits))) }
                if d.count == 8 { rawDuration = Double(bitPattern: bits) }
            }
        }
        if let rawDuration, rawDuration.isFinite, rawDuration > 0 { result.duration = rawDuration * scale / 1e9 }
    }

    private func parseTracks(_ e: EBMLReader.Element) {
        children(e) { entry in
            guard entry.id == MKV.trackEntry else { return }
            children(entry) { c in
                if c.id == MKV.trackNumber { trackNumbers.insert(r.uint(c)) }
            }
        }
    }

    private func parseSeekHead(_ e: EBMLReader.Element) {
        children(e) { seek in
            guard seek.id == MKV.seek else { return }
            var id: UInt32 = 0
            var position: Int?
            children(seek) { c in
                if c.id == MKV.seekID { id = r.binary(c).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
                if c.id == MKV.seekPosition { position = Int(r.uint(c)) }
            }
            guard id == MKV.cues, let position, cuesOffset == nil else { return }
            let offset = segmentStart + position
            guard offset < size else { return }
            var probe = r
            probe.pos = offset
            if let cues = try? probe.readElementHeader(), cues.id == MKV.cues, (cues.dataEnd ?? size + 1) <= size {
                cuesOffset = offset
                parseCues(cues)
            }
        }
    }

    private func parseCues(_ e: EBMLReader.Element) {
        var positions = Set<Int>()
        children(e) { point in
            guard point.id == MKV.cuePoint else { return }
            children(point) { track in
                guard track.id == MKV.cueTrackPositions else { return }
                children(track) { c in
                    if c.id == MKV.cueClusterPosition { positions.insert(segmentStart + Int(r.uint(c))) }
                }
            }
        }
        cuePositions = positions.sorted()
    }

    private func lowerBound(_ values: [Int], _ target: Int) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - MP4

private final class MP4DamageCheck {
    private struct Box {
        let type: String
        let offset: Int
        let payload: Int
        let end: Int
    }

    private struct Track {
        var timescale = 0.0
        var handler = ""
        var duration = 0.0
        var chunks: [(offset: Int, length: Int, time: Double)] = []
    }

    private let context: MediaDamageScanner.Context
    private var result = ContainerResult(format: "MP4")
    private var size: Int { context.file.size }

    init(context: MediaDamageScanner.Context) { self.context = context }

    private func add(_ severity: DamageSeverity, _ text: String) {
        result.findings.append(.init(severity: severity, text: text))
    }

    private func read(_ offset: Int, _ length: Int) -> [UInt8]? {
        guard length >= 0, offset >= 0, offset + length <= size else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let n = bytes.withUnsafeMutableBytes { context.file.read(into: $0.baseAddress!, offset: offset, length: length) }
        return n == length ? bytes : nil
    }

    private func be(_ b: ArraySlice<UInt8>) -> Int {
        b.reduce(0) { ($0 << 8) | Int($1) }
    }

    private func boxType(_ b: ArraySlice<UInt8>) -> String? {
        guard b.allSatisfy({ ($0 >= 0x20 && $0 < 0x7F) || $0 == 0xA9 }) else { return nil }
        return String(decoding: b, as: UTF8.self)
    }

    func run() throws -> ContainerResult {
        var offset = 0
        var mdats: [Range<Int>] = []
        var moov: Box?
        var fragmented = false

        while offset < size {
            try context.tick(Double(offset) / Double(max(1, size)))
            guard size - offset >= 8, let h = read(offset, min(16, size - offset)),
                  let type = boxType(h[4 ..< 8]) else {
                reportBreak(at: offset)
                break
            }
            var length = be(h[0 ..< 4]), headerLength = 8
            if length == 1 {
                guard h.count >= 16 else { reportBreak(at: offset); break }
                length = be(h[8 ..< 16])
                headerLength = 16
            } else if length == 0 {
                length = size - offset
            }
            guard length >= headerLength else {
                reportBreak(at: offset)
                break
            }
            let end = offset + length
            if end > size {
                add(.damaged, "Truncated: the \(type) box needs \(DamageFormat.bytes(end - size)) more than the file contains.")
            }
            let box = Box(type: type, offset: offset, payload: offset + headerLength, end: min(end, size))
            switch type {
            case "mdat": mdats.append(box.payload ..< box.end)
            case "moov": moov = box
            case "moof": fragmented = true
            case "free", "skip": result.knownRanges.append(box.payload ..< box.end)
            default: break
            }
            if end > size { break }
            offset = end
        }

        guard let moov else {
            add(.damaged, "The movie index (moov) is missing, so the file cannot be played.")
            return result
        }
        guard moov.end - moov.payload <= 1 << 30, let bytes = read(moov.payload, moov.end - moov.payload) else {
            add(.damaged, "The movie index (moov) could not be read.")
            return result
        }
        try checkMovie(bytes, mdats: mdats, fragmented: fragmented)
        return result
    }

    private func reportBreak(at offset: Int) {
        let range = offset ..< size
        let share = context.zeroFraction(range)
        var text = "Damaged data: \(DamageFormat.bytes(range.count))"
        if share >= 0.5 { text += " (\(Int((share * 100).rounded()))% zero-filled)" }
        add(.damaged, text + " at byte \(offset).")
        result.knownRanges.append(range)
    }

    private func children(_ b: [UInt8], _ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            var length = be(b[p ..< p + 4]), header = 8
            if length == 1, p + 16 <= range.upperBound {
                length = be(b[p + 8 ..< p + 16])
                header = 16
            } else if length == 0 {
                length = range.upperBound - p
            }
            guard length >= header, p + length <= range.upperBound else { break }
            out.append((String(decoding: b[p + 4 ..< p + 8], as: UTF8.self), p + header ..< p + length))
            p += length
        }
        return out
    }

    private func checkMovie(_ b: [UInt8], mdats: [Range<Int>], fragmented: Bool) throws {
        var movieDuration: Double?
        var tracks: [Track] = []
        for box in children(b, 0 ..< b.count) {
            if box.type == "mvhd", box.body.count >= 32 {
                let v1 = b[box.body.lowerBound] == 1
                let base = box.body.lowerBound
                let scale = Double(be(b[(base + (v1 ? 20 : 12)) ..< (base + (v1 ? 24 : 16))]))
                let raw = v1 ? be(b[(base + 24) ..< (base + 32)]) : be(b[(base + 16) ..< (base + 20)])
                if scale > 0 { movieDuration = Double(raw) / scale }
            } else if box.type == "trak", let track = parseTrack(b, box.body) {
                tracks.append(track)
            }
        }
        result.duration = movieDuration
        if fragmented {
            result.format = "MP4 (fragmented)"
            return
        }
        if tracks.isEmpty {
            add(.damaged, "The movie index contains no tracks.")
            return
        }

        let sortedMdats = mdats.sorted { $0.lowerBound < $1.lowerBound }
        var outside = 0, pastEnd = 0
        var firstBad: Double?
        for track in tracks {
            for chunk in track.chunks {
                if chunk.offset + chunk.length > size {
                    pastEnd += 1
                    firstBad = min(firstBad ?? chunk.time, chunk.time)
                } else if !inside(chunk.offset, chunk.length, sortedMdats) {
                    outside += 1
                    firstBad = min(firstBad ?? chunk.time, chunk.time)
                }
            }
        }
        if pastEnd > 0 {
            let at = firstBad.map { ", from \(DamageFormat.time($0))" } ?? ""
            add(.damaged, "Truncated: \(pastEnd) chunks lie past the end of the file\(at).")
        }
        if outside > 0 {
            add(.damaged, "\(outside) chunks point outside the media data.")
        }

        let ended = tracks.map(\.duration).max() ?? 0
        result.lastFrame = ended
        if let movieDuration, movieDuration - ended >= MediaDamageScanner.damagedShortfall {
            add(.damaged, "Tracks end at \(DamageFormat.time(ended)) of \(DamageFormat.time(movieDuration)).")
        } else if let movieDuration, movieDuration - ended >= MediaDamageScanner.warningShortfall {
            add(.warning, "The tracks end \(Int(movieDuration - ended)) seconds before the stated duration.")
        }

        let video = tracks.first { $0.handler == "vide" }
        if let video { try probe(video) }
        let index = (video?.chunks ?? []).sorted { $0.offset < $1.offset }
        let offsets = index.map(\.offset), times = index.map(\.time)
        result.timeAt = { offset in
            var lo = 0, hi = offsets.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if offsets[mid] <= offset { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? times[lo - 1] : nil
        }
    }

    private func inside(_ offset: Int, _ length: Int, _ ranges: [Range<Int>]) -> Bool {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].lowerBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return false }
        return offset + length <= ranges[lo - 1].upperBound
    }

    /// Video chunks never start with zeros, so sampled chunks reveal zero-filled regions.
    private func probe(_ track: Track) throws {
        let chunks = track.chunks.filter { $0.offset + $0.length <= size }
        guard !chunks.isEmpty else { return }
        let budget = context.file.isRotational ? 1500 : 20000
        let step = max(1, chunks.count / budget)
        var i = 0
        while i < chunks.count {
            try context.tick(0.5 + 0.5 * Double(i) / Double(chunks.count))
            let chunk = chunks[i]
            if !result.knownRanges.contains(where: { $0.contains(chunk.offset) }),
               let run = context.zeroRun(around: chunk.offset, within: 0 ..< size) {
                result.knownRanges.append(run)
                add(.damaged, "\(DamageFormat.bytes(run.count)) of zeros at byte \(run.lowerBound), around \(DamageFormat.time(chunk.time)).")
            }
            i += step
        }
    }

    private func find(_ b: [UInt8], _ range: Range<Int>, _ path: [String]) -> Range<Int>? {
        guard let head = path.first else { return range }
        guard let box = children(b, range).first(where: { $0.type == head }) else { return nil }
        return find(b, box.body, Array(path.dropFirst()))
    }

    private func parseTrack(_ b: [UInt8], _ trak: Range<Int>) -> Track? {
        guard let mdia = find(b, trak, ["mdia"]), let mdhd = find(b, mdia, ["mdhd"]),
              let hdlr = find(b, mdia, ["hdlr"]), let stbl = find(b, mdia, ["minf", "stbl"]),
              mdhd.count >= 24, hdlr.count >= 12 else { return nil }
        var track = Track()
        let v1 = b[mdhd.lowerBound] == 1
        let scaleAt = mdhd.lowerBound + (v1 ? 20 : 12)
        guard scaleAt + 4 <= mdhd.upperBound else { return nil }
        track.timescale = Double(be(b[scaleAt ..< scaleAt + 4]))
        track.handler = String(decoding: b[(hdlr.lowerBound + 8) ..< (hdlr.lowerBound + 12)], as: UTF8.self)
        guard track.timescale > 0 else { return nil }

        var chunkOffsets: [Int] = []
        if let stco = find(b, stbl, ["stco"]), stco.count >= 8 {
            let n = min(be(b[(stco.lowerBound + 4) ..< (stco.lowerBound + 8)]), (stco.count - 8) / 4)
            chunkOffsets.reserveCapacity(n)
            for i in 0 ..< n {
                let at = stco.lowerBound + 8 + i * 4
                chunkOffsets.append(be(b[at ..< at + 4]))
            }
        } else if let co64 = find(b, stbl, ["co64"]), co64.count >= 8 {
            let n = min(be(b[(co64.lowerBound + 4) ..< (co64.lowerBound + 8)]), (co64.count - 8) / 8)
            chunkOffsets.reserveCapacity(n)
            for i in 0 ..< n {
                let at = co64.lowerBound + 8 + i * 8
                chunkOffsets.append(be(b[at ..< at + 8]))
            }
        }
        guard let stsz = find(b, stbl, ["stsz"]), stsz.count >= 12,
              let stsc = find(b, stbl, ["stsc"]), stsc.count >= 8,
              let stts = find(b, stbl, ["stts"]), stts.count >= 8 else { return track }

        let uniform = be(b[(stsz.lowerBound + 4) ..< (stsz.lowerBound + 8)])
        let sampleCount = be(b[(stsz.lowerBound + 8) ..< (stsz.lowerBound + 12)])
        guard uniform > 0 || stsz.count >= 12 + sampleCount * 4 else { return track }
        func sampleSize(_ i: Int) -> Int {
            if uniform > 0 { return uniform }
            let at = stsz.lowerBound + 12 + i * 4
            return be(b[at ..< at + 4])
        }

        let runCount = min(be(b[(stsc.lowerBound + 4) ..< (stsc.lowerBound + 8)]), (stsc.count - 8) / 12)
        let timeRuns = min(be(b[(stts.lowerBound + 4) ..< (stts.lowerBound + 8)]), (stts.count - 8) / 8)
        var timeRun = 0, leftInRun = 0, delta = 0, ticks = 0
        func advanceRun() {
            while leftInRun == 0, timeRun < timeRuns {
                let at = stts.lowerBound + 8 + timeRun * 8
                leftInRun = be(b[at ..< at + 4])
                delta = be(b[(at + 4) ..< (at + 8)])
                timeRun += 1
            }
        }

        var sample = 0, stscIndex = 0
        track.chunks.reserveCapacity(chunkOffsets.count)
        for (chunkIndex, offset) in chunkOffsets.enumerated() where sample < sampleCount {
            while stscIndex + 1 < runCount {
                let at = stsc.lowerBound + 8 + (stscIndex + 1) * 12
                if be(b[at ..< at + 4]) - 1 <= chunkIndex { stscIndex += 1 } else { break }
            }
            guard runCount > 0 else { break }
            let at = stsc.lowerBound + 8 + stscIndex * 12
            let perChunk = be(b[(at + 4) ..< (at + 8)])
            let time = Double(ticks) / track.timescale
            var length = 0
            for _ in 0 ..< perChunk where sample < sampleCount {
                length += sampleSize(sample)
                advanceRun()
                if leftInRun > 0 {
                    ticks += delta
                    leftInRun -= 1
                }
                sample += 1
            }
            track.chunks.append((offset, length, time))
        }
        track.duration = Double(ticks) / track.timescale
        return track
    }
}
