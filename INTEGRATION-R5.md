# Release 5 – IMDb picker, MP4 output, AC-3 copies (integration notes)

R4 (H.265, content-aware naming, OCR fixes) was never compiled on the Mac; R5 builds on it and replaces its
Matroska output with MP4. Neither has been through a Swift compiler yet: expect a few trivial complaints.
Fold every fix you make back into the sources and commit it.

## New files

| File | What it is |
|---|---|
| `Sources/ExtractSubtitles/MovieResolver.swift` | `MovieResolver` (`@MainActor ObservableObject`): phase 1 of a job. `resolve(job:interaction:log:)` runs `IMDbLookup.identify`, renames on a confident match, otherwise shows `IMDbPickerSheet` (GUI, `withCheckedContinuation`) or a numbered list on the terminal (`--cli`), or keeps the name when there is no terminal. `IMDbPickerSheet` / `CandidateRow`: search field, poster, title, year, cast, "Keep file name" / "Use …". |
| `Sources/ExtractSubtitles/Matroska/MP4Writer.swift` | `BoxBuilder` and `MP4Writer`: `ftyp` + growing 64-bit `mdat`, chunks of ~1 s / 4 MB with an 8 MB write buffer, `moov` at the end (`mvhd`/`tkhd`/`elst`/`tref chap`/`mdhd`/`hdlr`/`elng`/`vmhd|smhd|nmhd|gmhd`/`dref`/`stsd`/`stts`/`ctts`/`stss`/`stsc`/`stsz`/`co64`, `udta/meta/ilst ©nam`). Sample-entry builders: `hvc1Entry` (+`hvcC`/`colr nclx`/`mdcv`/`clli`/`pasp`), `audioEntry` (+`esds`/`dac3`/`dec3`/`dmlp`/`dfLa`/`dOps`/`alac`), `tx3gEntry`, `chapterTextEntry`, `tx3gSample(text:italicRanges:)`, `chapterSample`. |
| `Sources/ExtractSubtitles/Matroska/AudioPackets.swift` | `AudioCodec.detect(track:firstPacket:)` parses AAC (AudioSpecificConfig), MP3/MP2, AC-3, E-AC-3, DTS core / DTS-HD (XLL/LBR/XBR), TrueHD/MLP (major sync, AU splitting), FLAC (STREAMINFO), Opus (OpusHead, pre-skip), ALAC; gives timescale, samples per packet, sample entry, `appleCanPlay`, `describe`. `MP4Language.codes` (ISO 639-2/T + extended IETF tag). |
| `Sources/ExtractSubtitles/Matroska/MP4Extras.swift` | `MKVChapters.parse` (raw Chapters element → default edition, visible chapters), `TextCue`, `TimedText.parseSRT` / `styled` (plain text + italic UTF-16 ranges) / `describe(fileName:movie:)` / `trackName`. |
| `Sources/ExtractSubtitles/AC3Transcoder.swift` | `AC3Transcoder.findFFmpeg()` (Contents/Helpers, Homebrew, /usr/local, MacPorts, PATH) and `run(frame:)`: `ffmpeg -i src -map 0:a:N -c:a ac3 -b:a 640k -ac 6 -f ac3 pipe:1`, syncframes split on the AC-3 header. |
| `INTEGRATION-R5.md` | this file |

## Removed

* `Sources/ExtractSubtitles/Matroska/MatroskaWriter.swift` (MKV muxer; delete it from the Mac's tree too).

## Rewritten / edited

* `Sources/ExtractSubtitles/VideoConverter.swift`: output through `MP4Writer`. Video dts on an exact timescale
  (24000/1001 → 24000), cts snapped to the frame grid, `ctts` + edit list for the B-frame delay. Audio tracks are
  added lazily at their first packet (`handleAudio`): passthrough with drift-corrected dts; DTS/TrueHD get an
  `AC3Worker` thread feeding an AC-3 track (throttled to video progress + 20 s so chunks stay interleaved); the copy
  is the enabled track, the original is in the same alternate group. tx3g tracks from the extracted SRTs
  (`Options.extraSubtitleFiles`) or MKV text tracks; chapter track; `©nam`. `Result` gains `audioTracks`,
  `ac3Copies`, `subtitleTracks`, `notes`.
* `Sources/ExtractSubtitles/MovieIdentifier.swift`: `MovieIdentity` (title, year, imdbID, kind, stars, poster),
  `FilenameParser` (MakeMKV `_t00` / `title00`, "copy", "(1)", ALL-CAPS), `IMDbLookup.search` (keyless
  `v3.sg.media-imdb.com/suggestion` endpoint) and `identify(guess:alternateTitle:) -> Resolution`
  (`confident` / `ambiguous(candidates, reason)` / `nothing`).
* `Sources/ExtractSubtitles/JobRunner.swift`: `Job.State.identifying`; `identifyQueue` → `workQueue`; all queued
  jobs are identified (sequentially, prompts included) before any subtitle work starts; `addAC3Copies`
  `@AppStorage` (key `addAC3Copies`, default true); `resolver` exposed for the sheet; no rename inside `process`.
* `Sources/ExtractSubtitles/App.swift`: `.environmentObject(runner.resolver)`; CLI phase 1 (identify all files,
  terminal picker when stdin is a TTY) then phase 2; `--no-ac3`; `--list` prints the IMDb preview.
* `Sources/ExtractSubtitles/ContentView.swift`: `.sheet(item: $resolver.prompt)`, identifying state, MP4 wording,
  AC-3 copy toggle.
* `Sources/ExtractSubtitles/VideoConversionJob.swift`: `run(job:quality:ac3Copies:log:)`, passes the job's SRTs.
* `README.md`: IMDb, MP4, AC-3, layout.

## How to test on the Mac

```bash
cd ~/Documents/GitHub/subtitletool && git pull
./build.sh --install          # or: xcodegen generate; xcodebuild … DEVELOPMENT_TEAM=69M2JRAT8P
APP="/Applications/Extract Subtitles.app/Contents/MacOS/Extract Subtitles"

# IMDb: a MakeMKV-style name → confident match or picker
cp "Tests/Sample (pgs).mkv" "/tmp/Cloud Atlas_t00.mkv"; "$APP" --cli --list "/tmp/Cloud Atlas_t00.mkv"
"$APP" --cli --no-convert "/tmp/Cloud Atlas_t00.mkv"            # renames to "Cloud Atlas (2012).mkv" (or asks)

# MP4: convert a short MKV with video (any DTS/TrueHD source to see the AC-3 copy)
"$APP" --cli --h265 --no-rename "/Volumes/Fastdisk/BD/Batman (1989).mkv"
ffprobe "/Volumes/Fastdisk/BD/Batman (1989).mp4"                # hvc1 video; every audio track + "AC-3 … (from DTS)" copies; tx3g subs; chapters
ffprobe -v error -show_entries stream=index,codec_name,codec_tag_string,disposition:stream_tags=language,title -of compact "/Volumes/Fastdisk/BD/Batman (1989).mp4"
open -a "QuickTime Player" "/Volumes/Fastdisk/BD/Batman (1989).mp4"   # plays with sound (AC-3), subtitles menu lists the tracks, chapters menu
ffmpeg -v error -i "/Volumes/Fastdisk/BD/Batman (1989).mp4" -f null -   # no demux/decode errors
# bit-exact passthrough of the DTS track:
ffmpeg -i "Batman (1989).mkv" -map 0:a:0 -c copy -f dts - | md5; ffmpeg -i "Batman (1989).mp4" -map 0:a:0 -c copy -f dts - | md5
```

## Things to check first when compiling

* `MP4Writer.TrackConfig(kind:timescale:)` is the only designated init; every other field is set afterwards.
* `AudioCodec` is a struct with `let family` and `var` everything else; `AC3CopyState.finish` mutates a copy.
* The AC-3 worker threads are plain `Thread`s joined with a `DispatchSemaphore`; `VideoConverter` is a class
  guarded by an `NSLock` (`lock`) for the fields the threads touch (`readingDone`, `lastVideoPtsNs`, `error`).
* `IMDbPickerSheet` needs `AsyncImage` (macOS 12+, fine).
* `MovieResolver.resolveInTerminal` uses `readLine()`; in the GUI the resolver only ever runs with `.gui`.

## Design notes / known limitations

* MP4 cannot carry PGS subtitles as tracks: PGS tracks other than the burned-in forced one are left out
  (they are still extracted as `.sup` / OCR'd to `.srt`, and the SRTs go in as tx3g).
* Vorbis / PCM audio is dropped; VC-1 / MPEG-2 video is not converted.
* The AC-3 copy depends on an ffmpeg binary on the Mac (Homebrew's `/opt/homebrew/bin/ffmpeg` is found
  automatically). To ship it inside the app, copy a static `ffmpeg` to `Contents/Helpers/ffmpeg` and sign it.
* `moov` is written at the end (no fast-start); the files are for local players, not streaming.
