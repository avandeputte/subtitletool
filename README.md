# Extract Subtitles (macOS app)

A native Swift/SwiftUI Mac app. Right-click an `.mkv` in Finder → **Services → Extract Subtitles**
(or drop MKVs on the app window / Dock icon, or use *Open With*).

For each MKV it:

0. Looks the movie up on IMDb (title and year parsed from the file name, release tags such as
   `1080p.BluRay.x264-GRP` ignored) and renames the file to `Movie Name (yyyy).mkv`.
   Everything below then uses that name. Switch off in Settings or with `--no-rename`;
   with no confident match the original name is kept.
1. Creates `<movie name> Subtitles/` next to the file.
2. Demuxes every subtitle track itself (no mkvtoolnix/ffmpeg needed) and writes
   `<movie>.<lang-tag>[.<track name>][.forced][.sdh][.commentary].<ext>`, e.g.
   `Batman (1989).fr-CA.sup`, `Batman (1989).fr-FR.sup`, `Batman (1989).en.sdh.sup`, `Batman (1989).en.forced.sup`.
   The language tag is the file's IETF tag when present (fr-CA); otherwise the ISO code, refined with a
   region when the track name says so ("French (Canada)" → fr-CA, "Latin American" → es-419, "Brazil" → pt-BR).
   Track names that only repeat the language ("French", "Full") are dropped; distinctive names are kept.
   SDH comes from the Matroska hearing-impaired flag or an "SDH"/"CC" in the name; commentary from the flag.
   Supported: SRT, ASS/SSA, WebVTT, PGS (`.sup`). Zlib-compressed and header-stripped tracks are handled.
   VobSub/DVB tracks are listed but not written yet.
3. Converts to SRT locally (Settings ⌘, → Off or Locally): ASS/SSA/WebVTT are converted directly;
   image tracks (PGS) are rendered frame by frame and read with Apple Vision text recognition in the
   track's language. Tracks already in SRT are copied as-is. Nothing is uploaded anywhere; the only
   network use is the IMDb title lookup.
4. Shows progress in the window and a notification when done.

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
"/Applications/Extract Subtitles.app/Contents/MacOS/Extract Subtitles" --cli [--no-convert|--local] [--no-rename] Movie.mkv
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
  JobRunner.swift                job queue + SubtitleExtractor (the per-file pipeline)
  ContentView.swift              window UI, drag & drop, Settings
  Matroska/EBMLReader.swift      EBML parsing over a memory-mapped file
  Matroska/MatroskaDemuxer.swift tracks, clusters, blocks, lacing, compression
  Matroska/SubtitleWriters.swift SRT / ASS / WebVTT / PGS .sup writers
  Matroska/PGSDecoder.swift      PGS display sets -> bitmaps (palette, RLE)
  LocalConverter.swift           local SRT: ASS/VTT tag stripping, PGS via Vision OCR
  Naming.swift                   language codes and file naming
  MovieIdentifier.swift          file-name parsing + IMDb lookup, "Movie Name (yyyy)" rename
Tests/Sample (srt+ass).mkv       tiny MKV with an English SRT and a French ASS track
Tests/Sample (pgs).mkv           tiny MKV with an English PGS track ("HELLO WORLD" / "Second line here / Bonjour tout le monde")
```
