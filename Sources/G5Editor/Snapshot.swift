import AppKit

/// Debug aid: with G5_SNAPSHOT=/path/prefix set, saves PNGs of the main window
/// (rendered in-process, so no screen-recording permission is needed).
enum Snapshot {
    @MainActor static func schedule(_ model: AppModel) {
        guard let prefix = ProcessInfo.processInfo.environment["G5_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            save("\(prefix)-editor.png")
            if let u = model.editing.flatMap({ e in (0..<9).first { e.patch.type($0)?.amp == true } }) { model.selectedUnit = u }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                save("\(prefix)-amp.png")
                model.browserUnit = model.selectedUnit
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    save("\(prefix)-browser.png", sheet: true)
                    model.browserUnit = nil
                }
            }
        }
    }

    @MainActor static func save(_ path: String, sheet: Bool = false) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }) else { return }
        let win = sheet ? (main.attachedSheet ?? main) : main
        guard let view = win.contentView?.superview ?? win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("snapshot \(path)")
    }
}

import SwiftUI
import G5Core

/// Debug aid: with G5_GALLERY=/path.png set, renders every amp and every pedal with a real-product look, then quits.
enum Gallery {
    @MainActor static func renderIfRequested() {
        if let path = ProcessInfo.processInfo.environment["G5_TUNERSHOT"] {
            let views = [(110.0 * pow(2, -18.0 / 1200), "flat"), (196.0 * pow(2, 1.0 / 1200), "intune"), (0, "idle")].map { f, _ -> AnyView in
                let t = TunerController(); if f > 0 { t.preview(f) }
                return AnyView(TunerView().environmentObject(t).background(Palette.panel))
            }
            write(HStack(spacing: 20) { ForEach(0..<views.count, id: \.self) { views[$0] } }.padding(20)
                    .background(Palette.background).environment(\.colorScheme, .dark), to: path)
        }
        if let path = ProcessInfo.processInfo.environment["G5_MONITORSHOT"] {
            let states: [(Float, LevelWarning?)] = [(0.3, nil), (1.0, .g5Clipping), (0.7, .monitorClipping)]
            let views = states.map { l, w -> AnyView in
                let m = MonitorController(); m.preview(level: l, warning: w)
                return AnyView(VStack(alignment: .leading) { MonitorSection() }.environmentObject(m).frame(width: 230, alignment: .top).padding(10).background(Palette.panel))
            }
            write(HStack(alignment: .top, spacing: 20) { ForEach(0..<views.count, id: \.self) { views[$0] } }.padding(20)
                    .background(Palette.background).environment(\.colorScheme, .dark), to: path)
        }
        guard let path = ProcessInfo.processInfo.environment["G5_GALLERY"] else { return }
        let types = EffectCatalog.shared.selectable
        let amps = types.filter(\.amp)
        let stomps = types.filter { !$0.amp && $0.stompLook != nil }
        let view = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(stride(from: 0, to: amps.count, by: 6)), id: \.self) { i in
                HStack(spacing: 14) { ForEach(amps[i..<min(i + 6, amps.count)], id: \.id) { UnitCard(info: UnitInfo(type: $0)) } }
            }
            ForEach(Array(stride(from: 0, to: stomps.count, by: 9)), id: \.self) { i in
                HStack(spacing: 12) { ForEach(stomps[i..<min(i + 9, stomps.count)], id: \.id) { UnitCard(info: UnitInfo(type: $0)) } }
            }
        }
        .padding(20).background(Palette.background).environment(\.colorScheme, .dark)
        write(view, to: path)
    }

    @MainActor static func write<V: View>(_ view: V, to path: String) {
        let r = ImageRenderer(content: view); r.scale = 1
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}
