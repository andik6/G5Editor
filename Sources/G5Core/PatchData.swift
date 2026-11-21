import Foundation

/// The 138 decoded bytes of a G5 patch, with bit-level accessors.
/// Layout (worked out from the pedal's edit buffer):
///   9 effect units × 12 bytes (bit 0 on/off, bits 1–8 type, then knobs)
///   byte 108: patch level (7 bits), then footswitch (4 bits)
///   bytes 127–136: name (10 ASCII characters)
public struct PatchData: Equatable {
    public static let length = 138, unitCount = 9, unitBytes = 12
    public static let nameOffset = 127, nameLength = 10
    /// prm index -> (bit offset within the unit, width)
    public static let paramLayout: [Int: (Int, Int)] = [
        2: (9, 13), 3: (22, 11), 4: (35, 11), 5: (48, 8), 6: (56, 8), 7: (64, 8), 8: (72, 8), 9: (80, 8),
    ]
    public static let footswitchNames = ["OFF", "Effect 1", "Effect 2", "Effect 3", "Effect 4", "Effect 5",
                                         "Effect 6", "Effect 7", "Effect 8", "Effect 9", "Tap Tempo", "Bypass / Mute"]
    public static let nameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !#$%&'()+,-.;=@[]^_`{}~")

    public var bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.length else { return nil }
        self.bytes = bytes
    }

    // MARK: bit fields
    public func field(_ bit: Int, _ width: Int) -> Int {
        var v = 0
        for k in 0..<width where (bytes[(bit + k) / 8] >> ((bit + k) % 8)) & 1 == 1 { v |= 1 << k }
        return v
    }

    public mutating func setField(_ bit: Int, _ width: Int, _ value: Int) {
        for k in 0..<width {
            let i = (bit + k) / 8, m = UInt8(1 << ((bit + k) % 8))
            if (value >> k) & 1 == 1 { bytes[i] |= m } else { bytes[i] &= ~m }
        }
    }

    // MARK: units
    static func base(_ unit: Int) -> Int { unit * unitBytes * 8 }

    public func isOn(_ unit: Int) -> Bool { field(Self.base(unit), 1) == 1 }
    public mutating func setOn(_ unit: Int, _ on: Bool) { setField(Self.base(unit), 1, on ? 1 : 0) }

    public func typeID(_ unit: Int) -> Int { field(Self.base(unit) + 1, 8) }
    public func type(_ unit: Int) -> EffectType? { EffectCatalog.shared.type(typeID(unit)) }

    public func param(_ unit: Int, _ prm: Int) -> Int {
        guard let (o, w) = Self.paramLayout[prm] else { return 0 }
        return field(Self.base(unit) + o, w)
    }
    public mutating func setParam(_ unit: Int, _ prm: Int, _ v: Int) {
        guard let (o, w) = Self.paramLayout[prm] else { return }
        setField(Self.base(unit) + o, w, v)
    }

    /// Moves an effect to a new position; footswitch assignments follow the effect.
    public mutating func moveUnit(from: Int, to: Int) {
        guard from != to, (0..<Self.unitCount).contains(from), (0..<Self.unitCount).contains(to) else { return }
        var blocks = (0..<Self.unitCount).map { Array(bytes[($0 * Self.unitBytes)..<(($0 + 1) * Self.unitBytes)]) }
        var order = Array(0..<Self.unitCount)
        blocks.insert(blocks.remove(at: from), at: to)
        order.insert(order.remove(at: from), at: to)
        for (i, b) in blocks.enumerated() { bytes.replaceSubrange((i * Self.unitBytes)..<((i + 1) * Self.unitBytes), with: b) }
        let fs = footswitch
        if (1...9).contains(fs), let newIndex = order.firstIndex(of: fs - 1) { footswitch = newIndex + 1 }
    }

    /// The patch's Z-Pedal slot: the unit holding a Z-Pedal effect or ZP-None.
    /// On the G5 this unit only accepts Z-Pedal effects (anything else becomes ZP-None), and a Z-Pedal effect
    /// sent to any other unit is refused (that unit becomes empty). Verified on the pedal, firmware 1.20.
    public var zSlot: Int? { (0..<Self.unitCount).first { type($0)?.zpedal == true } }

    // MARK: patch-wide
    public var level: Int { get { field(864, 7) } set { setField(864, 7, newValue) } }
    public var footswitch: Int { get { field(871, 4) } set { setField(871, 4, newValue) } }

    public var name: String {
        get {
            let b = bytes[Self.nameOffset..<(Self.nameOffset + Self.nameLength)].map { $0 == 0 ? 0x20 : $0 }
            return String(decoding: b, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        set {
            let clean = String(newValue.filter { Self.nameCharacters.contains($0) }.prefix(Self.nameLength))
            let padded = Array(clean.utf8) + Array(repeating: 0x20, count: Self.nameLength - clean.utf8.count)
            bytes.replaceSubrange(Self.nameOffset..<(Self.nameOffset + Self.nameLength), with: padded)
        }
    }

    // MARK: messages
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
        }
        return c   // already the inverted CRC-32 that Zoom expects (no final xor)
    }

    /// Raw "store patch" message (0x08) for a memory slot, with checksum.
    public func storeMessage(slot: Int) -> [UInt8] {
        let crc = Self.crc32(bytes)
        let ck = (0..<5).map { UInt8((crc >> (7 * UInt32($0))) & 0x7F) }
        return [0xF0, 0x52, 0x00, G5Device.modelID, 0x08, 0x00, UInt8(slot / 3), UInt8(slot % 3),
                UInt8(Self.length & 0x7F), UInt8(Self.length >> 7)] + Packing.pack(bytes) + ck + [0xF7]
    }

    /// "Load into edit buffer" message (0x28): changes the sound immediately.
    public var editBufferMessage: [UInt8] { [0xF0, 0x52, 0x00, G5Device.modelID, 0x28] + Packing.pack(bytes) + [0xF7] }
}

extension G5Patch {
    public var patchData: PatchData? { PatchData(data) }
    public init(slot: Int, patchData: PatchData) { self.init(slot: slot, raw: patchData.storeMessage(slot: slot)) }
}
