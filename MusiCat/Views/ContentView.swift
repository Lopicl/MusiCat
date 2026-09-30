import SwiftUI

struct ContentView: View {
    @Environment(HiResPlayer.self) private var player
    @State private var showsNowPlaying = false

    var body: some View {
        TabView {
            Tab("Songs", systemImage: "music.note") {
                NavigationStack { SongsView() }
            }
            Tab("Artists", systemImage: "music.microphone") {
                NavigationStack { ArtistsView() }
            }
            Tab("Albums", systemImage: "square.stack") {
                NavigationStack { AlbumsView() }
            }
            Tab("Playlists", systemImage: "music.note.list") {
                NavigationStack { PlaylistsView() }
            }
            Tab("Sources", systemImage: "externaldrive.connected.to.line.below") {
                NavigationStack { SourcesView() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if player.current != nil {
                NowPlayingBar { showsNowPlaying = true }
                    .padding(.bottom, 56)
            }
        }
        .sheet(isPresented: $showsNowPlaying) {
            NowPlayingView()
        }
    }
}

/// A list of songs that plays the list as a queue when one is tapped.
struct TrackList: View {
    let tracks: [Track]

    @Environment(HiResPlayer.self) private var player
    @Environment(PlaylistStore.self) private var playlists

    var body: some View {
        List(tracks) { track in
            Button {
                player.play(track, in: tracks)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .foregroundStyle(player.current == track ? Color.accentColor : .primary)
                    Text(track.artistLine + (track.album.map { " · " + $0 } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contextMenu {
                Menu("Add to Playlist", systemImage: "text.badge.plus") {
                    ForEach(playlists.playlists) { playlist in
                        Button(playlist.name) { playlists.add(track, to: playlist) }
                    }
                    Button("New Playlist…", systemImage: "plus") {
                        playlists.add(track, to: playlists.create(named: track.title))
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct SongsView: View {
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        TrackList(tracks: library.tracks)
            .navigationTitle("Songs")
            .overlay {
                if library.tracks.isEmpty {
                    if library.isScanning {
                        ProgressView()
                    } else {
                        ContentUnavailableView("No Music Yet", systemImage: "music.note", description: Text("Connect your FileCat library or add a folder in Sources."))
                    }
                }
            }
            .refreshable { await library.refresh() }
    }
}

struct ArtistsView: View {
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        List(library.artists, id: \.self) { artist in
            NavigationLink(artist) {
                TrackList(tracks: library.tracks(by: artist))
                    .navigationTitle(artist)
            }
        }
        .navigationTitle("Artists")
    }
}

struct AlbumsView: View {
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        List(library.albums, id: \.self) { album in
            NavigationLink(album) {
                TrackList(tracks: library.tracks(onAlbum: album))
                    .navigationTitle(album)
            }
        }
        .navigationTitle("Albums")
    }
}

struct PlaylistsView: View {
    @Environment(PlaylistStore.self) private var playlists
    @Environment(MusicLibrary.self) private var library
    @State private var isNaming = false
    @State private var name = ""

    var body: some View {
        List {
            ForEach(playlists.playlists) { playlist in
                NavigationLink {
                    PlaylistView(playlist: playlist)
                } label: {
                    LabeledContent(playlist.name, value: "\(playlist.trackIDs.count)")
                }
            }
            .onDelete { offsets in
                offsets.map { playlists.playlists[$0] }.forEach(playlists.delete)
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            Button("New Playlist", systemImage: "plus") {
                name = ""
                isNaming = true
            }
        }
        .alert("New Playlist", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { playlists.create(named: name) }
        }
    }
}

struct PlaylistView: View {
    let playlist: Playlist

    @Environment(PlaylistStore.self) private var playlists
    @Environment(MusicLibrary.self) private var library
    @Environment(HiResPlayer.self) private var player

    private var current: Playlist {
        playlists.playlists.first { $0.id == playlist.id } ?? playlist
    }

    var body: some View {
        let tracks = current.trackIDs.compactMap(library.track(id:))
        List {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                Button(track.title) { player.play(track, in: tracks) }
                    .tint(.primary)
            }
            .onDelete { playlists.remove(at: $0, from: current) }
            .onMove { playlists.move(from: $0, to: $1, in: current) }
        }
        .navigationTitle(current.name)
        .toolbar { EditButton() }
    }
}
