import SwiftUI
import AppKit
import G5Core

/// What the level check found, shown under the meter.
enum LevelWarning: Equatable {
    case g5Clipping        // the G5 itself is sending full-scale audio
    case monitorClipping   // only the Mac side clips: monitor volume above unity

    var title: String {
        switch self {
        case .g5Clipping: "Clipping at the G5"
        case .monitorClipping: "Monitor volume too high"
        }
    }
    var advice: String {
        switch self {
        case .g5Clipping: "The G5 is sending a signal that hits 0 dB, which sounds harsh and distorted. Lower MASTER LEVEL on the G5 (around 70) or this patch's PATCH LEVEL."
        case .monitorClipping: "The G5's signal is fine, but the monitor volume pushes it past 0 dB on the Mac. Bring the slider back toward 100% and turn up your speakers or amp instead."
        }
    }
}

/// IO buffer size for the monitor: smaller is less delay, larger survives a busy or older Mac.
enum MonitorLatency: Int, CaseIterable, Identifiable {
    case low = 32, normal = 64, safe = 128
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .safe: "Safe"
        }
    }
}

/// Owns the live "hear the G5 through another sound card" route and its settings.
final class MonitorController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var outputs: [AudioDevice] = []
    @Published var outputUID: String { didSet { UserDefaults.standard.set(outputUID, forKey: "monitorOutput"); if isOn { restart() } } }
    @Published var latency: MonitorLatency { didSet { UserDefaults.standard.set(latency.rawValue, forKey: "monitorBuffer"); if isOn { restart() } } }
    @Published var volume: Double { didSet { applyGain(); UserDefaults.standard.set(volume, forKey: "monitorVolume") } }
    /// Set by the tuner: silences the monitor without turning it off.
    @Published var tunerMuted = false { didSet { applyGain() } }
    private func applyGain() { monitor?.gain = tunerMuted ? 0 : Float(volume * volume) }
    @Published private(set) var level: Float = 0
    @Published private(set) var info = ""
    @Published var errorText: String?
    @Published private(set) var g5Present = false
    /// Set while monitoring is wanted but the audio route is down and being re-established.
    @Published private(set) var reconnecting = false
    @Published private(set) var warning: LevelWarning?

    private var monitor: AudioMonitor?
    private var timer: Timer?
    private var retry: DispatchWorkItem?
    /// Remembered so monitoring comes back by itself when the app starts or the pedal is re-plugged.
    private var wanted: Bool { didSet { UserDefaults.standard.set(wanted, forKey: "monitorOn") } }

    // Watchdog and level-check state, updated at 10 Hz.
    private var lastFrames = (input: 0, output: 0)
    private var stalledTicks = 0
    private var ticks = 0
    private var lastUnderruns = 0
    private var warningUntil = Date.distantPast

    init() {
        let d = UserDefaults.standard
        outputUID = d.string(forKey: "monitorOutput") ?? ""
        volume = d.object(forKey: "monitorVolume") as? Double ?? 1
        latency = MonitorLatency(rawValue: d.integer(forKey: "monitorBuffer")) ?? .low
        wanted = d.bool(forKey: "monitorOn")
        refreshDevices()
        CoreAudioDevices.observeDeviceList { [weak self] in self?.refreshDevices() }
        // Core Audio devices often come back with new IDs (or not at all) after sleep: rebuild the route.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.wanted else { return }
            log("monitor: woke from sleep, reconnecting")
            self.recover(after: 2)
        }
    }

    /// Debug rendering only.
    func preview(level: Float, warning: LevelWarning?) { isOn = true; info = "On · ~9 ms delay"; self.level = level; self.warning = warning }

    var selectedOutput: AudioDevice? { outputs.first { $0.uid == outputUID } }

    func toggle() { isOn ? stop(userInitiated: true) : start() }

    /// Starts monitoring. A user-initiated start reports problems in an alert; an automatic one retries quietly.
    func start(automatic: Bool = false) {
        wanted = true
        retry?.cancel(); retry = nil
        func fail(_ message: String) {
            if automatic {
                log("monitor: \(message) — retrying")
                recover(after: 3)
            } else {
                reconnecting = false
                errorText = message
            }
        }
        guard let input = CoreAudioDevices.zoomInput() else {
            return fail("The G5's USB audio isn't available. Check that the pedal is connected.")
        }
        guard let output = selectedOutput else { return fail("Choose an output for the monitor.") }
        stop(userInitiated: false)
        do {
            let m = try AudioMonitor(input: input, output: output, bufferFrames: UInt32(latency.rawValue))
            try m.start()
            monitor = m
            applyGain()
            isOn = true
            reconnecting = false
            lastFrames = (0, 0); stalledTicks = 0; ticks = 0; lastUnderruns = 0
            info = String(format: "%.1f → %.1f kHz", m.inputRate / 1000, m.outputRate / 1000)
            log("monitor on: \(input.name) -> \(output.name)")
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop(userInitiated: Bool) {
        if userInitiated {
            wanted = false
            retry?.cancel(); retry = nil
            reconnecting = false
        }
        timer?.invalidate(); timer = nil
        monitor?.stop(); monitor = nil
        if isOn { log("monitor off") }
        isOn = false; level = 0; warning = nil
    }

    private func restart() { stop(userInitiated: false); start() }

    /// Tears the route down and tries again shortly, for as long as monitoring is wanted.
    private func recover(after delay: Double) {
        stop(userInitiated: false)
        guard wanted else { return }
        reconnecting = true
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.wanted, !self.isOn else { return }
            self.outputs = CoreAudioDevices.outputs()
            self.g5Present = CoreAudioDevices.zoomInput() != nil
            self.start(automatic: true)
        }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func tick() {
        guard let m = monitor else { return }
        let s = m.takeStats()
        level = max(s.inputPeak, level * 0.8)                     // smooth fall-off for the meter
        info = String(format: "On · ~%.0f ms delay", s.latencyMs)
        if s.underruns > lastUnderruns {
            lastUnderruns = s.underruns
            if ticks > 20 { log("monitor: underrun #\(s.underruns) at \(latency.label) latency") }   // ignore start-up
        }
        ticks += 1

        // Watchdog: both sides must keep moving. A device that silently stopped (sleep, a USB hiccup,
        // another app taking it over) shows up as a frame counter that no longer grows.
        let moving = s.inputFrames > lastFrames.input && s.outputFrames > lastFrames.output
        lastFrames = (s.inputFrames, s.outputFrames)
        stalledTicks = moving ? 0 : stalledTicks + 1
        if stalledTicks >= 15 {                                   // 1.5 s without audio
            log("monitor: audio stalled (in \(s.inputFrames), out \(s.outputFrames)), reconnecting")
            return recover(after: 1)
        }
        // Once a second: the devices must still exist and run at the rates the resampler was built for.
        if ticks % 10 == 0 {
            let changed = CoreAudioDevices.sampleRate(m.input.id) != m.inputRate || CoreAudioDevices.sampleRate(m.output.id) != m.outputRate
            if !CoreAudioDevices.isAlive(m.input.id) || !CoreAudioDevices.isAlive(m.output.id) || changed {
                log("monitor: device \(changed ? "sample rate changed" : "went away"), reconnecting")
                return recover(after: 1)
            }
        }

        // Level check. 16-bit full scale is 32767/32768, so anything at -0.1 dBFS or above counts as clipping.
        let found: LevelWarning? = s.inputPeak >= 0.989 ? .g5Clipping
            : (s.outputPeak > 1.0 && !tunerMuted) ? .monitorClipping : nil
        if let found {
            if warning != found { log("monitor: \(found.title) (in \(s.inputPeak), out \(s.outputPeak))") }
            warning = found
            warningUntil = Date().addingTimeInterval(3)           // keep it up long enough to read
        } else if warning != nil, Date() > warningUntil {
            warning = nil
        }
    }

    private func refreshDevices() {
        outputs = CoreAudioDevices.outputs()
        let g5 = CoreAudioDevices.zoomInput()
        g5Present = g5 != nil
        if selectedOutput == nil {
            // First run (or the saved device is gone): prefer the HD USB interface, else the Mac's default output.
            let def = CoreAudioDevices.defaultOutputID()
            outputUID = (outputs.first { $0.name.localizedCaseInsensitiveContains("HD USB") }
                         ?? outputs.first { $0.id == def } ?? outputs.first)?.uid ?? outputUID
        }
        if isOn, let m = monitor {
            // Compare device IDs, not just names: a re-plugged device comes back with a new ID,
            // and the old route would stay "on" but silent.
            if g5?.id != m.input.id || !outputs.contains(where: { $0.id == m.output.id }) {
                log("monitor: devices changed, reconnecting")
                recover(after: 1)                                 // give a new device a moment to settle
            }
        } else if wanted, retry == nil, g5Present, selectedOutput != nil {
            recover(after: 1)
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
                        Text(monitor.isOn ? monitor.info
                             : monitor.reconnecting ? (monitor.g5Present ? "Reconnecting…" : "Waiting for the G5…")
                             : (monitor.g5Present ? "Off" : "G5 not connected"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { monitor.isOn || monitor.reconnecting }, set: { $0 ? monitor.start() : monitor.stop(userInitiated: true) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                Picker("Output", selection: $monitor.outputUID) {
                    ForEach(monitor.outputs) { Text($0.name).tag($0.uid) }
                }
                .controlSize(.small)
                Picker("Latency", selection: $monitor.latency) {
                    ForEach(MonitorLatency.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .help("Low has the least delay. If you hear clicks or dropouts, choose Normal or Safe.")
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $monitor.volume, in: 0...1.4).controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int((monitor.volume * 100).rounded()))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(monitor.volume > 1.005 ? .orange : .secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .help("Monitor volume. 100% plays the G5 at its own level; above that it can clip.")
                LevelMeter(level: monitor.level, clipping: monitor.warning != nil).opacity(monitor.isOn ? 1 : 0.35)
                if let w = monitor.warning {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                            Text(w.advice).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
                    .transition(.opacity)
                }
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
    var clipping = false
    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { g in
                let db = 20 * log10(max(Double(level), 0.00001))
                let frac = max(0, min(1, (db + 60) / 60))             // -60 dBFS … 0 dBFS
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * frac) }
                    // -6 dB mark: peaks around here leave comfortable headroom.
                    Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1).offset(x: g.size.width * 0.9)
                }
            }
            .frame(height: 5)
            Circle().fill(clipping ? Color.red : Color.white.opacity(0.1))
                .frame(width: 7, height: 7)
                .shadow(color: clipping ? .red : .clear, radius: 3)
        }
        .help("Signal coming from the G5. The tick marks -6 dB; the dot turns red when the signal clips.")
    }
}
