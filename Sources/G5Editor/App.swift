import SwiftUI
import G5Core

@main
struct G5EditorApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var monitor = MonitorController()
    @StateObject private var tuner = TunerController()
    init() { MainActor.assumeIsolated { Gallery.renderIfRequested() } }
    var body: some Scene {
        WindowGroup("G5 Editor") {
            ContentView().environmentObject(model).environmentObject(monitor).environmentObject(tuner)
                .onAppear { tuner.monitor = monitor }.frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Back Up Now") { model.backUpNow() }.keyboardShortcut("b").disabled(!model.isConnected || model.job != nil)
                Button("Import Backup…") { model.importBackup() }.keyboardShortcut("i")
            }
            CommandMenu("Monitor") {
                Button(monitor.isOn ? "Stop Monitoring" : "Start Monitoring") { monitor.toggle() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button(tuner.isOpen ? "Close Tuner" : "Tuner") { tuner.toggle() }.keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

/// View-local state holders (the command-line toolchain lacks the @State macro plugin).
final class Box<T>: ObservableObject { @Published var value: T; init(_ v: T) { value = v } }

func log(_ s: String) { FileHandle.standardError.write(Data("[G5] \(s)\n".utf8)) }
