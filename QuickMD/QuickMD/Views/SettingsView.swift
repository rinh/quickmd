import SwiftUI

/// Settings window (⌘,): general behaviour + theme picker + document fonts +
/// external editor selection.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
            FontPickerView()
                .tabItem { Label("Fonts", systemImage: "textformat") }
            ExternalEditorPickerView()
                .tabItem { Label("Editor", systemImage: "pencil") }
        }
    }
}

// MARK: - General

/// Settings → General: behaviour that is not about how the document looks.
/// Today only the opt-in auto-copy of selections (v1.11 S-D10); same grouped
/// Form and window size as the other tabs, so switching tabs does not resize
/// the window.
struct GeneralSettingsView: View {
    @AppStorage(SelectionAutoCopy.defaultsKey) private var autoCopySelection: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Copy selected text automatically", isOn: $autoCopySelection)
                } header: {
                    Text("Selection")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Selected text is copied to the clipboard as soon as you finish selecting. Off by default because it replaces whatever you copied in another app.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                #if !APPSTORE
                MermaidRendererSection()
                #endif
            }
            .formStyle(.grouped)
        }
        .frame(width: 360, height: 420)
    }
}

#if !APPSTORE
/// Settings ▸ General ▸ Mermaid: the bundled mermaid.js, or the reader's own
/// mmdc (MermaidCLI.swift). Not in the Mac App Store build — the sandbox does
/// not let it run mmdc.
private struct MermaidRendererSection: View {
    @AppStorage(MermaidCLI.rendererKey) private var renderer = MermaidCLI.Renderer.builtIn.rawValue
    @AppStorage(MermaidCLI.pathKey) private var mmdcPath = ""
    @AppStorage(MermaidCLI.configPathKey) private var configPath = ""
    @State private var status: String?
    @State private var isChecking = false

    var body: some View {
        Section {
            Picker("Renderer", selection: $renderer) {
                ForEach(MermaidCLI.Renderer.allCases) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            if renderer == MermaidCLI.Renderer.mmdc.rawValue {
                TextField("mmdc path", text: $mmdcPath, prompt: Text("Automatic"))
                TextField("Config file", text: $configPath, prompt: Text("None (-c config.json)"))
                HStack {
                    Button("Test mmdc") { check() }
                        .disabled(isChecking)
                    if isChecking { ProgressView().controlSize(.small) }
                }
                if let status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Mermaid")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
        } footer: {
            Text("mmdc draws each diagram with your installed mermaid-cli (about a second per diagram, cached afterwards). If it fails, the built-in renderer is used.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func check() {
        isChecking = true
        status = nil
        DispatchQueue.global(qos: .userInitiated).async {
            MermaidCLI.resetDiscovery()
            let text = MermaidCLI.statusDescription()
            DispatchQueue.main.async {
                status = text
                isChecking = false
            }
        }
    }
}
#endif
