import SwiftUI

/// The equalizer as a sheet, opened from the player.
struct EqualizerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EqualizerSettings()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

/// The parametric equalizer's controls: on/off and presets, the response curve with a point per
/// band, the selected band's type, frequency, gain and Q, and the overall level. Shown in the
/// player's sheet and in Settings.
struct EqualizerSettings: View {
    @Environment(HiResPlayer.self) private var player
    @State private var selected = 0
    @State private var entry: Entry?
    @State private var entryText = ""
    @State private var isNamingPreset = false
    @State private var presetName = ""

    private var equalizer: ParametricEqualizer { player.equalizer }
    private var band: EQBand { equalizer.bands[selected] }

    /// A value typed in exactly, after tapping it.
    private enum Entry: String, Identifiable {
        case frequency, gain, q, preamp

        var id: String { rawValue }

        var title: String {
            switch self {
            case .frequency: "Frequency"
            case .gain: "Gain"
            case .q: "Q"
            case .preamp: "Preamp"
            }
        }

        var hint: String {
            switch self {
            case .frequency: "In hertz, from 20 to 20000. \"2.5k\" works too."
            case .gain: "In decibels, from -15 to +15."
            case .q: "From 0.2 (wide) to 12 (narrow)."
            case .preamp: "In decibels, from -15 to +6."
            }
        }
    }

    var body: some View {
        @Bindable var equalizer = equalizer

        List {
            Section {
                Toggle("Equalizer", isOn: $equalizer.isEnabled.animation())
                    .accessibilityIdentifier("equalizerEnabled")
                Picker("Preset", selection: presetSelection) {
                    ForEach(equalizer.presets) { preset in
                        Text(preset.name).tag(Optional(preset.name))
                    }
                    if equalizer.preset == nil {
                        Text("Custom").tag(String?.none)
                    }
                }
                .pickerStyle(.menu)
            }

            Group {
                Section {
                    ResponseCurve(equalizer: equalizer, selected: $selected)
                        .frame(height: 230)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 4, trailing: 8))
                    bandPicker
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                } footer: {
                    Text("Drag a point to move its band: sideways for the frequency, up or down for the gain. Pinch to make it narrower or wider.")
                }

                bandSection
                levelSection
            }
            .disabled(!equalizer.isEnabled)
            .opacity(equalizer.isEnabled ? 1 : 0.4)

            presetsSection
        }
        .navigationTitle("Equalizer")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Reset") {
                    withAnimation(.snappy) { equalizer.apply(.flat) }
                }
                .disabled(!equalizer.isEnabled || equalizer.preset == .flat)
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .alert(entry?.title ?? "", isPresented: Binding(get: { entry != nil }, set: { if !$0 { entry = nil } }), presenting: entry) { entry in
            TextField(entry.title, text: $entryText)
                .keyboardType(.numbersAndPunctuation)
            Button("Cancel", role: .cancel) {}
            Button("Set") { commit(entry) }
        } message: { entry in
            Text(entry.hint)
        }
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { equalizer.savePreset(named: presetName) }
                .disabled(!isValidPresetName)
        } message: {
            Text(equalizer.userPresets.contains { $0.name == presetName.trimmingCharacters(in: .whitespaces) }
                 ? "A preset with this name is replaced."
                 : "Saves all twelve bands and the preamp.")
        }
    }

    // MARK: Sections

    private var bandPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(equalizer.bands.indices, id: \.self) { index in
                    let band = equalizer.bands[index]
                    let isSelected = index == selected
                    Button {
                        selected = index
                    } label: {
                        VStack(spacing: 1) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                            Text(Self.shortFrequency(band.frequency))
                                .font(.caption2.monospacedDigit())
                        }
                        .frame(minWidth: 44)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : band.isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Band \(index + 1), \(Self.frequency(band.frequency))")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var bandSection: some View {
        Section {
            Picker("Type", selection: binding(\.kind)) {
                ForEach(EQBand.Kind.allCases, id: \.self) { kind in
                    Text(kind.name).tag(kind)
                }
            }
            .pickerStyle(.menu)
            Toggle("Band On", isOn: binding(\.isEnabled))
            ParameterRow(title: "Frequency", value: Self.frequency(band.frequency), edit: { edit(.frequency) }) {
                Slider(value: logarithmic(\.frequency, in: ParametricEqualizer.frequencyRange, rounding: Self.roundFrequency), in: 0...1)
            }
            if band.kind.hasGain {
                ParameterRow(title: "Gain", value: Self.decibels(band.gain), edit: { edit(.gain) }) {
                    Slider(value: rounded(binding(\.gain), step: 0.1), in: ParametricEqualizer.gainRange)
                }
            }
            ParameterRow(title: "Q", value: String(format: "%.2f", Double(band.q)), edit: { edit(.q) }) {
                Slider(value: logarithmic(\.q, in: ParametricEqualizer.qRange, rounding: { ($0 * 100).rounded() / 100 }), in: 0...1)
            }
            Button("Reset Band") {
                withAnimation(.snappy) { equalizer.resetBand(selected) }
            }
            .disabled(band == ParametricEqualizer.standardBands[selected])
        } header: {
            Text("Band \(selected + 1)")
        } footer: {
            Text(Self.explanation(of: band.kind))
        }
    }

    private var levelSection: some View {
        @Bindable var equalizer = equalizer
        return Section {
            ParameterRow(title: "Preamp", value: Self.decibels(equalizer.preamp), edit: { edit(.preamp) }) {
                Slider(value: rounded($equalizer.preamp, step: 0.1), in: ParametricEqualizer.preampRange)
            }
            Toggle("Prevent Clipping", isOn: $equalizer.preventsClipping)
        } header: {
            Text("Level")
        } footer: {
            if equalizer.preventsClipping && equalizer.headroom > 0.05 {
                Text("Lowered by another \(String(format: "%.1f", Double(equalizer.headroom))) dB, the curve's highest boost, so boosted bands can't distort.")
            } else if equalizer.preventsClipping {
                Text("When bands are boosted, the level is lowered by the highest boost, so they can't distort.")
            } else {
                Text("Boosting bands can make loud songs distort. Lower the preamp to make room.")
            }
        }
    }

    private var presetsSection: some View {
        Section {
            ForEach(equalizer.userPresets) { preset in
                Button {
                    withAnimation(.snappy) { equalizer.apply(preset) }
                } label: {
                    HStack {
                        Text(preset.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if equalizer.preset?.name == preset.name {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(!equalizer.isEnabled)
            }
            .onDelete { offsets in
                offsets.map { equalizer.userPresets[$0] }.forEach(equalizer.deletePreset)
            }
            Button("Save as Preset…", systemImage: "square.and.arrow.down") {
                presetName = equalizer.preset.flatMap { equalizer.isBuiltIn($0) ? nil : $0.name } ?? ""
                isNamingPreset = true
            }
            .disabled(!equalizer.isEnabled)
        } header: {
            Text("My Presets")
        } footer: {
            if !equalizer.userPresets.isEmpty {
                Text("Swipe left on a preset to delete it.")
            }
        }
    }

    // MARK: Bindings

    private var presetSelection: Binding<String?> {
        Binding {
            equalizer.preset?.name
        } set: { name in
            if let preset = equalizer.presets.first(where: { $0.name == name }) {
                withAnimation(.snappy) { equalizer.apply(preset) }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<EQBand, Value>) -> Binding<Value> {
        let index = selected
        return Binding {
            equalizer.bands[index][keyPath: keyPath]
        } set: { value in
            equalizer.update(band: index) { $0[keyPath: keyPath] = value }
        }
    }

    private func rounded(_ value: Binding<Float>, step: Float) -> Binding<Float> {
        Binding {
            value.wrappedValue
        } set: {
            value.wrappedValue = ($0 / step).rounded() * step
        }
    }

    /// A 0…1 slider position for a value that's spread over decades, like frequency and Q.
    private func logarithmic(_ keyPath: WritableKeyPath<EQBand, Float>, in range: ClosedRange<Float>, rounding: @escaping (Float) -> Float) -> Binding<Float> {
        let value = binding(keyPath)
        let low = log(range.lowerBound), high = log(range.upperBound)
        return Binding {
            (log(value.wrappedValue) - low) / (high - low)
        } set: { position in
            value.wrappedValue = rounding(exp(low + position * (high - low)))
        }
    }

    // MARK: Typed entry

    private func edit(_ entry: Entry) {
        switch entry {
        case .frequency: entryText = String(Int(band.frequency.rounded()))
        case .gain: entryText = String(format: "%g", Double(band.gain))
        case .q: entryText = String(format: "%g", Double(band.q))
        case .preamp: entryText = String(format: "%g", Double(equalizer.preamp))
        }
        self.entry = entry
    }

    private func commit(_ entry: Entry) {
        var text = entryText.lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "hz", with: "")
            .replacingOccurrences(of: "db", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        var multiplier: Float = 1
        if entry == .frequency, text.hasSuffix("k") {
            multiplier = 1000
            text.removeLast()
        }
        guard let value = Float(text.trimmingCharacters(in: .whitespaces)).map({ $0 * multiplier }), value.isFinite else { return }
        withAnimation(.snappy) {
            switch entry {
            case .frequency: equalizer.update(band: selected) { $0.frequency = value }
            case .gain: equalizer.update(band: selected) { $0.gain = value }
            case .q: equalizer.update(band: selected) { $0.q = value }
            case .preamp: equalizer.preamp = value.clamped(to: ParametricEqualizer.preampRange)
            }
        }
    }

    // MARK: Formatting

    /// "45 Hz", "850 Hz", "2.8 kHz", "16 kHz"
    static func frequency(_ hertz: Float) -> String {
        hertz < 1000 ? "\(Int(hertz.rounded())) Hz" : shortFrequency(hertz).dropLast() + " kHz"
    }

    /// "45", "850", "2.8k", "16k"
    static func shortFrequency(_ hertz: Float) -> String {
        guard hertz >= 1000 else { return "\(Int(hertz.rounded()))" }
        let kilohertz = hertz / 1000
        return (kilohertz >= 10 || kilohertz.rounded() == kilohertz
                ? String(format: "%.0f", Double(kilohertz))
                : String(format: "%.1f", Double(kilohertz))) + "k"
    }

    /// "0 dB", "+3.5 dB", "-6 dB"
    static func decibels(_ value: Float) -> String {
        let value = (value * 10).rounded() / 10
        if value == 0 { return "0 dB" }
        return String(format: value.rounded() == value ? "%+.0f dB" : "%+.1f dB", Double(value))
    }

    /// Whole hertz below 1 kHz, then tens of hertz.
    static func roundFrequency(_ hertz: Float) -> Float {
        hertz < 1000 ? hertz.rounded() : (hertz / 10).rounded() * 10
    }

    private var isValidPresetName: Bool {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !EQPreset.builtIn.contains { $0.name == name }
    }

    private static func explanation(of kind: EQBand.Kind) -> String {
        switch kind {
        case .peak: "Boosts or cuts around the frequency. A higher Q makes the bell narrower."
        case .lowShelf: "Boosts or cuts everything below the frequency. A Q above 0.71 adds a bump at the corner."
        case .highShelf: "Boosts or cuts everything above the frequency. A Q above 0.71 adds a bump at the corner."
        case .lowCut: "Removes everything below the frequency, like rumble. A Q above 0.71 adds a bump at the corner."
        case .highCut: "Removes everything above the frequency, like hiss. A Q above 0.71 adds a bump at the corner."
        case .notch: "Removes a narrow slice around the frequency, like a hum or a ringing resonance."
        }
    }
}

/// A setting with its value on the right (tap it to type one in) and its slider below.
private struct ParameterRow<Control: View>: View {
    let title: String
    let value: String
    let edit: () -> Void
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Button(value, action: edit)
                    .font(.body.monospacedDigit())
                    .buttonStyle(.borderless)
                    .accessibilityHint("Type in a value")
            }
            control
                .accessibilityLabel(title)
        }
    }
}

/// The equalizer's frequency response from 20 Hz to 20 kHz, with a numbered point per band.
private struct ResponseCurve: View {
    let equalizer: ParametricEqualizer
    @Binding var selected: Int

    @Environment(\.isEnabled) private var isEnabled
    /// The band being dragged (`-1` when the drag didn't start on a point), and where on the
    /// point it was grabbed.
    @State private var dragging: Int?
    @State private var grabOffset = CGSize.zero
    @State private var pinchStartQ: Float?

    private static let decibelRange = Double(ParametricEqualizer.gainRange.upperBound)
    private static let gridFrequencies: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
    private static let handleRadius: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let plot = Self.plotRect(in: proxy.size)
            Canvas { context, _ in
                draw(in: &context, plot: plot)
            }
            .contentShape(Rectangle())
            .gesture(drag(plot: plot))
            .simultaneousGesture(pinch)
        }
        .accessibilityElement()
        .accessibilityLabel("Frequency response")
        .accessibilityValue(accessibilityDescription)
        .accessibilityAdjustableAction { direction in
            guard equalizer.bands[selected].kind.hasGain else { return }
            let step: Float = direction == .increment ? 0.5 : direction == .decrement ? -0.5 : 0
            equalizer.update(band: selected) { $0.gain += step }
        }
    }

    // MARK: Geometry

    private static func plotRect(in size: CGSize) -> CGRect {
        // Room for the decibel labels on the left, the edge points, and the frequency labels underneath.
        let left: CGFloat = 22 + handleRadius
        return CGRect(x: left, y: handleRadius + 1, width: max(1, size.width - left - handleRadius - 1), height: max(1, size.height - 2 * handleRadius - 20))
    }

    private static func x(_ frequency: Double, in plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(log10(frequency / 20) / 3) * plot.width
    }

    private static func frequency(atX x: CGFloat, in plot: CGRect) -> Double {
        20 * pow(10, 3 * Double((x - plot.minX) / plot.width))
    }

    private static func y(_ decibels: Double, in plot: CGRect) -> CGFloat {
        plot.midY - CGFloat(decibels / decibelRange) * plot.height / 2
    }

    private static func decibels(atY y: CGFloat, in plot: CGRect) -> Double {
        Double((plot.midY - y) / (plot.height / 2)) * decibelRange
    }

    private func handlePoint(_ band: EQBand, in plot: CGRect) -> CGPoint {
        CGPoint(x: Self.x(Double(band.frequency), in: plot), y: Self.y(band.kind.hasGain ? Double(band.gain) : 0, in: plot))
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, plot: CGRect) {
        let grid = Color(uiColor: .separator)
        let label = Color(uiColor: .tertiaryLabel)
        let accent = isEnabled ? Color.accentColor : Color.secondary

        // Grid: decibels across, frequencies down.
        for decibels in stride(from: -12.0, through: 12, by: 6) {
            let y = Self.y(decibels, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(grid.opacity(decibels == 0 ? 1 : 0.5)), lineWidth: decibels == 0 ? 1 : 0.5)
            let text = decibels == 0 ? "0" : String(format: "%+.0f", decibels)
            context.draw(Text(text).font(.system(size: 9).monospacedDigit()).foregroundStyle(label), at: CGPoint(x: plot.minX - Self.handleRadius - 4, y: y), anchor: .trailing)
        }
        for frequency in Self.gridFrequencies {
            let x = Self.x(frequency, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(grid.opacity(0.5)), lineWidth: 0.5)
            let text = frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
            context.draw(Text(text).font(.system(size: 9).monospacedDigit()).foregroundStyle(label), at: CGPoint(x: x, y: plot.maxY + Self.handleRadius + 8))
        }

        // The curve, sampled every two points.
        let count = max(2, Int(plot.width / 2))
        let frequencies = (0...count).map { 20 * pow(1000, Double($0) / Double(count)) }
        let curve = equalizer.response(at: frequencies)
        let points = zip(frequencies, curve).map { CGPoint(x: Self.x($0, in: plot), y: Self.y(max(-Self.decibelRange * 1.5, $1), in: plot)) }
        var stroke = Path()
        stroke.addLines(points)
        var fill = stroke
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
        fill.closeSubpath()

        var clipped = context
        clipped.clip(to: Path(plot.insetBy(dx: -Self.handleRadius, dy: 0)))
        clipped.fill(fill, with: .color(accent.opacity(0.15)))

        // The selected band on its own, dashed.
        let band = equalizer.bands[selected]
        if band.isEnabled {
            let own = ParametricEqualizer.response(of: [band], at: frequencies, sampleRate: equalizer.sampleRate)
            var path = Path()
            path.addLines(zip(frequencies, own).map { CGPoint(x: Self.x($0, in: plot), y: Self.y(max(-Self.decibelRange * 1.5, $1), in: plot)) })
            clipped.stroke(path, with: .color(accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        clipped.stroke(stroke, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        // The points, selected one last so it's on top.
        let order = equalizer.bands.indices.filter { $0 != selected } + [selected]
        for index in order {
            let band = equalizer.bands[index]
            let center = handlePoint(band, in: plot)
            let circle = Path(ellipseIn: CGRect(x: center.x - Self.handleRadius, y: center.y - Self.handleRadius, width: Self.handleRadius * 2, height: Self.handleRadius * 2))
            let isSelected = index == selected
            let color = band.isEnabled ? accent : Color.secondary
            if isSelected {
                context.fill(circle, with: .color(color))
            } else {
                context.fill(circle, with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
                context.stroke(circle, with: .color(color.opacity(band.isEnabled ? 1 : 0.5)), lineWidth: 1.5)
            }
            context.draw(Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(isSelected ? Color.white : color), at: center)
        }
    }

    // MARK: Gestures

    private func drag(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard isEnabled, pinchStartQ == nil else { return }
                if dragging == nil {
                    guard let index = nearestBand(to: drag.startLocation, in: plot) else {
                        dragging = -1
                        return
                    }
                    dragging = index
                    selected = index
                    let center = handlePoint(equalizer.bands[index], in: plot)
                    grabOffset = CGSize(width: center.x - drag.startLocation.x, height: center.y - drag.startLocation.y)
                }
                guard let index = dragging, index >= 0 else { return }
                let x = min(max(drag.location.x + grabOffset.width, plot.minX), plot.maxX)
                let y = min(max(drag.location.y + grabOffset.height, plot.minY), plot.maxY)
                let frequency = EqualizerSettings.roundFrequency(Float(Self.frequency(atX: x, in: plot)))
                let gain = (Float(Self.decibels(atY: y, in: plot)) * 10).rounded() / 10
                equalizer.update(band: index) { band in
                    band.frequency = frequency
                    if band.kind.hasGain { band.gain = gain }
                }
            }
            .onEnded { _ in
                dragging = nil
            }
    }

    /// Pinching the selected band changes its Q: spreading the fingers makes it wider.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isEnabled else { return }
                let start = pinchStartQ ?? equalizer.bands[selected].q
                pinchStartQ = start
                let q = start / Float(value.magnification)
                equalizer.update(band: selected) { $0.q = (q * 100).rounded() / 100 }
            }
            .onEnded { _ in
                pinchStartQ = nil
                dragging = nil
            }
    }

    /// The point under the finger, preferring the selected one when points overlap.
    private func nearestBand(to location: CGPoint, in plot: CGRect) -> Int? {
        let reach: CGFloat = 30
        func distance(_ index: Int) -> CGFloat {
            let point = handlePoint(equalizer.bands[index], in: plot)
            return hypot(point.x - location.x, point.y - location.y)
        }
        if distance(selected) <= Self.handleRadius + 4 { return selected }
        return equalizer.bands.indices
            .filter { distance($0) <= reach }
            .min { distance($0) < distance($1) }
    }

    private var accessibilityDescription: String {
        let band = equalizer.bands[selected]
        var parts = ["Band \(selected + 1)", band.kind.name, EqualizerSettings.frequency(band.frequency)]
        if band.kind.hasGain { parts.append(EqualizerSettings.decibels(band.gain)) }
        parts.append(String(format: "Q %.2f", Double(band.q)))
        if !band.isEnabled { parts.append("off") }
        return parts.joined(separator: ", ")
    }
}
