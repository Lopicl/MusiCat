import FileCatKit
import SwiftUI

/// `UserDefaults` keys for MusiCat's preferences, read with `@AppStorage` (or `isOn`).
enum MusiCatSettings {
    /// Switch the output to each song's own sample rate.
    static let matchesSampleRate = "matchesSampleRate"
    /// Pause when headphones or a DAC are unplugged.
    static let pausesOnDisconnect = "pausesOnDisconnect"
    /// Carry on after a phone call or Siri.
    static let resumesAfterInterruption = "resumesAfterInterruption"
    /// Download the next server song while the current one plays.
    static let prefetchesNextSong = "prefetchesNextSong"
    /// How many gigabytes downloaded server songs may take up.
    static let downloadLimit = "downloadLimit"
    /// The order of the Songs tab (`SongOrder`).
    static let songOrder = "songOrder"
    static let repeatMode = "repeatMode"
    static let shuffle = "shuffle"

    /// Everything "Reset All Settings" puts back (the equalizer resets itself).
    static let resettable = [matchesSampleRate, pausesOnDisconnect, resumesAfterInterruption, prefetchesNextSong, downloadLimit, songOrder, repeatMode, shuffle]

    /// A switch that's on until turned off.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum SongOrder: String, CaseIterable, Identifiable {
    case title, artist, album

    var id: String { rawValue }

    var name: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        }
    }

    func sorted(_ tracks: [Track]) -> [Track] {
        func order(_ a: String?, _ b: String?) -> ComparisonResult? {
            let result = (a ?? "").localizedStandardCompare(b ?? "")
            return result == .orderedSame ? nil : result
        }
        return tracks.sorted { a, b in
            let result: ComparisonResult? = switch self {
            case .title: nil
            case .artist: order(a.artistLine, b.artistLine) ?? order(a.album, b.album)
            case .album: order(a.album, b.album)
            }
            if let result { return result == .orderedAscending }
            if self != .title, a.album == b.album, a.trackNumber != b.trackNumber {
                return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

/// Where MusiCat finds music (FileCat's library, its servers, and folders added here), playback
/// and hi-res audio, downloads, and the long cat at the end.
struct SettingsView: View {
    @AppStorage(MusiCatSettings.matchesSampleRate) private var matchesSampleRate = true
    @AppStorage(MusiCatSettings.pausesOnDisconnect) private var pausesOnDisconnect = true
    @AppStorage(MusiCatSettings.resumesAfterInterruption) private var resumesAfterInterruption = true
    @AppStorage(MusiCatSettings.prefetchesNextSong) private var prefetchesNextSong = true
    @AppStorage(MusiCatSettings.downloadLimit) private var downloadLimit = 3
    @AppStorage(MusiCatSettings.songOrder) private var songOrder = SongOrder.title

    @Environment(MusicLibrary.self) private var library
    @Environment(HiResPlayer.self) private var player
    @State private var picking: Picking?
    @State private var errorMessage: String?
    @State private var meows = 0
    @State private var downloadsSize: Int64?
    @State private var isConfirmingRemoveDownloads = false
    @State private var isConfirmingReset = false
    @State private var confirmation: String?

    private enum Picking: Identifiable {
        case fileCat, folder
        /// The folder MusiCat follows for one of FileCat's.
        case fileCatFolder(SharedLocation)

        var id: String {
            switch self {
            case .fileCat: "fileCat"
            case .folder: "folder"
            case .fileCatFolder(let location): "fileCat:" + (location.id ?? location.name)
            }
        }
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

            Section {
                SharedStorageRows(otherApp: "FileCat")
            } header: {
                Text("Shared Storage")
            } footer: {
                Text("A test of storage shared with FileCat. Open FileCat once, then come back here.")
            }

            ServersSection(errorMessage: $errorMessage)

            if !library.fileCatFolders.isEmpty {
                Section {
                    ForEach(library.fileCatFolders, id: \.self) { location in
                        LabeledContent {
                            fileCatFolderStatus(location)
                        } label: {
                            Label(location.name, systemImage: symbol(for: location.kind))
                        }
                    }
                } header: {
                    Text("Folders in FileCat")
                } footer: {
                    if library.fileCatFoldersNeedingAccess.isEmpty {
                        Text("Folders and drives added in FileCat show up here by themselves, and go away when they're removed there.")
                    } else {
                        Text("Folders and drives added in FileCat show up here by themselves. iOS wants some picked once here too: tap Add and choose the same folder.")
                    }
                }
            }

            Section("Folders") {
                ForEach(library.ownFolders) { folder in
                    Label(folder.name, systemImage: "folder")
                }
                .onDelete { offsets in
                    let folders = library.ownFolders
                    offsets.map { folders[$0] }.forEach(library.removeFolder)
                }
                Button("Add Folder…", systemImage: "folder.badge.plus") { picking = .folder }
            }

            Section {
                NavigationLink {
                    EqualizerSettings()
                } label: {
                    LabeledContent("Equalizer", value: player.equalizer.isEnabled ? (player.equalizer.preset?.name ?? "Custom") : "Off")
                }
                .accessibilityIdentifier("equalizerSettings")
                Toggle("Pause When Unplugged", isOn: $pausesOnDisconnect)
                Toggle("Resume After Calls", isOn: $resumesAfterInterruption)
            } header: {
                Text("Playback")
            } footer: {
                Text("Pauses when headphones or a DAC are unplugged, and carries on after a phone call or Siri.")
            }

            Section {
                Toggle("Match Sample Rate", isOn: $matchesSampleRate)
                LabeledContent("Output", value: player.outputDescription)
                if player.current != nil {
                    LabeledContent("Playing", value: player.sourceFormat)
                    LabeledContent("Sample Rate", value: player.isBitPerfectRate ? "Matches the file" : "Resampled by iOS")
                }
            } header: {
                Text("Hi-Res Audio")
            } footer: {
                Text(matchesSampleRate
                     ? "Plug in a USB DAC with a Lightning or USB-C adapter: MusiCat switches it to each song's own sample rate, up to 192 kHz, for WAV, FLAC and ALAC."
                     : "The output stays at 48 kHz and iOS resamples songs recorded at other rates. Turn this on for bit-perfect sample rates; it applies from the next song.")
            }

            Section {
                Picker("Sort Songs By", selection: $songOrder) {
                    ForEach(SongOrder.allCases) { order in
                        Text(order.name).tag(order)
                    }
                }
            } header: {
                Text("Library")
            }

            Section {
                Toggle("Download Next Song Early", isOn: $prefetchesNextSong)
                Picker("Keep Up To", selection: $downloadLimit) {
                    ForEach([1, 3, 5, 10, 20], id: \.self) { gigabytes in
                        Text("\(gigabytes) GB").tag(gigabytes)
                    }
                }
                LabeledContent("Downloaded Songs", value: formatted(downloadsSize))
                Button("Remove Downloaded Songs", role: .destructive) {
                    isConfirmingRemoveDownloads = true
                }
                .disabled(downloadsSize == 0)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Songs on servers are downloaded before they play and kept, so they start straight away next time. When they take up more than the limit, the ones played longest ago go first.")
            }

            Section {
                Button("Reset All Settings", role: .destructive) {
                    isConfirmingReset = true
                }
                .accessibilityIdentifier("resetAllSettings")
            } footer: {
                Text("Puts every setting back to its default, including the equalizer, repeat and shuffle. Your music, folders, servers, playlists and saved equalizer presets are kept.")
            }

            Section {
                LabeledContent("Version", value: Self.version)
            } footer: {
                LongCat(meows: meows)
            }
        }
        .onHardOverscroll {
            meows += 1
            Meow.play()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: meows)
        .navigationTitle("Settings")
        .task { downloadsSize = await SongDownloads.size() }
        .onChange(of: downloadLimit) {
            Task.detached(priority: .utility) { SongDownloads.trim() }
        }
        .confirmationDialog("Remove downloaded songs?", isPresented: $isConfirmingRemoveDownloads, titleVisibility: .visible) {
            Button("Remove Downloaded Songs", role: .destructive) {
                Task {
                    await SongDownloads.shared.removeAll()
                    downloadsSize = await SongDownloads.size()
                }
            }
        } message: {
            Text("They stay on the servers and are downloaded again when played.")
        }
        .confirmationDialog("Reset all settings?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset All Settings", role: .destructive) {
                for key in MusiCatSettings.resettable {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                player.equalizer.reset()
                player.resetModes()
                confirmation = "All settings were reset."
            }
        }
        .alert(confirmation ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("OK") {}
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), allowedContentTypes: [.folder]) { result in
            let kind = picking
            picking = nil
            do {
                let url = try result.get()
                switch kind {
                case .fileCat: try library.connectFileCat(to: url)
                case .fileCatFolder(let location): try library.addFolder(url, following: location)
                case .folder, nil: try library.addFolder(url)
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

    @ViewBuilder
    private func fileCatFolderStatus(_ location: SharedLocation) -> some View {
        if let id = location.id, library.fileCatFoldersNeedingAccess.contains(id) {
            Button("Add…") { picking = .fileCatFolder(location) }
        } else if location.isConnected == false || library.folder(following: location).map(library.isReachable) == false {
            Text(location.kind == .drive ? "Not Plugged In" : "Not Connected")
        } else if library.folder(following: location) != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("In Library")
        } else {
            // FileCat from before it shared folders: pick them by hand.
            Button("Add…") { picking = .folder }
        }
    }

    private func formatted(_ size: Int64?) -> String {
        guard let size else { return "…" }
        return size == 0 ? "None" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
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
