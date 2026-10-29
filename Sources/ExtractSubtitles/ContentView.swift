import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var runner: JobRunner
    @State private var isTargeted = false

    var body: some View {
        Group {
            if runner.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    runner.openPanel()
                } label: { Label("Open MKV…", systemImage: "plus") }

                Button {
                    runner.clearFinished()
                } label: { Label("Clear finished", systemImage: "trash") }
                .disabled(runner.jobs.isEmpty)

                SettingsButton { Label("Settings", systemImage: "gearshape") }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Drop MKV files here")
                .font(.title2.weight(.semibold))
            Text("Or right-click an MKV in Finder and choose\nServices › Extract Subtitles")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var jobList: some View {
        List {
            ForEach(runner.jobs) { job in
                JobRow(job: job)
            }
        }
        .listStyle(.inset)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) { runner.enqueue(urls) }
        return found
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if !job.message.isEmpty {
                Label(job.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            ForEach(job.tracks) { track in
                TrackRow(result: track)
            }
        } label: {
            HStack {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.movieName).font(.headline)
                    if let identity = job.identity {
                        HStack(spacing: 4) {
                            if let original = job.originalName { Text("was \(original) ·").font(.caption).foregroundStyle(.secondary) }
                            Link("IMDb \(identity.imdbID)", destination: identity.imdbURL).font(.caption)
                        }
                    }
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .done = job.state, let folder = job.outputFolder {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(.link)
                } else if isWorking {
                    ProgressView(value: job.progress).frame(width: 120)
                }
            }
        }
    }

    private var isWorking: Bool {
        switch job.state {
        case .scanning, .extracting, .converting: return true
        default: return false
        }
    }

    private var statusIcon: some View {
        Group {
            switch job.state {
            case .queued: Image(systemName: "clock")
            case .scanning, .extracting, .converting: ProgressView().controlSize(.small)
            case .done:
                Image(systemName: job.hasFailures ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(job.hasFailures ? .orange : .green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 20)
    }

    private var statusText: String {
        switch job.state {
        case .queued: return "Waiting"
        case .scanning: return "Reading file…"
        case .extracting: return "Extracting subtitle tracks…"
        case .converting: return "Converting to SRT…"
        case .done:
            return "\(job.tracks.count) track(s), \(job.srtCount) SRT file(s) → \(job.outputFolder?.lastPathComponent ?? "")"
        case .failed(let why): return why
        }
    }
}

struct TrackRow: View {
    @ObservedObject var result: TrackResult

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(result.languageName).fontWeight(.medium)
                    Text(result.languageTag).font(.caption).foregroundStyle(.secondary)
                    if !result.track.name.isEmpty { Text(result.track.name).foregroundStyle(.secondary) }
                    if result.track.isForced { Text("forced").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                    if Naming.isSDH(result.track) { Text("SDH").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                    if result.track.isCommentary { Text("commentary").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                    Text(result.track.kind.label).font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let p = result.detailProgress, result.state == .converting {
                    ProgressView(value: p).frame(maxWidth: 220)
                }
            }
            Spacer()
        }
        .padding(.leading, 8)
    }

    private var icon: some View {
        Group {
            switch result.state {
            case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
            case .extracted: Image(systemName: "doc").foregroundStyle(.secondary)
            case .converting: ProgressView().controlSize(.mini)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private var detail: String {
        switch result.state {
        case .pending: return result.fileName
        case .extracted: return result.fileName
        case .converting:
            let what = result.track.kind.isTextBased ? "converting to SRT…" : "running Apple Vision OCR…"
            return "\(result.fileName) → \(what)"
        case .done:
            var s = result.fileName
            let extra = result.srtNames.filter { $0 != result.fileName }
            if !extra.isEmpty { s += "  +  " + extra.joined(separator: ", ") }
            if !result.notes.isEmpty { s += "\n" + result.notes.joined(separator: "; ") }
            return s
        case .skipped(let why): return "\(result.fileName) — \(why)"
        case .failed(let why): return "\(result.fileName) — \(why)"
        }
    }
}

struct SettingsView: View {
    @AppStorage(ConversionMode.storageKey) private var conversionModeRaw = ConversionMode.local.rawValue
    @AppStorage(JobRunner.renameKey) private var renameFromIMDb = true

    var body: some View {
        Form {
            Section("File naming") {
                Toggle("Look the movie up on IMDb and rename to \"Movie Name (yyyy).mkv\"", isOn: $renameFromIMDb)
                Text("The title and year are read from the file name (release tags are ignored) and matched on IMDb. The MKV, its subtitle folder and every subtitle file then use that name. If there is no confident match the original name is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Subtitle files are named <movie>.<language>[.<track name>][.forced][.sdh][.commentary].<ext>. The language tag keeps the region when the file gives one (fr-CA, fr-FR, pt-BR, es-419…), so two tracks of the same language stay apart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Convert to SRT") {
                Picker("Method", selection: $conversionModeRaw) {
                    ForEach(ConversionMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Everything runs on this Mac: ASS/SSA/WebVTT are converted directly, image subtitles (PGS) are rendered frame by frame and read with Apple Vision text recognition in the track's language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.bottom)
    }
}

/// A button that opens the Settings scene. macOS 14+ requires `SettingsLink`;
/// on macOS 13 the `showSettingsWindow:` responder action is used.
struct SettingsButton<Label: View>: View {
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { label() }
        } else {
            Button { SettingsOpener.open() } label: { label() }
        }
    }
}

enum SettingsOpener {
    /// Opens the SwiftUI Settings scene (macOS 13: showSettingsWindow:, older: showPreferencesWindow:).
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
