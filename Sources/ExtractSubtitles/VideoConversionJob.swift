import Foundation

/// The "convert to H.265 (MP4)" step of a job: on its own for a convert-only job (Services menu,
/// `--h265`), or after subtitle extraction when the Settings toggle is on. The IMDb rename has
/// already happened by now (MovieResolver), so the output name is final.
enum VideoConversionStep {

    static func run(job: Job, quality: Double, ac3Copies: Bool, log: ((String) -> Void)?) async {
        let url = await job.url
        log?("Converting \(url.lastPathComponent) to H.265 / MP4 (quality \(String(format: "%.2f", quality)))")
        let token = await job.cancelToken
        await MainActor.run {
            job.state = .encoding
            job.progress = 0
            job.conversion = Job.ConversionStatus(fraction: 0, fps: 0, etaSeconds: nil)
        }

        // Subtitles already extracted by this job (OCR'd SRTs) go into the MP4 as text tracks too.
        let extractedSRTs: [URL] = await MainActor.run {
            guard let folder = job.outputFolder else { return [] }
            return job.tracks.flatMap { t in t.srtNames.map { folder.appendingPathComponent($0) } }
        }
        // Forced PGS tracks extracted by this job, or by an earlier run into "<movie> Subtitles".
        let forcedSups: [URL] = await MainActor.run {
            let folder = job.outputFolder ?? url.deletingPathExtension().deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " Subtitles")
            let stem = url.deletingPathExtension().lastPathComponent
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasPrefix(stem + ".") && $0.hasSuffix(".forced.sup") }.sorted()
                .map { folder.appendingPathComponent($0) }
        }
        var options = VideoConverter.Options(quality: quality, burnInSubtitles: true, ac3Copies: ac3Copies, extraSubtitleFiles: extractedSRTs)
        options.forcedSupFiles = forcedSups
        let outcome: Result<VideoConverter.Result, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let result = try VideoConverter.convert(source: url, options: options, cancel: token, log: { line in
                    log?(line)
                }, progress: { p in
                    Task { @MainActor in
                        job.progress = p.fraction
                        job.conversion = Job.ConversionStatus(fraction: p.fraction, fps: p.fps, etaSeconds: p.etaSeconds)
                    }
                })
                return .success(result)
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let r):
            var summary = String(format: "%@ · %.2f GB · video %.1f Mbit/s · %d audio track(s)",
                                 r.outputURL.lastPathComponent, Double(r.outputBytes) / 1e9, r.videoBitrate / 1e6, r.audioTracks)
            if r.ac3Copies > 0 { summary += " (incl. \(r.ac3Copies) AC-3 cop\(r.ac3Copies == 1 ? "y" : "ies"))" }
            if r.subtitleTracks > 0 { summary += " · \(r.subtitleTracks) subtitle track(s)" }
            if let b = r.burnedTrack {
                summary += " · burned-in \(Naming.displayName(b.languageTag)) forced subtitles"
            }
            for note in r.notes { summary += " · " + note }
            let finalSummary = summary
            await MainActor.run {
                job.conversionOutput = r.outputURL
                job.conversionSummary = finalSummary
                job.conversion = nil
                job.progress = 1
                job.state = .done
                if job.outputFolder == nil { job.outputFolder = r.outputURL }
            }
            log?("Done: \(r.outputURL.path)")
        case .failure(let error):
            let why = token.isCancelled ? "Conversion cancelled" : "Conversion failed: \(error.localizedDescription)"
            log?("  \(why)")
            await MainActor.run {
                job.conversion = nil
                job.state = .failed(why)
            }
        }
    }
}
