import SwiftUI
import AppKit
import G5Core

enum SidebarItem: Hashable { case patch(Int), backup(URL) }

final class SidebarState: ObservableObject {
    @Published var selection: SidebarItem?
    @Published var search = ""
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: MonitorController
    @StateObject private var ui = SidebarState()

    var body: some View {
        NavigationSplitView {
            List(selection: $ui.selection) {
                Section {
                    HStack(spacing: 8) {
                        Circle().fill(model.isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ZOOM G5").font(.system(size: 12, weight: .bold))
                            Text(statusLine).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                MonitorSection()
                Section("Patches") {
                    ForEach(filteredPatches) { p in
                        HStack(spacing: 8) {
                            Text(AppModel.label(p.slot)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            Text(p.name)
                            Spacer()
                            if model.editing?.slot == p.slot {
                                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Palette.accent)
                            }
                        }
                        .tag(SidebarItem.patch(p.slot))
                    }
                }
                Section("Backups on this Mac") {
                    if model.backups.isEmpty { Text("No backups yet").foregroundStyle(.secondary) }
                    ForEach(model.backups) { b in
                        Label(b.date.formatted(date: .abbreviated, time: .shortened), systemImage: "archivebox")
                            .help(b.url.lastPathComponent)
                            .tag(SidebarItem.backup(b.url))
                            .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) } }
                    }
                }
            }
            .searchable(text: $ui.search, placement: .sidebar, prompt: "Find patch")
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Import Backup…") { model.importBackup() }
                    Spacer()
                    Button { NSWorkspace.shared.open(Backup.defaultFolder) } label: { Image(systemName: "folder") }
                        .help("Open the backups folder in Finder")
                }.buttonStyle(.borderless).padding(10)
            }
        } detail: {
            switch ui.selection {
            case .backup(let url): BackupView(url: url).id(url)
            default: EditorView()
            }
        }
        .onChange(of: ui.selection) { _, new in
            if case .patch(let slot) = new { model.openPatch(slot) }
        }
        .onReceive(model.$editing.map { $0?.slot }.removeDuplicates()) { slot in
            guard let slot else { return }
            if case .backup = ui.selection { return }
            if ui.selection != .patch(slot) { ui.selection = .patch(slot) }
        }
        .toolbar {
            ToolbarItem {
                Button { monitor.toggle() } label: {
                    Label(monitor.isOn ? "Monitor On" : "Monitor", systemImage: monitor.isOn ? "headphones.circle.fill" : "headphones")
                        .foregroundStyle(monitor.isOn ? Palette.accent : .primary)
                }
                .help(monitor.isOn ? "Stop playing the G5 through \(monitor.selectedOutput?.name ?? "the Mac")"
                                   : "Play the G5 through \(monitor.selectedOutput?.name ?? "the Mac") (⇧⌘M)")
            }
            ToolbarItem {
                Button { model.backUpNow() } label: { Label("Back Up Now", systemImage: "square.and.arrow.down") }
                    .disabled(!model.isConnected || model.job != nil)
                    .help("Save every patch on the G5 to this Mac")
            }
        }
        .sheet(item: Binding(get: { model.job.map { JobBox(job: $0) } }, set: { _ in })) { box in
            VStack(alignment: .leading, spacing: 12) {
                Text(box.job.title).font(.headline)
                ProgressView(value: Double(box.job.done), total: Double(max(box.job.total, 1)))
                Text("Keep the pedal connected.").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 360)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorText ?? "") }
        .alert("Done", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") {}
        } message: { Text(model.message ?? "") }
    }

    private var filteredPatches: [G5Patch] {
        let s = ui.search.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return model.pedalPatches }
        return model.pedalPatches.filter { p in
            p.name.localizedCaseInsensitiveContains(s) || AppModel.label(p.slot).hasPrefix(s)
                || (p.patchData.map { d in (0..<9).contains { d.type($0)?.name.localizedCaseInsensitiveContains(s) == true } } ?? false)
        }
    }

    var statusLine: String {
        switch model.status {
        case .searching: return "Looking for pedal…"
        case .connected(let fw): return "Connected · firmware \(fw)"
        case .disconnected: return "Not connected"
        }
    }
}

struct JobBox: Identifiable { var job: AppModel.Job; var id: String { job.title } }

final class BackupState: ObservableObject {
    @Published var patches: [G5Patch] = []
    @Published var loadError: String?
    @Published var selection = Set<Int>()
    @Published var confirm: [G5Patch]?
}

struct BackupView: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @StateObject private var st = BackupState()

    var differing: Set<Int> {
        guard !model.pedalPatches.isEmpty else { return [] }
        let pedal = Dictionary(uniqueKeysWithValues: model.pedalPatches.map { ($0.slot, $0.data) })
        return Set(st.patches.filter { pedal[$0.slot] != $0.data }.map(\.slot))
    }

    var body: some View {
        Group {
            if let e = st.loadError {
                ContentUnavailableView("Can't open this backup", systemImage: "exclamationmark.triangle", description: Text(e))
            } else {
                VStack(spacing: 0) {
                    Table(st.patches, selection: $st.selection) {
                        TableColumn("#") { p in Text(AppModel.label(p.slot)).monospacedDigit().foregroundStyle(.secondary) }.width(56)
                        TableColumn("Name") { p in Text(p.name).font(.body.monospaced()) }
                        TableColumn("Effects") { p in
                            Text(p.patchData.map { d in (0..<9).compactMap { d.type($0) }.filter { !$0.isEmpty }.map(\.name).joined(separator: " → ") } ?? "")
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        TableColumn("") { p in
                            if differing.contains(p.slot) { Text("differs from pedal").font(.caption).foregroundStyle(.orange) }
                        }.width(min: 0, ideal: 120)
                    }
                    Divider()
                    HStack {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Selected…") { st.confirm = st.patches.filter { st.selection.contains($0.slot) } }
                            .disabled(st.selection.isEmpty || !model.isConnected || model.job != nil)
                        Button("Restore All…") { st.confirm = st.patches }
                            .disabled(st.patches.isEmpty || !model.isConnected || model.job != nil)
                    }.padding(12)
                }
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .onAppear {
            do { st.patches = try Backup.read(url) } catch { st.loadError = error.localizedDescription }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { st.confirm != nil }, set: { if !$0 { st.confirm = nil } })) {
            Button("Restore to G5", role: .destructive) {
                if let c = st.confirm { model.restore(c, from: url.lastPathComponent) }
                st.confirm = nil
            }
        } message: {
            Text("This replaces these patches on the pedal with the versions in this backup. The app first saves a safety backup of everything currently on the pedal, so you can undo this.")
        }
    }

    var confirmTitle: String {
        let c = st.confirm ?? []
        return c.count == 1 ? "Restore patch \(AppModel.label(c[0].slot)) “\(c[0].name)”?" : "Restore \(c.count) patches to the G5?"
    }

    var summary: String {
        if model.pedalPatches.isEmpty { return "Connect the pedal to compare and restore." }
        let d = differing.count
        return d == 0 ? "Identical to what's on the pedal now." : "\(d) patch\(d == 1 ? "" : "es") differ from the pedal."
    }
}
