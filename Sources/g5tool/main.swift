import Foundation
import G5Core

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
