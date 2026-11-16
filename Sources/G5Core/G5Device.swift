import Foundation

/// A patch exactly as stored on the pedal (the raw 0x08 SysEx message).
public struct G5Patch: Codable, Hashable, Identifiable {
    public var slot: Int
    public var raw: [UInt8]
    public var id: Int { slot }

    public init(slot: Int, raw: [UInt8]) { self.slot = slot; self.raw = raw }

    /// Encoded payload: after "F0 52 00 5B 08 b1 b2 b3 lenLo lenHi", before 5 checksum bytes + F7.
    public var data: [UInt8] { raw.count > 16 ? Packing.unpack(raw[10..<(raw.count - 6)]) : [] }

    public static let nameOffset = 127, nameLength = 10
    public var name: String {
        let d = data
        guard d.count >= Self.nameOffset + Self.nameLength else { return "?" }
        let bytes = d[Self.nameOffset..<(Self.nameOffset + Self.nameLength)].map { $0 == 0 ? 0x20 : $0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

public final class G5Device {
    public static let modelID: UInt8 = 0x5B
    public let midi = MIDIConnection()
    public init() {}

    public static func zoom(_ body: [UInt8]) -> [UInt8] { [0xF0, 0x52, 0x00, modelID] + body + [0xF7] }

    public struct Identity { public var firmware: String }

    public func connect() throws -> Identity {
        try midi.connect()
        let r = try midi.request([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], what: "identity") {
            $0.count >= 15 && $0[1] == 0x7E && $0[3] == 0x06 && $0[4] == 0x02 && $0[5] == 0x52
        }
        guard r[6] == Self.modelID else { throw G5Error.badReply("this isn't a G5 (model \(String(format: "%02X", r[6])))") }
        let fw = String(decoding: r[10..<14], as: UTF8.self)
        return Identity(firmware: fw)
    }

    public func editorMode(_ on: Bool) throws { try midi.send(Self.zoom([on ? 0x50 : 0x51])) }

    /// Reads a stored patch without changing the active patch.
    public func readPatch(_ slot: Int) throws -> G5Patch {
        let r = try midi.request(Self.zoom([0x09, 0x00, UInt8(slot / 3), UInt8(slot % 3)]), what: "patch \(slot + 1)") {
            $0.count > 20 && $0[1] == 0x52 && $0[3] == Self.modelID && $0[4] == 0x08
        }
        return G5Patch(slot: slot, raw: r)
    }
}

extension G5Device {
    /// Writes a patch into its slot (as given by `patch.slot`) and verifies by reading it back.
    public func writePatch(_ patch: G5Patch) throws {
        var msg = patch.raw
        msg[6] = UInt8(patch.slot / 3); msg[7] = UInt8(patch.slot % 3)
        _ = try midi.request(msg, what: "saving patch \(patch.slot + 1)") {
            $0.count == 7 && $0[1] == 0x52 && $0[3] == Self.modelID && $0[4] == 0x00
        }
        let back = try readPatch(patch.slot)
        guard back.data == patch.data else {
            throw G5Error.badReply("patch \(patch.slot + 1) didn't verify after writing")
        }
    }

    /// Writes several patches inside one editor-mode session.
    public func writePatches(_ patches: [G5Patch], progress: (Int, Int) -> Void = { _, _ in }) throws {
        try editorMode(true)
        defer { try? editorMode(false) }
        for (i, p) in patches.enumerated() {
            var lastError: Error?
            var ok = false
            for _ in 0..<3 where !ok {
                do { try writePatch(p); ok = true } catch { lastError = error }
            }
            if !ok { throw lastError! }
            progress(i + 1, patches.count)
        }
    }
}

// MARK: - Live editing
extension G5Device {
    /// Makes `slot` the active patch on the pedal (bank select + program change).
    /// The G5 only accepts this with editor mode off; editor mode is turned back on afterwards.
    public func selectPatch(_ slot: Int) throws {
        try editorMode(false)
        Thread.sleep(forTimeInterval: 0.05)
        try midi.send([0xB0, 0x00, 0x00])
        try midi.send([0xB0, 0x20, UInt8(slot / 3)])
        try midi.send([0xC0, UInt8(slot % 3)])
        Thread.sleep(forTimeInterval: 0.25)
        try editorMode(true)
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Which patch is active on the pedal (needs editor mode on).
    public func activeSlot() throws -> Int {
        midi.clearInbox()
        try midi.send(Self.zoom([0x33]))
        var bank = 0
        while true {
            let m = try midi.wait(timeout: 1, what: "active patch") { $0.count >= 2 && ($0[0] & 0xF0 == 0xB0 || $0[0] & 0xF0 == 0xC0) }
            if m[0] & 0xF0 == 0xB0, m[1] == 0x20 { bank = Int(m[2]) }
            if m[0] & 0xF0 == 0xC0 { return bank * 3 + Int(m[1]) }
        }
    }

    public func readEditBuffer() throws -> PatchData {
        let r = try midi.request(Self.zoom([0x29]), what: "current patch") { $0.count > 20 && $0[3] == Self.modelID && $0[4] == 0x28 }
        guard let p = PatchData(Packing.unpack(r[5..<(r.count - 1)])) else { throw G5Error.badReply("current patch has wrong size") }
        return p
    }

    /// Live parameter change on the active patch. prm 0 = on/off, 1 = effect type, 2+ = knobs.
    /// unit 9 = patch settings (prm 2 level, prm 3 footswitch).
    public func sendParam(unit: Int, prm: Int, value: Int) throws {
        try midi.send(Self.zoom([0x31, UInt8(unit), UInt8(prm), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]))
    }

    public func sendEditBuffer(_ p: PatchData) throws { try midi.send(p.editBufferMessage) }

    /// Stores patch data into a memory slot and verifies it.
    public func store(_ p: PatchData, slot: Int) throws {
        try writePatch(G5Patch(slot: slot, patchData: p))
    }
}
