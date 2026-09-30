import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays a queue of songs at their own sample rate. Before each song, the audio session asks the
/// output for the file's rate, so a USB DAC (or the built-in output, where it can) runs at 44.1,
/// 48, 88.2, 96, 176.4 or 192 kHz instead of iOS resampling everything to 48 kHz. Decoding stays
/// in 32-bit float, which carries 24-bit sources without loss. Songs on servers are downloaded
/// first (see `SongDownloads`), and the next one in the queue is fetched while the current one plays.
/// Like FileCat's player, it keeps going in the background and shows up on the Lock Screen.
@MainActor
@Observable
final class HiResPlayer {
    enum RepeatMode: String {
        case off, all, one

        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var artwork: UIImage?
    /// What the file is: "FLAC · 24-bit · 96 kHz".
    private(set) var sourceFormat = ""
    /// Where it's going: "USB DAC · 96 kHz", "Speaker · 48 kHz".
    private(set) var outputDescription = ""
    /// True when the output runs at the file's own rate (no resampling).
    private(set) var isBitPerfectRate = false
    private(set) var error: String?

    var repeatMode: RepeatMode {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: MusiCatSettings.repeatMode) }
    }

    private(set) var isShuffled: Bool {
        didSet { UserDefaults.standard.set(isShuffled, forKey: MusiCatSettings.shuffle) }
    }

    let equalizer = ParametricEqualizer()

    var current: Track? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    /// How far the current song's download is, while it's being fetched from its server.
    var downloadProgress: Double? {
        current.flatMap { SongDownloads.shared.progress[$0.id] }
    }

    // Playback graph: player node → equalizer → main mixer → output.
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    /// Bumped whenever scheduled audio is thrown away, so stale completion callbacks are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    /// The queue in its own order, to go back to when shuffle is turned off.
    @ObservationIgnored private var unshuffledQueue: [Track] = []
    /// Bumped whenever playback starts or stops, so a late session deactivation can tell it's stale.
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private let servers: ServerStore

    init(servers: ServerStore) {
        self.servers = servers
        let defaults = UserDefaults.standard
        repeatMode = defaults.string(forKey: MusiCatSettings.repeatMode).flatMap(RepeatMode.init) ?? .off
        isShuffled = defaults.bool(forKey: MusiCatSettings.shuffle)
        engine.attach(node)
        engine.attach(equalizer.unit)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self else { return }
                self.describeOutput()
                // Pause when headphones or the DAC are unplugged, unless Settings says otherwise.
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                   MusiCatSettings.isOn(MusiCatSettings.pausesOnDisconnect) {
                    self.pause()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.handleEngineStopped(resume: false)
                } else if type == AVAudioSession.InterruptionType.ended.rawValue,
                          AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
                          MusiCatSettings.isOn(MusiCatSettings.resumesAfterInterruption) {
                    // Pick up again after a phone call or Siri, if the system says we may.
                    self.handleEngineStopped(resume: true)
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The engine stops itself when the output hardware changes; carry on where we were.
                guard let self else { return }
                self.handleEngineStopped(resume: self.isPlaying)
            }
        })
        describeOutput()
        configureRemoteCommands()
    }

    // MARK: Controls

    func play(_ track: Track, in queue: [Track]) {
        let list = queue.isEmpty ? [track] : queue
        unshuffledQueue = list
        if isShuffled {
            self.queue = [track] + list.filter { $0 != track }.shuffled()
            index = 0
        } else {
            self.queue = list
            index = list.firstIndex(of: track) ?? 0
        }
        load(autoplay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = position
        node.pause()
        engine.pause()
        isPlaying = false
        stopTimer()
        updateNowPlaying()
    }

    func resume() {
        guard file != nil, startEngineIfNeeded() else { return }
        fadeIn()
        node.play()
        isPlaying = true
        startTimer()
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        load(autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // Like Music: go back to the start of the song first.
        if position > 3 {
            seek(to: 0)
        } else {
            index = (index - 1 + queue.count) % queue.count
            load(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        schedule(file, from: AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate))
        currentTime = Double(startFrame) / file.processingFormat.sampleRate
        if isPlaying {
            fadeIn()
            node.play()
        }
        updateNowPlaying()
    }

    /// Shuffles the rest of the queue after the current song, or puts it back in order.
    func toggleShuffle() {
        isShuffled.toggle()
        guard let current else { return }
        if isShuffled {
            unshuffledQueue = queue
            queue = [current] + queue.enumerated().filter { $0.offset != index }.map(\.element).shuffled()
            index = 0
        } else if !unshuffledQueue.isEmpty {
            queue = unshuffledQueue
            index = queue.firstIndex(of: current) ?? 0
        }
    }

    /// Repeat and shuffle off (Settings → Reset All Settings).
    func resetModes() {
        repeatMode = .off
        if isShuffled { toggleShuffle() }
    }

    /// Stops playback and empties the queue (the mini player's swipe).
    func stop() {
        generation += 1
        node.stop()
        engine.stop()
        stopTimer()
        loading?.cancel()
        artworkTask?.cancel()
        SongDownloads.shared.cancel(except: [])
        file = nil
        queue = []
        unshuffledQueue = []
        index = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        artwork = nil
        nowPlayingArtwork = nil
        error = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Let other apps' audio resume. Deactivating blocks, so keep it off the main thread, and
        // skip it if playback has started again in the meantime.
        sessionGeneration += 1
        let session = sessionGeneration
        Task { [weak self] in
            guard let self, self.sessionGeneration == session, !self.engine.isRunning else { return }
            await Self.deactivateSession()
        }
    }

    // MARK: Internals

    private var position: Double {
        guard let file, isPlaying, let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime) else { return currentTime }
        return min(Double(startFrame + max(0, time.sampleTime)) / file.processingFormat.sampleRate, duration)
    }

    private func load(autoplay: Bool) {
        guard let track = current else {
            stop()
            return
        }
        // Stopping calls the old song's completion handler; the new generation makes it ignore that.
        generation += 1
        node.stop()
        engine.stop()
        stopTimer()
        error = nil
        artwork = nil
        nowPlayingArtwork = nil
        artworkTask?.cancel()
        loading?.cancel()
        switch track.location {
        case .file(let url):
            open(url, for: track, autoplay: autoplay)
        case .server(let serverID, _, _):
            guard let server = servers.server(id: serverID) else {
                error = "This song's server isn't in MusiCat anymore."
                isPlaying = false
                return
            }
            file = nil
            isPlaying = false
            currentTime = 0
            duration = track.duration ?? 0
            sourceFormat = track.format
            updateNowPlaying()
            let downloads = SongDownloads.shared
            let upNext = MusiCatSettings.isOn(MusiCatSettings.prefetchesNextSong) ? nextTrack : nil
            downloads.cancel(except: Set([track.id, upNext?.id].compactMap { $0 }))
            loading = Task {
                do {
                    let url = try await downloads.file(for: track, on: server)
                    guard !Task.isCancelled, current == track else { return }
                    open(url, for: track, autoplay: autoplay)
                    if let upNext { prefetch(upNext) }
                } catch {
                    guard !Task.isCancelled, current == track else { return }
                    self.error = "This song couldn't be downloaded. \(error.localizedDescription)"
                }
            }
        }
    }

    private var nextTrack: Track? {
        guard queue.count > 1, repeatMode != .one else { return nil }
        if index + 1 == queue.count, repeatMode == .off { return nil }
        return queue[(index + 1) % queue.count]
    }

    /// Downloads a server song ahead of time, so it starts right away.
    private func prefetch(_ track: Track) {
        guard case .server(let serverID, _, _) = track.location, let server = servers.server(id: serverID) else { return }
        Task { _ = try? await SongDownloads.shared.file(for: track, on: server) }
    }

    private func open(_ url: URL, for track: Track, autoplay: Bool) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            self.file = file
            let rate = file.fileFormat.sampleRate
            // Ask the hardware for the song's own rate; a DAC that supports it switches to it.
            let session = AVAudioSession.sharedInstance()
            let matchesRate = MusiCatSettings.isOn(MusiCatSettings.matchesSampleRate)
            try? session.setPreferredSampleRate(matchesRate ? rate : 48000)
            try session.setActive(true)
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(equalizer.unit)
            engine.connect(node, to: equalizer.unit, format: file.processingFormat)
            engine.connect(equalizer.unit, to: engine.mainMixerNode, format: file.processingFormat)
            equalizer.sampleRate = file.processingFormat.sampleRate
            duration = Double(file.length) / file.processingFormat.sampleRate
            sourceFormat = Self.describe(file, name: track.format)
            describeOutput()
            schedule(file, from: 0)
            currentTime = 0
            loadArtwork(from: url)
            if autoplay { resume() } else { updateNowPlaying() }
        } catch {
            self.error = "This song can't be played. \(error.localizedDescription)"
            isPlaying = false
        }
    }

    private func schedule(_ file: AVAudioFile, from frame: AVAudioFramePosition) {
        generation += 1
        let current = generation
        node.stop()
        startFrame = max(0, min(frame, file.length - 1))
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(file.length - startFrame), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.songDidFinish()
            }
        }
    }

    private func songDidFinish() {
        switch repeatMode {
        case .one:
            seek(to: 0)
        case .all:
            next()
        case .off:
            if index + 1 < queue.count {
                index += 1
                load(autoplay: true)
            } else {
                pause()
                seek(to: 0)
            }
        }
    }

    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        sessionGeneration += 1
        do {
            // Activate the session and allocate the engine's resources first; leaving it to
            // engine.start() can make iOS reconfigure the output just after playback has begun.
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Runs off the main actor: deactivating the session blocks until audio I/O has stopped.
    private nonisolated static func deactivateSession() async {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Re-schedules from the last known position after the system stopped the engine.
    private func handleEngineStopped(resume shouldResume: Bool) {
        guard file != nil else { return }
        let position = position
        isPlaying = false
        stopTimer()
        seek(to: position)
        if shouldResume { resume() }
    }

    /// Ramps the output up over a tenth of a second so playback doesn't start with a click.
    private func fadeIn(duration: Double = 0.1) {
        let steps = 10
        var step = 0
        fadeTimer?.invalidate()
        engine.mainMixerNode.outputVolume = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                step += 1
                let progress = Float(step) / Float(steps)
                self.engine.mainMixerNode.outputVolume = progress * progress
                if step >= steps {
                    timer.invalidate()
                    self.engine.mainMixerNode.outputVolume = 1
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = self.position
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func describeOutput() {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let rate = session.sampleRate
        let name: String
        switch output?.portType {
        case .usbAudio?: name = "USB DAC (\(output?.portName ?? "USB"))"
        case .headphones?: name = "Headphones"
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: name = output?.portName ?? "Bluetooth"
        case .airPlay?: name = "AirPlay"
        default: name = output?.portName ?? "Speaker"
        }
        outputDescription = "\(name) · \(Self.kilohertz(rate))"
        if let file {
            isBitPerfectRate = abs(file.fileFormat.sampleRate - rate) < 1
        }
    }

    private static func describe(_ file: AVAudioFile, name: String) -> String {
        let description = file.fileFormat.streamDescription.pointee
        var bits = Int(description.mBitsPerChannel)
        if bits == 0 {
            // Lossless codecs keep the source's bit depth in their flags.
            switch description.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: bits = 16
            case kAppleLosslessFormatFlag_20BitSourceData: bits = 20
            case kAppleLosslessFormatFlag_24BitSourceData: bits = 24
            case kAppleLosslessFormatFlag_32BitSourceData: bits = 32
            default: break
            }
        }
        let codec = description.mFormatID == kAudioFormatAppleLossless ? "ALAC" : name.uppercased()
        return [codec, bits > 0 ? "\(bits)-bit" : nil, kilohertz(file.fileFormat.sampleRate)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func kilohertz(_ rate: Double) -> String {
        let value = rate / 1000
        return value.rounded() == value ? "\(Int(value)) kHz" : String(format: "%.1f kHz", value)
    }

    // MARK: Artwork and the Lock Screen

    /// Reads the cover embedded in the song, for the player and the Lock Screen.
    private func loadArtwork(from url: URL) {
        artworkTask?.cancel()
        let track = current
        artworkTask = Task { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var image: UIImage?
            if let metadata = try? await AVURLAsset(url: url).load(.commonMetadata),
               let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
               let data = try? await item.load(.dataValue) {
                image = UIImage(data: data)
            }
            guard let self, !Task.isCancelled, self.current == track else { return }
            self.artwork = image
            self.nowPlayingArtwork = image.map(Self.makeArtwork)
            self.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = current.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The artwork handler is called on a background queue, so it must not be main-actor isolated.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
    }
}
