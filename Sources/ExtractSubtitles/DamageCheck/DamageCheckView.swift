import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class DamageCheckModel: ObservableObject {
    static let shared = DamageCheckModel()

    enum Status {
        case waiting
        case checking(Double)
        case finished(DamageReport)
        case failed(String)
    }

    final class Row: ObservableObject, Identifiable {
        let id = UUID()
        let url: URL
        @Published var status: Status = .waiting
        init(url: URL) { self.url = url }

        var rank: Int {
            switch status {
            case .failed: return 0
            case .finished(let report): return report.severity == .damaged ? 1 : (report.severity == .warning ? 2 : 4)
            default: return 3
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isCollecting = false
    @Published private(set) var completed = 0
    @Published var readEveryByte = false
    @Published var onlyProblems = false

    private let cancelFlag = CancelFlag()
    private var lastSelection: [URL] = []

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    var visibleRows: [Row] {
        onlyProblems ? rows.filter { $0.rank < 3 } : rows
    }

    var summary: String {
        if isCollecting { return "Looking for videos…" }
        if rows.isEmpty { return "" }
        if isRunning { return "Checked \(completed) of \(rows.count)" }
        let damaged = rows.filter { $0.rank <= 1 }.count
        let check = rows.filter { $0.rank == 2 }.count
        let ok = rows.filter { $0.rank == 4 }.count
        var parts = ["\(damaged) damaged", "\(ok) OK"]
        if check > 0 { parts.insert("\(check) to check", at: 1) }
        return parts.joined(separator: " · ")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose videos or a folder to check"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .movie]
        panel.prompt = "Check"
        if panel.runModal() == .OK { start(panel.urls) }
    }

    func recheck() { start(lastSelection) }
    var canRecheck: Bool { !lastSelection.isEmpty && !isRunning }

    func start(_ urls: [URL]) {
        guard !isRunning, !urls.isEmpty else { return }
        lastSelection = urls
        isRunning = true
        isCollecting = true
        completed = 0
        rows = []
        cancelFlag.set(false)
        let flag = cancelFlag
        let everyByte = readEveryByte

        Task.detached(priority: .userInitiated) { [weak self] in
            let files = MediaDamageScanner.collectFiles(urls)
            let rows = await MainActor.run { () -> [Row] in
                let rows = files.map(Row.init)
                self?.rows = rows
                self?.isCollecting = false
                return rows
            }
            for row in rows {
                if flag.isSet { break }
                await MainActor.run { row.status = .checking(0) }
                let status: Status
                do {
                    let report = try MediaDamageScanner.scan(url: row.url, readEveryByte: everyByte,
                                                             isCancelled: { flag.isSet }) { fraction in
                        Task { @MainActor in
                            if case .checking = row.status { row.status = .checking(fraction) }
                        }
                    }
                    status = .finished(report)
                } catch is MediaDamageScanner.Cancelled {
                    await MainActor.run { row.status = .waiting }
                    break
                } catch {
                    status = .failed(error.localizedDescription)
                }
                await MainActor.run {
                    row.status = status
                    self?.completed += 1
                }
            }
            await MainActor.run {
                guard let self else { return }
                if flag.isSet { self.rows.removeAll { if case .waiting = $0.status { return true }; return false } }
                self.rows.sort { ($0.rank, $0.url.path) < ($1.rank, $1.url.path) }
                self.isRunning = false
            }
        }
    }

    func stop() { cancelFlag.set(true) }

    func copyReport() {
        var lines: [String] = []
        for row in rows.sorted(by: { ($0.rank, $0.url.path) < ($1.rank, $1.url.path) }) {
            switch row.status {
            case .finished(let report):
                lines.append("[\(report.severity.label)] \(row.url.path)")
                lines += report.findings.map { "    \($0.text)" }
            case .failed(let message):
                lines.append("[Unreadable] \(row.url.path)")
                lines.append("    \(message)")
            default: break
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

struct DamageCheckView: View {
    @ObservedObject var model: DamageCheckModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if model.rows.isEmpty {
                emptyState
            } else {
                List(model.visibleRows) { row in
                    DamageRowView(row: row)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
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

    private var controls: some View {
        HStack(spacing: 12) {
            if model.isRunning {
                Button("Stop") { model.stop() }
            } else {
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Check Again") { model.recheck() }
                    .disabled(!model.canRecheck)
            }
            Toggle("Read every byte", isOn: $model.readEveryByte)
                .disabled(model.isRunning)
                .help("Slower. Also finds read errors and zero-filled areas hidden inside a cluster.")
            Spacer()
            Text(model.summary).font(.callout).foregroundStyle(.secondary)
            Toggle("Problems only", isOn: $model.onlyProblems)
            Button {
                model.copyReport()
            } label: { Image(systemName: "doc.on.doc") }
            .help("Copy the report")
            .disabled(model.rows.isEmpty)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drop a folder of videos here")
                .font(.title2.weight(.semibold))
            Text("Checks every MKV and MP4, including subfolders.\nYour files are only read, never changed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        final class Collected { var urls: [URL] = [] }
        let collected = Collected()
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url = item as? URL
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let url { lock.lock(); collected.urls.append(url); lock.unlock() }
            }
        }
        let model = self.model
        group.notify(queue: .main) { Task { @MainActor in model.start(collected.urls) } }
        return !providers.isEmpty
    }
}

private struct DamageRowView: View {
    @ObservedObject var row: DamageCheckModel.Row
    @State private var expanded = false

    var body: some View {
        if case .finished(let report) = row.status, report.findings.count > 1 {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(report.findings) { finding in
                    Text(finding.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } label: { content }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if case .checking(let fraction) = row.status {
                ProgressView(value: fraction).frame(width: 110)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        switch row.status {
        case .waiting: return "Waiting"
        case .checking: return "Checking…"
        case .failed(let message): return message
        case .finished(let report): return report.headline
        }
    }

    @ViewBuilder private var icon: some View {
        switch row.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .finished(let report):
            switch report.severity {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .damaged: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }
}

/// Owns the single "Check for Damage" window.
@MainActor
final class DamageCheckWindow {
    static let shared = DamageCheckWindow()
    private var window: NSWindow?

    func show(checking urls: [URL] = []) {
        if window == nil {
            let hosting = NSHostingController(rootView: DamageCheckView(model: .shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Check for Damage"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 540))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !urls.isEmpty { DamageCheckModel.shared.start(urls) }
    }
}

/// `--cli --check [--deep] folder-or-file …` prints one result per file. Exit status 1 if any is damaged.
enum DamageCheckCLI {
    static func run(paths: [URL], readEveryByte: Bool, forceSampling: Bool = false) -> Never {
        let files = MediaDamageScanner.collectFiles(paths)
        var damaged = 0
        for url in files {
            do {
                let report = try MediaDamageScanner.scan(url: url, readEveryByte: readEveryByte, forceSampling: forceSampling)
                print("[\(report.severity.label)] \(url.path) (\(String(format: "%.1f", report.elapsed))s\(report.sampled ? ", sampled" : ""))")
                for finding in report.findings { print("    \(finding.text)") }
                if report.severity == .damaged { damaged += 1 }
            } catch {
                print("[Unreadable] \(url.path)\n    \(error.localizedDescription)")
                damaged += 1
            }
        }
        print("\(files.count) checked, \(damaged) damaged")
        exit(damaged == 0 ? 0 : 1)
    }
}
