import Foundation

/// A bank of three patches described in plain terms (effect and knob names), as written by a person or an AI.
/// `validate()` resolves it against the effect catalog; `apply(to:bank:)` writes it to the pedal.
///
/// JSON shape:
/// ```json
/// { "title": "Stars - Switchfoot",
///   "patches": [
///     { "name": "STARS VRS", "level": 80, "zpedal": "ZP-None",
///       "effects": [ { "effect": "VX COMBO", "on": true, "params": { "Gain": 45, "CAB": "VX COMBO 2x12" } } ] } ] }
/// ```
/// Knob values are what the pedal displays (e.g. delay Time in ms); choice knobs may use their label.
public struct BankSpec: Codable {
    public var title: String?
    public var notes: String?
    public var patches: [PatchSpec]

    public struct PatchSpec: Codable {
        public var name: String
        public var level: Int?
        public var zpedal: String?          // Z-Pedal slot effect; default ZP-None
        public var effects: [EffectSpec]    // in signal order, up to 8 (the 9th unit is the Z-Pedal slot)
        public var notes: String?
        public init(name: String, level: Int?, zpedal: String?, effects: [EffectSpec], notes: String?) {
            self.name = name; self.level = level; self.zpedal = zpedal; self.effects = effects; self.notes = notes
        }
    }

    public struct EffectSpec: Codable {
        public var effect: String
        public var on: Bool?
        public var params: [String: KnobValue]?
        public init(effect: String, on: Bool?, params: [String: KnobValue]?) { self.effect = effect; self.on = on; self.params = params }
    }

    public init(title: String?, notes: String?, patches: [PatchSpec]) { self.title = title; self.notes = notes; self.patches = patches }

    public enum KnobValue: Codable, CustomStringConvertible {
        case number(Int), label(String)
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .number(n) } else { self = .label(try c.decode(String.self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .number(let n): try c.encode(n); case .label(let s): try c.encode(s) }
        }
        public var description: String { switch self { case .number(let n): "\(n)"; case .label(let s): s } }
    }

    // MARK: resolved form

    public struct Resolved {
        public struct Unit { public let type: EffectType; public let on: Bool; public let raw: [(prm: Int, name: String, raw: Int)] }
        public struct Patch { public let name: String; public let level: Int?; public let zpedal: EffectType; public let units: [Unit] }
        public let patches: [Patch]
    }

    public static func load(_ url: URL) throws -> BankSpec { try JSONDecoder().decode(BankSpec.self, from: Data(contentsOf: url)) }

    /// Checks every name and value against the catalog and the G5's rules. Returns the resolved bank or all problems found.
    public func validate() -> Result<Resolved, ValidationErrors> {
        let cat = EffectCatalog.shared
        func find(_ n: String) -> EffectType? {
            let key = n.uppercased().filter { $0.isLetter || $0.isNumber }
            return cat.types.first { $0.name.uppercased().filter { $0.isLetter || $0.isNumber } == key }
        }
        var errors: [String] = [], out: [Resolved.Patch] = []
        if patches.isEmpty || patches.count > 3 { errors.append("A bank has 1 to 3 patches (got \(patches.count)).") }
        for (i, p) in patches.enumerated() {
            let where_ = "Patch \(i + 1) “\(p.name)”"
            if p.name.isEmpty || p.name.count > PatchData.nameLength || !p.name.allSatisfy({ PatchData.nameCharacters.contains($0) }) {
                errors.append("\(where_): name must be 1–10 characters from the G5's character set.")
            }
            if let l = p.level, !(0...120).contains(l) { errors.append("\(where_): level \(l) is outside 0–120.") }
            let z = find(p.zpedal ?? "ZP-None")
            if z == nil || z?.zpedal != true { errors.append("\(where_): Z-Pedal slot effect “\(p.zpedal ?? "")” is not a Z-Pedal effect.") }
            if p.effects.count > PatchData.unitCount - 1 { errors.append("\(where_): at most 8 effects besides the Z-Pedal slot (got \(p.effects.count)).") }
            var units: [Resolved.Unit] = []
            for (k, e) in p.effects.enumerated() {
                let at = "\(where_), effect \(k + 1) “\(e.effect)”"
                guard let t = find(e.effect), !t.hidden else { errors.append("\(at): unknown effect."); continue }
                if t.zpedal { errors.append("\(at): Z-Pedal effects only go in the patch's Z-Pedal slot (use \"zpedal\")."); continue }
                var raw: [(Int, String, Int)] = []
                for (pname, v) in e.params ?? [:] {
                    guard let prm = t.params.first(where: { $0.name.caseInsensitiveCompare(pname) == .orderedSame }) else {
                        errors.append("\(at): no knob “\(pname)” (knobs: \(t.params.map(\.name).joined(separator: ", "))).")
                        continue
                    }
                    let r: Int?
                    switch v {
                    // Knobs with display labels (e.g. Cent -25…25, Width L50…R50) are matched by label, numbers included:
                    // the AI writes what the pedal shows, never the raw index.
                    case .number(let n): r = prm.choices == nil ? n - prm.offset : prm.labelIndex("\(n)")
                    case .label(let s): r = prm.labelIndex(s)
                    }
                    let limit = prm.syncFrom ?? (prm.max + 1)   // free values only; tempo sync is not offered yet
                    guard let rv = r, rv >= 0, rv < limit else {
                        errors.append("\(at): \(prm.name) = \(v) is out of range (\(prm.offset)–\(limit - 1 + prm.offset)\(prm.choices.map { ", or one of: " + $0.joined(separator: ", ") } ?? "")).")
                        continue
                    }
                    raw.append((prm.prm, prm.name, rv))
                }
                units.append(.init(type: t, on: e.on ?? true, raw: raw.map { (prm: $0.0, name: $0.1, raw: $0.2) }))
            }
            if let z, z.zpedal { out.append(.init(name: p.name, level: p.level, zpedal: z, units: units)) }
        }
        return errors.isEmpty ? .success(Resolved(patches: out)) : .failure(ValidationErrors(messages: errors))
    }

    public struct ValidationErrors: Error, CustomStringConvertible {
        public let messages: [String]
        public var description: String { messages.map { "• " + $0 }.joined(separator: "\n") }
    }
}

extension BankSpec.Resolved {
    /// Writes the bank to `bank` (1–99) on the pedal: for each patch, builds it in the edit buffer (the pedal fills in
    /// defaults for every knob not given), stores it, and reads it back. The caller is responsible for a backup first.
    public func apply(to dev: G5Device, bank: Int, log: (String) -> Void = { print($0) }) throws {
        precondition((1...99).contains(bank))
        try dev.editorMode(true)
        defer { try? dev.editorMode(false) }
        for (i, p) in patches.enumerated() {
            let slot = (bank - 1) * 3 + i
            try dev.selectPatch(slot)
            Thread.sleep(forTimeInterval: 0.6)
            let start = try dev.readEditBuffer()
            guard let z = start.zSlot else { throw G5Error.badReply("Patch \(bank)-\(i + 1) has no Z-Pedal slot.") }
            let units = (0..<PatchData.unitCount).filter { $0 != z }
            func send(_ u: Int, _ prm: Int, _ v: Int) throws { try dev.sendParam(unit: u, prm: prm, value: v); Thread.sleep(forTimeInterval: 0.12) }
            // Z-Pedal slot first, then the effects in order on the remaining units; unused units become empty and off.
            try send(z, 1, p.zpedal.id); Thread.sleep(forTimeInterval: 0.25)
            for (k, u) in units.enumerated() {
                let spec = k < p.units.count ? p.units[k] : nil
                try send(u, 1, spec?.type.id ?? EffectCatalog.emptyID)
                Thread.sleep(forTimeInterval: 0.25)
                try send(u, 0, spec?.on == true ? 1 : 0)
                for r in spec?.raw ?? [] { try send(u, r.prm, r.raw) }
            }
            var data = try dev.readEditBuffer()
            for (k, u) in units.enumerated() where k < p.units.count {
                if data.typeID(u) != p.units[k].type.id {
                    throw G5Error.badReply("Pedal refused \(p.units[k].type.name) in \(bank)-\(i + 1), effect \(u + 1).")
                }
            }
            data.name = p.name
            if let l = p.level { data.level = l }
            try dev.store(data, slot: slot)
            let back = try dev.readPatch(slot)
            guard back.patchData == data else { throw G5Error.badReply("Read-back of \(bank)-\(i + 1) differs from what was written.") }
            log("  \(bank)-\(i + 1) “\(p.name)”: " + (0..<PatchData.unitCount).map { u in
                let t = data.type(u)?.name ?? "?"; return u == z ? "[Z:\(t)]" : (data.isOn(u) ? t : "(\(t))")
            }.joined(separator: " → ") + "  ✓ verified")
        }
    }
}

// MARK: - For AI assistants

extension BankSpec {

    /// Describes patches as they are on the pedal, in the same plain terms (used to tell an AI what a bank holds now).
    /// Empty units are left out; knobs the bank format can't express (tempo sync) are left out too.
    public init(describing patches: [PatchData], title: String? = nil) {
        self.title = title; self.notes = nil
        self.patches = patches.map { p in
            let z = p.zSlot
            let effects: [EffectSpec] = (0..<PatchData.unitCount).compactMap { u in
                guard u != z, let t = p.type(u), !t.isEmpty else { return nil }
                var params: [String: KnobValue] = [:]
                for prm in t.editableParams {
                    let raw = p.param(u, prm.prm)
                    if let s = prm.syncFrom, raw >= s { continue }
                    if let c = prm.choices, raw < c.count { params[prm.name] = Int(c[raw]).map { .number($0) } ?? .label(c[raw]) }
                    else { params[prm.name] = .number(raw + prm.offset) }
                }
                return EffectSpec(effect: t.name, on: p.isOn(u), params: params)
            }
            return PatchSpec(name: p.name, level: p.level, zpedal: z.flatMap { p.type($0)?.name } ?? "ZP-None", effects: effects, notes: nil)
        }
    }

    public func json() -> String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Finds the last ```json … ``` block (or a bare JSON object) in an AI reply and decodes it.
    public static func extract(from reply: String) -> (spec: BankSpec?, error: String?, prose: String) {
        var body: Substring?
        var prose = reply
        if let fence = reply.range(of: "```json", options: .backwards),
           let end = reply.range(of: "```", range: fence.upperBound..<reply.endIndex) {
            body = reply[fence.upperBound..<end.lowerBound]
            prose = String(reply[..<fence.lowerBound] + reply[end.upperBound...])
        } else if let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"), a < b, reply.contains("\"patches\"") {
            body = reply[a...b]
            prose = String(reply[..<a] + reply[reply.index(after: b)...])
        }
        guard let body else { return (nil, nil, reply) }
        do { return (try JSONDecoder().decode(BankSpec.self, from: Data(body.utf8)), nil, prose.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { return (nil, "The bank JSON could not be read: \(error)", prose.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Every effect an AI may use, with knob names, ranges (as displayed) and choices. About 6k tokens.
    public static func catalogReference() -> String {
        let cat = EffectCatalog.shared
        var lines: [String] = ["Values are written as the pedal displays them: \"Cent -25…25\" takes -25 to 25 (0 = none), \"Width L50…R50\" takes \"L50\", \"0\", \"R20\" and so on."]
        var group = ""
        for t in cat.selectable.sorted(by: { ($0.group.rawValue, $0.name) < ($1.group.rawValue, $1.name) }) {
            if t.group.rawValue != group {
                group = t.group.rawValue; lines.append("\n## \(group)")
                if t.amp, let cab = t.params.first(where: { $0.name == "CAB" })?.choices {
                    lines.append("Every amp's CAB knob takes one of: \(cab.joined(separator: " | ")).")
                }
            }
            let knobs = t.editableParams.map { p -> String in
                if t.amp && p.name == "CAB" { return "CAB (cabinet)" }
                let top = (p.syncFrom ?? (p.max + 1)) - 1
                if let c = p.choices, p.isChoice { return "\(p.name){\(c.prefix(top + 1).joined(separator: "|"))}" }
                if let c = p.choices { return "\(p.name) \(c[0])…\(c[min(top, c.count - 1)])" }
                return "\(p.name) \(p.offset)–\(top + p.offset)"
            }.joined(separator: "; ")
            var extra = ""
            if let c = t.cabinet { extra += " — models: " + (c.components(separatedBy: " · ").last ?? c).replacingOccurrences(of: " cabinet with", with: ",") }
            else if let d = t.description { extra += " — " + (d.hasSuffix(".") ? String(d.dropLast()) : d) }
            lines.append("- \(t.name)\(extra). Knobs: \(knobs)")
        }
        return lines.joined(separator: "\n")
    }
}
