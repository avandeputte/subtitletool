# Release 4 – Convert to H.265 (integration notes)

Written without a Swift toolchain at hand: the code follows well-known APIs and the project's style,
but it has **not been compiled**. Expect a handful of trivial compiler complaints (see "Things to check first").

## New files

| File | What it is |
|---|---|
| `Sources/ExtractSubtitles/Matroska/MatroskaStream.swift` | `MatroskaMediaReader`: all tracks (`MediaTrack`: codec ID, CodecPrivate, DefaultDuration, pixel/display size, Colour incl. HDR mastering, audio frequency/channels/bit depth, language, name, flags, ContentEncodings, raw TrackEntry bytes) and `forEachBlock` streaming every SimpleBlock / BlockGroup (lacing, cluster timestamp, TimestampScale, keyframe flag, BlockDuration) in file order. Also records raw Chapters/Attachments. Extra element IDs are added as an `extension MKV`. |
| `Sources/ExtractSubtitles/Matroska/MatroskaWriter.swift` | `EBMLWrite` helpers, `MatroskaWriter` (EBML header, Segment with patched size, SeekHead patched at the end, Info with patched Duration, Tracks, ~5 s / ~5 MB Clusters of SimpleBlocks with cluster-relative timestamps, Cues on video keyframes), `TrackEntryBuilder` (HEVC video entry from the source track + hvcC; copied tracks re-emit the original TrackEntry bytes). |
| `Sources/ExtractSubtitles/VideoConverter.swift` | `CancelToken`, `VideoConverter` (format description from avcC/hvcC → `VTDecompressionSession` async → PTS reorder queue → optional Core Image compositing → `VTCompressionSession` HEVC with Quality / bitrate fallback, colour + HDR10 metadata → `InterleavingMuxer` → `MatroskaWriter`), progress (fraction, fps, ETA), bitrate/size log. |
| `Sources/ExtractSubtitles/SubtitleBurner.swift` | `PGSOverlayDecoder` (full-canvas RGBA display sets with alpha, reuses `PGSDecoder.State/Palette/decodeRLE`), `TextOverlayRenderer` (NSAttributedString, white + black outline + shadow, bottom-centred, size = height/22), `SubtitleOverlayTrack` (collects the forced track's cues while reading, answers "overlay at PTS"). |
| `Sources/ExtractSubtitles/VideoConversionJob.swift` | `VideoConversionStep.run(job:quality:rename:log:)`: the job glue (state `.encoding`, progress to the `Job`, cancel, summary, failure). |
| `INTEGRATION-R4.md` | this file |

## Edits to existing files

* `Sources/ExtractSubtitles/JobRunner.swift`
  * `Job`: new `enum Kind { extract, convert }`, `struct ConversionStatus`, `let kind`, `let cancelToken = CancelToken()`,
    `@Published conversion / conversionOutput / conversionSummary / cancelRequested`, new state case `.encoding`,
    `init(url:kind:)`, `cancelConversion()`, `allowsConversion`.
  * `JobRunner`: `@AppStorage` `convertToH265` (key `convertToH265`, default false) and `h265Quality` (key `h265Quality`, default 0.85);
    `enqueue(_:kind:)`; `openPanel(kind:)`; the run loop switches on `job.kind` and calls `VideoConversionStep.run` after
    extraction when the toggle is on (or on its own for convert jobs); `notify` mentions the conversion.
* `Sources/ExtractSubtitles/App.swift`
  * File menu: "Convert to H.265…" (⇧⌘O). `AppDelegate.convertToH265(_ urls:)`.
  * `ServiceProvider`: new `@objc(convertToH265:userData:error:)` for the second NSServices entry.
  * CLI: `--h265` (convert only) and `--quality 0.9` / `--quality=0.9`; the stored "convert after extracting"
    setting is honoured for normal `--cli` runs; usage string updated.
* `Sources/ExtractSubtitles/ContentView.swift`
  * `JobRow`: `.encoding` state (spinner, progress bar, cancel button, "Converting to H.265… 43% · 61.2 fps · 12 min left"),
    conversion summary line, "Show in Finder" selects the `.hevc.mkv` when there is one, `etaText`.
  * `SettingsView`: section "Video conversion" with the toggle and a 0.5–1.0 quality slider.
* `Resources/Info.plist`: second `NSServices` entry "Convert to H.265" → `convertToH265`.
* `README.md`: "Convert to H.265" section, layout table, CLI line.

Untouched: `Naming.swift`, `MovieIdentifier.swift`, `EBMLReader.swift`, `MatroskaDemuxer.swift`, `PGSDecoder.swift`,
`SubtitleWriters.swift`, `LocalConverter.swift`, `project.yml`, `build.sh`, entitlements, `Tests/`.
(VideoToolbox / CoreMedia / CoreImage are system frameworks and auto-link from the `import`s; nothing to add to `project.yml`.)

## How to test on the Mac

```bash
cd ExtractSubtitles
./build.sh --install

# 1. Convert only, from the command line (log goes to stdout):
"/Applications/Extract Subtitles.app/Contents/MacOS/Extract Subtitles" --cli --h265 --no-rename --quality 0.85 \
    "/Volumes/Fastdisk/BD/Batman (1989).mkv"

# 2. Check the result:
ffprobe "/Volumes/Fastdisk/BD/Batman (1989).hevc.mkv"          # hevc video, all audio tracks, subtitle tracks minus the forced one
mkvinfo "/Volumes/Fastdisk/BD/Batman (1989).hevc.mkv" | head -80  # (mkvtoolnix) tracks, cues, seek head
mkvmerge -i "/Volumes/Fastdisk/BD/Batman (1989).hevc.mkv"
open -a "IINA" "/Volumes/Fastdisk/BD/Batman (1989).hevc.mkv"   # or QuickTime/VLC: seek around, check A/V sync and the burned-in subtitles

# 3. Compare audio bit-exactness (one track):
ffmpeg -i "Batman (1989).mkv" -map 0:a:0 -c copy a_src.mka && ffmpeg -i "Batman (1989).hevc.mkv" -map 0:a:0 -c copy a_out.mka
ffmpeg -i a_src.mka -f md5 - ; ffmpeg -i a_out.mka -f md5 -    # same hash

# 4. GUI: Settings (⌘,) → Video conversion → toggle on; drop an MKV; watch progress/fps/ETA; press ⓧ to cancel
#    (the .hevc.mkv.part file disappears). Finder → right-click MKV → Services → Convert to H.265.
# 5. Small files: Tests/Sample (pgs).mkv has no video track → the convert job fails with a clear message.
```

## Things to check first when compiling

* `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)` and
  `VTCompressionSessionEncodeFrame(_:imageBuffer:presentationTimeStamp:duration:frameProperties:infoFlagsOut:outputHandler:)`
  are the Swift names of the `…WithOutputHandler` C functions; both sessions are created with `outputCallback: nil`.
* `CVBufferCopyAttachment` / `CVBufferCopyAttachments` are macOS 12+ (deployment target is 13, fine).
* `CMFormatDescriptionGetExtension(...) as? NSDictionary` and `atoms["hvcC"] as? Data` (CFData bridging) in `VideoConverter.writeHeader`.
* `CVImageBufferCreateColorSpaceFromAttachments` returns `Unmanaged<CGColorSpace>?` (`takeRetainedValue()` is used).
* `CIContextOption.workingFormat` with `CIFormat.RGBAh` for 10-bit sources.
* Swift may want explicit `self.` inside the `forEachBlock` closure (already written with `self.`).
* `CancelToken` is `@unchecked Sendable`; `Job.cancelToken` is read with `await` from the detached task.

## Design notes / known limitations

* Decode → encode runs fully in memory-bounded streaming: 6 frames in the decoder, a PTS reorder window of 16
  frames (H.264) / 8 (HEVC), up to 32 frames queued in the encoder. For 4K 10-bit that is roughly 1–1.5 GB of
  pixel buffers. If a stream reorders more than the window, frames reach the encoder out of order (rare; raise `reorderDepth`).
* Matroska stores only PTS; blocks are written in decode order with PTS timestamps (as mkvmerge does).
  Copied tracks are interleaved by timestamp with a 2 s safety margin behind the video.
* Subtitle burn-in is done per frame with Core Image on the GPU; for HDR (PQ/HLG) sources the sRGB subtitle
  white is converted through Core Image's colour management and may look dimmer or brighter than players render it.
  Overlapping text cues are drawn on top of each other. Subtitles whose blocks come *after* the video frames they
  cover (badly interleaved files) miss their first frames.
* Only the first video track is converted; additional video tracks are dropped. Tags are dropped (their
  statistics would be wrong anyway); Chapters and Attachments are copied as is.
* The burned-in forced track is not copied to the output; all other subtitle tracks are.
* Track numbers and UIDs are kept from the source, so chapter/track references stay valid.
* Hardware encoding is requested (`EnableHardwareAcceleratedVideoEncoder`); on a Mac without an HEVC hardware
  encoder VideoToolbox falls back to software (slow). The `Quality` property is honoured by Apple Silicon encoders;
  otherwise an average bitrate (1080p → 12 Mbit/s, 2160p → 30 Mbit/s, scaled by quality) is used and logged.
* Cancel deletes the partial `.hevc.mkv.part`. A conversion never touches the source file; an existing
  `<movie>.hevc.mkv` is kept and the new file gets ` 2`, ` 3`… appended.
* VC-1 / MPEG-2 sources fail with "video codec … is not supported".
