import AVFoundation
import Observation

/// One band of the parametric equalizer: a filter with its own type, frequency, gain and Q.
struct EQBand: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case peak, lowShelf, highShelf, lowCut, highCut, notch

        var name: String {
            switch self {
            case .peak: "Peak"
            case .lowShelf: "Low Shelf"
            case .highShelf: "High Shelf"
            case .lowCut: "Low Cut"
            case .highCut: "High Cut"
            case .notch: "Notch"
            }
        }

        /// Cut and notch filters remove frequencies outright instead of boosting or cutting them
        /// by a set amount.
        var hasGain: Bool {
            self == .peak || self == .lowShelf || self == .highShelf
        }

        /// The resonant shelves and passes take a Q (as a bandwidth), where the plain ones are
        /// fixed at 0.707. Measured against the RBJ cookbook filters `response` draws: they match.
        var filterType: AVAudioUnitEQFilterType {
            switch self {
            case .peak: .parametric
            case .lowShelf: .resonantLowShelf
            case .highShelf: .resonantHighShelf
            case .lowCut: .resonantHighPass
            case .highCut: .resonantLowPass
            case .notch: .bandStop
            }
        }
    }

    var kind: Kind
    var frequency: Float
    var gain: Float
    var q: Float
    var isEnabled = true

    /// The Q of a Butterworth filter: a shelf or cut without a bump.
    static let butterworthQ: Float = 0.71

    /// `AVAudioUnitEQ` takes the width of a filter in octaves rather than as a Q.
    var bandwidth: Float {
        2 / log(2) * asinh(1 / (2 * q))
    }
}

struct EQPreset: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var bands: [EQBand]
    var preamp: Float = 0

    var id: String { name }

    /// A preset for the standard layout: only the gains change.
    init(name: String, gains: [Float]) {
        self.name = name
        bands = zip(ParametricEqualizer.standardBands, gains).map { band, gain in
            var band = band
            band.gain = gain
            return band
        }
    }

    init(name: String, bands: [EQBand], preamp: Float) {
        self.name = name
        self.bands = bands
        self.preamp = preamp
    }

    static let flat = EQPreset(name: "Flat", gains: Array(repeating: 0, count: ParametricEqualizer.bandCount))

    /// Gains for 25, 45, 80, 150, 250, 470, 850 Hz, 1.5, 2.8, 5, 9 and 16 kHz.
    static let builtIn: [EQPreset] = [
        flat,
        EQPreset(name: "Acoustic", gains: [4, 4, 3.5, 2, 1, 1.5, 2, 2.5, 3, 3, 2.5, 2]),
        EQPreset(name: "Bass Booster", gains: [6, 5.5, 4.5, 3, 1.5, 0.5, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Reducer", gains: [-6, -5.5, -4.5, -3, -1.5, -0.5, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Classical", gains: [4, 3.5, 2.5, 1.5, 0, -1, -1, 0, 1.5, 2.5, 3.5, 4]),
        EQPreset(name: "Electronic", gains: [5, 4.5, 3, 0.5, -1, -2, 1, 1, 1.5, 3.5, 4.5, 5]),
        EQPreset(name: "Hip-Hop", gains: [5, 5, 4, 2, 1, -1, -1, 0.5, -0.5, 1.5, 2.5, 3]),
        EQPreset(name: "Jazz", gains: [3.5, 3, 2, 1.5, -0.5, -1.5, -1, 0.5, 1.5, 3, 3.5, 4]),
        EQPreset(name: "Loudness", gains: [6, 5, 3, 0, -1, -1.5, 0, -1, -3, 3, 5, 2]),
        EQPreset(name: "Pop", gains: [-1, -1, 0, 1.5, 3, 4, 4, 3, 1.5, 0, -1, -1]),
        EQPreset(name: "Rock", gains: [5, 4.5, 3.5, 1.5, -0.5, -1.5, -1, 1, 2.5, 3.5, 4.5, 5]),
        EQPreset(name: "Treble Booster", gains: [0, 0, 0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        EQPreset(name: "Treble Reducer", gains: [0, 0, 0, 0, 0, 0, 0, -1, -2.5, -4, -5, -6]),
        EQPreset(name: "Vocal Booster", gains: [-2, -2, -1, -1, 0, 2, 3.5, 4, 3, 1.5, 0, 0]),
    ]
}

/// A 12-band parametric equalizer applied to playback. Every band can be a peak, shelf, cut or
/// notch filter at any frequency, gain and Q. Settings are remembered across launches.
@MainActor
@Observable
final class ParametricEqualizer {
    nonisolated static let bandCount = 12
    nonisolated static let frequencyRange: ClosedRange<Float> = 20...20000
    nonisolated static let gainRange: ClosedRange<Float> = -15...15
    nonisolated static let qRange: ClosedRange<Float> = 0.2...12
    nonisolated static let preampRange: ClosedRange<Float> = -15...6

    /// Twelve bands spread evenly (about 0.85 octave apart) from sub-bass to air: a low shelf,
    /// ten peaks and a high shelf.
    nonisolated static let standardBands: [EQBand] = ([25, 45, 80, 150, 250, 470, 850, 1500, 2800, 5000, 9000, 16000] as [Float])
        .enumerated()
        .map { index, frequency in
            let kind: EQBand.Kind = index == 0 ? .lowShelf : index == bandCount - 1 ? .highShelf : .peak
            return EQBand(kind: kind, frequency: frequency, gain: 0, q: kind == .peak ? 1.4 : EQBand.butterworthQ)
        }

    /// The audio unit inserted between the player and the output.
    @ObservationIgnored let unit = AVAudioUnitEQ(numberOfBands: bandCount)

    var isEnabled: Bool {
        didSet { apply(); save() }
    }

    private(set) var bands: [EQBand] {
        didSet { apply(); save() }
    }

    /// Overall level in dB, applied after the bands.
    var preamp: Float {
        didSet { apply(); save() }
    }

    /// Lowers the level by the curve's highest boost, so boosted bands can't clip.
    var preventsClipping: Bool {
        didSet { apply(); save() }
    }

    private(set) var userPresets: [EQPreset] {
        didSet { save() }
    }

    /// The sample rate the filters run at (the song's own), for drawing the curve as it sounds.
    var sampleRate: Double = 48000 {
        didSet { if sampleRate != oldValue { apply() } }
    }

    var presets: [EQPreset] { EQPreset.builtIn + userPresets }

    /// The preset matching the current bands, or `nil` for a custom curve.
    var preset: EQPreset? {
        presets.first { $0.bands == bands && $0.preamp == preamp }
    }

    private enum Keys {
        static let enabled = "peqEnabled"
        static let bands = "peqBands"
        static let preamp = "peqPreamp"
        static let preventsClipping = "peqPreventsClipping"
        static let userPresets = "peqUserPresets"
        static let all = [enabled, bands, preamp, preventsClipping, userPresets]
    }

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: Keys.bands).flatMap { try? JSONDecoder().decode([EQBand].self, from: $0) }
        bands = saved?.count == Self.bandCount ? saved! : Self.standardBands
        isEnabled = defaults.bool(forKey: Keys.enabled)
        preamp = defaults.float(forKey: Keys.preamp)
        preventsClipping = defaults.object(forKey: Keys.preventsClipping) as? Bool ?? true
        userPresets = defaults.data(forKey: Keys.userPresets).flatMap { try? JSONDecoder().decode([EQPreset].self, from: $0) } ?? []
        apply()
    }

    // MARK: Editing

    func update(band index: Int, _ change: (inout EQBand) -> Void) {
        guard bands.indices.contains(index) else { return }
        var band = bands[index]
        change(&band)
        band.frequency = band.frequency.clamped(to: Self.frequencyRange)
        band.gain = band.gain.clamped(to: Self.gainRange)
        band.q = band.q.clamped(to: Self.qRange)
        if band != bands[index] { bands[index] = band }
    }

    /// Puts one band back where it is in the standard layout.
    func resetBand(_ index: Int) {
        guard bands.indices.contains(index) else { return }
        bands[index] = Self.standardBands[index]
    }

    func apply(_ preset: EQPreset) {
        guard preset.bands.count == Self.bandCount else { return }
        bands = preset.bands
        preamp = preset.preamp
    }

    /// Saves the current curve as a preset, replacing one of the user's with the same name.
    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !EQPreset.builtIn.contains(where: { $0.name == name }) else { return }
        let preset = EQPreset(name: name, bands: bands, preamp: preamp)
        if let index = userPresets.firstIndex(where: { $0.name == name }) {
            userPresets[index] = preset
        } else {
            userPresets.append(preset)
        }
    }

    func isBuiltIn(_ preset: EQPreset) -> Bool {
        EQPreset.builtIn.contains { $0.name == preset.name }
    }

    func deletePreset(_ preset: EQPreset) {
        userPresets.removeAll { $0.name == preset.name }
    }

    /// Back to a flat, switched-off equalizer (Settings → Reset All Settings). Saved presets stay.
    func reset() {
        isEnabled = false
        bands = Self.standardBands
        preamp = 0
        preventsClipping = true
        for key in Keys.all where key != Keys.userPresets {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: Response

    /// The level change in dB the enabled bands make at each of `frequencies`.
    func response(at frequencies: [Double]) -> [Double] {
        Self.response(of: bands, at: frequencies, sampleRate: sampleRate)
    }

    /// The level change in dB of the given bands at each of `frequencies`: the sum of each filter's.
    nonisolated static func response(of bands: [EQBand], at frequencies: [Double], sampleRate: Double) -> [Double] {
        let filters = bands.filter(\.isEnabled).map { Biquad($0, sampleRate: sampleRate) }
        return frequencies.map { frequency in
            filters.reduce(0) { $0 + $1.decibels(at: frequency) }
        }
    }

    /// The curve's highest point, found on a fine sweep plus each band's own frequency.
    var peakBoost: Double {
        let sweep = (0...240).map { 20 * pow(1000, Double($0) / 240) }
        return response(at: sweep + bands.map { Double($0.frequency) }).max() ?? 0
    }

    /// What `preventsClipping` takes off, in dB.
    var headroom: Float {
        preventsClipping ? Float(max(0, peakBoost)) : 0
    }

    // MARK: Internals

    private func apply() {
        for (unitBand, band) in zip(unit.bands, bands) {
            unitBand.filterType = band.kind.filterType
            unitBand.frequency = min(band.frequency, Float(sampleRate / 2) * 0.95)
            unitBand.gain = band.kind.hasGain ? band.gain : 0
            unitBand.bandwidth = band.bandwidth
            unitBand.bypass = !band.isEnabled
        }
        unit.globalGain = (preamp - headroom).clamped(to: -96...24)
        unit.bypass = !isEnabled
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(try? JSONEncoder().encode(bands), forKey: Keys.bands)
        defaults.set(preamp, forKey: Keys.preamp)
        defaults.set(preventsClipping, forKey: Keys.preventsClipping)
        defaults.set(try? JSONEncoder().encode(userPresets), forKey: Keys.userPresets)
    }
}

/// A band's filter as RBJ Audio EQ Cookbook coefficients, for drawing its response.
private struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
    let sampleRate: Double

    init(_ band: EQBand, sampleRate: Double) {
        self.sampleRate = sampleRate
        let frequency = min(Double(band.frequency), sampleRate / 2 * 0.95)
        let a = pow(10, Double(band.kind.hasGain ? band.gain : 0) / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * Double(band.q))
        switch band.kind {
        case .peak:
            (b0, b1, b2) = (1 + alpha * a, -2 * cosW, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * cosW, 1 - alpha / a)
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            (b0, b1, b2) = (a * ((a + 1) - (a - 1) * cosW + s), 2 * a * ((a - 1) - (a + 1) * cosW), a * ((a + 1) - (a - 1) * cosW - s))
            (a0, a1, a2) = ((a + 1) + (a - 1) * cosW + s, -2 * ((a - 1) + (a + 1) * cosW), (a + 1) + (a - 1) * cosW - s)
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            (b0, b1, b2) = (a * ((a + 1) + (a - 1) * cosW + s), -2 * a * ((a - 1) + (a + 1) * cosW), a * ((a + 1) + (a - 1) * cosW - s))
            (a0, a1, a2) = ((a + 1) - (a - 1) * cosW + s, 2 * ((a - 1) - (a + 1) * cosW), (a + 1) - (a - 1) * cosW - s)
        case .lowCut:
            (b0, b1, b2) = ((1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * cosW, 1 - alpha)
        case .highCut:
            (b0, b1, b2) = ((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * cosW, 1 - alpha)
        case .notch:
            (b0, b1, b2) = (1, -2 * cosW, 1)
            (a0, a1, a2) = (1 + alpha, -2 * cosW, 1 - alpha)
        }
    }

    func decibels(at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        return 20 * log10(max(magnitude(b0, b1, b2, w) / magnitude(a0, a1, a2, w), 1e-6))
    }

    private func magnitude(_ c0: Double, _ c1: Double, _ c2: Double, _ w: Double) -> Double {
        let real = c0 + c1 * cos(w) + c2 * cos(2 * w)
        let imaginary = c1 * sin(w) + c2 * sin(2 * w)
        return sqrt(real * real + imaginary * imaginary)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
