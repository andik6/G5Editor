import SwiftUI
import AppKit
import G5Core

enum SidebarItem: Hashable { case patch(Int), bank(Int), backup(URL) }

final class SidebarState: ObservableObject {
    @Published var selection: SidebarItem?
    @Published var search = ""
    /// Banks shown open in the sidebar; remembered between launches.
    @Published var expanded: Set<Int> = Set(UserDefaults.standard.array(forKey: "expandedBanks") as? [Int] ?? []) {
        didSet { UserDefaults.standard.set(Array(expanded).sorted(), forKey: "expandedBanks") }
    }
    /// Song titles of banks written by the Sound Patcher whose patch names still match the pedal.
    @Published var bankTitles: [Int: String] = [:]

    func refreshTitles(_ patches: [G5Patch]) {
        let names = Dictionary(uniqueKeysWithValues: patches.map { ($0.slot, $0.name.trimmingCharacters(in: .whitespaces)) })
        let dir = Backup.defaultFolder.appendingPathComponent("Sound Patcher", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [Int: String] = [:]
        for f in files {   // "<date> bank N - title.json", oldest first so the newest wins
            let n = f.lastPathComponent
            guard let r = n.range(of: " bank "), let bank = Int(n[r.upperBound...].prefix { $0.isNumber }),
                  let spec = try? BankSpec.load(f) else { continue }
            let match = spec.patches.enumerated().allSatisfy { i, p in
                names[(bank - 1) * 3 + i] == p.name.trimmingCharacters(in: .whitespaces)
            }
            if match, let t = spec.title { out[bank] = t } else { out[bank] = nil }
        }
        if out != bankTitles { bankTitles = out }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: MonitorController
    @EnvironmentObject var tuner: TunerController
    @EnvironmentObject var patcher: PatcherController
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
                Section {
                    ForEach(filteredBanks, id: \.bank) { group in
                        DisclosureGroup(isExpanded: expansion(group.bank)) {
                            ForEach(group.patches) { p in
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
                        } label: {
                            bankLabel(group)
                        }
                    }
                } header: {
                    HStack {
                        Text("Patches")
                        Spacer()
                        let allOpen = ui.expanded.count >= 99
                        Button(allOpen ? "Collapse All" : "Expand All") {
                            ui.expanded = allOpen ? [] : Set(1...99)
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Or ⌥-click a bank's disclosure triangle")
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
            .onKeyPress(.leftArrow) { arrow(open: false) }
            .onKeyPress(.rightArrow) { arrow(open: true) }
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
        .onAppear { ui.refreshTitles(model.pedalPatches) }
        .onChange(of: model.pedalPatches) { _, new in ui.refreshTitles(new) }
        .onReceive(model.$editing.map { $0?.slot }.removeDuplicates()) { slot in
            guard let slot else { return }
            if !ui.expanded.contains(slot / 3 + 1) { ui.expanded.insert(slot / 3 + 1) }   // the bank being played opens
            if case .backup = ui.selection { return }
            if ui.selection != .patch(slot) { ui.selection = .patch(slot) }
        }
        .inspector(isPresented: $patcher.isOpen) {
            PatcherPanel().inspectorColumnWidth(min: 320, ideal: 380, max: 560)
        }
        .onChange(of: patcher.isOpen) { _, open in
            if open, let s = model.editing?.slot, patcher.messages.isEmpty { patcher.bank = s / 3 + 1 }
        }
        .toolbar {
            ToolbarItem {
                Button { patcher.toggle() } label: {
                    Label("Sound Patcher", systemImage: "sparkles").foregroundStyle(patcher.isOpen ? Palette.accent : .primary)
                }
                .help("AI Sound Patcher: tones for a song (⇧⌘P)")
            }
            ToolbarItem {
                Button { tuner.toggle() } label: { Label("Tuner", systemImage: "tuningfork") }
                    .help("Tune your guitar (⇧⌘T)")
            }
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
        .sheet(isPresented: $tuner.isOpen) { TunerView().environmentObject(tuner) }
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
                || ui.bankTitles[p.slot / 3 + 1]?.localizedCaseInsensitiveContains(s) == true
                || (p.patchData.map { d in (0..<9).contains { d.type($0)?.name.localizedCaseInsensitiveContains(s) == true } } ?? false)
        }
    }

    private struct BankGroup { let bank: Int; let patches: [G5Patch] }

    private var filteredBanks: [BankGroup] {
        Dictionary(grouping: filteredPatches) { $0.slot / 3 + 1 }
            .map { BankGroup(bank: $0.key, patches: $0.value.sorted { $0.slot < $1.slot }) }
            .sorted { $0.bank < $1.bank }
    }

    /// Open/closed state of a bank. While searching every matching bank is open; ⌥-click opens or closes all.
    private func expansion(_ bank: Int) -> Binding<Bool> {
        Binding(
            get: { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.expanded.contains(bank) },
            set: { open in
                var next = ui.expanded
                if NSEvent.modifierFlags.contains(.option) { next = open ? Set(1...99) : [] }
                else if open { next.insert(bank) } else { next.remove(bank) }
                if next != ui.expanded { ui.expanded = next }
            })
    }

    @ViewBuilder private func bankLabel(_ g: BankGroup) -> some View {
        let playing = model.editing.map { $0.slot / 3 + 1 == g.bank } ?? false
        HStack(spacing: 8) {
            Text(String(format: "%02d", g.bank)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            if let title = ui.bankTitles[g.bank] {
                Text(title).lineLimit(1)
            } else {
                Text(g.patches.map(\.name).joined(separator: " · ")).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if playing && !ui.expanded.contains(g.bank) {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Palette.accent)
            }
        }
        .help(g.patches.map { "\(AppModel.label($0.slot))  \($0.name)" }.joined(separator: "\n"))
        .tag(SidebarItem.bank(g.bank))
    }

    /// ← closes the selected patch's bank (selecting the bank row), → opens the selected bank.
    private func arrow(open: Bool) -> KeyPress.Result {
        switch ui.selection {
        case .patch(let slot) where !open:
            let b = slot / 3 + 1; ui.expanded.remove(b); ui.selection = .bank(b); return .handled
        case .bank(let b):
            if open { ui.expanded.insert(b) } else { ui.expanded.remove(b) }
            return .handled
        default: return .ignored
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
