import FileCatKit
import SwiftUI

/// Where MusiCat finds music (FileCat's library, its servers, and folders added here), the
/// hi-res audio status, and the long cat at the end.
struct SettingsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(HiResPlayer.self) private var player
    @State private var picking: Picking?
    @State private var errorMessage: String?
    @State private var meows = 0

    private enum Picking: Identifiable {
        case fileCat, folder
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                if library.isConnectedToFileCat {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Connect FileCat Library…", systemImage: "link") { picking = .fileCat }
                }
            } header: {
                Text("FileCat")
            } footer: {
                Text("In the folder picker, go to On My iPhone and select FileCat. Music in FileCat's Local Storage then shows up here, and stays in sync.")
            }

            ServersSection(errorMessage: $errorMessage)

            if !library.fileCatFolders.isEmpty {
                Section {
                    ForEach(library.fileCatFolders, id: \.self) { location in
                        LabeledContent {
                            Button("Add…") { picking = .folder }
                        } label: {
                            Label(location.name, systemImage: symbol(for: location.kind))
                        }
                    }
                } header: {
                    Text("Folders in FileCat")
                } footer: {
                    Text("Folders and drives added in FileCat. iOS gives each app its own access, so pick them once here too.")
                }
            }

            Section("Folders") {
                ForEach(library.folders, id: \.self) { folder in
                    Label(folder.lastPathComponent, systemImage: "folder")
                }
                Button("Add Folder…", systemImage: "folder.badge.plus") { picking = .folder }
            }

            Section {
                LabeledContent("Output", value: player.outputDescription)
                if player.current != nil {
                    LabeledContent("Playing", value: player.sourceFormat)
                    LabeledContent("Sample Rate", value: player.isBitPerfectRate ? "Matches the file" : "Resampled by iOS")
                }
            } header: {
                Text("Hi-Res Audio")
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Plug in a USB DAC with a Lightning or USB-C adapter: MusiCat switches it to each song's own sample rate, up to 192 kHz, for WAV, FLAC and ALAC.")
                    LongCat(meows: meows)
                }
            }
        }
        .onHardOverscroll {
            meows += 1
            Meow.play()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: meows)
        .navigationTitle("Settings")
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), allowedContentTypes: [.folder]) { result in
            let kind = picking
            picking = nil
            do {
                let url = try result.get()
                if kind == .fileCat {
                    try library.connectFileCat(to: url)
                } else {
                    try library.addFolder(url)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func symbol(for kind: SharedLocation.Kind) -> String {
        switch kind {
        case .folder: "folder"
        case .drive: "externaldrive"
        case .iCloud: "icloud"
        case .server: "server.rack"
        }
    }
}
