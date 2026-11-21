import SwiftUI
import G5Core

final class BrowserState: ObservableObject {
    @Published var group: EffectGroup? = nil
    @Published var search = ""
}

struct EffectBrowser: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let unit: Int
    @StateObject private var st = BrowserState()

    /// The patch's Z-Pedal slot. That unit only takes Z-Pedal effects, and Z-Pedal effects only fit there.
    private var zSlot: Int? { model.editing?.patch.zSlot }
    private var isZSlot: Bool { zSlot == unit }
    private var allowed: [EffectType] {
        EffectCatalog.shared.selectable.filter { zSlot == nil || $0.zpedal == isZSlot }
    }

    private var groups: [EffectGroup] {
        let present = Set(allowed.map(\.group))
        return EffectGroup.allCases.filter { present.contains($0) && $0 != .empty }
    }

    private var shown: [EffectType] {
        allowed.filter { t in
            !t.isEmpty
                && (st.group == nil || t.group == st.group)
                && (st.search.isEmpty || t.name.localizedCaseInsensitiveContains(st.search)
                    || (t.description ?? "").localizedCaseInsensitiveContains(st.search)
                    || (t.cabinet ?? "").localizedCaseInsensitiveContains(st.search))
        }
        .sorted { a, b in
            let ia = EffectGroup.allCases.firstIndex(of: a.group)!, ib = EffectGroup.allCases.firstIndex(of: b.group)!
            return ia != ib ? ia < ib : a.name < b.name
        }
    }

    var body: some View {
        let current = model.editing?.patch.typeID(unit)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isZSlot ? "EFFECT \(unit + 1) · Z-PEDAL SLOT" : "EFFECT \(unit + 1)")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.bottom, 8)
                groupRow(nil, "All", "square.grid.2x2")
                ForEach(groups) { g in groupRow(g, g.rawValue, g.symbol) }
                Spacer()
            }
            .padding(14).frame(width: 200).background(Palette.panel)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search effects and amps (e.g. Marshall, delay)", text: $st.search).textFieldStyle(.plain)
                    Spacer()
                    Button(isZSlot ? "ZP-None" : "Empty Slot") {
                        model.setType(unit, isZSlot ? EffectCatalog.zpNoneID : EffectCatalog.emptyID); dismiss()
                    }
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(12).background(Palette.panel)
                if let z = zSlot {
                    Label(isZSlot ? "This is the patch's Z-Pedal slot. On the G5 it can only hold a Z-Pedal effect."
                                  : "Z-Pedal effects are only available in this patch's Z-Pedal slot (effect \(z + 1)).",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 18) {
                        ForEach(shown) { t in
                            Button { model.setType(unit, t.id); dismiss() } label: { tile(t, isCurrent: t.id == current) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 960, height: 640)
        .background(Palette.background)
    }

    private func groupRow(_ g: EffectGroup?, _ title: String, _ symbol: String) -> some View {
        Button { st.group = g } label: {
            HStack {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(g?.color ?? .secondary)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(st.group == g ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tile(_ t: EffectType, isCurrent: Bool) -> some View {
        VStack(spacing: 8) {
            UnitCard(info: UnitInfo(type: t), compact: true).allowsHitTesting(false)
            Text(t.name).font(.system(size: 13, weight: .bold))
            Text(t.cabinet ?? t.description ?? t.group.rawValue)
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineLimit(3).frame(height: 44, alignment: .top)
            if t.zpedal { Text("Z-PEDAL").font(.system(size: 9, weight: .bold)).foregroundStyle(EffectGroup.zpedal.color) }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isCurrent ? Palette.accent : Palette.panelLine, lineWidth: isCurrent ? 2 : 1))
        .contentShape(Rectangle())
    }
}
