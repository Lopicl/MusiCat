import Foundation

/// A song in the library.
struct Track: Identifiable, Hashable, Sendable {
    enum Location: Hashable, Sendable {
        case file(URL)
        /// A file on a server imported from FileCat. The size tells a finished download from a partial one.
        case server(id: String, path: String, size: Int64?)
    }

    /// Stable across launches: the file's path relative to the folder or server it was found in.
    let id: String
    let location: Location
    var title: String
    /// Every artist credited on the track, in order ("A feat. B" → ["A", "B"]).
    var artists: [String]
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var duration: Double?
    /// Filled in when the track is opened: "FLAC · 24-bit · 96 kHz".
    var format: String

    var artistLine: String {
        artists.isEmpty ? "Unknown Artist" : artists.joined(separator: ", ")
    }

    /// Formats MusiCat plays, including the high-resolution ones.
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac"]
}

enum ArtistCredits {
    /// Splits an artist tag into its artists: "A & B", "A feat. B", "A, B; C", "A x B", "A / B".
    static func split(_ text: String?) -> [String] {
        guard var text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        for separator in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " & ", " and ", " x ", " × ", " / ", ";", ","] {
            text = text.replacingOccurrences(of: separator, with: "\u{1F}", options: .caseInsensitive)
        }
        var seen = Set<String>()
        return text.split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
