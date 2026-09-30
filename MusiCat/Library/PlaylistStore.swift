import Foundation
import Observation

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// `Track.id`s, in order.
    var trackIDs: [String] = []
}

/// The user's playlists, saved as JSON in Application Support.
@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []

    private let file = URL.applicationSupportDirectory.appending(path: "Playlists.json")

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = saved
        }
    }

    @discardableResult
    func create(named name: String) -> Playlist {
        let playlist = Playlist(name: name.isEmpty ? "New Playlist" : name)
        playlists.append(playlist)
        save()
        return playlist
    }

    func rename(_ playlist: Playlist, to name: String) {
        edit(playlist) { $0.name = name }
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func add(_ track: Track, to playlist: Playlist) {
        edit(playlist) { $0.trackIDs.append(track.id) }
    }

    func remove(at offsets: IndexSet, from playlist: Playlist) {
        edit(playlist) { $0.trackIDs.remove(atOffsets: offsets) }
    }

    func move(from source: IndexSet, to destination: Int, in playlist: Playlist) {
        edit(playlist) { $0.trackIDs.move(fromOffsets: source, toOffset: destination) }
    }

    private func edit(_ playlist: Playlist, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        change(&playlists[index])
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(playlists).write(to: file, options: .atomic)
    }
}
