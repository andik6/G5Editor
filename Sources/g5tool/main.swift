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
if args.first == "apply", args.contains("--dry-run") {
    // apply <bank.json> <bank 1-99> --dry-run : validate a bank spec and print the plan, without the pedal
    let spec = try! BankSpec.load(URL(fileURLWithPath: args[1]))
    switch spec.validate() {
    case .failure(let e): print("Problems:\n\(e)"); exit(1)
    case .success(let r):
        print("\(spec.title ?? "bank") → bank \(args[2]) (dry run, nothing written)")
        for (i, p) in r.patches.enumerated() {
            print("  \(args[2])-\(i + 1) “\(p.name)” level \(p.level.map(String.init) ?? "unchanged"), Z slot: \(p.zpedal.name)")
            for u in p.units { print("      \(u.on ? "ON " : "off") \(u.type.name.padding(toLength: 10, withPad: " ", startingAt: 0)) " + u.raw.map { "\($0.name)=\($0.raw)" }.joined(separator: " ")) }
        }
        exit(0)
    }
}
if args.first == "zslots" {
    // zslots <backup.syx> : offline check of PatchData.zSlot across a backup
    let all = try! Backup.read(URL(fileURLWithPath: args[1]))
    var none = 0, zpNone = 0, multi = 0
    for g in all {
        guard let p = g.patchData else { continue }
        let zs = (0..<9).filter { p.type($0)?.zpedal == true }
        if zs.isEmpty { none += 1 } else if zs.count > 1 { multi += 1 }
        if let z = p.zSlot, p.typeID(z) == EffectCatalog.zpNoneID { zpNone += 1 }
    }
    print("patches \(all.count): without Z slot \(none), with more than one \(multi), Z slot = ZP-None \(zpNone)")
    exit(0)
}
if args.first == "devices" {
    // devices : every Core Audio device, and which ones the monitor would use
    for d in CoreAudioDevices.all() {
        print(String(format: "%4d  in %d  out %d  ", d.device.id, d.inputs, d.outputs) + d.device.name + "  [" + d.device.uid + "]")
    }
    print("G5 input:", CoreAudioDevices.zoomInput()?.name ?? "none")
    print("outputs:", CoreAudioDevices.outputs().map(\.name))
    exit(0)
}
if args.first == "latency" {
    // latency : buffer ranges, hidden driver latency and supported rates of the G5 and every output
    var devs = CoreAudioDevices.outputs().map { ($0, false) }
    if let g = CoreAudioDevices.zoomInput() { devs.insert((g, true), at: 0) }
    for (d, isIn) in devs {
        let sr = CoreAudioDevices.sampleRate(d.id), hw = CoreAudioDevices.hardwareLatency(d.id, input: isIn), br = CoreAudioDevices.bufferRange(d.id)
        print(String(format: "%@ (%@) %.0f Hz  buffer %d..%d  hidden %d frames = %.2f ms  rates %@", d.name, isIn ? "in" : "out", sr, br.min, br.max, hw, Double(hw) / sr * 1000,
                     CoreAudioDevices.availableRates(d.id).map { String(Int($0)) }.joined(separator: ",")))
    }
    exit(0)
}
if args.first == "setrate" {
    // setrate <device-name> <Hz> : change a device's sample rate (used to test the monitor's recovery)
    guard args.count > 2, let rate = Double(args[2]),
          let d = CoreAudioDevices.all().first(where: { $0.device.name.localizedCaseInsensitiveContains(args[1]) })?.device else { print("usage: setrate <name> <Hz>"); exit(1) }
    print(d.name, CoreAudioDevices.sampleRate(d.id), "->", rate, CoreAudioDevices.setSampleRate(d.id, rate) ? "ok" : "failed")
    exit(0)
}
if args.first == "monitor" {
    // monitor <seconds> [output-name] : G5 USB audio -> output device, prints flow stats each second
    guard let inp = CoreAudioDevices.zoomInput() else { print("no ZOOM audio input"); exit(1) }
    let outs = CoreAudioDevices.outputs()
    print("outputs:", outs.map(\.name))
    let want = args.count > 2 ? args[2] : "HD USB"
    guard let out = outs.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) else { print("no output", want); exit(1) }
    let frames = args.count > 3 ? UInt32(args[3]) ?? 32 : 32
    let m = try! AudioMonitor(input: inp, output: out, bufferFrames: frames, margin: args.count > 4 ? Int(args[4]) ?? 64 : 64)
    if args.count > 5, let db = Float(args[5]) { m.gain = pow(10, db / 20) }   // optional gain in dB (tests the limiter)
    print("\(inp.name) \(m.inputRate) Hz -> \(out.name) \(m.outputRate) Hz  buffers \(m.bufferFrames)  target \(m.targetFrames)")
    try! m.start()
    for t in 1...(Int(args[1]) ?? 5) {
        Thread.sleep(forTimeInterval: 1)
        let s = m.takeStats()
        print(String(format: "%2ds in %6d out %6d  underruns %d skips %d  peak in %.4f out %.4f  limiting %.1f dB  latency %.1f ms",
                     t, s.inputFrames, s.outputFrames, s.underruns, s.skips, s.inputPeak, s.outputPeak, s.limitingDb, s.latencyMs))
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
    case "whoami":
        // whoami <backup.syx> : active slot, its name, and which stored slots differ from the backup
        let all = try Backup.read(URL(fileURLWithPath: args[1]))
        try dev.editorMode(true)
        Thread.sleep(forTimeInterval: 0.3)
        let a = try dev.activeSlot()
        print("active slot \(a) (\(a / 3 + 1)-\(a % 3 + 1))")
        for s in Set([a, 296, 0]).sorted() {
            let now = try dev.readPatch(s); let was = all.first { $0.slot == s }!
            print("slot \(s): now '\(now.name)'  backup '\(was.name)'  identical: \(now.data == was.data)")
        }
        try dev.editorMode(false)
    case "show":
        // show <slot> : stored patch with every unit's knobs as the pedal displays them
        try dev.editorMode(true)
        let g = try dev.readPatch(Int(args[1])!)
        guard let d = g.patchData else { break }
        print("\(g.name)  level \(d.level)  Z slot: effect \((d.zSlot ?? -1) + 1)")
        for u in 0..<PatchData.unitCount {
            guard let t = d.type(u), !t.isEmpty else { continue }
            print("  \(u + 1) \(d.isOn(u) ? "ON " : "off") \(t.name.padding(toLength: 10, withPad: " ", startingAt: 0)) " + t.params.map { "\($0.name)=\($0.display(d.param(u, $0.prm)))" }.joined(separator: " "))
        }
        try dev.editorMode(false)
    case "apply":
        // apply <bank.json> <bank 1-99> : full backup, then write the bank and verify each patch by reading it back
        let spec = try BankSpec.load(URL(fileURLWithPath: args[1]))
        let bank = Int(args[2])!
        let resolved: BankSpec.Resolved
        switch spec.validate() { case .failure(let e): print("Problems:\n\(e)"); exit(1); case .success(let r): resolved = r }
        let all = try dev.readAll { _, _ in }
        try FileManager.default.createDirectory(at: Backup.defaultFolder, withIntermediateDirectories: true)
        let url = Backup.timestampedURL()
        try Backup.write(all, to: url)
        print("backup: \(url.path)")
        try resolved.apply(to: dev, bank: bank)
        print("done: \(spec.title ?? "bank") written to bank \(bank)")
    case "alloff":
        // alloff <slot> : saves the stored patch to a .syx, then stores it with every effect switched off
        // (a clean signal path for noise tests). Undo with: restore1 <that .syx> <slot>
        let slot = Int(args[1])!
        try dev.editorMode(true)
        let orig = try dev.readPatch(slot)
        let url = Backup.defaultFolder.appendingPathComponent("slot\(slot)-before-alloff.syx")
        try Backup.write([orig], to: url)
        try dev.selectPatch(slot); Thread.sleep(forTimeInterval: 0.6)
        for u in 0..<PatchData.unitCount { try dev.sendParam(unit: u, prm: 0, value: 0); Thread.sleep(forTimeInterval: 0.12) }
        let d = try dev.readEditBuffer()
        try dev.store(d, slot: slot)
        print("saved \(orig.name) to \(url.path); stored with all effects off: \((0..<PatchData.unitCount).allSatisfy { !d.isOn($0) })")
        try dev.editorMode(false)
    case "verifyall":
        // verifyall <backup.syx> : reads every stored patch and lists those that differ from the backup
        let all = try Backup.read(URL(fileURLWithPath: args[1]))
        let now = try dev.readAll { _, _ in }
        let diff = now.filter { n in all.first { $0.slot == n.slot }?.data != n.data }
        print(diff.isEmpty ? "all \(now.count) patches identical to the backup" : "DIFFERENT: " + diff.map { "\($0.slot / 3 + 1)-\($0.slot % 3 + 1) \($0.name)" }.joined(separator: ", "))
    case "hold":
        // hold <seconds> <unit>:<typeID> ... : sets types, switches them on, and keeps editor mode for <seconds>
        // so the pedal's display and sound can be checked. The edit buffer reverts when editor mode ends.
        try dev.editorMode(true)
        for a in args.dropFirst(2) {
            let p = a.split(separator: ":").map { Int($0)! }
            try dev.sendParam(unit: p[0], prm: 1, value: p[1]); Thread.sleep(forTimeInterval: 0.3)
            try dev.sendParam(unit: p[0], prm: 0, value: 1); Thread.sleep(forTimeInterval: 0.3)
        }
        let b = try dev.readEditBuffer()
        print("holding:", (0..<9).map { u in "\(u + 1):\(b.type(u)?.name ?? String(b.typeID(u)))\(b.isOn(u) ? "" : "(off)")" }.joined(separator: "  "))
        Thread.sleep(forTimeInterval: Double(args[1])!)
        try dev.editorMode(false)
        print("released")
    case "settype":
        // settype <unit> <typeID> [<unit> <typeID> ...] : sets effect types in the edit buffer, prints all 9 unit types after each
        try dev.editorMode(true)
        func show(_ label: String) throws {
            let b = try dev.readEditBuffer()
            print(label.padding(toLength: 14, withPad: " ", startingAt: 0), (0..<9).map { u in "\(u):\(b.typeID(u))\(b.isOn(u) ? "" : "-")" }.joined(separator: " "))
        }
        try show("before")
        var i = 1
        while i + 1 < args.count {
            let u = Int(args[i])!, t = Int(args[i + 1])!
            try dev.sendParam(unit: u, prm: 1, value: t)
            Thread.sleep(forTimeInterval: 0.5)
            try show("u\(u) := \(t)")
            i += 2
        }
        try dev.editorMode(false)
    case "dspprobe":
        // dspprobe <slot> <dsp_budget.json> : measures the pedal's per-patch DSP limit on a scratch slot.
        // Fills units with effects of known firmware budget until the pedal refuses one, then refines with lighter ones.
        // The slot's edit buffer gets auto-saved by the pedal, so restore the slot from a backup afterwards.
        let slot = Int(args[1])!
        let table = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: [String: Any]]
        var budget: [Int: Double] = [:], name: [Int: String] = [:], isAmp: [Int: Bool] = [:]
        for (k, v) in table {
            guard let id = Int(k), let cat = v["catalog"] as? String, v["zpedal"] as? Bool == false, v["hidden"] as? Bool == false else { continue }
            budget[id] = v["budget"] as? Double; name[id] = cat; isAmp[id] = v["amp"] as? Bool ?? false
        }
        let none = 107
        try dev.editorMode(true)
        try dev.selectPatch(slot)
        Thread.sleep(forTimeInterval: 0.8)
        print("probing on slot \(slot) (\(slot / 3 + 1)-\(slot % 3 + 1))")
        // Sets the type and switches the unit on; the pedal only budgets DSP for enabled effects.
        func setType(_ unit: Int, _ id: Int) throws -> Bool {
            try dev.sendParam(unit: unit, prm: 1, value: id)
            Thread.sleep(forTimeInterval: 0.3)
            if id != none { try dev.sendParam(unit: unit, prm: 0, value: 1); Thread.sleep(forTimeInterval: 0.3) }
            let b = try dev.readEditBuffer()
            return b.typeID(unit) == id && (id == none || b.isOn(unit))
        }
        func clear() throws { for u in (0..<9).reversed() { _ = try setType(u, none) } }
        var accepted: [(Double, String)] = [], refused: [(Double, String)] = []
        let effects = budget.keys.filter { $0 != none }
        let nonAmps = effects.filter { !(isAmp[$0] ?? false) }.sorted { budget[$0]! > budget[$1]! }
        let amps = effects.filter { isAmp[$0] ?? false }.sorted()
        // Trial plans: start sequences (filled in order), refined at the first refusal with lighter candidates.
        var plans: [[Int]] = [
            Array(nonAmps.prefix(9)),                                   // heaviest non-amps
            Array(nonAmps.dropFirst(9).prefix(9)),                      // next tier
            Array(nonAmps.dropFirst(20).prefix(9)),
            [amps[0]] + Array(nonAmps.prefix(8)),                       // one amp + heavy
            [amps[0], amps[1]] + Array(nonAmps.dropFirst(10).prefix(7)),// two amps
            Array(amps.prefix(3)),                                      // three amps
        ]
        plans.append(Array(nonAmps.reversed().prefix(9)))               // lightest: should always fit
        if args.count > 3 && args[3] == "extreme" { plans = [Array(amps.prefix(9))] }   // every unit an amp
        // Units holding a Z-Pedal effect only accept Z-Pedal types, so leave them out.
        let zIDs = Set(table.compactMap { k, v in (v["zpedal"] as? Bool == true) ? Int(k) : nil } + [165])
        try clear()
        let start = try dev.readEditBuffer()
        let usable = (0..<9).filter { !zIDs.contains(start.typeID($0)) }
        print("usable units: \(usable.map { $0 + 1 }) (Z-Pedal unit skipped)")
        for (t, plan) in plans.enumerated() {
            try clear()
            var sum = 0.0, chain: [String] = [], n = 0
            var refusedAt: Int?
            for id in plan where n < usable.count {
                if try setType(usable[n], id) { sum += budget[id]!; chain.append(name[id]!); n += 1 }
                else { refusedAt = id; refused.append((sum + budget[id]!, chain.joined(separator: "+") + " +[\(name[id]!)]")); break }
            }
            if let r = refusedAt, n < usable.count {
                for id in nonAmps where budget[id]! < budget[r]! {
                    if try setType(usable[n], id) { sum += budget[id]!; chain.append(name[id]!); n += 1; break }
                    else { refused.append((sum + budget[id]!, chain.joined(separator: "+") + " +[\(name[id]!)]")) }
                }
            }
            accepted.append((sum, chain.joined(separator: "+")))
            print(String(format: "trial %d: accepted total %.2f with %d units%@", t + 1, sum, n, refusedAt.map { " (first refusal: \(name[$0]!))" } ?? ""))
        }
        try clear()
        let maxOK = accepted.max { $0.0 < $1.0 }!, minNo = refused.min { $0.0 < $1.0 }
        print(String(format: "\nlargest accepted total: %.2f  (%@)", maxOK.0, maxOK.1))
        if let m = minNo { print(String(format: "smallest refused total: %.2f  (%@)", m.0, m.1)) }
        if let m = minNo { print(maxOK.0 < m.0 ? String(format: "CONSISTENT: limit is between %.2f and %.2f", maxOK.0, m.0)
                                               : "INCONSISTENT: an accepted total exceeds a refused one (limit is not a plain sum)") }
        try dev.editorMode(false)
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
