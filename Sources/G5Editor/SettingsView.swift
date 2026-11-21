import SwiftUI

/// App settings (⌘,). For now: which AI the Sound Patcher uses.
struct SettingsView: View {
    @EnvironmentObject var patcher: PatcherController

    var body: some View {
        TabView {
            patcherTab.tabItem { Label("Sound Patcher", systemImage: "sparkles") }
        }
        .frame(width: 520)
        .onAppear { patcher.checkStatus() }
    }

    private var patcherTab: some View {
        Form {
            Section {
                Picker("AI assistant", selection: $patcher.backend) {
                    ForEach(PatcherBackend.allCases) { b in Text(b.name).tag(b) }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("The Sound Patcher runs the assistant's command-line tool on this Mac, using your own subscription. G5 Editor stores no API key and adds no cost of its own. The assistant may only search and read the web; it can't change files on your Mac. Switching starts a new chat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status") {
                ForEach(PatcherBackend.allCases) { b in row(b) }
                HStack {
                    Spacer()
                    Button("Check Again") { patcher.checkStatus() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func row(_ b: PatcherBackend) -> some View {
        let s = patcher.status[b] ?? .checking
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                switch s {
                case .checking: ProgressView().controlSize(.small)
                case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .loggedOut: Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                case .missing: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                }
                Text(b.name).fontWeight(b == patcher.backend ? .semibold : .regular)
                Spacer()
                Text(label(s)).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail(b, s)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func label(_ s: PatcherBackend.Status) -> String {
        switch s {
        case .checking: "Checking…"
        case .ready: "Ready"
        case .loggedOut: "Not logged in"
        case .missing: "Not installed"
        }
    }

    private func detail(_ b: PatcherBackend, _ s: PatcherBackend.Status) -> String {
        switch s {
        case .missing: b.installHint
        case .loggedOut: b.loginHint.replacingOccurrences(of: " Then send the message again.", with: "")
        default: "Uses your \(b.account). \(b.locate()?.path ?? "")"
        }
    }
}
