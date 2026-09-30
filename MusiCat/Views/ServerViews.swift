import FileCatKit
import SwiftUI

/// The servers section of Settings: servers imported from FileCat, and the ones still to import.
struct ServersSection: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.openURL) private var openURL
    @Binding var errorMessage: String?

    private var servers: ServerStore { library.servers }

    var body: some View {
        Section {
            ForEach(servers.servers) { server in
                NavigationLink {
                    ServerView(serverID: server.id)
                } label: {
                    ServerRow(server: server, folderCount: servers.musicFolders[server.id]?.count ?? 0, error: servers.errors[server.id])
                }
            }
            ForEach(servers.needingImport.filter { servers.server(id: $0.id) == nil }) { server in
                LabeledContent {
                    Text("Not Imported")
                } label: {
                    Label(server.name, systemImage: NetworkSource.Kind(rawValue: server.kind)?.systemImage ?? "server.rack")
                }
            }
            if !servers.needingImport.isEmpty || servers.servers.isEmpty {
                Button(servers.servers.isEmpty ? "Import Servers from FileCat…" : "Update from FileCat…", systemImage: "arrow.down.circle") {
                    openURL(ServerStore.importRequest.url) { opened in
                        if !opened { errorMessage = "FileCat isn't installed." }
                    }
                }
                .accessibilityIdentifier("importServers")
            }
        } header: {
            Text("Servers")
        } footer: {
            if servers.needingImport.contains(where: { servers.server(id: $0.id) != nil }) {
                Text("A password changed in FileCat. Update to get the new one.")
            } else {
                Text("FileCat asks before it shares your servers and their passwords. After that, changes in FileCat show up here by themselves. Choose the folders with music on each server.")
            }
        }
    }
}

private struct ServerRow: View {
    let server: NetworkSource
    let folderCount: Int
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(server.name, systemImage: server.kind.systemImage)
            Group {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if folderCount == 0 {
                    Text("Choose music folders")
                } else {
                    Text(folderCount == 1 ? "1 music folder" : "\(folderCount) music folders")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }
}

/// A server's music folders.
struct ServerView: View {
    let serverID: String

    @Environment(MusicLibrary.self) private var library

    var body: some View {
        if let server = library.servers.server(id: serverID) {
            List {
                Section {
                    ForEach(library.servers.musicFolders[server.id] ?? [], id: \.self) { path in
                        Label(path == "/" ? server.name : path, systemImage: "folder")
                    }
                    .onDelete { offsets in
                        let folders = library.servers.musicFolders[server.id] ?? []
                        offsets.map { folders[$0] }.forEach { library.servers.removeMusicFolder($0, on: server) }
                        Task { await library.refresh() }
                    }
                    NavigationLink {
                        RemoteFolderView(server: server, path: "/")
                    } label: {
                        Label("Add Music Folder…", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Music Folders")
                } footer: {
                    Text("Songs in these folders and the folders inside them are in your library. Songs download when they play and stay on the device for next time.")
                }
                Section {
                    LabeledContent("Address", value: server.displayAddress)
                    if !server.username.isEmpty {
                        LabeledContent("User", value: server.username)
                    }
                } footer: {
                    Text("Imported from FileCat. Change or remove the server in FileCat and MusiCat follows.")
                }
            }
            .navigationTitle(server.name)
        } else {
            ContentUnavailableView("Server Removed", systemImage: "server.rack", description: Text("This server was removed in FileCat."))
        }
    }
}

/// Browses a folder on a server: open folders, play songs, and choose the folder for the library.
struct RemoteFolderView: View {
    let server: NetworkSource
    let path: String

    @Environment(MusicLibrary.self) private var library
    @Environment(HiResPlayer.self) private var player
    @State private var entries: [RemoteEntry]?
    @State private var error: String?

    private var isMusicFolder: Bool {
        (library.servers.musicFolders[server.id] ?? []).contains(RemotePath.normalized(path))
    }

    private var songs: [Track] {
        (entries ?? [])
            .filter { !$0.isDirectory && Track.extensions.contains(($0.name as NSString).pathExtension.lowercased()) }
            .map { entry in
                let file = RemotePath.join(path, entry.name)
                let id = "server:\(server.id):\(file)"
                return library.track(id: id) ?? Track(id: id, location: .server(id: server.id, path: file, size: entry.size), tags: SongTags())
            }
    }

    var body: some View {
        List {
            if let entries {
                ForEach(entries.filter(\.isDirectory), id: \.name) { folder in
                    NavigationLink {
                        RemoteFolderView(server: server, path: RemotePath.join(path, folder.name))
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
                let songs = songs
                ForEach(songs) { song in
                    Button {
                        player.play(song, in: songs)
                    } label: {
                        Label(song.title, systemImage: "music.note")
                            .foregroundStyle(player.current == song ? Color.accentColor : .primary)
                    }
                }
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if entries == nil {
                ProgressView()
            } else if entries?.isEmpty == true {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .navigationTitle(path == "/" ? server.name : RemotePath.name(of: path))
        .toolbar {
            Button(isMusicFolder ? "In Library" : "Use for Music", systemImage: isMusicFolder ? "checkmark.circle.fill" : "plus.circle") {
                if isMusicFolder {
                    library.servers.removeMusicFolder(RemotePath.normalized(path), on: server)
                } else {
                    library.servers.addMusicFolder(path, on: server)
                }
                Task { await library.refresh() }
            }
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("useForMusic")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let fileSystem = try await RemoteConnections.shared.fileSystem(for: server)
            entries = try await fileSystem.list(path)
                .filter { !$0.name.hasPrefix(".") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
        } catch {
            await RemoteConnections.shared.invalidate(server.id)
            self.error = error.localizedDescription
        }
    }
}
