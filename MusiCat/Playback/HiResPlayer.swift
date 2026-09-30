import AVFoundation
import Observation

/// Plays a queue of songs at their own sample rate. Before each song, the audio session asks the
/// output for the file's rate, so a USB DAC (or the built-in output, where it can) runs at 44.1,
/// 48, 88.2, 96, 176.4 or 192 kHz instead of iOS resampling everything to 48 kHz. Decoding stays
/// in 32-bit float, which carries 24-bit sources without loss. Songs on servers are downloaded
/// first (see `SongDownloads`), and the next one in the queue is fetched while the current one plays.
@MainActor
@Observable
final class HiResPlayer {
    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// What the file is: "FLAC · 24-bit · 96 kHz".
    private(set) var sourceFormat = ""
    /// Where it's going: "USB DAC · 96 kHz", "Speaker · 48 kHz".
    private(set) var outputDescription = ""
    /// True when the output runs at the file's own rate (no resampling).
    private(set) var isBitPerfectRate = false
    private(set) var error: String?

    var current: Track? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    /// How far the current song's download is, while it's being fetched from its server.
    var downloadProgress: Double? {
        current.flatMap { SongDownloads.shared.progress[$0.id] }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let servers: ServerStore

    init(servers: ServerStore) {
        self.servers = servers
        engine.attach(node)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.describeOutput() }
        }
        describeOutput()
    }

    func play(_ track: Track, in queue: [Track]) {
        self.queue = queue.isEmpty ? [track] : queue
        index = self.queue.firstIndex(of: track) ?? 0
        load(autoplay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        currentTime = position
        node.pause()
        isPlaying = false
    }

    func resume() {
        guard file != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
            node.play()
            isPlaying = true
            startTimer()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func next() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        load(autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if position > 3 {
            seek(to: 0)
        } else {
            index = (index - 1 + queue.count) % queue.count
            load(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        schedule(file, from: AVAudioFramePosition(seconds * file.processingFormat.sampleRate))
        currentTime = seconds
        if isPlaying { node.play() }
    }

    // MARK: Internals

    private var position: Double {
        guard let file, isPlaying, let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime) else { return currentTime }
        return Double(startFrame + time.sampleTime) / file.processingFormat.sampleRate
    }

    private func load(autoplay: Bool) {
        guard let track = current else { return }
        // Stopping calls the old song's completion handler; the new generation makes it ignore that.
        generation += 1
        node.stop()
        engine.stop()
        error = nil
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
            let downloads = SongDownloads.shared
            let upNext = nextTrack
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
        queue.count > 1 ? queue[(index + 1) % queue.count] : nil
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
            try? session.setPreferredSampleRate(rate)
            try session.setActive(true)
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            duration = Double(file.length) / file.processingFormat.sampleRate
            sourceFormat = Self.describe(file, name: track.format)
            describeOutput()
            schedule(file, from: 0)
            currentTime = 0
            if autoplay { resume() }
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
                self.next()
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
}
