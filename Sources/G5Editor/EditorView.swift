import SwiftUI
import UniformTypeIdentifiers
import G5Core

struct EditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if !model.isConnected {
                ContentUnavailableView {
                    Label("G5 not connected", systemImage: "cable.connector.slash")
                } description: {
                    Text("Connect the G5 with a USB cable and switch it on. It will appear here automatically.")
                } actions: { Button("Try Again") { model.connect() } }
            } else if let e = model.editing {
                VStack(spacing: 0) {
                    PatchHeader(session: e)
                    ChainView(patch: e.patch)
                    Divider().overlay(Palette.panelLine)
                    UnitPanel(patch: e.patch, unit: min(model.selectedUnit, PatchData.unitCount - 1))
                }
                .overlay(alignment: .top) {
                    if model.switching { ProgressView().controlSize(.small).padding(8).background(.ultraThinMaterial, in: Capsule()).padding(8) }
                }
            } else {
                ProgressView(model.pedalPatches.isEmpty ? "Reading patches…" : "Opening patch…")
            }
        }
        .background(Palette.background)
        .navigationTitle(model.editing.map { "\(AppModel.label($0.slot))  \($0.patch.name)" } ?? "G5 Editor")
        .sheet(item: Binding(get: { model.browserUnit.map { BrowserTarget(unit: $0) } }, set: { model.browserUnit = $0?.unit })) { t in
            EffectBrowser(unit: t.unit).environmentObject(model)
        }
    }
}

struct BrowserTarget: Identifiable { var unit: Int; var id: Int { unit } }

// MARK: - Header

struct PatchHeader: View {
    @EnvironmentObject var model: AppModel
    let session: EditSession
    @StateObject private var name = Box("")
    @StateObject private var lastSlot = Box(-1)

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BANK \(session.slot / 3 + 1)  ·  PATCH \(session.slot % 3 + 1)")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(1)
                TextField("Name", text: $name.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .frame(width: 200)
                    .onSubmit { model.rename(name.value) }
                    .onChange(of: name.value) { _, v in
                        let clean = String(v.filter { PatchData.nameCharacters.contains($0) }.prefix(PatchData.nameLength))
                        if clean != v { name.value = clean }
                    }
                    .help("Up to 10 characters. Press Return to save the name.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PATCH LEVEL  \(session.patch.level)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(session.patch.level) }, set: { model.setLevel(Int($0.rounded())) }), in: 0...120)
                    .frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("CONTROL SWITCH").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { session.patch.footswitch }, set: { model.setFootswitch($0) })) {
                    ForEach(Array(PatchData.footswitchNames.enumerated()), id: \.offset) { i, n in
                        Text(i >= 1 && i <= 9 ? "\(n) – \(session.patch.type(i - 1)?.name ?? "")" : n).tag(i)
                    }
                }.labelsHidden().frame(width: 180)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button("Revert") { model.revert() }.fixedSize()
                        .disabled(!session.isModified)
                        .help("Undo every change since you opened this patch")
                    Button("Save to Pedal") { model.saveNow() }.fixedSize()
                        .help("Store this patch in the pedal's memory now")
                }
                Text(session.isModified ? "Edited · auto-saved by the pedal" : "Edits play live on the pedal")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Palette.panel)
        .onAppear { sync() }
        .onChange(of: session.slot) { _, _ in sync() }
        .onChange(of: session.patch.name) { _, _ in if lastSlot.value == session.slot { name.value = session.patch.name } }
    }

    private func sync() { name.value = session.patch.name; lastSlot.value = session.slot }
}

// MARK: - Chain

struct ChainView: View {
    @EnvironmentObject var model: AppModel
    let patch: PatchData

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                Jack(label: "GUITAR", symbol: "guitars")
                ForEach(0..<PatchData.unitCount, id: \.self) { i in
                    Cable()
                    VStack(spacing: 6) {
                        UnitCard(info: UnitInfo(patch, i), selected: model.selectedUnit == i) {
                            model.setOn(i, !patch.isOn(i))
                        }
                        .onTapGesture { model.selectedUnit = i }
                        .onTapGesture(count: 2) { model.selectedUnit = i; model.browserUnit = i }
                        .onDrag { model.selectedUnit = i; return NSItemProvider(object: String(i) as NSString) }
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in
                            _ = providers.first?.loadObject(ofClass: NSString.self) { obj, _ in
                                if let s = obj as? String, let from = Int(s) {
                                    DispatchQueue.main.async { model.move(from, to: i) }
                                }
                            }
                            return true
                        }
                        Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                Cable()
                Jack(label: "OUTPUT", symbol: "speaker.wave.2")
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
        }
        .frame(height: 250)
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.12, blue: 0.13), Color(red: 0.07, green: 0.07, blue: 0.08)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .topTrailing) {
            Text("Click a footswitch to turn an effect on/off · drag to reorder · double-click to change")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 5)
        }
    }
}

struct Cable: View {
    var body: some View {
        Rectangle().fill(Color(white: 0.28)).frame(width: 18, height: 4).padding(.bottom, 18)
    }
}

struct Jack: View {
    let label: String; let symbol: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(label).font(.system(size: 9, weight: .bold)).tracking(1)
        }
        .foregroundStyle(.secondary)
        .frame(width: 64).padding(.bottom, 18)
    }
}

// MARK: - Selected effect

struct UnitPanel: View {
    @EnvironmentObject var model: AppModel
    let patch: PatchData
    let unit: Int

    var body: some View {
        let type = patch.type(unit)
        let group = type?.group ?? .empty
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: group.symbol)
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(group.color.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("EFFECT \(unit + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(group.rawValue.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(group.color)
                        }
                        Text(type?.isEmpty == false ? type!.name : "Empty slot").font(.system(size: 24, weight: .heavy, design: .rounded))
                        if let d = type?.description ?? type?.cabinet.map({ "Models a \($0)" }) {
                            Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if type?.isEmpty == false {
                        Toggle("On", isOn: Binding(get: { patch.isOn(unit) }, set: { model.setOn(unit, $0) }))
                            .toggleStyle(.switch)
                    }
                    Button(type?.isEmpty == false ? "Change Effect…" : "Add Effect…") { model.browserUnit = unit }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                    Menu {
                        Button("Move Left") { model.move(unit, to: unit - 1) }.disabled(unit == 0)
                        Button("Move Right") { model.move(unit, to: unit + 1) }.disabled(unit == PatchData.unitCount - 1)
                        Divider()
                        Button("Remove Effect", role: .destructive) { model.setType(unit, EffectCatalog.emptyID) }
                            .disabled(type?.isEmpty != false)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 34)
                }

                if let type, !type.isEmpty {
                    let params = type.editableParams
                    if type.amp, let cab = params.first(where: { $0.name == "CAB" }) {
                        CabinetPicker(param: cab, value: patch.param(unit, cab.prm)) { model.setParam(unit, cab.prm, $0) }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(params.filter { !(type.amp && $0.name == "CAB") }) { p in
                            let v = patch.param(unit, p.prm)
                            if p.isChoice {
                                ChoiceControl(param: p, value: v) { model.setParam(unit, p.prm, $0) }
                            } else {
                                Knob(param: p, value: v, tint: group == .amp ? Palette.accent : group.color) { model.setParam(unit, p.prm, $0) }
                            }
                        }
                    }
                    if type.params.count > params.count || type.name == "CUSTOM" {
                        Label("Some settings of this Z-Pedal effect can only be changed on the pedal for now.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("This slot is empty. Add an effect or an amp to use it.").foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
        .background(Palette.background)
    }
}

struct CabinetPicker: View {
    let param: EffectParam
    let value: Int
    let onChange: (Int) -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hifispeaker.2.fill").font(.system(size: 26)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("CABINET").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Picker("Cabinet", selection: Binding(get: { value }, set: onChange)) {
                    ForEach(Array((param.choices ?? []).enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                }.labelsHidden().frame(width: 220)
            }
            if let label = param.choices?[safe: value] {
                Text(EffectCatalog.shared.cabinetInfo(label) ?? (label == "OFF" ? "No cabinet simulation" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
