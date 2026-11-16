import SwiftUI
import G5Core

/// Owns the live "hear the G5 through another sound card" route and its settings.
final class MonitorController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var outputs: [AudioDevice] = []
    @Published var outputUID: String { didSet { UserDefaults.standard.set(outputUID, forKey: "monitorOutput"); if isOn { restart() } } }
    @Published var volume: Double { didSet { monitor?.gain = Float(volume * volume); UserDefaults.standard.set(volume, forKey: "monitorVolume") } }
    @Published private(set) var level: Float = 0
    @Published private(set) var info = ""
    @Published var errorText: String?
    @Published private(set) var g5Present = false

    private var monitor: AudioMonitor?
    private var timer: Timer?
    /// Remembered so monitoring comes back by itself when the app starts or the pedal is re-plugged.
    private var wanted: Bool { didSet { UserDefaults.standard.set(wanted, forKey: "monitorOn") } }

    init() {
        let d = UserDefaults.standard
        outputUID = d.string(forKey: "monitorOutput") ?? ""
        volume = d.object(forKey: "monitorVolume") as? Double ?? 1
        wanted = d.bool(forKey: "monitorOn")
        refreshDevices()
        CoreAudioDevices.observeDeviceList { [weak self] in self?.refreshDevices() }
    }

    var selectedOutput: AudioDevice? { outputs.first { $0.uid == outputUID } }

    func toggle() { isOn ? stop(userInitiated: true) : start() }

    func start() {
        wanted = true
        guard let input = CoreAudioDevices.zoomInput() else {
            errorText = "The G5's USB audio isn't available. Check that the pedal is connected."; return
        }
        guard let output = selectedOutput else { errorText = "Choose an output for the monitor."; return }
        stop(userInitiated: false)
        do {
            let m = try AudioMonitor(input: input, output: output)
            m.gain = Float(volume * volume)
            try m.start()
            monitor = m
            isOn = true
            info = String(format: "%.1f → %.1f kHz", m.inputRate / 1000, m.outputRate / 1000)
            log("monitor on: \(input.name) -> \(output.name)")
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func stop(userInitiated: Bool) {
        if userInitiated { wanted = false }
        timer?.invalidate(); timer = nil
        monitor?.stop(); monitor = nil
        if isOn { log("monitor off") }
        isOn = false; level = 0
    }

    private func restart() { stop(userInitiated: false); start() }

    private func tick() {
        guard let m = monitor else { return }
        let s = m.takeStats()
        level = max(s.inputPeak, level * 0.8)                     // smooth fall-off for the meter
        info = String(format: "On · %.0f ms delay", s.latencyMs)
    }

    private func refreshDevices() {
        outputs = CoreAudioDevices.outputs()
        g5Present = CoreAudioDevices.zoomInput() != nil
        if selectedOutput == nil {
            // First run (or the saved device is gone): prefer the HD USB interface, else the Mac's default output.
            let def = CoreAudioDevices.defaultOutputID()
            outputUID = (outputs.first { $0.name.localizedCaseInsensitiveContains("HD USB") }
                         ?? outputs.first { $0.id == def } ?? outputs.first)?.uid ?? outputUID
        }
        if isOn, let m = monitor, !(g5Present && outputs.contains { $0.uid == m.output.uid }) {
            stop(userInitiated: false)                            // a device was unplugged
        } else if !isOn, wanted, g5Present, selectedOutput != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in   // let a new device settle
                guard let self, !self.isOn, self.wanted else { return }
                self.start()
            }
        }
    }
}

/// Sidebar section: on/off, output picker, volume and an input meter.
struct MonitorSection: View {
    @EnvironmentObject var monitor: MonitorController

    var body: some View {
        Section("Monitor") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: monitor.isOn ? "headphones.circle.fill" : "headphones.circle")
                        .font(.system(size: 18)).foregroundStyle(monitor.isOn ? Palette.accent : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Play through Mac").font(.system(size: 12, weight: .semibold))
                        Text(monitor.isOn ? monitor.info : (monitor.g5Present ? "Off" : "Waiting for the G5…"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { monitor.isOn }, set: { $0 ? monitor.start() : monitor.stop(userInitiated: true) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                Picker("Output", selection: $monitor.outputUID) {
                    ForEach(monitor.outputs) { Text($0.name).tag($0.uid) }
                }
                .controlSize(.small)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $monitor.volume, in: 0...1.4).controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                }
                .help("Monitor volume")
                LevelMeter(level: monitor.level).opacity(monitor.isOn ? 1 : 0.35)
            }
            .padding(.vertical, 4)
        }
        .alert("Monitor", isPresented: Binding(get: { monitor.errorText != nil }, set: { if !$0 { monitor.errorText = nil } })) {
            Button("OK") {}
        } message: { Text(monitor.errorText ?? "") }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(Double(level), 0.00001))
            let frac = max(0, min(1, (db + 60) / 60))                 // -60 dBFS … 0 dBFS
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * frac) }
            }
        }
        .frame(height: 5)
        .help("Signal coming from the G5")
    }
}
