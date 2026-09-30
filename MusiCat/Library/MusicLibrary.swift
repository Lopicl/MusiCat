import AVFoundation
import FileCatKit
import Observation

/// Every song MusiCat can play: those in FileCat's Local Storage (through FileCatKit), folders
/// the user added in MusiCat itself (for example the same USB drive or iCloud folder added in
/// FileCat: access to those belongs to FileCat, so MusiCat asks for them once too), and the music
/// folders chosen on servers imported from FileCat.
@MainActor
@Observable
final class MusicLibrary {
    private(set) var tracks: [Track] = []
    private(set) var isScanning = false
    private(set) var folders: [URL] = []

    let fileCat = FileCatLibrary()
    let servers = ServerStore()
    private let foldersKey = "MusiCat.folders"
    /// Tags of songs on servers, so they're only read over the network once.
    @ObservationIgnored private var serverTags = ServerTagCache()

    init() {
        restoreFolders()
    }

    var isConnectedToFileCat: Bool { fileCat.isConnected }

    /// Folders added in FileCat, from its library manifest. Servers are in `servers`.
    var fileCatFolders: [SharedLocation] {
        (fileCat.manifest?.locations ?? []).filter { $0.kind != .server }
    }

    /// Picks up changes to FileCat's servers. Runs with every refresh too.
    func syncServers() {
        servers.sync(with: fileCat.manifest?.servers)
        let ids = Set(servers.servers.map(\.id))
        tracks.removeAll { track in
            if case .server(let id, _, _) = track.location { !ids.contains(id) } else { false }
        }
    }

    var artists: [String] {
        Array(Set(tracks.flatMap(\.artists))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var albums: [String] {
        Array(Set(tracks.compactMap(\.album))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Songs an artist plays on, as lead or featured artist.
    func tracks(by artist: String) -> [Track] {
        tracks.filter { $0.artists.contains(artist) }
    }

    func tracks(onAlbum album: String) -> [Track] {
        tracks.filter { $0.album == album }.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    func track(id: String) -> Track? {
        tracks.first { $0.id == id }
    }

    // MARK: Sources

    func connectFileCat(to folder: URL) throws {
        try fileCat.connect(to: folder)
        Task { await refresh() }
    }

    func addFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData()
        var saved = UserDefaults.standard.array(forKey: foldersKey) as? [Data] ?? []
        saved.append(bookmark)
        UserDefaults.standard.set(saved, forKey: foldersKey)
        restoreFolders()
        Task { await refresh() }
    }

    private func restoreFolders() {
        let saved = UserDefaults.standard.array(forKey: foldersKey) as? [Data] ?? []
        folders = saved.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        }
    }

    // MARK: Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        syncServers()

        var files: [(url: URL, id: String)] = fileCat.files(ofKinds: [.audio])
            .filter { Track.extensions.contains($0.url.pathExtension.lowercased()) }
            .map { ($0.url, "filecat:" + $0.relativePath) }
        for folder in folders {
            files += await Task.detached { Self.audioFiles(in: folder) }.value
        }
        var found: [Track] = []
        for file in files {
            let tags = await SongTags(asset: AVURLAsset(url: file.url))
            found.append(Track(id: file.id, location: .file(file.url), tags: tags))
        }
        for server in servers.servers {
            found += await scan(server)
        }
        tracks = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        serverTags.save()
    }

    /// The songs in a server's music folders. Tags come from the cache, or are read over the
    /// network (only the parts of each file that hold them).
    private func scan(_ server: NetworkSource) async -> [Track] {
        let folders = servers.musicFolders[server.id] ?? []
        guard !folders.isEmpty else { return [] }
        do {
            let fileSystem = try await RemoteConnections.shared.fileSystem(for: server)
            var files: [String: RemoteEntry] = [:]
            for folder in folders {
                for (path, entry) in try await Self.audioFiles(in: folder, on: fileSystem) {
                    files[path] = entry
                }
            }
            servers.errors[server.id] = nil
            let cache = serverTags
            let found = await withTaskGroup(of: Track.self) { group in
                var tracks: [Track] = []
                var pending = files.sorted { $0.key < $1.key }.makeIterator()
                // A few at a time, so a big first scan doesn't swamp the server.
                func addNext() -> Bool {
                    guard let (path, entry) = pending.next() else { return false }
                    let id = "server:\(server.id):\(path)"
                    group.addTask {
                        let location = Track.Location.server(id: server.id, path: path, size: entry.size)
                        if let cached = cache.tags(for: id, size: entry.size, modified: entry.modified) {
                            return Track(id: id, location: location, tags: cached)
                        }
                        var tags = SongTags()
                        if let size = entry.size, size > 0 {
                            let stream = RemoteStream(path: path, name: entry.name, size: size, fileSystem: fileSystem, download: nil)
                            let streaming = StreamingAsset(stream: stream)
                            tags = await SongTags(asset: streaming.asset)
                            streaming.release()
                        }
                        tags.size = entry.size
                        tags.modified = entry.modified
                        cache.store(tags, for: id)
                        return Track(id: id, location: location, tags: tags)
                    }
                    return true
                }
                for _ in 0..<4 { _ = addNext() }
                while let track = await group.next() {
                    tracks.append(track)
                    _ = addNext()
                }
                return tracks
            }
            return found
        } catch {
            servers.errors[server.id] = error.localizedDescription
            await RemoteConnections.shared.invalidate(server.id)
            return []
        }
    }

    /// Every song below a folder on a server, by path.
    private nonisolated static func audioFiles(in folder: String, on fileSystem: any RemoteFileSystem) async throws -> [(String, RemoteEntry)] {
        var found: [(String, RemoteEntry)] = []
        var queue = [folder]
        while let current = queue.popLast() {
            for entry in try await fileSystem.list(current) where !entry.name.hasPrefix(".") {
                let path = RemotePath.join(current, entry.name)
                if entry.isDirectory {
                    queue.append(path)
                } else if Track.extensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                    found.append((path, entry))
                }
            }
        }
        return found
    }

    private nonisolated static func audioFiles(in folder: URL) -> [(url: URL, id: String)] {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { Track.extensions.contains($0.pathExtension.lowercased()) }
            .map { ($0, folder.lastPathComponent + ":" + $0.path(percentEncoded: false).dropFirst(folder.path(percentEncoded: false).count)) }
    }
}

/// A song's tags, as read from the file.
struct SongTags: Codable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var duration: Double?
    /// For songs on servers: the version of the file the tags were read from.
    var size: Int64?
    var modified: Date?

    init() {}

    init(asset: AVAsset) async {
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                let value = try? await item.load(.stringValue)
                switch item.commonKey {
                case .commonKeyTitle?: title = value
                case .commonKeyArtist?: artist = value
                case .commonKeyAlbumName?: album = value
                default: break
                }
                if item.identifier == .iTunesMetadataAlbumArtist || item.identifier == .id3MetadataBand {
                    albumArtist = value
                }
                if item.identifier == .iTunesMetadataTrackNumber || item.identifier == .id3MetadataTrackNumber {
                    trackNumber = value.flatMap { Int($0.split(separator: "/").first ?? "") }
                }
            }
        }
        duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil }
    }
}

extension Track {
    /// A track from its tags. Artists are split into every credited artist.
    init(id: String, location: Location, tags: SongTags) {
        self.id = id
        self.location = location
        let name = switch location {
        case .file(let url): url.lastPathComponent
        case .server(_, let path, _): RemotePath.name(of: path)
        }
        title = tags.title ?? (name as NSString).deletingPathExtension
        artists = ArtistCredits.split(tags.artist)
        album = tags.album
        albumArtist = tags.albumArtist
        trackNumber = tags.trackNumber
        duration = tags.duration
        format = (name as NSString).pathExtension.uppercased()
    }
}

/// Tags of songs on servers, kept in Caches and checked against the file's size and date.
final class ServerTagCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: SongTags]
    private var changed = false
    private let file = URL.cachesDirectory.appending(path: "ServerTags.json")

    init() {
        entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: SongTags].self, from: $0) } ?? [:]
    }

    func tags(for id: String, size: Int64?, modified: Date?) -> SongTags? {
        lock.withLock {
            guard let tags = entries[id], tags.size == size, tags.modified == modified else { return nil }
            return tags
        }
    }

    func store(_ tags: SongTags, for id: String) {
        lock.withLock {
            entries[id] = tags
            changed = true
        }
    }

    func save() {
        let data: Data? = lock.withLock {
            guard changed else { return nil }
            changed = false
            return try? JSONEncoder().encode(entries)
        }
        try? data?.write(to: file, options: .atomic)
    }
}
