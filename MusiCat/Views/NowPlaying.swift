import AVKit
import SwiftUI

extension View {
    /// Shows the mini player at the bottom of this tab while a song is loaded.
    func miniPlayerInset(onOpen: @escaping () -> Void) -> some View {
        modifier(MiniPlayerInset(onOpen: onOpen))
    }
}

private struct MiniPlayerInset: ViewModifier {
    let onOpen: () -> Void
    @Environment(HiResPlayer.self) private var player

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil {
                    MiniPlayer(onOpen: onOpen)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: player.current == nil)
    }
}

/// Floating bar shown while a song is loaded, as in FileCat. Tap to open the full player; swipe
/// left to stop.
struct MiniPlayer: View {
    let onOpen: () -> Void

    @Environment(HiResPlayer.self) private var player
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    /// How far the pill has to travel before letting go stops playback.
    private let stopThreshold: CGFloat = 110

    var body: some View {
        pill
            .offset(x: dragOffset)
            .background(alignment: .trailing) { stopIndicator }
            .simultaneousGesture(swipeToStop)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer")
            .accessibilityAction(named: "Stop Playback") { player.stop() }
            .frame(maxWidth: 500)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .sensoryFeedback(.impact(weight: .medium), trigger: dragOffset < -stopThreshold)
    }

    private var pill: some View {
        HStack(spacing: 12) {
            ArtworkView(image: player.artwork, cornerRadius: 6)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(player.downloadProgress.map { "Downloading… \(Int($0 * 100)) %" } ?? player.current?.artistLine ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            Button("Next", systemImage: "forward.fill") {
                player.next()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MiniPlayerButtonStyle())
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: shape)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Stop Playback", systemImage: "stop.fill", role: .destructive) {
                player.stop()
            }
        }
    }

    /// Revealed under the pill as it slides left, like swipe-to-delete.
    private var stopIndicator: some View {
        let revealed = max(0, -dragOffset)
        return shape
            .fill(Color.red)
            .overlay(alignment: .trailing) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .scaleEffect(revealed > stopThreshold ? 1.15 : 1)
                    .frame(width: min(max(revealed, 0), 80))
                    .clipped()
            }
            .frame(width: revealed + 16)
            .opacity(revealed > 0 ? 1 : 0)
            .animation(.snappy(duration: 0.15), value: revealed > stopThreshold)
    }

    private var swipeToStop: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                guard !isDismissing, abs(drag.translation.width) > abs(drag.translation.height) else { return }
                // Only leftwards, with resistance past the threshold.
                let x = min(0, drag.translation.width)
                dragOffset = x > -stopThreshold ? x : -stopThreshold + (x + stopThreshold) * 0.6
            }
            .onEnded { drag in
                guard !isDismissing else { return }
                let flung = drag.predictedEndTranslation.width < -stopThreshold * 2.5
                if dragOffset < -stopThreshold || flung {
                    isDismissing = true
                    withAnimation(.easeIn(duration: 0.2)) {
                        dragOffset = -600
                    } completion: {
                        player.stop()
                        dragOffset = 0
                        isDismissing = false
                    }
                } else {
                    withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

private struct MiniPlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.4 : 1)
    }
}

/// The song's cover, or a record on a gradient when it has none.
struct ArtworkView: View {
    let image: UIImage?
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    GeometryReader { proxy in
                        ZStack {
                            LinearGradient(
                                colors: [Color(uiColor: .systemGray4), Color(uiColor: .systemGray5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.note")
                                .font(.system(size: proxy.size.width * 0.4))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The full player, laid out like FileCat's, plus what MusiCat knows about hi-res output.
struct NowPlayingView: View {
    @Environment(HiResPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false
    @State private var showsEqualizer = false

    private var displayedTime: Double {
        isScrubbing ? scrubTime : player.currentTime
    }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if let artwork = player.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.35)
                    .ignoresSafeArea()
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showsEqualizer) {
            EqualizerView()
        }
        .onChange(of: player.current == nil) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    // MARK: Layouts

    private var portraitLayout: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 8)
            artwork
                .frame(maxWidth: 340)
            titles
            progress
            transport
            secondaryControls
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 500)
    }

    /// iPhone in landscape: artwork and titles on the left half, controls on the right half.
    private var landscapeLayout: some View {
        HStack(spacing: 40) {
            VStack(spacing: 16) {
                artwork
                    .frame(maxWidth: 240)
                titles
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 24) {
                progress
                transport
                secondaryControls
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    // MARK: Parts

    private var artwork: some View {
        ArtworkView(image: player.artwork, cornerRadius: 16)
            .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
            .scaleEffect(player.isPlaying ? 1 : 0.88)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: player.isPlaying)
    }

    private var titles: some View {
        VStack(spacing: 4) {
            Text(player.current?.title ?? "")
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("nowPlayingTitle")
            Text(player.current?.artistLine ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !player.sourceFormat.isEmpty {
                // Green when the output runs at the song's own rate.
                Text(player.sourceFormat + "  →  " + player.outputDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(player.isBitPerfectRate ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }
            if let error = player.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let download = player.downloadProgress {
            VStack(spacing: 6) {
                ProgressView(value: download)
                Text("Downloading from the server… \(Int(download * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                Slider(
                    value: Binding(get: { displayedTime }, set: { scrubTime = $0 }),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubTime = player.currentTime
                            isScrubbing = true
                        } else {
                            player.seek(to: scrubTime)
                            isScrubbing = false
                        }
                    })
                HStack {
                    Text(formatTime(displayedTime))
                    Spacer()
                    Text("-" + formatTime(max(0, player.duration - displayedTime)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 48) {
            Button("Previous", systemImage: "backward.fill") { player.previous() }
                .font(.title)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlayPause()
            }
            .font(.system(size: 48))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 64, height: 64)
            .accessibilityIdentifier("nowPlayingPlayPause")
            Button("Next", systemImage: "forward.fill") { player.next() }
                .font(.title)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.primary)
    }

    private var secondaryControls: some View {
        HStack(spacing: 0) {
            Button {
                player.repeatMode = player.repeatMode.next
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Repeat")
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Shuffle")
            .accessibilityAddTraits(player.isShuffled ? .isSelected : [])
            Spacer()
            if player.queue.count > 1 {
                Text("\(player.index + 1) of \(player.queue.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button {
                showsEqualizer = true
            } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(player.equalizer.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Equalizer")
            RoutePicker()
                .frame(width: 44, height: 44)
        }
        .font(.title3)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

/// AirPlay / Bluetooth output picker.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .secondaryLabel
        view.activeTintColor = .tintColor
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
