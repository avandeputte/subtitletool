import Foundation

/// MSB-first bit reader over a Data slice.
struct BitReader {
    private let bytes: [UInt8]
    private(set) var bitPos: Int = 0

    init(_ data: Data, offset: Int = 0) {
        bytes = Array(data.dropFirst(offset))
    }

    var bitsLeft: Int { bytes.count * 8 - bitPos }

    mutating func bits(_ n: Int) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0 ..< n {
            let byte = bitPos >> 3
            let bit: UInt32 = byte < bytes.count ? UInt32((bytes[byte] >> (7 - UInt8(bitPos & 7))) & 1) : 0
            v = (v << 1) | bit
            bitPos += 1
        }
        return v
    }

    mutating func bit() -> Bool { bits(1) != 0 }
    mutating func skip(_ n: Int) { bitPos += n }
}

private func be16(_ d: Data, _ i: Int) -> UInt32 {
    guard i + 1 < d.endIndex - d.startIndex + 0, d.count >= i + 2 else { return 0 }
    let s = d.startIndex
    return UInt32(d[s + i]) << 8 | UInt32(d[s + i + 1])
}

private func be32(_ d: Data, _ i: Int) -> UInt32 {
    guard d.count >= i + 4 else { return 0 }
    let s = d.startIndex
    return UInt32(d[s + i]) << 24 | UInt32(d[s + i + 1]) << 16 | UInt32(d[s + i + 2]) << 8 | UInt32(d[s + i + 3])
}

private func le16(_ d: Data, _ i: Int) -> UInt32 {
    guard d.count >= i + 2 else { return 0 }
    let s = d.startIndex
    return UInt32(d[s + i]) | UInt32(d[s + i + 1]) << 8
}

private func le32(_ d: Data, _ i: Int) -> UInt32 {
    guard d.count >= i + 4 else { return 0 }
    let s = d.startIndex
    return UInt32(d[s + i]) | UInt32(d[s + i + 1]) << 8 | UInt32(d[s + i + 2]) << 16 | UInt32(d[s + i + 3]) << 24
}

/// Everything the MP4 muxer needs to know about one audio track's packets: timescale, how long
/// each packet is, how to split it into samples, and the sample description to write.
struct AudioCodec {
    enum Family: String {
        case aac = "AAC", mp3 = "MP3", mp2 = "MP2", ac3 = "AC-3", eac3 = "E-AC-3", dts = "DTS", truehd = "TrueHD", mlp = "MLP",
             flac = "FLAC", opus = "Opus", alac = "ALAC"
    }

    let family: Family
    var sampleRate: Int
    var channels: Int
    var bitDepth: Int = 16
    /// Packet length in samples when it never changes; else `samples(in:)` is asked per packet.
    var fixedSamplesPerPacket: Int? = nil
    /// Codec configuration (AudioSpecificConfig, STREAMINFO, OpusHead, ALAC cookie).
    var config: Data = Data()
    /// Opus pre-skip (samples at 48 kHz): written as the edit-list media time.
    var preSkip: Int = 0
    /// "DTS-HD MA", "DTS Express", "AAC-LC", … for logs and track names.
    var profile: String = ""
    /// The first access unit with a major sync (TrueHD), kept for the dmlp box.
    var majorSyncUnit: Data? = nil
    /// Sample entry type: mp4a, ac-3, ec-3, mlpa, fLaC, Opus, alac
    var entryType: String = "mp4a"
    var objectType: UInt8 = 0
    var dac3: Data = Data()
    var dec3: Data = Data()

    /// Apple's players (QuickTime, Apple TV, iOS) decode these.
    var appleCanPlay: Bool {
        switch family {
        case .aac, .mp3, .mp2, .ac3, .eac3, .flac, .alac, .opus: return true
        case .dts, .truehd, .mlp: return false
        }
    }

    var describe: String {
        var s = profile.isEmpty ? family.rawValue : profile
        s += " \(AudioCodec.layoutName(channels: channels))"
        s += " \(sampleRate) Hz"
        return s
    }

    static func layoutName(channels: Int) -> String {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    // MARK: - Detection

    /// nil when the codec cannot go into an MP4 (Vorbis, PCM, …).
    static func detect(track: MediaTrack, firstPacket: Data?) -> AudioCodec? {
        let rate = Int(track.samplingFrequency.rounded())
        let channels = Int(track.channels)
        let bits = Int(track.bitDepth)
        let priv = track.codecPrivate
        switch track.codecID {
        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG4/LC/SBR", "A_AAC/MPEG4/MAIN", "A_AAC/MPEG2/LC", "A_AAC/MPEG4/LTP", "A_AAC/MPEG2/MAIN":
            return aac(config: priv, rate: rate, channels: channels)
        case "A_MPEG/L3", "A_MPEG/L2", "A_MPEG/L1":
            return mpegAudio(first: firstPacket, rate: rate, channels: channels, layerHint: track.codecID)
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10":
            return ac3(first: firstPacket, rate: rate, channels: channels)
        case "A_EAC3":
            return eac3(first: firstPacket, rate: rate, channels: channels)
        case "A_DTS", "A_DTS/EXPRESS", "A_DTS/LOSSLESS":
            return dts(first: firstPacket, rate: rate, channels: channels)
        case "A_TRUEHD", "A_MLP":
            return truehd(first: firstPacket, rate: rate, channels: channels, isMLP: track.codecID == "A_MLP")
        case "A_FLAC":
            return flac(config: priv, rate: rate, channels: channels, bits: bits)
        case "A_OPUS":
            return opus(config: priv, channels: channels)
        case "A_ALAC":
            return alac(config: priv, rate: rate, channels: channels, bits: bits)
        default:
            return nil
        }
    }

    // MARK: AAC

    static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    static func aac(config: Data, rate: Int, channels: Int) -> AudioCodec? {
        guard config.count >= 2 else { return nil }
        var r = BitReader(config)
        var aot = Int(r.bits(5))
        if aot == 31 { aot = 32 + Int(r.bits(6)) }
        let fi = Int(r.bits(4))
        var coreRate = fi == 15 ? Int(r.bits(24)) : (fi < aacRates.count ? aacRates[fi] : rate)
        let cc = Int(r.bits(4))
        if coreRate <= 0 { coreRate = rate }
        var c = AudioCodec(family: .aac, sampleRate: coreRate > 0 ? coreRate : 48000, channels: channels > 0 ? channels : max(1, cc))
        c.config = config
        c.entryType = "mp4a"
        c.objectType = 0x40
        switch aot {
        case 2: c.profile = "AAC-LC"
        case 5: c.profile = "HE-AAC"
        case 29: c.profile = "HE-AACv2"
        case 23, 39: c.profile = "AAC-LD"
        default: c.profile = "AAC"
        }
        c.fixedSamplesPerPacket = (aot == 23 || aot == 39) ? 512 : 1024
        return c
    }

    // MARK: MP3 / MP2

    static func mpegAudio(first: Data?, rate: Int, channels: Int, layerHint: String) -> AudioCodec? {
        var c = AudioCodec(family: layerHint.hasSuffix("L3") ? .mp3 : .mp2, sampleRate: rate > 0 ? rate : 44100, channels: channels > 0 ? channels : 2)
        c.entryType = "mp4a"
        c.objectType = c.sampleRate > 24000 ? 0x6B : 0x69
        c.profile = layerHint.hasSuffix("L3") ? "MP3" : (layerHint.hasSuffix("L2") ? "MP2" : "MP1")
        if let f = first, let n = mpegFrameSamples(f) { c.fixedSamplesPerPacket = n }
        else { c.fixedSamplesPerPacket = layerHint.hasSuffix("L1") ? 384 : (c.sampleRate >= 32000 || !layerHint.hasSuffix("L3") ? 1152 : 576) }
        return c
    }

    static func mpegFrameSamples(_ d: Data) -> Int? {
        guard d.count >= 4 else { return nil }
        let b1 = d[d.startIndex + 1]
        guard d[d.startIndex] == 0xFF, b1 & 0xE0 == 0xE0 else { return nil }
        let version = (b1 >> 3) & 3      // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        let layer = (b1 >> 1) & 3        // 3 = I, 2 = II, 1 = III
        switch layer {
        case 3: return 384
        case 2: return 1152
        case 1: return version == 3 ? 1152 : 576
        default: return nil
        }
    }

    // MARK: AC-3

    static let ac3Rates = [48000, 44100, 32000]
    static let ac3Bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
    static let ac3Channels = [2, 1, 2, 3, 3, 4, 4, 5]

    struct AC3Header {
        var fscod = 0, frmsizecod = 0, bsid = 0, bsmod = 0, acmod = 0, lfeon = 0
        var sampleRate = 48000
        var frameBytes = 0
        var bitrateKbps = 0
        var channels = 2
    }

    static func parseAC3(_ d: Data, at offset: Int = 0) -> AC3Header? {
        guard d.count >= offset + 7, be16(d, offset) == 0x0B77 else { return nil }
        var r = BitReader(d, offset: offset + 4)
        var h = AC3Header()
        h.fscod = Int(r.bits(2))
        h.frmsizecod = Int(r.bits(6))
        h.bsid = Int(r.bits(5))
        h.bsmod = Int(r.bits(3))
        h.acmod = Int(r.bits(3))
        guard h.fscod < 3, h.frmsizecod < 38, h.bsid <= 10 else { return nil }
        if h.acmod & 1 != 0 && h.acmod != 1 { r.skip(2) }
        if h.acmod & 4 != 0 { r.skip(2) }
        if h.acmod == 2 { r.skip(2) }
        h.lfeon = Int(r.bits(1))
        h.sampleRate = ac3Rates[h.fscod] >> (h.bsid == 9 ? 1 : (h.bsid == 10 ? 2 : 0))
        let kbps = ac3Bitrates[h.frmsizecod >> 1]
        h.bitrateKbps = kbps >> (h.bsid == 9 ? 1 : (h.bsid == 10 ? 2 : 0))
        switch h.fscod {
        case 0: h.frameBytes = kbps * 4
        case 2: h.frameBytes = kbps * 6
        default: h.frameBytes = (Int(kbps * 1536000 / 705600) + (h.frmsizecod & 1)) * 2
        }
        h.channels = ac3Channels[h.acmod] + h.lfeon
        return h
    }

    static func ac3(first: Data?, rate: Int, channels: Int) -> AudioCodec? {
        var c = AudioCodec(family: .ac3, sampleRate: rate > 0 ? rate : 48000, channels: channels > 0 ? channels : 2)
        c.entryType = "ac-3"
        c.profile = "AC-3"
        c.fixedSamplesPerPacket = 1536
        if let f = first, let h = parseAC3(f) {
            c.sampleRate = h.sampleRate
            if channels <= 0 { c.channels = h.channels }
            var b = BitReaderWriter()
            b.put(h.fscod, 2); b.put(h.bsid, 5); b.put(h.bsmod, 3); b.put(h.acmod, 3); b.put(h.lfeon, 1); b.put(h.frmsizecod >> 1, 5); b.put(0, 5)
            c.dac3 = b.data
            c.profile = "AC-3 \(h.bitrateKbps) kbps"
        }
        return c
    }

    /// Number of AC-3 syncframes in a packet (MKV blocks normally hold exactly one).
    static func ac3Frames(in d: Data) -> Int {
        var count = 0
        var pos = 0
        while let h = parseAC3(d, at: pos), h.frameBytes > 0 {
            count += 1
            pos += h.frameBytes
            if pos >= d.count { break }
        }
        return max(1, count)
    }

    // MARK: E-AC-3

    struct EAC3Header {
        var strmtyp = 0, substreamid = 0, frameBytes = 0, fscod = 0, numblks = 6, acmod = 0, lfeon = 0, bsid = 16
        var sampleRate = 48000
        var channels = 2
        var chanmap: Int? = nil
    }

    static func parseEAC3(_ d: Data, at offset: Int = 0) -> EAC3Header? {
        guard d.count >= offset + 6, be16(d, offset) == 0x0B77 else { return nil }
        var r = BitReader(d, offset: offset + 2)
        var h = EAC3Header()
        h.strmtyp = Int(r.bits(2))
        h.substreamid = Int(r.bits(3))
        h.frameBytes = (Int(r.bits(11)) + 1) * 2
        h.fscod = Int(r.bits(2))
        if h.fscod == 3 {
            let fscod2 = Int(r.bits(2))
            guard fscod2 < 3 else { return nil }
            h.sampleRate = [24000, 22050, 16000][fscod2]
            h.numblks = 6
        } else {
            h.sampleRate = ac3Rates[h.fscod]
            h.numblks = [1, 2, 3, 6][Int(r.bits(2))]
        }
        h.acmod = Int(r.bits(3))
        h.lfeon = Int(r.bits(1))
        h.bsid = Int(r.bits(5))
        guard h.bsid >= 11, h.bsid <= 16 else { return nil }
        h.channels = ac3Channels[h.acmod] + h.lfeon
        // dialnorm / compr (twice for dual mono), then the dependent stream's channel map
        for _ in 0 ..< (h.acmod == 0 ? 2 : 1) {
            r.skip(5)
            if r.bit() { r.skip(8) }
        }
        if h.strmtyp == 1, r.bit() { h.chanmap = Int(r.bits(16)) }
        return h
    }

    static func eac3(first: Data?, rate: Int, channels: Int) -> AudioCodec? {
        var c = AudioCodec(family: .eac3, sampleRate: rate > 0 ? rate : 48000, channels: channels > 0 ? channels : 2)
        c.entryType = "ec-3"
        c.profile = "E-AC-3"
        if let f = first, let h = parseEAC3(f) {
            c.sampleRate = h.sampleRate
            var numDep = 0
            var chanLoc = 0
            var pos = h.frameBytes
            var total = h.channels
            while pos < f.count, let dep = parseEAC3(f, at: pos) {
                if dep.strmtyp == 1 {
                    numDep += 1
                    if let m = dep.chanmap { chanLoc |= (m >> 5) & 0x1F } else { chanLoc |= dep.acmod }
                    total += dep.channels - 2
                }
                pos += dep.frameBytes
            }
            if channels <= 0 { c.channels = numDep > 0 ? max(total, h.channels) : h.channels }
            let dataRate = h.frameBytes * 8 * h.sampleRate / (h.numblks * 256) / 1000
            var b = BitReaderWriter()
            b.put(min(dataRate, 8191), 13); b.put(0, 3)
            b.put(h.fscod, 2); b.put(h.bsid, 5); b.put(0, 1); b.put(0, 1); b.put(0, 3); b.put(h.acmod, 3); b.put(h.lfeon, 1); b.put(0, 3)
            b.put(numDep, 4)
            if numDep == 0 { b.put(0, 1) } else { b.put(chanLoc, 9) }
            c.dec3 = b.data
            c.profile = numDep > 0 ? "E-AC-3 (with dependent substream)" : "E-AC-3 \(dataRate) kbps"
        }
        return c
    }

    /// Samples in an E-AC-3 packet: the blocks of every independent syncframe in it.
    static func eac3Samples(in d: Data) -> Int? {
        var pos = 0
        var samples = 0
        while pos < d.count, let h = parseEAC3(d, at: pos), h.frameBytes > 0 {
            if h.strmtyp != 1, h.substreamid == 0 { samples += h.numblks * 256 }
            pos += h.frameBytes
        }
        return samples > 0 ? samples : nil
    }

    // MARK: DTS

    static let dtsRates: [Int] = [0, 8000, 16000, 32000, 0, 0, 11025, 22050, 44100, 0, 0, 12000, 24000, 48000, 0, 0]
    static let dtsChannels: [Int] = [1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8]

    struct DTSCore {
        var samples = 512
        var frameBytes = 0
        var sampleRate = 48000
        var channels = 2
    }

    static func parseDTSCore(_ d: Data, at offset: Int = 0) -> DTSCore? {
        guard d.count >= offset + 12, be32(d, offset) == 0x7FFE8001 else { return nil }
        var r = BitReader(d, offset: offset + 4)
        r.skip(1 + 5 + 1)                 // FTYPE, SHORT, CPF
        let nblks = Int(r.bits(7))
        let fsize = Int(r.bits(14))
        let amode = Int(r.bits(6))
        let sfreq = Int(r.bits(4))
        r.skip(5 + 1 + 1 + 1 + 1 + 1 + 3 + 1 + 1)   // RATE … ASPF
        let lff = Int(r.bits(2))
        guard nblks >= 5, fsize >= 95 else { return nil }
        var c = DTSCore()
        c.samples = (nblks + 1) * 32
        c.frameBytes = fsize + 1
        c.sampleRate = dtsRates[sfreq] > 0 ? dtsRates[sfreq] : 48000
        c.channels = (amode < dtsChannels.count ? dtsChannels[amode] : 6) + (lff != 0 ? 1 : 0)
        return c
    }

    /// "DTS-HD MA", "DTS-HD HRA", "DTS Express" or "DTS" from the extension substream, if any.
    static func dtsProfile(_ d: Data, coreBytes: Int) -> (name: String, objectType: UInt8) {
        guard d.count > coreBytes + 16, be32(d, coreBytes) == 0x64582025 else {
            return coreBytes > 0 ? ("DTS", 0xA9) : ("DTS-HD", 0xAA)
        }
        // Look for the asset sync words inside the extension substream.
        let s = d.startIndex + coreBytes
        let end = min(d.endIndex, s + 4096)
        var i = s + 4
        while i + 4 <= end {
            let w = UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
            switch w {
            case 0x41A29547: return ("DTS-HD MA", 0xAB)
            case 0x0A801921: return ("DTS Express", 0xAC)
            case 0x655E315E, 0x1D95F262, 0x47004A03: return ("DTS-HD HRA", 0xAA)
            default: break
            }
            i += 1
        }
        return coreBytes > 0 ? ("DTS-HD", 0xAA) : ("DTS-HD", 0xAA)
    }

    static func dts(first: Data?, rate: Int, channels: Int) -> AudioCodec? {
        var c = AudioCodec(family: .dts, sampleRate: rate > 0 ? rate : 48000, channels: channels > 0 ? channels : 6)
        c.entryType = "mp4a"
        c.objectType = 0xA9
        c.profile = "DTS"
        if let f = first {
            if let core = parseDTSCore(f) {
                c.sampleRate = core.sampleRate
                if channels <= 0 { c.channels = core.channels }
                let p = dtsProfile(f, coreBytes: core.frameBytes)
                c.profile = p.name
                c.objectType = p.objectType
            } else {
                let p = dtsProfile(f, coreBytes: 0)
                c.profile = p.name
                c.objectType = p.objectType
            }
        }
        return c
    }

    /// Samples in a DTS packet from its core frame header; nil without a core (timestamps are used then).
    static func dtsSamples(in d: Data) -> Int? {
        guard let core = parseDTSCore(d) else { return nil }
        return core.samples
    }

    // MARK: TrueHD / MLP

    static func truehd(first: Data?, rate: Int, channels: Int, isMLP: Bool) -> AudioCodec? {
        var c = AudioCodec(family: isMLP ? .mlp : .truehd, sampleRate: rate > 0 ? rate : 48000, channels: channels > 0 ? channels : 6)
        c.entryType = "mlpa"
        c.profile = isMLP ? "MLP" : "TrueHD"
        c.bitDepth = 24
        if let f = first {
            for (au, sync) in truehdUnits(f) where sync {
                c.majorSyncUnit = au
                if rate <= 0 {
                    let formatInfo = be32(au, 8)
                    let code = Int(formatInfo >> 28)
                    c.sampleRate = (code & 8 != 0 ? 44100 : 48000) << (code & 7)
                }
                break
            }
        }
        let base = c.sampleRate % 44100 == 0 ? 44100 : 48000
        c.fixedSamplesPerPacket = 40 * max(1, c.sampleRate / base)
        return c
    }

    /// Splits a TrueHD block into access units (each a sample); `sync` = carries a major sync.
    static func truehdUnits(_ d: Data) -> [(Data, Bool)] {
        var units: [(Data, Bool)] = []
        var pos = 0
        while pos + 4 <= d.count {
            let len = Int(be16(d, pos) & 0xFFF) * 2
            guard len >= 4, pos + len <= d.count else { break }
            let unit = d.subdata(in: (d.startIndex + pos) ..< (d.startIndex + pos + len))
            let sync = len >= 12 && (be32(unit, 4) == 0xF8726FBA || be32(unit, 4) == 0xF8726FBB)
            units.append((unit, sync))
            pos += len
        }
        if units.isEmpty { units.append((d, false)) }
        return units
    }

    // MARK: FLAC

    static func flac(config: Data, rate: Int, channels: Int, bits: Int) -> AudioCodec? {
        // CodecPrivate: "fLaC" + metadata blocks; STREAMINFO is the first (type 0, 34 bytes).
        var streamInfo: Data?
        var pos = config.starts(with: Array("fLaC".utf8)) ? 4 : 0
        while pos + 4 <= config.count {
            let header = config[config.startIndex + pos]
            let type = header & 0x7F
            let len = Int(be32(config, pos) & 0xFFFFFF)
            if type == 0, len == 34, pos + 4 + 34 <= config.count {
                streamInfo = config.subdata(in: (config.startIndex + pos + 4) ..< (config.startIndex + pos + 4 + 34))
                break
            }
            if header & 0x80 != 0 { break }
            pos += 4 + len
        }
        guard let si = streamInfo else { return nil }
        let s = si.startIndex
        let srate = Int(si[s + 10]) << 12 | Int(si[s + 11]) << 4 | Int(si[s + 12] >> 4)
        let ch = Int((si[s + 12] >> 1) & 7) + 1
        let bps = Int((si[s + 12] & 1) << 4 | (si[s + 13] >> 4)) + 1
        let minBlock = Int(be16(si, 0)), maxBlock = Int(be16(si, 2))
        var c = AudioCodec(family: .flac, sampleRate: srate > 0 ? srate : (rate > 0 ? rate : 48000), channels: channels > 0 ? channels : ch)
        c.bitDepth = bps
        c.entryType = "fLaC"
        c.config = si
        c.profile = "FLAC \(bps)-bit"
        if minBlock == maxBlock, minBlock > 0 { c.fixedSamplesPerPacket = nil }   // still parse: the last frame is shorter
        return c
    }

    /// Block size of a FLAC frame from its header.
    static func flacSamples(in d: Data, fallback: Int) -> Int {
        guard d.count >= 6, d[d.startIndex] == 0xFF, d[d.startIndex + 1] & 0xFE == 0xF8 else { return fallback }
        let bsCode = Int(d[d.startIndex + 2] >> 4)
        let srCode = Int(d[d.startIndex + 2] & 0x0F)
        var pos = 4
        // UTF-8 style coded frame/sample number
        let first = d[d.startIndex + pos]
        var extra = 0
        if first & 0x80 == 0 { extra = 0 }
        else if first & 0xE0 == 0xC0 { extra = 1 }
        else if first & 0xF0 == 0xE0 { extra = 2 }
        else if first & 0xF8 == 0xF0 { extra = 3 }
        else if first & 0xFC == 0xF8 { extra = 4 }
        else if first & 0xFE == 0xFC { extra = 5 }
        else { extra = 6 }
        pos += 1 + extra
        switch bsCode {
        case 1: return 192
        case 2 ... 5: return 576 << (bsCode - 2)
        case 6:
            guard d.count > pos else { return fallback }
            return Int(d[d.startIndex + pos]) + 1
        case 7:
            guard d.count > pos + 1 else { return fallback }
            return Int(be16(d, pos)) + 1
        case 8 ... 15: return 256 << (bsCode - 8)
        default:
            _ = srCode
            return fallback
        }
    }

    // MARK: Opus

    static func opus(config: Data, channels: Int) -> AudioCodec? {
        guard config.count >= 19, config.starts(with: Array("OpusHead".utf8)) else { return nil }
        let ch = Int(config[config.startIndex + 9])
        var c = AudioCodec(family: .opus, sampleRate: 48000, channels: channels > 0 ? channels : ch)
        c.entryType = "Opus"
        c.config = config
        c.preSkip = Int(le16(config, 10))
        c.profile = "Opus"
        return c
    }

    /// Samples (at 48 kHz) in an Opus packet, from its TOC byte.
    static func opusSamples(in d: Data) -> Int? {
        guard d.count >= 1 else { return nil }
        let toc = Int(d[d.startIndex])
        let config = toc >> 3
        let frameSize: Int   // in 48 kHz samples
        if config < 12 { frameSize = [480, 960, 1920, 2880][config & 3] }
        else if config < 16 { frameSize = [480, 960][config & 1] }
        else { frameSize = [120, 240, 480, 960][config & 3] }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard d.count >= 2 else { return nil }
            frames = Int(d[d.startIndex + 1] & 0x3F)
        }
        return frames * frameSize
    }

    // MARK: ALAC

    static func alac(config: Data, rate: Int, channels: Int, bits: Int) -> AudioCodec? {
        var cookie = config
        if cookie.count > 24, let r = cookie.range(of: Data("alac".utf8)) {
            // "frma"/"alac" atom wrapping: the 24-byte config follows the alac atom header (size, type, version/flags)
            let start = r.upperBound + 4
            if cookie.count >= start + 24 { cookie = cookie.subdata(in: start ..< start + 24) }
        }
        guard cookie.count >= 24 else { return nil }
        let frameLength = Int(be32(cookie, 0))
        let bps = Int(cookie[cookie.startIndex + 5])
        let ch = Int(cookie[cookie.startIndex + 9])
        let srate = Int(be32(cookie, 20))
        var c = AudioCodec(family: .alac, sampleRate: srate > 0 ? srate : (rate > 0 ? rate : 44100), channels: channels > 0 ? channels : ch)
        c.bitDepth = bps > 0 ? bps : bits
        c.entryType = "alac"
        c.config = cookie.prefix(24)
        c.profile = "ALAC \(c.bitDepth)-bit"
        c.fixedSamplesPerPacket = frameLength > 0 ? frameLength : 4096
        return c
    }

    // MARK: - Per-packet duration and splitting

    /// Samples in one packet; nil when it cannot be told from the bytes (the muxer then uses timestamps).
    func samples(in packet: Data) -> Int? {
        switch family {
        case .aac, .alac, .truehd, .mlp: return fixedSamplesPerPacket
        case .mp3, .mp2: return AudioCodec.mpegFrameSamples(packet) ?? fixedSamplesPerPacket
        case .ac3: return 1536 * AudioCodec.ac3Frames(in: packet)
        case .eac3: return AudioCodec.eac3Samples(in: packet)
        case .dts: return AudioCodec.dtsSamples(in: packet)
        case .flac: return AudioCodec.flacSamples(in: packet, fallback: fixedSamplesPerPacket ?? 4096)
        case .opus: return AudioCodec.opusSamples(in: packet)
        }
    }

    /// One MP4 sample per codec access unit: TrueHD blocks can hold several; everything else is 1:1.
    func split(_ packet: Data) -> [(data: Data, sync: Bool)] {
        switch family {
        case .truehd, .mlp:
            return AudioCodec.truehdUnits(packet).map { (data: $0.0, sync: $0.1) }
        default:
            return [(data: packet, sync: true)]
        }
    }

    /// TrueHD needs a sync-sample table (only access units with a major sync are random access points).
    var marksSyncSamples: Bool { family == .truehd || family == .mlp }

    // MARK: - Sample entry

    func sampleEntry(trackID: UInt32, maxBitrate: UInt32, avgBitrate: UInt32) -> Data {
        var extra = Data()
        switch family {
        case .aac, .mp3, .mp2, .dts:
            extra = MP4Writer.esds(objectType: objectType, decoderSpecific: family == .aac ? config : Data(),
                                   maxBitrate: maxBitrate, avgBitrate: avgBitrate, trackID: UInt16(clamping: trackID))
        case .ac3:
            extra = BoxBuilder.box("dac3", dac3.isEmpty ? Data([0x10, 0x3D, 0x40]) : dac3)   // 48 kHz, 3/2, LFE, 640 kbps if unknown
        case .eac3:
            extra = BoxBuilder.box("dec3", dec3.isEmpty ? Data([0x0A, 0x00, 0x20, 0x0F, 0x00]) : dec3)
        case .truehd, .mlp:
            var b = BoxBuilder()
            if let au = majorSyncUnit, au.count >= 20 {
                b.u32(be32(au, 8))                               // format_info
                b.u32((be16(au, 18) & 0x7FFF) << 17)             // peak_data_rate(15) + reserved(17)
            } else {
                b.u32(0); b.u32(0)
            }
            extra = BoxBuilder.box("dmlp", b.data)
        case .flac:
            extra = BoxBuilder.fullBox("dfLa") { b in
                b.u8(0x80); b.u24(34); b.bytes(config)
            }
        case .opus:
            extra = BoxBuilder.box("dOps") { b in
                b.u8(0)
                b.u8(config[config.startIndex + 9])
                b.u16(UInt16(le16(config, 10)))
                b.u32(le32(config, 12))
                b.u16(UInt16(le16(config, 16)))
                let family = config[config.startIndex + 18]
                b.u8(family)
                if family != 0, config.count >= 21 + channels {
                    b.bytes(config.subdata(in: (config.startIndex + 19) ..< (config.startIndex + 21 + channels)))
                }
            }
        case .alac:
            extra = BoxBuilder.fullBox("alac") { b in b.bytes(config) }
        }
        var entry = MP4Writer.audioEntry(type: entryType, channels: channels, sampleSize: (family == .flac || family == .alac) ? bitDepth : 16,
                                         sampleRate: sampleRate, extra: extra)
        if family != .aac && family != .mp3 && family != .mp2 && family != .dts, maxBitrate > 0 {
            // btrt: buffer size, max and average bitrate (informational)
            entry = MP4Writer.appendToEntry(entry, BoxBuilder.box("btrt") { b in b.u32(0); b.u32(maxBitrate); b.u32(avgBitrate) })
        }
        return entry
    }
}

/// Tiny MSB-first bit writer for dac3 / dec3.
struct BitReaderWriter {
    private(set) var data = Data()
    private var bitCount = 0

    mutating func put(_ value: Int, _ bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            let bit = UInt8((value >> i) & 1)
            if bitCount % 8 == 0 { data.append(0) }
            data[data.count - 1] |= bit << UInt8(7 - bitCount % 8)
            bitCount += 1
        }
    }
}

extension MP4Writer {
    /// Appends a child box to a sample entry (patches the outer size).
    static func appendToEntry(_ entry: Data, _ child: Data) -> Data {
        var out = entry
        out.append(child)
        let size = UInt32(out.count)
        out[out.startIndex] = UInt8(size >> 24)
        out[out.startIndex + 1] = UInt8((size >> 16) & 0xFF)
        out[out.startIndex + 2] = UInt8((size >> 8) & 0xFF)
        out[out.startIndex + 3] = UInt8(size & 0xFF)
        return out
    }
}

/// ISO 639-2 language codes for MP4 (bibliographic "fre" → terminologic "fra") from Matroska tags.
enum MP4Language {
    private static let bToT: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld", "fre": "fra",
        "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas",
        "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]
    private static let twoToThree: [String: String] = [
        "en": "eng", "fr": "fra", "de": "deu", "es": "spa", "it": "ita", "nl": "nld", "pt": "por", "ru": "rus", "ja": "jpn",
        "zh": "zho", "ko": "kor", "ar": "ara", "sv": "swe", "no": "nor", "nb": "nob", "nn": "nno", "da": "dan", "fi": "fin",
        "pl": "pol", "tr": "tur", "cs": "ces", "hu": "hun", "el": "ell", "he": "heb", "th": "tha", "vi": "vie", "id": "ind",
        "ms": "msa", "uk": "ukr", "ro": "ron", "hr": "hrv", "sr": "srp", "bg": "bul", "sl": "slv", "sk": "slk", "lt": "lit",
        "lv": "lav", "et": "est", "hi": "hin", "bn": "ben", "ta": "tam", "te": "tel", "ur": "urd", "fa": "fas", "ca": "cat",
        "gl": "glg", "eu": "eus", "is": "isl", "ga": "gle", "cy": "cym", "mk": "mkd", "sq": "sqi", "bs": "bos", "tl": "tgl",
        "la": "lat", "fil": "fil",
    ]

    /// (three-letter code for mdhd, extended tag for elng or "")
    static func codes(language: String, ietf: String) -> (String, String) {
        var three = language.lowercased()
        if three.isEmpty, !ietf.isEmpty {
            let base = ietf.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
            three = base.count == 3 ? base : (twoToThree[base] ?? "und")
        }
        if let t = bToT[three] { three = t }
        if three.count != 3 { three = "und" }
        let extended = ietf.contains("-") ? ietf : ""
        return (three, extended)
    }
}
