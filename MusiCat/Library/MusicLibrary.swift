import AVFoundation
import FileCatKit
import Observation

/// A folder MusiCat takes music from: one of FileCat's folders, which it follows, or one added
/// in MusiCat itself.
struct MusicFolder: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var bookmark: Data
    /// The FileCat folder this one follows (`SharedLocation.id`); removing it there removes it here.
    var fileCatID: String?
}

/// Every song MusiCat can play: those in FileCat's Local Storage (through FileCatKit), the folders
/// and drives added in FileCat's Connections tab (followed automatically, see `syncWithFileCat`),
/// folders added in MusiCat itself, and the music folders chosen on servers imported from FileCat.
@MainActor
@Observable
final class MusicLibrary {
    private(set) var tracks: [Track] = []
    private(set) var isScanning = false
    private(set) var folders: [MusicFolder] = []
    /// IDs of FileCat folders that iOS won't open with FileCat's bookmark: the user picks them once.
    private(set) var fileCatFoldersNeedingAccess: Set<String> = []

    let fileCat = FileCatLibrary()
    let servers = ServerStore()
    private let foldersKey = "MusiCat.musicFolders"
    /// Before build 5: bookmarks only, for folders added in MusiCat.
    private let oldFoldersKey = "MusiCat.folders"
    /// The folders' locations while MusiCat has access to them, by folder ID.
    @ObservationIgnored private var folderURLs: [String: URL] = [:]
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

    /// Folders added in MusiCat itself.
    var ownFolders: [MusicFolder] {
        folders.filter { $0.fileCatID == nil }
    }

    /// The MusiCat folder that follows a FileCat folder.
    func folder(following location: SharedLocation) -> MusicFolder? {
        guard let id = location.id else { return nil }
        return folders.first { $0.fileCatID == id }
    }

    /// Picks up changes to FileCat's servers and folders, and tells FileCat which of them MusiCat
    /// uses. Runs with every refresh too. Returns true if folders were added, which need a scan.
    @discardableResult
    func syncWithFileCat() -> Bool {
        let manifest = fileCat.manifest
        servers.sync(with: manifest?.servers)
        let ids = Set(servers.servers.map(\.id))
        tracks.removeAll { track in
            if case .server(let id, _, _) = track.location { !ids.contains(id) } else { false }
        }
        let added = syncFolders(with: manifest?.locations)
        if let root = fileCat.rootURL {
            let usage = CompanionUsage(app: "MusiCat", locationIDs: folders.compactMap(\.fileCatID).sorted(), serverIDs: ids.sorted())
            try? usage.write(to: root)
        }
        return added
    }

    /// Follows FileCat's folders: new ones are added (with FileCat's bookmark when iOS allows),
    /// removed ones go away. Unplugged drives stay. `nil` (FileCat isn't connected, or is too
    /// old to list IDs) leaves everything as it is.
    private func syncFolders(with shared: [SharedLocation]?) -> Bool {
        guard let shared, !shared.contains(where: { $0.id == nil }) else {
            fileCatFoldersNeedingAccess = []
            return false
        }
        let locations = shared.filter { $0.kind != .server }
        let ids = Set(locations.compactMap(\.id))
        for folder in folders where folder.fileCatID.map({ !ids.contains($0) }) == true {
            removeFolder(folder)
        }
        // Renamed in FileCat (drives get their own name there).
        for index in folders.indices {
            if let location = locations.first(where: { $0.id == folders[index].fileCatID }), location.name != folders[index].name {
                folders[index].name = location.name
            }
        }
        var added = false
        var needingAccess: Set<String> = []
        for location in locations where folder(following: location) == nil {
            let resolved = location.resolveBookmark()
            // The same folder, added here by hand before, now follows FileCat's.
            if let url = resolved?.url, let index = folders.firstIndex(where: { $0.fileCatID == nil && folderURLs[$0.id].map { Self.isSameFolder($0, url) } == true }) {
                folders[index].fileCatID = location.id
                continue
            }
            if let resolved, resolved.isReadable {
                let accessing = resolved.url.startAccessingSecurityScopedResource()
                let bookmark = (try? resolved.url.bookmarkData()) ?? location.bookmark
                if accessing { resolved.url.stopAccessingSecurityScopedResource() }
                if let bookmark {
                    folders.append(MusicFolder(name: location.name, bookmark: bookmark, fileCatID: location.id))
                    added = true
                    continue
                }
            }
            // An unplugged drive is picked once it's back.
            if location.isConnected != false, let id = location.id {
                needingAccess.insert(id)
            }
        }
        if needingAccess != fileCatFoldersNeedingAccess { fileCatFoldersNeedingAccess = needingAccess }
        saveFolders()
        if added { restoreFolders() }
        return added
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

    /// Adds a folder the user picked. With `location`, it's the FileCat folder it follows.
    func addFolder(_ url: URL, following location: SharedLocation? = nil) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData()
        folders.append(MusicFolder(name: location?.name ?? url.lastPathComponent, bookmark: bookmark, fileCatID: location?.id))
        if let id = location?.id { fileCatFoldersNeedingAccess.remove(id) }
        saveFolders()
        restoreFolders()
        Task { await refresh() }
    }

    /// Removes a folder and its songs.
    func removeFolder(_ folder: MusicFolder) {
        if let url = folderURLs.removeValue(forKey: folder.id) {
            let prefix = url.path(percentEncoded: false)
            tracks.removeAll { track in
                if case .file(let file) = track.location { file.path(percentEncoded: false).hasPrefix(prefix) } else { false }
            }
            url.stopAccessingSecurityScopedResource()
        }
        folders.removeAll { $0.id == folder.id }
        saveFolders()
    }

    /// Resolves the folders' bookmarks, and keeps access to them open so their songs play.
    private func restoreFolders() {
        if folders.isEmpty {
            if let data = UserDefaults.standard.data(forKey: foldersKey),
               let saved = try? JSONDecoder().decode([MusicFolder].self, from: data) {
                folders = saved
            } else if let old = UserDefaults.standard.array(forKey: oldFoldersKey) as? [Data] {
                folders = old.map { MusicFolder(name: "", bookmark: $0) }
            }
        }
        for index in folders.indices where folderURLs[folders[index].id] == nil {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: folders[index].bookmark, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            folderURLs[folders[index].id] = url
            if folders[index].name.isEmpty { folders[index].name = url.lastPathComponent }
            if stale, let fresh = try? url.bookmarkData() { folders[index].bookmark = fresh }
        }
        saveFolders()
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: foldersKey)
        }
        UserDefaults.standard.removeObject(forKey: oldFoldersKey)
    }

    /// Whether a folder could be reached in the last scan (an unplugged drive can't).
    func isReachable(_ folder: MusicFolder) -> Bool {
        folderURLs[folder.id].map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    }

    private static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            == b.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    // MARK: Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        syncWithFileCat()
        // Drives plugged in since the last scan.
        restoreFolders()

        var files: [(url: URL, id: String)] = fileCat.files(ofKinds: [.audio])
            .filter { Track.extensions.contains($0.url.pathExtension.lowercased()) }
            .map { ($0.url, "filecat:" + $0.relativePath) }
        for folder in folders {
            guard let url = folderURLs[folder.id] else { continue }
            files += await Task.detached { Self.audioFiles(in: url) }.value
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
