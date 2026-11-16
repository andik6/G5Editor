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
