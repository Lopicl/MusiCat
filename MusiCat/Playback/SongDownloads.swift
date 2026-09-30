import Foundation
import Observation

/// Songs from servers, downloaded before they play: `AVAudioFile` needs the whole file to play
/// at its own sample rate and seek precisely. They stay in Caches (up to `limit`, the ones played
/// longest ago go first), so a song plays straight away the next time.
@MainActor
@Observable
final class SongDownloads {
    static let shared = SongDownloads()

    /// Downloads in progress, from 0 to 1, by track ID.
    private(set) var progress: [String: Double] = [:]
    @ObservationIgnored private var running: [String: Task<URL, Error>] = [:]

    /// How much the downloads may take up, set in Settings (3 GB unless changed).
    nonisolated static var limit: Int64 {
        let gigabytes = UserDefaults.standard.object(forKey: MusiCatSettings.downloadLimit) as? Int ?? 3
        return Int64(gigabytes) * 1024 * 1024 * 1024
    }
    nonisolated static var folder: URL {
        URL.cachesDirectory.appending(path: "Songs", directoryHint: .isDirectory)
    }

    /// The song's file on the device, downloaded first if needed.
    func file(for track: Track, on server: NetworkSource) async throws -> URL {
        guard case .server(_, let path, let size) = track.location else {
            throw RemoteError.unsupported("This song isn't on a server.")
        }
        let destination = Self.url(for: path, on: server.id)
        if Self.isComplete(destination, size: size) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path(percentEncoded: false))
            return destination
        }
        if let task = running[track.id] {
            return try await task.value
        }
        let id = track.id
        progress[id] = 0
        let reporter = ProgressThrottle { fraction in
            Task { @MainActor in
                if SongDownloads.shared.progress[id] != nil { SongDownloads.shared.progress[id] = fraction }
            }
        }
        let task = Task.detached {
            let fileSystem = try await RemoteConnections.shared.fileSystem(for: server)
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + RemotePath.name(of: path))
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await fileSystem.download(path, to: temporary) { bytes in
                if let size, size > 0 { reporter.report(Double(bytes) / Double(size)) }
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
        running[id] = task
        defer {
            running[id] = nil
            progress[id] = nil
        }
        let url = try await task.value
        Task.detached(priority: .utility) { Self.trim() }
        return url
    }

    /// Stops downloads that aren't needed anymore (after skipping through songs, say).
    func cancel(except ids: Set<String>) {
        for (id, task) in running where !ids.contains(id) {
            task.cancel()
        }
    }

    nonisolated static func url(for path: String, on serverID: String) -> URL {
        RemotePath.components(of: path).reduce(folder.appending(path: serverID, directoryHint: .isDirectory)) {
            $0.appending(path: $1)
        }
    }

    nonisolated static func removeAll(for serverID: String) {
        try? FileManager.default.removeItem(at: folder.appending(path: serverID, directoryHint: .isDirectory))
    }

    /// Settings → Remove Downloaded Songs. They're downloaded again when played.
    func removeAll() async {
        cancel(except: [])
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: Self.folder)
        }.value
    }

    /// The space the downloaded songs take up.
    nonisolated static func size() async -> Int64 {
        await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
            return total
        }.value
    }

    private nonisolated static func isComplete(_ url: URL, size: Int64?) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else { return false }
        guard let size else { return true }
        return (attributes[.size] as? Int64) == size
    }

    /// Removes the songs played longest ago until the cache fits in `limit`.
    nonisolated static func trim() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        let maximum = Self.limit
        for file in files.sorted(by: { $0.date < $1.date }) where total > maximum {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}

/// Passes progress on only when it moved by a percent, so a download doesn't flood the main actor.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    private let handler: @Sendable (Double) -> Void

    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ fraction: Double) {
        let percent = Int(fraction * 100)
        let changed = lock.withLock {
            guard percent != last else { return false }
            last = percent
            return true
        }
        if changed { handler(min(1, fraction)) }
    }
}
