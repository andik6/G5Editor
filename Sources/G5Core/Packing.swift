import Foundation

/// Zoom packs 8-bit data into 7-bit SysEx: each group starts with a byte
/// holding the high bits of the following (up to) 7 bytes; bit 6 belongs to
/// the first byte of the group, bit 5 to the second, and so on.
public enum Packing {
    public static func unpack(_ src: some Collection<UInt8>) -> [UInt8] {
        let s = Array(src); var out: [UInt8] = []; var i = 0
        while i < s.count {
            let hi = s[i]; var j = 1
            while j <= 7 && i + j < s.count {
                out.append(s[i + j] | (((hi >> (7 - j)) & 1) << 7)); j += 1
            }
            i += 8
        }
        return out
    }

    public static func pack(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; var i = 0
        while i < src.count {
            let chunk = src[i..<min(i + 7, src.count)]
            var hi: UInt8 = 0
            for (k, b) in chunk.enumerated() where b & 0x80 != 0 { hi |= 1 << (6 - k) }
            out.append(hi); out += chunk.map { $0 & 0x7F }
            i += 7
        }
        return out
    }
}
