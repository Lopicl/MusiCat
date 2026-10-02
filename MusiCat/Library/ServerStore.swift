import FileCatKit
import Foundation
import Observation

/// Servers imported from FileCat, and the folders on them that MusiCat takes music from.
///
/// FileCat lists its servers, without passwords, in its library manifest, and MusiCat follows that
/// list: servers changed in FileCat change here, servers removed there go away here. Passwords come
/// from FileCat itself (`ServerShareRequest`) once the user agrees there, and are kept in MusiCat's
/// own keychain. The protocol code (SMB, NFS, WebDAV, SFTP, FTP) is FileCat's, compiled into MusiCat too.
@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [NetworkSource] = []
    /// Folders on each server that are scanned for music, by server ID. "/" is the whole server.
    private(set) var musicFolders: [String: [String]] = [:]
    /// Servers in FileCat that aren't here yet, or whose password changed there since they were imported.
    private(set) var needingImport: [SharedServer] = []
    /// Why a server couldn't be read in the last scan, by server ID.
    var errors: [String: String] = [:]

    /// Opens FileCat, which asks the user and then comes back with `musicat://filecat-servers?…`.
    static let importRequest = ServerShareRequest(replyScheme: "musicat")

    private let serversKey = "MusiCat.servers"
    private let foldersKey = "MusiCat.serverMusicFolders"

    init() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let saved = try? JSONDecoder().decode([NetworkSource].self, from: data) {
            servers = saved
        }
        musicFolders = UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: [String]] ?? [:]
    }

    func server(id: String) -> NetworkSource? {
        servers.first { $0.id == id }
    }

    /// Takes the servers FileCat handed over, with their passwords.
    func importServers(_ reply: ServerShareReply) {
        for item in reply.servers {
            guard let source = NetworkSource(shared: item.server) else { continue }
            Keychain.setPassword(item.password, for: source.id)
            store(source)
            needingImport.removeAll { $0.id == source.id }
        }
        persist()
    }

    /// Follows FileCat's list of servers. `nil` (FileCat's library isn't connected) leaves
    /// everything as it is.
    func sync(with shared: [SharedServer]?) {
        guard let shared else {
            needingImport = []
            return
        }
        for server in servers {
            guard let update = shared.first(where: { $0.id == server.id }) else {
                remove(server)
                continue
            }
            guard var source = NetworkSource(shared: update) else { continue }
            // Keep the date of the password MusiCat has: a newer one in FileCat means asking again.
            source.passwordChanged = server.passwordChanged
            if source != server { store(source) }
        }
        needingImport = shared.filter { item in
            guard let server = server(id: item.id) else { return true }
            return item.passwordChanged != server.passwordChanged
        }
        // NFS has no password, so those come over straight away.
        for item in needingImport where item.kind == NetworkSource.Kind.nfs.rawValue {
            if let source = NetworkSource(shared: item) { store(source) }
        }
        needingImport.removeAll { $0.kind == NetworkSource.Kind.nfs.rawValue }
        persist()
    }

    func addMusicFolder(_ path: String, on server: NetworkSource) {
        let path = RemotePath.normalized(path)
        guard !(musicFolders[server.id] ?? []).contains(path) else { return }
        musicFolders[server.id, default: []].append(path)
        persist()
    }

    func removeMusicFolder(_ path: String, on server: NetworkSource) {
        musicFolders[server.id]?.removeAll { $0 == path }
        persist()
    }

    private func store(_ source: NetworkSource) {
        if let index = servers.firstIndex(where: { $0.id == source.id }) {
            servers[index] = source
        } else {
            servers.append(source)
        }
        errors[source.id] = nil
        Task { await RemoteConnections.shared.invalidate(source.id) }
    }

    private func remove(_ server: NetworkSource) {
        servers.removeAll { $0.id == server.id }
        musicFolders[server.id] = nil
        errors[server.id] = nil
        Keychain.deletePassword(for: server.id)
        SongDownloads.removeAll(for: server.id)
        Task { await RemoteConnections.shared.invalidate(server.id) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
        UserDefaults.standard.set(musicFolders, forKey: foldersKey)
    }
}
