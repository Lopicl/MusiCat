import SwiftUI

struct NowPlayingBar: View {
    let onOpen: () -> Void
    @Environment(HiResPlayer.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(player.downloadProgress.map { "Downloading… \(Int($0 * 100)) %" } ?? player.sourceFormat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlayPause()
            }
            .labelStyle(.iconOnly)
            .font(.title3)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

struct NowPlayingView: View {
    @Environment(HiResPlayer.self) private var player

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 160))
                .foregroundStyle(.tint)
                .padding(.top, 48)
            VStack(spacing: 6) {
                Text(player.current?.title ?? "")
                    .font(.title2.weight(.semibold))
                Text(player.current?.artistLine ?? "")
                    .foregroundStyle(.secondary)
                Text(player.sourceFormat + "  →  " + player.outputDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(player.isBitPerfectRate ? Color.green : Color.secondary)
            }
            .multilineTextAlignment(.center)
            if let progress = player.downloadProgress {
                ProgressView("Downloading from the server…", value: progress)
                    .font(.caption)
                    .padding(.horizontal)
            }
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                .padding(.horizontal)
            HStack(spacing: 48) {
                Button("Previous", systemImage: "backward.fill") { player.previous() }
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlayPause() }
                    .font(.largeTitle)
                Button("Next", systemImage: "forward.fill") { player.next() }
            }
            .labelStyle(.iconOnly)
            .font(.title)
            if let error = player.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
        .presentationDragIndicator(.visible)
    }
}
