import SwiftUI
import AppKit
import G5Core

// MARK: - AI provider: Claude Code in headless mode

/// Runs the user's own Claude Code CLI (`claude -p`), so requests use their existing subscription.
/// Only the web tools are enabled: the AI can research a song but can't touch files or run commands.
final class ClaudeCodeProvider {
    struct Reply { var text: String; var sessionID: String?; var isError: Bool }

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private var process: Process?

    /// Sends one message. `activity` gets short progress notes ("Searching the web: …"); `done` the final reply.
    /// Both are called on the main thread.
    func send(_ message: String, system: String, resume: String?, model: String?,
              activity: @escaping (String) -> Void, done: @escaping (Reply) -> Void) {
        guard let exe = Self.locate() else {
            done(Reply(text: "Claude Code isn't installed on this Mac.", sessionID: nil, isError: true)); return
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("G5 Editor/Sound Patcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var args = ["-p", message, "--output-format", "stream-json", "--verbose",
                    "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch",
                    "--strict-mcp-config", "--append-system-prompt", system]
        if let resume { args += ["--resume", resume] }
        if let model { args += ["--model", model] }

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDECODE" || k == "AI_AGENT" { env[k] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice

        var buffer = Data(), final: Reply?, session: String?, errText = ""
        let lock = NSLock()
        func handle(line: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let s = obj["session_id"] as? String { session = s }
            switch obj["type"] as? String {
            case "assistant":
                let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                for c in content where c["type"] as? String == "tool_use" {
                    let input = c["input"] as? [String: Any]
                    let note: String
                    switch c["name"] as? String {
                    case "WebSearch": note = "Searching the web: \(input?["query"] as? String ?? "")"
                    case "WebFetch": note = "Reading \(URL(string: input?["url"] as? String ?? "")?.host ?? "a page")"
                    default: note = "Working…"
                    }
                    DispatchQueue.main.async { activity(note) }
                }
            case "result":
                final = Reply(text: obj["result"] as? String ?? "", sessionID: session, isError: obj["is_error"] as? Bool ?? false)
            default: break
            }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]; buffer.removeSubrange(buffer.startIndex...nl)
                handle(line: Data(line))
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            lock.lock(); errText += s; lock.unlock()
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            if !buffer.isEmpty { handle(line: buffer); buffer.removeAll() }
            let reply = final ?? Reply(text: proc.terminationReason == .uncaughtSignal ? "Stopped."
                                       : "Claude Code ended without a reply. \(errText.prefix(400))", sessionID: session, isError: true)
            lock.unlock()
            DispatchQueue.main.async { done(reply) }
        }
        do { try p.run(); process = p } catch {
            done(Reply(text: "Couldn't start Claude Code: \(error.localizedDescription)", sessionID: nil, isError: true))
        }
    }

    func cancel() { process?.terminate() }
}

// MARK: - Chat state

@MainActor
final class PatcherController: ObservableObject {
    struct Proposal {
        var spec: BankSpec
        var resolved: BankSpec.Resolved
        var bank: Int
        var written: URL?          // safety backup taken when it was written
        var undone = false
    }
    struct Message: Identifiable {
        enum Role { case user, assistant, note, error }
        let id = UUID()
        var role: Role
        var text: String
        var proposal: Proposal?
    }

    @Published var isOpen = false { didSet { UserDefaults.standard.set(isOpen, forKey: "patcherOpen") } }
    @Published var messages: [Message] = []
    @Published var draft = ""
    @Published var busy = false
    @Published var activity = ""
    @Published var started: Date?
    @Published var bank = 99
    @Published var confirmWrite: UUID?

    weak var model: AppModel?
    private let provider = ClaudeCodeProvider()
    private var session: String?
    private var fixAttempts = 0

    var available: Bool { ClaudeCodeProvider.locate() != nil }

    init() { isOpen = UserDefaults.standard.bool(forKey: "patcherOpen") }

    func toggle() { isOpen.toggle() }

    func newChat() {
        provider.cancel()
        messages = []; session = nil; busy = false; activity = ""
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        messages.append(Message(role: .user, text: text))
        fixAttempts = 0
        let bank = self.bank
        // Tell the AI what the target bank holds right now (including knob tweaks made on the pedal).
        currentBank(bank) { current in
            var ctx = "[G5 Editor] Target bank: \(bank) (patches \(bank)-1, \(bank)-2, \(bank)-3)."
            if let current {
                ctx += " It currently holds (read from the pedal just now):\n```json\n\(current.json())\n```"
            } else {
                ctx += " The pedal isn't connected, so its current contents are unknown."
            }
            self.ask(ctx + "\n\nUser: " + text)
        }
    }

    func stop() { provider.cancel() }

    private func ask(_ prompt: String) {
        busy = true; activity = "Thinking…"; started = Date()
        provider.send(prompt, system: Self.systemPrompt, resume: session, model: nil,
                      activity: { [weak self] in self?.activity = $0 },
                      done: { [weak self] in self?.received($0) })
    }

    private func received(_ r: ClaudeCodeProvider.Reply) {
        busy = false; activity = ""
        if let s = r.sessionID { session = s }
        if r.isError {
            var t = r.text
            if t.localizedCaseInsensitiveContains("not logged in") || t.contains("/login") {
                t += "\n\nClaude Code on this Mac isn't logged in. Open Terminal, run `claude auth login` (or `claude`, then `/login`) and sign in with your Claude account. Then send the message again."
            }
            messages.append(Message(role: .error, text: t)); return
        }
        let (spec, decodeError, prose) = BankSpec.extract(from: r.text)
        var msg = Message(role: .assistant, text: prose.isEmpty ? (spec == nil ? r.text : "") : prose)
        var problems: String?
        if let decodeError { problems = decodeError }
        if let spec {
            switch spec.validate() {
            case .success(let res): msg.proposal = Proposal(spec: spec, resolved: res, bank: bank)
            case .failure(let e): problems = e.description
            }
        }
        messages.append(msg)
        if let problems {
            guard fixAttempts < 2 else {
                messages.append(Message(role: .error, text: "The bank still doesn't fit the G5:\n\(problems)")); return
            }
            fixAttempts += 1
            messages.append(Message(role: .note, text: "Fixing the bank so it fits the G5…"))
            ask("[G5 Editor] The app couldn't use that bank. Problems:\n\(problems)\n\nSend the corrected, complete bank JSON (all patches) with a one-line note on what changed.")
        }
    }

    private func currentBank(_ bank: Int, _ done: @escaping (BankSpec?) -> Void) {
        guard let model, model.isConnected, model.job == nil else { done(nil); return }
        let slots = (0..<3).map { (bank - 1) * 3 + $0 }
        model.queue.async { [device = model.device] in
            try? device.editorMode(true)
            let ps = slots.compactMap { try? device.readPatch($0).patchData }
            DispatchQueue.main.async { done(ps.count == 3 ? BankSpec(describing: ps) : nil) }
        }
    }

    // MARK: writing

    func write(_ id: UUID) {
        guard let model, let i = messages.firstIndex(where: { $0.id == id }), let p = messages[i].proposal else { return }
        model.applyBank(p.resolved, spec: p.spec, bank: p.bank) { [weak self] backup in
            guard let self, let backup, let j = self.messages.firstIndex(where: { $0.id == id }) else { return }
            self.messages[j].proposal?.written = backup
            self.messages[j].proposal?.undone = false
            self.messages.append(Message(role: .note, text: "Written to bank \(p.bank) and verified. The previous contents are in “\(backup.lastPathComponent)”."))
            self.bank = p.bank
        }
    }

    func undo(_ id: UUID) {
        guard let model, let i = messages.firstIndex(where: { $0.id == id }), let p = messages[i].proposal, let url = p.written,
              let all = try? Backup.read(url) else { return }
        let slots = Set((0..<3).map { (p.bank - 1) * 3 + $0 })
        model.restore(all.filter { slots.contains($0.slot) }, from: url.lastPathComponent)
        messages[i].proposal?.undone = true
    }

    // MARK: prompt

    static let systemPrompt: String = """
    You are the AI Sound Patcher inside G5 Editor, a Mac editor for the original ZOOM G5 guitar multi-effects pedal (firmware 1.20).
    The user asks for guitar tones, usually for a song, and you fill one bank: three patches X-1, X-2, X-3 (for example clean / rhythm / lead, or whatever parts the user names).
    Each message from the app starts with "[G5 Editor]" and tells you the target bank and what it holds now. Changes the user asks for apply to that bank; keep what they didn't ask to change, including knob values they tuned themselves.

    How to answer:
    - Reply in the language the user writes in. Be brief: what each patch is for, the key choices, and tips (pickup, what to tweak).
    - Whenever you propose or change a bank, end your reply with exactly one ```json block holding the complete bank (all patches). The app validates it and shows a preview; the user decides whether to write it. Without a bank change, send no JSON.
    - Research before you design a song's tones: use web search to check the guitarist's gear on that recording and the song's tempo (BPM). Set delay times from the tempo (quarter note ms = 60000 / BPM; dotted eighth = 0.75 × that). List your sources (titles or sites) in one short line, and say plainly what you couldn't verify. You can't hear recordings; never claim you did.

    Bank JSON:
    {"title": "...", "notes": "...", "patches": [
      {"name": "...", "level": 100, "zpedal": "ZP-None", "notes": "...",
       "effects": [{"effect": "COMP", "on": true, "params": {"Sense": 5, "ATTCK": "Fast"}}]}]}
    Rules (the app rejects anything else):
    - name: 1–10 characters; letters, digits, space and !#$%&'()+,-.;=@[]^_`{}~ only. Uppercase reads best on the pedal.
    - level: patch level 0–120. Keep the three patches balanced (about 100); a lead may be 5–10 higher.
    - effects: up to 8, in signal order (input first). Use effect and knob names exactly as in the catalog below. Omitted knobs get the pedal's defaults; "on" defaults to true.
    - Knob values are what the pedal displays (delay Time in ms). For knobs listed with {a|b|...} use one of those labels as a string. Tempo-synced note values aren't available; give delay times in ms.
    - zpedal: the patch's single Z-Pedal slot. Only Z-Pedal effects (the "Z-Pedal" group) go there, and they go nowhere else. Use "ZP-None" when the expression pedal isn't needed.
    - Amps include a cabinet knob (CAB); pick the matching cabinet unless there's a reason not to. A noise gate (ZNR) first helps high-gain patches.
    - No DSP limit has been hit on this pedal, so don't leave effects out for CPU reasons.
    - The user listens through the Mac or an amp; assume GLOBAL OUTPUT = DIRECT (full-range) unless told otherwise.

    Effect catalog (name — what it models. Knobs with displayed ranges):
    """ + BankSpec.catalogReference()
}

// MARK: - Panel

struct PatcherPanel: View {
    @EnvironmentObject var patcher: PatcherController
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !patcher.available {
                ContentUnavailableView {
                    Label("Claude Code not found", systemImage: "sparkles")
                } description: {
                    Text("The Sound Patcher uses Claude Code on this Mac, with your own Claude subscription. Install it from claude.com/claude-code, run `claude` once in Terminal to log in, then reopen this panel.")
                }
            } else {
                transcript
                Divider()
                composer
            }
        }
        .frame(minWidth: 320, idealWidth: 380)
        .background(Palette.background)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { patcher.confirmWrite != nil }, set: { if !$0 { patcher.confirmWrite = nil } })) {
            Button("Write to Bank \(proposal(patcher.confirmWrite)?.bank ?? 0)", role: .destructive) {
                if let id = patcher.confirmWrite { patcher.write(id) }
                patcher.confirmWrite = nil
            }
        } message: {
            Text("This replaces \(currentNames(proposal(patcher.confirmWrite)?.bank ?? 0)). A backup of every patch is saved first, so you can undo this.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Palette.accent)
            Text("Sound Patcher").font(.headline)
            Spacer()
            Stepper(value: $patcher.bank, in: 1...99) {
                Text("Bank \(String(format: "%02d", patcher.bank))").font(.callout.monospacedDigit())
            }
            .help("The bank (3 patches) the AI fills")
            Button { patcher.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("New chat")
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if patcher.messages.isEmpty { intro }
                    ForEach(patcher.messages) { m in MessageView(message: m).id(m.id) }
                    if patcher.busy { progress.id("busy") }
                }.padding(12)
            }
            .onChange(of: patcher.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(patcher.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: patcher.busy) { _, b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask for the guitar tones of a song. The AI researches the gear and tempo, then fills bank \(String(format: "%02d", patcher.bank)) with three patches. You see a preview first; nothing is written until you click Write.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(["Gravity by John Mayer: clean, rhythm and solo", "Make the clean patch brighter", "Less gain on the rhythm patch"], id: \.self) { s in
                Button(s) { patcher.draft = s }.buttonStyle(.link).font(.callout)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(patcher.activity)  \(Int(Date().timeIntervalSince(patcher.started ?? Date()))) s")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Stop") { patcher.stop() }.controlSize(.small)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Song and parts, or what to change…", text: $patcher.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
                .onSubmit { patcher.send() }
            Button { patcher.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(patcher.busy || patcher.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(10)
    }

    private func proposal(_ id: UUID?) -> PatcherController.Proposal? { patcher.messages.first { $0.id == id }?.proposal }
    private var confirmTitle: String { "Write the new patches to bank \(proposal(patcher.confirmWrite)?.bank ?? 0)?" }
    private func currentNames(_ bank: Int) -> String {
        guard bank > 0 else { return "these patches" }
        let names = (0..<3).map { i -> String in
            let s = (bank - 1) * 3 + i
            return "\(AppModel.label(s)) “\(model.pedalPatches.first { $0.slot == s }?.name ?? "?")”"
        }
        return names.joined(separator: ", ")
    }
}

struct MessageView: View {
    @EnvironmentObject var patcher: PatcherController
    @EnvironmentObject var model: AppModel
    let message: PatcherController.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack { Spacer(minLength: 40); bubble(message.text, Palette.accent.opacity(0.25)) }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty { markdown(message.text).textSelection(.enabled) }
                if let p = message.proposal { ProposalCard(proposal: p, id: message.id) }
            }
        case .note:
            Label(message.text, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .error:
            Label { markdown(message.text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .font(.callout)
        }
    }

    private func bubble(_ s: String, _ c: Color) -> some View {
        Text(s).textSelection(.enabled).padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(c))
    }

    private func markdown(_ s: String) -> some View {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
            .font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}

struct ProposalCard: View {
    @EnvironmentObject var patcher: PatcherController
    @EnvironmentObject var model: AppModel
    let proposal: PatcherController.Proposal
    let id: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = proposal.spec.title { Text(t).font(.subheadline.weight(.semibold)) }
            ForEach(Array(proposal.resolved.patches.enumerated()), id: \.offset) { i, p in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(String(format: "%02d-%d", proposal.bank, i + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(p.name).font(.system(size: 12, weight: .bold, design: .monospaced))
                        Spacer()
                        Text("level \(p.level.map(String.init) ?? "–")").font(.caption).foregroundStyle(.secondary)
                    }
                    Flow(spacing: 4) {
                        ForEach(Array(p.units.enumerated()), id: \.offset) { _, u in chip(u) }
                        if !p.zpedal.isEmpty { chip(name: "Z: \(p.zpedal.name)", color: EffectGroup.zpedal.color, on: true) }
                    }
                    if let n = proposal.spec.patches[i].notes { Text(n).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            DisclosureGroup("Knob settings") {
                Text(knobText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption)
            HStack {
                if let url = proposal.written {
                    if proposal.undone {
                        Label("Undone", systemImage: "arrow.uturn.backward").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Written to bank \(proposal.bank)", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                        Spacer()
                        Button("Undo") { patcher.undo(id) }.controlSize(.small)
                            .help("Restore bank \(proposal.bank) from “\(url.lastPathComponent)”")
                            .disabled(!model.isConnected || model.job != nil)
                    }
                } else {
                    Spacer()
                    Button("Write to Bank \(String(format: "%02d", proposal.bank))") { patcher.confirmWrite = id }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.small)
                        .disabled(!model.isConnected || model.job != nil)
                        .help(model.isConnected ? "Back up, write the three patches and verify them" : "Connect the G5 first")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.panelLine))
    }

    private func chip(_ u: BankSpec.Resolved.Unit) -> some View { chip(name: u.type.name, color: u.type.group.color, on: u.on) }
    private func chip(name: String, color: Color, on: Bool) -> some View {
        Text(name).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(on ? 0.85 : 0.3)))
            .foregroundStyle(.white)
    }

    private var knobText: String {
        proposal.resolved.patches.enumerated().map { i, p in
            "\(proposal.bank)-\(i + 1) \(p.name)\n" + p.units.map { u in
                "  \(u.on ? "" : "(off) ")\(u.type.name): " + u.raw.map { r in
                    let prm = u.type.params.first { $0.prm == r.prm }
                    return "\(r.name) \(prm?.display(r.raw) ?? String(r.raw))"
                }.joined(separator: ", ")
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// Wrapping row of small views.
struct Flow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing; row = max(row, z.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, w), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + z.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}
