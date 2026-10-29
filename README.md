# Extract Subtitles (macOS app)

A native Swift/SwiftUI Mac app. Right-click an `.mkv` in Finder → **Services → Extract Subtitles**
(or drop MKVs on the app window / Dock icon, or use *Open With*).

For each MKV it:

0. Identifies the movie on IMDb and renames the file to `Movie Name (yyyy).mkv`. The title and year are
   parsed from the file name: MakeMKV suffixes (`Cloud Atlas_t00.mkv`, `title00.mkv`), release tags
   (`1080p.BluRay.x264-GRP`), "copy"/"(1)" and ALL-CAPS are cleaned up, so `Cloud Atlas_t00.mkv` becomes
   `Cloud Atlas (2012).mkv`. The rename is only automatic when exactly one IMDb title matches (same title, year
   within a year when the file has one). With several similar titles, a different year, or no hit, a picker
   opens: the candidates with poster, year and cast, a search field to try another title, and "Keep file name".
   When several MKVs are queued, all of them are identified (and all questions asked) before any subtitle
   work starts, so the batch then runs unattended. Everything below uses the new name. Switch off in Settings
   or with `--no-rename`; in `--cli` mode the picker is a numbered list in the terminal (no terminal: the name is kept).
1. Creates `<movie name> Subtitles/` next to the file.
2. Demuxes every subtitle track itself (no mkvtoolnix/ffmpeg needed) and writes
   `<movie>.<lang-tag>[.<track name>][.forced][.sdh][.commentary].<ext>`, e.g.
   `Batman (1989).fr-CA.sup`, `Batman (1989).fr-FR.sup`, `Batman (1989).en.sdh.sup`, `Batman (1989).en.forced.sup`.
   The language tag is the file's IETF tag when present (fr-CA); otherwise the ISO code, refined with a
   region when the track name says so ("French (Canada)" → fr-CA, "Latin American" → es-419, "Brazil" → pt-BR).
   Track names that only repeat the language ("French", "Full") are dropped; distinctive names are kept.
   SDH comes from the Matroska hearing-impaired flag or an "SDH"/"CC" in the name; commentary from the flag.
   When the metadata is silent (MakeMKV rips: several "fre" PGS tracks, no names, no flags) the content decides:
   a track byte-identical to an earlier one is skipped; `.forced` is added when every PGS cue is flagged forced
   in the stream or the track has under 10% of the cues of the fullest track in that language (signs-only tracks);
   `.sdh` when more than 5% of the OCR'd cues carry `[SIRENS]` / `(laughs)` / `♪` / `NAME:` captions; Chinese gets
   `zh-Hans` / `zh-Hant` from the characters. Names that still collide get the track number (`zh-Hant.10`).
   Regions (fr-CA vs fr-FR) are never guessed from the text. `--cli --list` shows the analysis without writing.
   Supported: SRT, ASS/SSA, WebVTT, PGS (`.sup`). Zlib-compressed and header-stripped tracks are handled.
   VobSub/DVB tracks are listed but not written yet.
3. Converts to SRT locally (Settings ⌘, → Off or Locally): ASS/SSA/WebVTT are converted directly;
   image tracks (PGS) are rendered frame by frame and read with Apple Vision text recognition in the
   track's language. Tracks already in SRT are copied as-is. Nothing is uploaded anywhere; the only
   network use is the IMDb title lookup.
4. Shows progress in the window and a notification when done.

## OCR

PGS bitmaps go through a few passes before and after Apple Vision (`VNRecognizeTextRequest`, accurate level,
language correction, languages picked from the track's language tag):

* Each display set is cropped to its ink (8 px margin), composited on opaque white as dark text (light text
  is inverted) and upscaled 2x (text under 60 px) or 3x (under 30 px) with high-quality interpolation.
* Of Vision's top 3 candidates per line the one needing the fewest clean-up fixes wins (ties by confidence).
* Italics: the slant of each line's ink (horizontal centroid of the top third vs. the bottom third) tags the
  line as `<i>…</i>`.
* `OCRCleanup.clean` then fixes capital I read as l/|/1 (`l'm`, `lt's`, `I'Il`; English only), leading dialogue
  dashes (`-x` → `- x`), ellipses (`..`, `....`, `…` → `...`), stray capitals inside words (`BOo` → `Boo`),
  `''`/curly quotes and spacing around punctuation, leaving `<i>` tags untouched.

## Convert to H.265 (MP4)

Right-click an `.mkv` in Finder → **Services → Convert to H.265** (or File › Convert to H.265…, or
`--cli --h265`), or switch on *Settings › Video conversion › Convert to H.265 (MP4) after extracting* to run it
automatically after the subtitles of every job (off by default). It works like HandBrake: the app drives
**ffmpeg** (`brew install ffmpeg`; also looked for in the app's `Contents/Helpers`, `/usr/local/bin`, MacPorts
and `$PATH`) and shows its progress. The output is an `.mp4` that QuickTime, Apple TV, iOS, Infuse, Plex and
VLC all play:

* Video: `hevc_videotoolbox` (the Mac's hardware HEVC encoder) in constant-quality mode
  (`-q:v`, default 0.85 → 85, slider 0.5–1.0, `--quality 0.9`), same resolution and frame rate, `hvc1` tag,
  Main 10 for 10-bit sources, colour primaries/transfer/matrix carried over. If the encoder refuses
  constant-quality mode (Intel Macs) the conversion is retried with a resolution-based average bitrate.
* **All audio tracks are kept, untouched** (`-c:a copy`): AAC, MP3, AC-3, E-AC-3, DTS / DTS-HD MA / DTS:X,
  TrueHD / Atmos, FLAC, Opus, ALAC. Codecs MP4 cannot carry (Vorbis, PCM) are re-encoded as AAC.
* **AC-3 copy of every DTS / TrueHD track** (Settings toggle, `--no-ac3` to skip): Apple's players cannot decode
  DTS or TrueHD, so ffmpeg also encodes a Dolby Digital 5.1 copy at 640 kbps (stereo 256) with the same
  language, placed before the original and flagged default so QuickTime and Apple TV start with sound; the
  original stays selectable for AV receivers. No copy is made when the file already has an AC-3/E-AC-3 track in
  that language.
* Subtitles: the SRT files just extracted (or the MKV's own text tracks) become `mov_text` tracks named
  "English", "French (Canada) SDH", …, switched off by default. The forced **PGS** track (preferring the default
  audio's language, then English) is burned into the picture with the `overlay` filter; a forced text track is
  added as a forced subtitle track instead (Homebrew's ffmpeg has no libass). Other PGS tracks cannot go into an
  MP4 and are left out (they are still extracted as `.sup` / OCR'd to `.srt`).
* Chapters and the movie title are kept (`-map_chapters 0`, `title=`).
* Output: `<movie>.mp4` next to the source (after the IMDb rename, e.g. `Batman (1989).mp4`); an existing file is
  never overwritten (` 2.mp4`, ` 3.mp4`…). The source is never modified or deleted. Progress (percent, fps,
  time left) is shown in the window with a cancel button; the log shows the exact ffmpeg command, the tracks
  written and the output size/bitrate.

```bash
"/Applications/Extract Subtitles.app/Contents/MacOS/Extract Subtitles" --cli --h265 --quality 0.9 Movie.mkv
"/Applications/Extract Subtitles.app/Contents/MacOS/Extract Subtitles" --cli --h265 --no-ac3 Movie.mkv   # passthrough only
```

## Build & install

If team auto-detection picks the wrong team, pass it explicitly: `DEVELOPMENT_TEAM=XXXXXXXXXX ./build.sh --install`.

Requirements: Xcode 15+, Homebrew (for XcodeGen).

```bash
./build.sh --install
```

This generates `ExtractSubtitles.xcodeproj` from `project.yml` (XcodeGen), builds Release with
`xcodebuild`, signs with the first developer identity in your Keychain (or ad-hoc if none),
copies the app to `/Applications`, registers it with Launch Services and launches it.

You can also open `ExtractSubtitles.xcodeproj` in Xcode after `xcodegen generate` and run from there.

## Command line

```bash
"/Applications/Extract Subtitles.app/Contents/MacOS/Extract Subtitles" --cli [--no-convert|--local] [--no-rename] [--h265] [--no-ac3] [--quality 0.9] Movie.mkv
"/Applications/Extract Subtitles.app/Contents/MacOS/Extract Subtitles" --cli --list Movie.mkv   # tracks + names only, writes nothing
```

## Layout

```
project.yml                      XcodeGen spec (app target, signing, Info.plist, entitlements)
build.sh                         build / install script
Resources/Info.plist             NSServices (Finder menu), document types, MKV UTI
Resources/*.entitlements         no sandbox (network client kept for the IMDb lookup)
Resources/icon-1024.png          app icon source (build.sh makes the asset catalog)
Sources/ExtractSubtitles/
  App.swift                      SwiftUI App, AppDelegate, Services provider, --cli mode
  JobRunner.swift                identify queue -> work queue, SubtitleExtractor (the per-file pipeline)
  ContentView.swift              window UI, drag & drop, Settings
  Matroska/EBMLReader.swift      EBML parsing over a memory-mapped file
  Matroska/MatroskaDemuxer.swift tracks, clusters, blocks, lacing, compression
  Matroska/SubtitleWriters.swift SRT / ASS / WebVTT / PGS .sup writers
  Matroska/PGSDecoder.swift      PGS display sets -> bitmaps (palette, RLE)
  LocalConverter.swift           local SRT: ASS/VTT tag stripping, PGS via Vision OCR
  VideoConverter.swift           ffprobe -> plan (burn-in, audio copies, subtitles) -> ffmpeg hevc_videotoolbox + MP4, progress
  SubtitleTrackNames.swift       subtitle file name -> MP4 track language / name
  VideoConversionJob.swift       the "convert to H.265" job step (progress, cancel, result)
  Naming.swift                   language codes and file naming (metadata + content plan)
  TrackAnalysis.swift            cue counts, PGS forced flags, stream hashes, SDH / Chinese-script heuristics
  MovieIdentifier.swift          file-name parsing + IMDb suggestion search, confident / ambiguous resolution
  MovieResolver.swift            identification phase: picker sheet (GUI) or numbered list (terminal), rename
Tests/Sample (srt+ass).mkv       tiny MKV with an English SRT and a French ASS track
Tests/Sample (pgs).mkv           tiny MKV with an English PGS track ("HELLO WORLD" / "Second line here / Bonjour tout le monde")
```
