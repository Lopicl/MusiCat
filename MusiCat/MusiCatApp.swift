import FileCatKit
import SwiftUI

@main
struct MusiCatApp: App {
    @State private var library: MusicLibrary
    @State private var playlists = PlaylistStore()
    @State private var player: HiResPlayer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // For FileCat's UI tests: `-MusiCatUITestReset YES` starts without servers or downloads.
        if UserDefaults.standard.bool(forKey: "MusiCatUITestReset") {
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            try? FileManager.default.removeItem(at: SongDownloads.folder)
            try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "ServerTags.json"))
        }
        #endif
        let library = MusicLibrary()
        _library = State(initialValue: library)
        _player = State(initialValue: HiResPlayer(servers: library.servers))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(playlists)
                .environment(player)
                .task { await library.refresh() }
                .onOpenURL { url in
                    // FileCat's answer to "Import Servers from FileCat".
                    guard let reply = ServerShareReply(url: url) else { return }
                    library.servers.importServers(reply)
                    Task { await library.refresh() }
                }
        }
        .onChange(of: scenePhase) {
            // Servers may have changed in FileCat meanwhile.
            if scenePhase == .active { library.syncServers() }
        }
    }
}
