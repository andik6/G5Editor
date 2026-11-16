import Foundation

/// A backup is a standard .syx file: every patch's raw 0x08 message back to back,
/// exactly as the pedal sent it (checksums included), in slot order.
public enum Backup {
    public static let patchCount = 297   // 99 groups × 3 patches

    public static func slot(of raw: [UInt8]) -> Int { Int(raw[6]) * 3 + Int(raw[7]) }

    public static func write(_ patches: [G5Patch], to url: URL) throws {
        let bytes = patches.sorted { $0.slot < $1.slot }.flatMap(\.raw)
        try Data(bytes).write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) throws -> [G5Patch] {
        let d = [UInt8](try Data(contentsOf: url))
        var out: [G5Patch] = []; var i = 0
        while let s = d[i...].firstIndex(of: 0xF0), let e = d[s...].firstIndex(of: 0xF7) {
            let m = Array(d[s...e])
            if m.count > 20, m[1] == 0x52, m[3] == G5Device.modelID, m[4] == 0x08 {
                out.append(G5Patch(slot: slot(of: m), raw: m))
            }
            i = e + 1
        }
        guard !out.isEmpty else { throw G5Error.badReply("no G5 patches found in \(url.lastPathComponent)") }
        return out
    }

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/G5 Backups", isDirectory: true)
    }

    public static func timestampedURL() -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return defaultFolder.appendingPathComponent("G5 backup \(f.string(from: Date())).syx")
    }
}

extension G5Device {
    /// Reads every patch. `progress` is called with (done, total).
    public func readAll(progress: (Int, Int) -> Void = { _, _ in }) throws -> [G5Patch] {
        try editorMode(true)
        defer { try? editorMode(false) }
        var out: [G5Patch] = []
        for s in 0..<Backup.patchCount {
            var p: G5Patch?
            for _ in 0..<3 where p == nil { p = try? readPatch(s) }   // retry flaky USB reads
            guard let got = p else { throw G5Error.timeout("patch \(s + 1)") }
            guard Backup.slot(of: got.raw) == s else { throw G5Error.badReply("asked for patch \(s + 1), got \(Backup.slot(of: got.raw) + 1)") }
            out.append(got); progress(s + 1, Backup.patchCount)
        }
        return out
    }
}
