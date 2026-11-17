import SwiftUI
import G5Core

/// Reads the G5's USB audio and turns it into a stable note + cents reading.
final class TunerController: ObservableObject {
    @Published var isOpen = false { didSet { isOpen ? start() : stop() } }
    @Published private(set) var reading: NoteReading?
    @Published private(set) var level: Float = 0
    @Published var errorText: String?
    @Published var a4: Double { didSet { UserDefaults.standard.set(a4, forKey: "tunerA4") } }
    @Published var muteWhileTuning: Bool { didSet { UserDefaults.standard.set(muteWhileTuning, forKey: "tunerMute"); applyMute() } }

    weak var monitor: MonitorController?
    private var tap: AudioInputTap?
    private var detector: PitchDetector?
    private var timer: Timer?
    private let work = DispatchQueue(label: "tuner", qos: .userInteractive)
    private var busy = false
    private var recent: [Double] = []          // last few raw frequencies, for a median
    private var lastHeard = Date.distantPast

    init() {
        let d = UserDefaults.standard
        a4 = d.object(forKey: "tunerA4") as? Double ?? 440
        muteWhileTuning = d.object(forKey: "tunerMute") as? Bool ?? true
    }

    func toggle() { isOpen.toggle() }

    /// Debug rendering only: shows a fixed reading without audio.
    func preview(_ f: Double) { reading = NoteReading(freq: f, a4: a4); level = 0.3 }

    private func start() {
        guard let dev = CoreAudioDevices.zoomInput() else {
            errorText = "The G5's USB audio isn't available. Check that the pedal is connected."; return
        }
        let t = AudioInputTap(device: dev)
        do { try t.start() } catch { errorText = error.localizedDescription; return }
        tap = t
        detector = PitchDetector(sampleRate: t.sampleRate)
        recent = []; reading = nil
        applyMute()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in self?.tick() }
        log("tuner on")
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        tap?.stop(); tap = nil
        reading = nil; level = 0
        applyMute()
        log("tuner off")
    }

    private func applyMute() { monitor?.tunerMuted = isOpen && muteWhileTuning }

    private func tick() {
        guard !busy, let tap, let detector else { return }
        busy = true
        let a4 = a4
        work.async { [weak self] in
            let x = tap.latest(detector.windowSize)
            let peak = x.suffix(2048).map(abs).max() ?? 0
            let r = detector.detect(x)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.level = max(peak, self.level * 0.85)
                guard self.isOpen else { return }
                if let r, r.clarity > 0.6 {
                    // Restart the median when the note changes by more than a semitone.
                    if let m = self.recent.sorted()[safe: self.recent.count / 2], abs(1200 * log2(r.freq / m)) > 100 { self.recent = [] }
                    self.recent.append(r.freq)
                    if self.recent.count > 5 { self.recent.removeFirst() }
                    let median = self.recent.sorted()[self.recent.count / 2]
                    self.reading = NoteReading(freq: median, a4: a4)
                    self.lastHeard = Date()
                } else if Date().timeIntervalSince(self.lastHeard) > 1.2 {
                    self.reading = nil; self.recent = []
                }
            }
        }
    }
}

struct TunerView: View {
    @EnvironmentObject var tuner: TunerController

    private let strings = [(40, "E"), (45, "A"), (50, "D"), (55, "G"), (59, "B"), (64, "e")]   // standard tuning, MIDI numbers

    var body: some View {
        let r = tuner.reading
        let cents = r?.cents ?? 0
        let inTune = r.map { abs($0.cents) <= 3 } ?? false
        let tint: Color = r == nil ? .secondary : inTune ? .green : abs(cents) <= 12 ? .yellow : .orange

        VStack(spacing: 14) {
            HStack {
                Label("Tuner", systemImage: "tuningfork").font(.headline)
                Spacer()
                Button("Done") { tuner.isOpen = false }.keyboardShortcut(.cancelAction)
            }

            // Note name
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(r.map { String($0.name.prefix(1)) } ?? "–")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                if let r, r.name.count > 1 { Text("♯").font(.system(size: 44, weight: .bold, design: .rounded)) }
                if let r { Text("\(r.octave)").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.secondary) }
            }
            .foregroundStyle(tint)
            .frame(height: 110)

            Gauge(cents: cents, active: r != nil, tint: tint)
                .frame(height: 120)
                .animation(.easeOut(duration: 0.12), value: cents)

            HStack {
                Text(r.map { String(format: "%+.1f cents", $0.cents) } ?? "Play a single string")
                Spacer()
                Text(r.map { String(format: "%.2f Hz", $0.freq) } ?? "")
            }
            .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)

            // Standard tuning strings, the matching one lit up
            HStack(spacing: 10) {
                ForEach(strings, id: \.0) { midi, label in
                    let hit = r?.midi == midi
                    Text(label).font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(hit ? (inTune ? Color.green : tint).opacity(0.85) : Color.white.opacity(0.07)))
                        .foregroundStyle(hit ? .black : .secondary)
                }
            }

            LevelMeter(level: tuner.level).frame(maxWidth: 220)

            Divider()
            HStack(spacing: 16) {
                Stepper(value: $tuner.a4, in: 435...445, step: 1) {
                    Text("A4 = \(Int(tuner.a4)) Hz").monospacedDigit()
                }
                Spacer()
                Toggle("Mute speakers while tuning", isOn: $tuner.muteWhileTuning).toggleStyle(.checkbox)
            }
            .font(.system(size: 12))
            Text("Tip: tune on a clean patch with the neck pickup for the steadiest reading.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(width: 460)
        .alert("Tuner", isPresented: Binding(get: { tuner.errorText != nil }, set: { if !$0 { tuner.errorText = nil; tuner.isOpen = false } })) {
            Button("OK") {}
        } message: { Text(tuner.errorText ?? "") }
    }
}

/// Needle gauge from -50 to +50 cents.
private struct Gauge: View {
    let cents: Double
    let active: Bool
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 6)
            let radius = min(size.width / 2 - 10, size.height - 14)
            func point(_ c: Double, _ r: Double) -> CGPoint {
                let a = (-90 + c / 50 * 60) * .pi / 180          // ±50 cents → ±60°
                return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            }
            // in-tune zone
            var zone = Path()
            zone.addArc(center: center, radius: radius - 4, startAngle: .degrees(-90 - 3.6), endAngle: .degrees(-90 + 3.6), clockwise: false)
            ctx.stroke(zone, with: .color(.green.opacity(0.6)), lineWidth: 10)
            // ticks
            for c in stride(from: -50, through: 50, by: 5) {
                let major = c % 25 == 0
                var t = Path()
                t.move(to: point(Double(c), radius - (major ? 22 : 14)))
                t.addLine(to: point(Double(c), radius))
                ctx.stroke(t, with: .color(.white.opacity(major ? 0.6 : 0.25)), lineWidth: major ? 2 : 1)
            }
            ctx.draw(Text("♭").font(.system(size: 18, weight: .bold)).foregroundStyle(.secondary), at: point(-58, radius - 6))
            ctx.draw(Text("♯").font(.system(size: 18, weight: .bold)).foregroundStyle(.secondary), at: point(58, radius - 6))
            // needle
            let c = max(-50, min(50, cents))
            var n = Path()
            n.move(to: center); n.addLine(to: point(c, radius - 2))
            ctx.stroke(n, with: .color(active ? tint : .gray.opacity(0.4)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)), with: .color(active ? tint : .gray))
        }
    }
}
