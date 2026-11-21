import Foundation

public struct EffectParam: Decodable, Hashable, Identifiable {
    public let prm: Int
    public let name: String
    public let max: Int
    public let initial: Int
    public let offset: Int
    public let pedal: Bool
    public let control: String
    public let choices: [String]?
    public let syncFrom: Int?
    public let syncCount: Int
    public var id: Int { prm }

    /// Tempo-synced note values, shortest first. NOTE: order inferred from other
    /// Zoom pedals; not yet verified against the G5's display.
    static let syncNotes: [String] = ["𝅘𝅥𝅯𝅘𝅥𝅯 1/32", "1/16 trip", "1/16", "1/8 trip", "1/16 dot", "1/8", "1/4 trip", "1/8 dot", "1/4", "1/4 dot"]
        + (2...19).map { "1/4 ×\($0)" }

    public var isChoice: Bool { choices != nil && (choices!.count <= 32 || control != "Knob") }
    /// Raw value for a display label ("-13", "+12", "R20", "Fast"), ignoring case and a leading "+".
    public func labelIndex(_ label: String) -> Int? {
        let s = label.hasPrefix("+") ? String(label.dropFirst()) : label
        return choices?.firstIndex { $0.caseInsensitiveCompare(s) == .orderedSame }
    }

    public func display(_ raw: Int) -> String {
        if let s = syncFrom, raw >= s {
            let i = raw - s
            return i < Self.syncNotes.count ? "♩ " + Self.syncNotes[i].replacingOccurrences(of: "𝅘𝅥𝅯𝅘𝅥𝅯 ", with: "") : "sync \(i + 1)"
        }
        if let c = choices, raw >= 0, raw < c.count { return c[raw] }
        return "\(raw + offset)"
    }
}

public struct EffectType: Decodable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let category: String?
    public let amp: Bool
    public let zpedal: Bool
    public let thru: Bool
    public let hidden: Bool
    public let params: [EffectParam]
    public let description: String?
    public let cabinet: String?

    public var isEmpty: Bool { thru || name == "ZP-None" }

    /// Friendly category used for browsing and colours.
    public var group: EffectGroup {
        if isEmpty { return .empty }
        if zpedal { return .zpedal }
        if amp { return .amp }
        switch category ?? "" {
        case "Dynamics": return .dynamics
        case "Filter_EQ": return .filter
        case "Stomp Modeling", "Original Stomp": return .drive
        case "Original Amp": return .drive
        case "Modulation": return .modulation
        case "Delay": return .delay
        case "Reverb": return .reverb
        case "Combination Fx": return .combo
        case "Pedal Fx": return .pedal
        case "SFX": return .sfx
        default: return .other
        }
    }

    /// Only these knob positions are mapped in the patch data.
    public var editableParams: [EffectParam] { params.filter { PatchData.paramLayout[$0.prm] != nil } }
}

public enum EffectGroup: String, CaseIterable, Identifiable {
    case dynamics = "Dynamics", filter = "Filter & EQ", drive = "Drive & Distortion", amp = "Amps",
         modulation = "Modulation", delay = "Delay", reverb = "Reverb", combo = "Combination",
         pedal = "Pedal", zpedal = "Z-Pedal", sfx = "Special FX", other = "Other", empty = "Empty"
    public var id: String { rawValue }
}

public final class EffectCatalog {
    public static let shared = EffectCatalog()
    public let types: [EffectType]
    private let byID: [Int: EffectType]
    public static let emptyID = 107
    /// "ZP-None": the empty choice for a patch's Z-Pedal slot.
    public static let zpNoneID = 165

    init() {
        types = (try? JSONDecoder().decode([EffectType].self, from: Data(effectsJSON.utf8))) ?? []
        byID = Dictionary(types.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func type(_ id: Int) -> EffectType? { byID[id] }

    /// Types a user can pick (excludes internal placeholders).
    public var selectable: [EffectType] { types.filter { !$0.hidden && $0.name != "ZP-None" && $0.name != "CUSTOM" } }

    /// Description of a cabinet choice such as "MS 1959 4x12".
    public func cabinetInfo(_ label: String) -> String? {
        let key = label.lowercased().replacingOccurrences(of: " ", with: "")
        return types.first { $0.amp && key.hasPrefix($0.name.lowercased().replacingOccurrences(of: " ", with: "")) }?.cabinet
    }
}
