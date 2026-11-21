import SwiftUI
import AppKit
import G5Core

struct EditSession: Equatable {
    var slot: Int
    var patch: PatchData
    var original: PatchData
    var isModified: Bool { patch != original }
}

/// Coalesces rapid knob changes so the pedal gets only the latest value per knob.
final class ParamSender {
    private let lock = NSLock()
    private var pending: [(unit: Int, prm: Int, value: Int)] = []
    private var scheduled = false

    var isIdle: Bool { lock.lock(); defer { lock.unlock() }; return !scheduled }

    func set(unit: Int, prm: Int, value: Int, on queue: DispatchQueue, device: G5Device) {
        lock.lock()
        pending.removeAll { $0.unit == unit && $0.prm == prm }
        pending.append((unit, prm, value))
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.async { self.flush(device) } }
    }

    private func flush(_ device: G5Device) {
        while true {
            lock.lock()
            let items = pending; pending = []
            if items.isEmpty { scheduled = false; lock.unlock(); return }
            lock.unlock()
            for i in items { try? device.sendParam(unit: i.unit, prm: i.prm, value: i.value) }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable { case searching, connected(String), disconnected(String) }
    struct Job: Equatable { var title: String; var done: Int; var total: Int }
    struct BackupFile: Identifiable, Hashable { var url: URL; var id: URL { url }; var date: Date }

    @Published var status: Status = .searching { didSet { log("status: \(status)") } }
    @Published var pedalPatches: [G5Patch] = []
    @Published var backups: [BackupFile] = []
    @Published var job: Job?
    @Published var message: String?
    @Published var errorText: String? { didSet { if let e = errorText { log("error: \(e)") } } }

    // Editor
    @Published var editing: EditSession? { didSet { if editing?.slot != oldValue?.slot { log("editing slot \(editing.map { "\($0.slot + 1) \($0.patch.name)" } ?? "-")") } } }
    @Published var selectedUnit = 0
    @Published var switching = false
    @Published var browserUnit: Int?

    let device = G5Device()
    let queue = DispatchQueue(label: "g5.device")   // all pedal I/O is serialised here
    private let sender = ParamSender()
    private var lastLocalEdit = Date.distantPast
    private var polling = false
    private var pollTimer: Timer?

    init() {
        device.midi.onSetupChanged = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.connect() }
        }
        refreshBackups()
        connect()
        Snapshot.schedule(self)
        SelfTest.schedule(self)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    var isConnected: Bool { if case .connected = status { return true }; return false }

    func connect() {
        guard job == nil else { return }
        queue.async { [device] in
            do {
                let id = try device.connect()
                DispatchQueue.main.async {
                    let wasConnected = self.isConnected
                    self.status = .connected(id.firmware)
                    if self.pedalPatches.isEmpty || !wasConnected { self.loadPedal() }
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = .disconnected(error.localizedDescription)
                    self.pedalPatches = []
                    self.editing = nil
                }
            }
        }
    }

    /// Runs pedal work off the main thread with a progress sheet.
    private func run(_ title: String, total: Int,
                     _ work: @escaping (G5Device, @escaping (Int, Int) -> Void) throws -> Void,
                     done: @escaping () -> Void = {}) {
        job = Job(title: title, done: 0, total: total)
        queue.async { [device] in
            let progress: (Int, Int) -> Void = { d, t in
                DispatchQueue.main.async { self.job?.done = d; self.job?.total = t }
            }
            do {
                try work(device, progress)
                DispatchQueue.main.async { self.job = nil; done(); self.resumeEditing() }
            } catch {
                DispatchQueue.main.async { self.job = nil; self.errorText = error.localizedDescription; self.resumeEditing() }
            }
        }
    }

    func loadPedal() {
        var got: [G5Patch] = []
        run("Reading patches from the G5…", total: Backup.patchCount, { d, p in
            got = try d.readAll(progress: p)
        }, done: {
            self.pedalPatches = got
            log("pedal patches: \(got.count)")
        })
    }

    /// After a backup/restore job, re-open the patch that is active on the pedal.
    private func resumeEditing() {
        guard isConnected, !pedalPatches.isEmpty else { return }
        queue.async { [device] in
            try? device.editorMode(true)
            let slot = (try? device.activeSlot()) ?? self.editingSlotSnapshot ?? 0
            DispatchQueue.main.async { self.openPatch(slot, force: true) }
        }
    }
    nonisolated(unsafe) private var editingSlotSnapshot: Int?

    func backUpNow() {
        var url: URL?
        var got: [G5Patch] = []
        run("Backing up all patches…", total: Backup.patchCount, { d, p in
            got = try d.readAll(progress: p)
            url = try Self.save(got)
        }, done: {
            self.pedalPatches = got
            self.refreshBackups()
            self.message = "Saved \(got.count) patches to “\(url!.lastPathComponent)”."
        })
    }

    nonisolated private static func save(_ patches: [G5Patch]) throws -> URL {
        try FileManager.default.createDirectory(at: Backup.defaultFolder, withIntermediateDirectories: true)
        let url = Backup.timestampedURL()
        try Backup.write(patches, to: url)
        guard try Backup.read(url) == patches.sorted(by: { $0.slot < $1.slot }) else {
            throw G5Error.badReply("backup file didn't verify")
        }
        return url
    }

    /// Restores patches. Always saves a safety backup of the pedal first.
    func restore(_ patches: [G5Patch], from name: String) {
        var safety: URL?
        var current: [G5Patch] = []
        run("Restoring \(patches.count) patch\(patches.count == 1 ? "" : "es")…", total: Backup.patchCount + patches.count, { d, p in
            current = try d.readAll { i, _ in p(i, Backup.patchCount + patches.count) }
            safety = try Self.save(current)
            let todo = patches.filter { new in current.first { $0.slot == new.slot }?.data != new.data }
            try d.writePatches(todo) { i, _ in p(Backup.patchCount + i, Backup.patchCount + todo.count) }
            current = try d.readAll { _, _ in }
        }, done: {
            self.pedalPatches = current
            self.refreshBackups()
            self.message = "Restored \(patches.count) patch\(patches.count == 1 ? "" : "es") from “\(name)”. "
                + "A safety backup of the previous pedal contents was saved as “\(safety!.lastPathComponent)”."
        })
    }

    /// Writes a 3-patch bank from the Sound Patcher: full safety backup, write, verify. `done` gets the backup's URL.
    func applyBank(_ bank: BankSpec.Resolved, spec: BankSpec, bank number: Int, done: @escaping (URL?) -> Void) {
        var safety: URL?
        var fresh: [G5Patch] = []
        let slots = (0..<3).map { (number - 1) * 3 + $0 }
        run("Writing bank \(number)…", total: Backup.patchCount + bank.patches.count, { d, p in
            let all = try d.readAll { i, _ in p(i, Backup.patchCount + bank.patches.count) }
            safety = try Self.save(all)
            var n = 0
            try bank.apply(to: d, bank: number) { line in n += 1; log("bank \(number):" + line); p(Backup.patchCount + n, Backup.patchCount + bank.patches.count) }
            try d.editorMode(true)
            fresh = try slots.map { try d.readPatch($0) }
            Self.keep(spec, bank: number)
        }, done: {
            for f in fresh { if let i = self.pedalPatches.firstIndex(where: { $0.slot == f.slot }) { self.pedalPatches[i] = f } }
            self.refreshBackups()
            done(safety)
        })
        if job == nil { done(nil) }
    }

    /// Keeps a copy of every bank the Sound Patcher wrote, next to the backups.
    nonisolated private static func keep(_ spec: BankSpec, bank: Int) {
        let dir = Backup.defaultFolder.appendingPathComponent("Sound Patcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = (spec.title ?? "bank").filter { !"/:\\".contains($0) }.prefix(60)
        try? Data(spec.json().utf8).write(to: dir.appendingPathComponent("\(f.string(from: Date())) bank \(bank) - \(safe).json"))
    }

    func refreshBackups() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Backup.defaultFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        backups = urls.filter { $0.pathExtension.lowercased() == "syx" }.map {
            BackupFile(url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "syx")!]
        panel.message = "Choose a G5 backup (.syx) to add to your backups"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            _ = try Backup.read(src)
            try FileManager.default.createDirectory(at: Backup.defaultFolder, withIntermediateDirectories: true)
            let dst = Backup.defaultFolder.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(at: src, to: dst) }
            refreshBackups()
        } catch { errorText = error.localizedDescription }
    }

    // MARK: - Editing

    /// Switches the pedal to `slot` and loads it into the editor.
    func openPatch(_ slot: Int, force: Bool = false) {
        guard isConnected, job == nil else { return }
        if !force, editing?.slot == slot { return }
        switching = true
        editingSlotSnapshot = slot
        queue.async { [device] in
            do {
                try device.selectPatch(slot)
                var buf = try device.readEditBuffer()
                // The pedal may need a moment; make sure we really are on the right patch.
                if (try? device.activeSlot()) != slot {
                    try device.selectPatch(slot); buf = try device.readEditBuffer()
                }
                DispatchQueue.main.async {
                    self.switching = false
                    let keepUnit = self.editing?.slot == slot
                    let original = (self.editing?.slot == slot ? self.editing?.original : nil) ?? buf
                    self.editing = EditSession(slot: slot, patch: buf, original: original)
                    if !keepUnit {
                        self.selectedUnit = (0..<PatchData.unitCount).first { !(buf.type($0)?.isEmpty ?? true) } ?? 0
                    }
                    self.updateLibrary(slot, buf)
                }
            } catch {
                DispatchQueue.main.async { self.switching = false; self.errorText = error.localizedDescription }
            }
        }
    }

    private func updateLibrary(_ slot: Int, _ p: PatchData) {
        if let i = pedalPatches.firstIndex(where: { $0.slot == slot }), pedalPatches[i].patchData != p {
            pedalPatches[i] = G5Patch(slot: slot, patchData: p)
        }
    }

    private func mutate(_ change: (inout PatchData) -> Void) {
        guard var e = editing else { return }
        change(&e.patch)
        editing = e
        lastLocalEdit = Date()
        updateLibrary(e.slot, e.patch)
    }

    func setOn(_ unit: Int, _ on: Bool) {
        mutate { $0.setOn(unit, on) }
        sender.set(unit: unit, prm: 0, value: on ? 1 : 0, on: queue, device: device)
    }

    func setParam(_ unit: Int, _ prm: Int, _ value: Int) {
        mutate { $0.setParam(unit, prm, value) }
        sender.set(unit: unit, prm: prm, value: value, on: queue, device: device)
    }

    func setLevel(_ v: Int) {
        mutate { $0.level = v }
        sender.set(unit: 9, prm: 2, value: v, on: queue, device: device)
    }

    func setFootswitch(_ v: Int) {
        mutate { $0.footswitch = v }
        sender.set(unit: 9, prm: 3, value: v, on: queue, device: device)
    }

    /// Changes the effect type; the pedal fills in default settings, so we read them back.
    func setType(_ unit: Int, _ typeID: Int) {
        guard let e = editing else { return }
        var typeID = typeID
        let z = e.patch.zSlot
        if typeID == EffectCatalog.emptyID && unit == z { typeID = EffectCatalog.zpNoneID }   // "empty" on the Z slot is ZP-None
        let wanted = EffectCatalog.shared.type(typeID)
        // The G5 keeps one Z-Pedal slot per patch; check both directions before the pedal silently rewrites the unit.
        if let w = wanted, let z {
            if unit == z && !w.zpedal {
                errorText = "Effect \(z + 1) is this patch's Z-Pedal slot. On the G5 it can only hold a Z-Pedal effect (choose ZP-None to leave it empty). Pick another effect slot for “\(w.name)”."
                return
            }
            if unit != z && w.zpedal {
                errorText = "Z-Pedal effects can only go in this patch's Z-Pedal slot, effect \(z + 1) (now “\(e.patch.type(z)?.name ?? "")”). Change that effect instead."
                return
            }
        }
        lastLocalEdit = Date()
        mutate { $0.setField(unit * 96 + 1, 8, typeID) }
        queue.async { [device] in
            do {
                try device.sendParam(unit: unit, prm: 1, value: typeID)
                Thread.sleep(forTimeInterval: 0.3)
                let buf = try device.readEditBuffer()
                DispatchQueue.main.async {
                    guard var s = self.editing, s.slot == e.slot else { return }
                    s.patch = buf; self.editing = s
                    self.updateLibrary(s.slot, buf)
                    if buf.typeID(unit) != typeID {
                        self.errorText = "The pedal didn't accept “\(wanted?.name ?? "this effect")” in effect \(unit + 1) and set it to “\(buf.type(unit)?.name ?? "another effect")” instead."
                    }
                }
            } catch { DispatchQueue.main.async { self.errorText = error.localizedDescription } }
        }
    }

    /// Sends the whole patch (used for reordering and renaming).
    private func sendWhole() {
        guard let p = editing?.patch else { return }
        lastLocalEdit = Date()
        queue.async { [device] in try? device.sendEditBuffer(p) }
    }

    func move(_ from: Int, to: Int) {
        guard from != to else { return }
        mutate { $0.moveUnit(from: from, to: to) }
        if selectedUnit == from { selectedUnit = to }
        sendWhole()
    }

    func rename(_ name: String) {
        guard editing?.patch.name != name else { return }
        mutate { $0.name = name }
        sendWhole()
    }

    func revert() {
        guard let e = editing else { return }
        mutate { $0 = e.original }
        let p = e.original
        queue.async { [device] in
            do { try device.sendEditBuffer(p); try device.store(p, slot: e.slot); try device.editorMode(true) }
            catch { DispatchQueue.main.async { self.errorText = error.localizedDescription } }
        }
    }

    func saveNow() {
        guard let e = editing else { return }
        let p = e.patch
        queue.async { [device] in
            do {
                try device.store(p, slot: e.slot); try device.editorMode(true)
                DispatchQueue.main.async { self.message = "“\(p.name)” is saved on the pedal (patch \(Self.label(e.slot)))." }
            } catch { DispatchQueue.main.async { self.errorText = error.localizedDescription } }
        }
    }

    nonisolated static func label(_ slot: Int) -> String { String(format: "%02d-%d", slot / 3 + 1, slot % 3 + 1) }

    /// Follows changes made on the pedal itself (knobs turned, patch switched).
    private func poll() {
        guard let e = editing, isConnected, job == nil, !switching, !polling, sender.isIdle,
              Date().timeIntervalSince(lastLocalEdit) > 2.5 else { return }
        polling = true
        queue.async { [device] in
            let active = try? device.activeSlot()
            let buf = try? device.readEditBuffer()
            DispatchQueue.main.async {
                self.polling = false
                guard let buf, let active, Date().timeIntervalSince(self.lastLocalEdit) > 2.5,
                      let cur = self.editing, cur.slot == e.slot, !self.switching else { return }
                if active != cur.slot {
                    let orig = self.pedalPatches.first { $0.slot == active }?.patchData ?? buf
                    self.editing = EditSession(slot: active, patch: buf, original: orig)
                    self.selectedUnit = (0..<PatchData.unitCount).first { !(buf.type($0)?.isEmpty ?? true) } ?? 0
                } else if buf != cur.patch {
                    var s = cur; s.patch = buf; self.editing = s
                }
                self.updateLibrary(active, buf)
            }
        }
    }
}
