import Foundation
import G5Core
import CoreAudio

let args = Array(CommandLine.arguments.dropFirst())
let dev = G5Device()
if args.first == "selftest" {
    // Offline: rebuild every patch in a backup from decoded data and compare byte-for-byte.
    let all = try! Backup.read(URL(fileURLWithPath: args[1]))
    var ok = 0
    for p in all { if let d = p.patchData, d.storeMessage(slot: p.slot) == p.raw { ok += 1 } else { print("mismatch slot", p.slot) } }
    print("\(ok)/\(all.count) patches rebuilt identically")
    var d = all[60].patchData!
    print("patch 61:", d.name, "level", d.level, (0..<9).map { "\(d.type($0)?.name ?? "?")\(d.isOn($0) ? "*" : "")" })
    d.moveUnit(from: 3, to: 0); d.name = "Test Ü@#1234567"
    print("after move+rename:", d.name, (0..<9).map { d.type($0)?.name ?? "?" })
    let t = EffectCatalog.shared.type(53)!
    print(t.name, t.params.map { "\($0.name)=\($0.display(d.param(4, $0.prm)))" }, EffectCatalog.shared.types.count)
    exit(0)
}
if args.first == "monitor" {
    // monitor <seconds> [output-name] : G5 USB audio -> output device, prints flow stats each second
    guard let inp = CoreAudioDevices.zoomInput() else { print("no ZOOM audio input"); exit(1) }
    let outs = CoreAudioDevices.outputs()
    print("outputs:", outs.map(\.name))
    let want = args.count > 2 ? args[2] : "HD USB"
    guard let out = outs.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) else { print("no output", want); exit(1) }
    let m = try! AudioMonitor(input: inp, output: out)
    print("\(inp.name) \(m.inputRate) Hz -> \(out.name) \(m.outputRate) Hz")
    try! m.start()
    for t in 1...(Int(args[1]) ?? 5) {
        Thread.sleep(forTimeInterval: 1)
        let s = m.takeStats()
        print(String(format: "%2ds in %6d out %6d  underruns %d skips %d  peak in %.4f out %.4f  latency %.1f ms",
                     t, s.inputFrames, s.outputFrames, s.underruns, s.skips, s.inputPeak, s.outputPeak, s.latencyMs))
    }
    m.stop(); exit(0)
}
if args.first == "tunertest" {
    // Offline: synthetic guitar-like tones at known pitches, reports the detector's error in cents.
    let sr = 44100.0
    let det = PitchDetector(sampleRate: sr)
    var worst = 0.0, misses = 0
    let strings: [(String, Double)] = [("B1", 61.74), ("D2", 73.42), ("E2", 82.41), ("A2", 110.0), ("D3", 146.83), ("G3", 196.0), ("B3", 246.94), ("E4", 329.63), ("E5", 659.26), ("E6", 1318.51)]
    for (name, f0) in strings {
        for detune in [-23.0, 0, 7.0] {
            let f = f0 * pow(2, detune / 1200)
            for kind in ["sine", "guitar", "weakfund"] {
                let x: [Float] = (0..<det.windowSize).map { i in
                    let t = Double(i) / sr
                    switch kind {
                    case "sine": return Float(0.3 * sin(2 * .pi * f * t))
                    case "guitar":   // 1/n harmonics with a little inharmonicity, slight noise
                        var v = Double.random(in: -0.003...0.003)
                        for h in 1...12 {
                            let k = Double(h), stretch = (1 + 1e-4 * k * k).squareRoot() / (1 + 1e-4).squareRoot()   // real-string inharmonicity, f1 exact
                            v += 0.25 / k * sin(2 * Double.pi * f * k * stretch * t + k)
                        }
                        return Float(v)
                    default:         // fundamental much weaker than the 2nd/3rd harmonics (bridge pickup, distortion)
                        let w = 2 * Double.pi * f * t
                        let v: Double = 0.05 * sin(w) + 0.3 * sin(2 * w + 1) + 0.25 * sin(3 * w + 2)
                        return Float(v)
                    }
                }
                guard let r = det.detect(x) else { print("MISS \(name) \(kind) \(detune)"); misses += 1; continue }
                let err = 1200 * log2(r.freq / f)
                worst = max(worst, abs(err))
                if abs(err) > 2 { print(String(format: "%@ %@ detune %+.0f: got %.2f Hz (err %+.1f cents)", name, kind, detune, r.freq, err)) }
            }
        }
    }
    let n = NoteReading(freq: 329.63 * pow(2, 7.0 / 1200))
    print(String(format: "worst error %.2f cents, misses %d; 329.63 Hz +7c -> %@%d %+.1f", worst, misses, n.name, n.octave, n.cents))
    exit(0)
}
if args.first == "tuner" {
    // tuner <seconds> : live note readings from the G5 USB input
    guard let inp = CoreAudioDevices.zoomInput() else { print("no ZOOM audio input"); exit(1) }
    let tap = AudioInputTap(device: inp); try! tap.start()
    let det = PitchDetector(sampleRate: tap.sampleRate)
    for _ in 0..<((Int(args.dropFirst().first ?? "10") ?? 10) * 4) {
        Thread.sleep(forTimeInterval: 0.25)
        if let r = det.detect(tap.latest(det.windowSize)) {
            let n = NoteReading(freq: r.freq)
            print(String(format: "%7.2f Hz  %@%d  %+5.1f cents  clarity %.2f", r.freq, n.name, n.octave, n.cents, r.clarity))
        } else { print("  –") }
    }
    exit(0)
}
if args.first == "noise" {
    // noise <seconds> : captures the G5 USB input and prints per-second level, hum and hiss content
    guard let inp = CoreAudioDevices.zoomInput() else { print("no ZOOM audio input"); exit(1) }
    let rate = CoreAudioDevices.sampleRate(inp.id)
    let secs = Int(args.dropFirst().first ?? "10") ?? 10
    let total = Int(rate) * secs
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: total); var n = 0
    let lock = NSLock()
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, inp.id, nil) { _, inData, _, _, _ in
        let b = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))[0]
        let ch = Int(b.mNumberChannels), p = b.mData!.assumingMemoryBound(to: Float.self)
        let frames = Int(b.mDataByteSize) / (4 * ch)
        lock.lock(); for i in 0..<frames where n < total { buf[n] = p[i * ch]; n += 1 }; lock.unlock()
    }
    AudioDeviceStart(inp.id, proc)
    while true { Thread.sleep(forTimeInterval: 0.2); lock.lock(); let d = n >= total; lock.unlock(); if d { break } }
    AudioDeviceStop(inp.id, proc); AudioDeviceDestroyIOProcID(inp.id, proc!)
    func db(_ x: Double) -> String { String(format: "%6.1f", 20 * log10(max(x, 1e-9))) }
    func goertzel(_ x: UnsafeBufferPointer<Float>, _ f: Double) -> Double {
        let w = 2 * Double.pi * f / rate, c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
        for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
        return sqrt(max(0, s1 * s1 + s2 * s2 - c * s1 * s2)) * 2 / Double(x.count) / sqrt(2)   // RMS of that sine
    }
    print("sec   RMS dB  peak dB   hiss>3k dB   hum 50/100/150 Hz dB        60/120/180 Hz dB")
    for k in 0..<secs {
        let x = UnsafeBufferPointer(start: buf + k * Int(rate), count: Int(rate))
        let rms = sqrt(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count))
        let peak = Double(x.map(abs).max() ?? 0)
        // crude high-pass: first difference emphasises >3 kHz content
        var hp = 0.0; for i in 1..<x.count { let d = Double(x[i] - x[i-1]); hp += d * d }
        let hiss = sqrt(hp / Double(x.count)) / 2
        let h = [50.0, 100, 150, 60, 120, 180].map { db(goertzel(x, $0)) }
        print(String(format: "%2d", k + 1), db(rms), " ", db(peak), "   ", db(hiss), "     ", h[0...2].joined(separator: " "), "     ", h[3...5].joined(separator: " "))
    }
    exit(0)
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
do {
    let id = try dev.connect()
    print("G5 firmware \(id.firmware)")
    switch args.first {
    case "raw":
        for a in args.dropFirst() {
            let msg = a.split(separator: " ").map { UInt8($0, radix: 16)! }
            dev.midi.clearInbox(); try dev.midi.send(msg)
            while let r = try? dev.midi.wait(timeout: 1, what: "", { _ in true }) { print(hex(r)) }
        }
    case "scan":
        try dev.editorMode(true)
        for s in (Int(args.dropFirst().first ?? "0") ?? 0)..<(Int(args.dropFirst(2).first ?? "128") ?? 128) {
            let p = try dev.readPatch(s)
            print(String(format: "%3d  id %@  %@", s, hex(Array(p.raw[5...7])), p.name))
        }
        try dev.editorMode(false)
    case "backup":
        let all = try dev.readAll { d, t in if d % 30 == 0 || d == t { print("  read \(d)/\(t)") } }
        try FileManager.default.createDirectory(at: Backup.defaultFolder, withIntermediateDirectories: true)
        let url = Backup.timestampedURL()
        try Backup.write(all, to: url)
        let back = try Backup.read(url)
        precondition(back == all, "backup file didn't read back identically")
        print("Saved \(all.count) patches to \(url.path)")
    case "writeback":
        // Writes slot N back with its own unchanged bytes and reports the pedal's replies.
        let n = Int(args[1])!
        try dev.editorMode(true)
        let before = try dev.readPatch(n)
        dev.midi.clearInbox(); try dev.midi.send(before.raw)
        while let r = try? dev.midi.wait(timeout: 1.5, what: "", { _ in true }) { print("reply:", hex(r)) }
        let after = try dev.readPatch(n)
        print(before == after ? "Read-back identical: \(after.name)" : "DIFFERENT after write!")
        try dev.editorMode(false)
    case "copytest":
        // Copy slot A into slot B, verify, then restore B's original bytes and verify.
        let a = Int(args[1])!, b = Int(args[2])!
        try dev.editorMode(true)
        let src = try dev.readPatch(a), orig = try dev.readPatch(b)
        var msg = src.raw; msg[6] = UInt8(b / 3); msg[7] = UInt8(b % 3)
        dev.midi.clearInbox(); try dev.midi.send(msg)
        print("write copy reply:", hex(try dev.midi.wait(timeout: 2, what: "ack") { $0[4] == 0x00 }))
        let mid = try dev.readPatch(b)
        print("slot \(b + 1) now: \(mid.name)  (data equals source: \(mid.data == src.data))")
        dev.midi.clearInbox(); try dev.midi.send(orig.raw)
        print("restore reply:", hex(try dev.midi.wait(timeout: 2, what: "ack") { $0[4] == 0x00 }))
        let fin = try dev.readPatch(b)
        print(fin == orig ? "Restored OK: \(fin.name)" : "RESTORE MISMATCH")
        try dev.editorMode(false)
    case "edit":
        // edit <unit> <param> <value> : param change on the edit buffer, prints changed bits
        try dev.editorMode(true)
        func buf() throws -> [UInt8] {
            let r = try dev.midi.request(G5Device.zoom([0x29]), what: "edit buffer") { $0.count > 20 && $0[4] == 0x28 }
            return Packing.unpack(r[5..<(r.count - 1)])
        }
        let a = try buf()
        let u = UInt8(args[1])!, pr = UInt8(args[2])!, v = Int(args[3])!
        dev.midi.clearInbox()
        try dev.midi.send(G5Device.zoom([0x31, u, pr, UInt8(v & 0x7F), UInt8(v >> 7)]))
        while let r = try? dev.midi.wait(timeout: 0.4, what: "", { _ in true }) { print("reply:", hex(r)) }
        let b = try buf()
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            print(String(format: "byte %3d: %02X -> %02X  (bits changed %@)", i, a[i], b[i], String(a[i] ^ b[i], radix: 2)))
        }
        if a.count != b.count { print("length", a.count, b.count) }
    case "bits":
        // bits <unit> <param> <v1> <v2> ... : sets each value, prints bit positions that are set vs value 0
        try dev.editorMode(true)
        func buf() throws -> [UInt8] {
            let r = try dev.midi.request(G5Device.zoom([0x29]), what: "edit buffer") { $0.count > 20 && $0[4] == 0x28 }
            return Packing.unpack(r[5..<(r.count - 1)])
        }
        func set(_ v: Int) throws {
            try dev.midi.send(G5Device.zoom([0x31, UInt8(args[1])!, UInt8(args[2])!, UInt8(v & 0x7F), UInt8(v >> 7)]))
            Thread.sleep(forTimeInterval: 0.15)
        }
        for vs in args.dropFirst(3) {
            let v = Int(vs)!
            try set(v); let a = try buf()
            // compare against neighbouring value to isolate this field
            try set(v == 0 ? 1 : 0); let z = try buf()
            var pos: [String] = []
            for i in 0..<a.count where a[i] != z[i] {
                for k in 0..<8 where (a[i] ^ z[i]) >> k & 1 == 1 { pos.append("\(i * 8 + k)\((a[i] >> k) & 1 == 1 ? "+" : "-")") }
            }
            print("value \(v): \(pos.joined(separator: " "))")
        }
    case "sweep":
        // sweep <unit> <param> <values...> : for each value prints "value hexbuffer"
        try dev.editorMode(true)
        for vs in args.dropFirst(3) {
            let v = Int(vs)!
            try dev.midi.send(G5Device.zoom([0x31, UInt8(args[1])!, UInt8(args[2])!, UInt8(v & 0x7F), UInt8(v >> 7)]))
            Thread.sleep(forTimeInterval: 0.12)
            let r = try dev.midi.request(G5Device.zoom([0x29]), what: "edit buffer") { $0.count > 20 && $0[4] == 0x28 }
            print(v, Packing.unpack(r[5..<(r.count - 1)]).map { String(format: "%02X", $0) }.joined())
        }
    case "restore1":
        // restore1 <backup.syx> <slot> : writes slot from backup to memory AND edit buffer, verifies both
        let all = try Backup.read(URL(fileURLWithPath: args[1]))
        let p = all.first { $0.slot == Int(args[2])! }!
        try dev.writePatches([p])
        try dev.editorMode(true)
        let enc = Array(p.raw[10..<(p.raw.count - 6)])
        try dev.midi.send(G5Device.zoom([0x28] + enc))
        Thread.sleep(forTimeInterval: 0.3)
        let r = try dev.midi.request(G5Device.zoom([0x29]), what: "edit buffer") { $0.count > 20 && $0[4] == 0x28 }
        print("memory restored: \(p.name); edit buffer matches: \(Packing.unpack(r[5..<(r.count - 1)]) == p.data)")
        try dev.editorMode(false)
    case "autosave":
        // Changes unit 1 level-ish knob live, waits, and checks if stored slot 0 changed; then reverts.
        try dev.editorMode(true)
        let stored0 = try dev.readPatch(0)
        func buf() throws -> [UInt8] {
            let r = try dev.midi.request(G5Device.zoom([0x29]), what: "edit buffer") { $0.count > 20 && $0[4] == 0x28 }
            return Packing.unpack(r[5..<(r.count - 1)])
        }
        let before = try buf()
        print("edit buffer == stored slot 1:", before == stored0.data)
        try dev.midi.send(G5Device.zoom([0x31, 0x00, 0x00, before[0] & 1 == 1 ? 0 : 1, 0]))   // toggle unit 1 on/off
        for t in [0.5, 2.0, 5.0] {
            Thread.sleep(forTimeInterval: t)
            let now = try dev.readPatch(0)
            print("after \(t)s more: stored slot 1 changed =", now.data != stored0.data)
        }
        try dev.editorMode(false)
        Thread.sleep(forTimeInterval: 3)
        print("after leaving editor mode: stored slot 1 changed =", try dev.readPatch(0).data != stored0.data)
    case "active":
        // prints the active patch name (edit buffer) after optionally sending raw messages (editor mode OFF while sending)
        for a in args.dropFirst() {
            try dev.midi.send(a.split(separator: " ").map { UInt8($0, radix: 16)! }); Thread.sleep(forTimeInterval: 0.4)
        }
        try dev.editorMode(true)
        let r = try dev.midi.request(G5Device.zoom([0x29]), what: "edit buffer") { $0.count > 20 && $0[4] == 0x28 }
        let d = Packing.unpack(r[5..<(r.count - 1)])
        print("active:", String(decoding: d[127..<137], as: UTF8.self))
        try dev.editorMode(false)
    case "livetest":
        try dev.selectPatch(0)
        print("active slot:", try dev.activeSlot())
        let orig = try dev.readEditBuffer()
        var m = orig; m.moveUnit(from: 3, to: 0)
        try dev.sendEditBuffer(m); Thread.sleep(forTimeInterval: 0.4)
        let got = try dev.readEditBuffer()
        print("reorder accepted:", got == m, (0..<9).map { got.type($0)?.name ?? "?" })
        try dev.sendParam(unit: 0, prm: 2, value: 77); Thread.sleep(forTimeInterval: 0.2)
        print("knob change -> amp gain now", try dev.readEditBuffer().param(0, 2))
        try dev.sendEditBuffer(orig); try dev.store(orig, slot: 0); Thread.sleep(forTimeInterval: 0.3)
        print("back to original:", try dev.readEditBuffer() == orig, "stored:", try dev.readPatch(0).patchData == orig)
        try dev.editorMode(false)
    default: break
    }
} catch { print("Error:", error.localizedDescription); exit(1) }
