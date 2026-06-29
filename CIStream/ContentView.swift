import SwiftUI
import SwiftData

struct ContentView: View {

    @State private var engine = AudioEngine()
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.timestamp, order: .reverse) private var sessions: [SessionRecord]
    @State private var showingExport = false
    @State private var exportURL: URL? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    routeCard
                    meterCard
                    sceneCard
                    snrCard
                    userAdjCard
                    pipelineCard
                    historyCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("CIStream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !sessions.isEmpty {
                        Button {
                            let csv = sessions.exportCSV()
                            let url = FileManager.default.temporaryDirectory
                                .appendingPathComponent("CIStream_Sessions.csv")
                            try? csv.write(to: url, atomically: true, encoding: .utf8)
                            exportURL    = url
                            showingExport = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    scenePill
                }
            }
            .safeAreaInset(edge: .bottom) {
                controlBar
            }
            .task {
                if engine.micPermission == nil {
                    await engine.requestMicPermission()
                }
            }
            .sheet(item: $engine.pendingSession) { pending in
                EffortRatingView(
                    pending: pending,
                    onRate: { rating in
                        let record = SessionRecord(
                            scene:               pending.scene,
                            suppressionStrength: pending.suppressionStrength,
                            sceDepth:            pending.sceDepth,
                            trebleBoost:         pending.trebleBoost,
                            effortRating:        rating,
                            durationSeconds:     pending.durationSeconds
                        )
                        modelContext.insert(record)
                        engine.clearPendingSession()
                    },
                    onSkip: { engine.clearPendingSession() }
                )
            }
            .sheet(isPresented: $showingExport) {
                if let url = exportURL {
                    ShareSheet(url: url)
                }
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .font(.headline)
                if case .error(let msg) = engine.status {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(engine.isRunning
                         ? "Audio flowing mic \u{2192} DSP \u{2192} output"
                         : "Tap Start to begin preprocessing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if engine.micPermission == false {
                Label("No mic", systemImage: "mic.slash.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .card()
    }

    // MARK: - Route card

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Audio Route")

            HStack(alignment: .center, spacing: 8) {
                portBadge(engine.inputPortName,  icon: "mic.fill",       color: .blue)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                portBadge(engine.outputPortName, icon: "headphones",     color: .purple)
            }

            Divider()

            row(label: "Round-trip latency",
                icon: "timer",
                value: engine.isRunning
                    ? String(format: "%.1f ms", engine.latencyMS)
                    : "—")
        }
        .padding()
        .card()
    }

    // MARK: - Meter card

    private var meterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Input Level")
                Spacer()
                Text(engine.isRunning
                     ? String(format: "%.0f dBFS", engine.inputLevelDB)
                     : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LevelMeterView(levelDB: engine.inputLevelDB, active: engine.isRunning)
            HStack {
                Text("−80").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("−18").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("0 dBFS").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding()
        .card()
    }

    // MARK: - User Adjustment card (Phase 3)

    private var userAdjCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("User Adjustment")

            adjSlider(
                label: "Spectral Contrast",
                icon: "waveform.path.ecg",
                value: $engine.sceDepth,
                hint: "Sharpens speech peaks vs. noise valleys across frequency bands"
            )

            Divider()

            adjSlider(
                label: "High-Freq Emphasis",
                icon: "waveform.badge.plus",
                value: $engine.trebleBoost,
                hint: "Boosts consonants above 1 kHz — /s/, /f/, /t/ — often clearest gain for CI users"
            )
        }
        .padding()
        .card()
    }

    private func adjSlider(label: String, icon: String,
                           value: Binding<Float>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(value.wrappedValue < 0.01
                     ? "Off"
                     : String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(value.wrappedValue < 0.01 ? Color.secondary : Color.blue)
            }
            Slider(value: value, in: 0...1).tint(.blue)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - SNR Engine card (Phase 2)

    private var snrCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("SNR Engine")
                Spacer()
                Text(engine.suppressionStrength < 0.01
                     ? "Off"
                     : String(format: "%.0f%%", engine.suppressionStrength * 100))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(engine.suppressionStrength < 0.01 ? Color.secondary : Color.blue)
                    .animation(.easeInOut, value: engine.suppressionStrength)
            }

            Slider(value: $engine.suppressionStrength, in: 0...0.7)
                .tint(.blue)

            HStack {
                Text("Off (passthrough)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Strong").font(.caption2).foregroundStyle(.tertiary)
            }

            if engine.suppressionStrength > 0.01 && engine.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Calibrating — stay in background noise (not silence) for 0.2 s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if engine.suppressionStrength > 0.01 {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Scene preset applied. Drag to fine-tune.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .card()
    }

    // MARK: - Pipeline card

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DSP Pipeline")
            HStack {
                pipelineStage("SNR\nEngine",    icon: "waveform.badge.minus",  phase: 1, active: true)
                connector
                pipelineStage("Scene\nProfile", icon: "map",                   phase: 2, active: true)
                connector
                pipelineStage("User\nAdj.",     icon: "slider.horizontal.3",   phase: 3, active: true)
                connector
                pipelineStage("Effort\nFBK",    icon: "brain.head.profile",    phase: 4, active: true)
            }
            Text("All 4 stages active. Rate effort after each session to teach the adaptive model.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .card()
    }

    private var connector: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func pipelineStage(_ label: String, icon: String, phase: Int, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(active ? Color.blue : Color.secondary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(active ? .primary : .secondary)
            Text("Ph. \(phase)")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scene card

    private var sceneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Scene Profile")
            HStack(spacing: 8) {
                ForEach(SceneProfile.allCases) { scene in
                    sceneButton(scene)
                }
            }
            Text(engine.currentScene.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .card()
    }

    private func sceneButton(_ scene: SceneProfile) -> some View {
        let selected = engine.currentScene == scene
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                engine.setScene(scene)   // applies preset defaults
                // Override with learned parameters if enough history exists
                if let adapted = sessions.adaptedParameters(for: scene) {
                    engine.suppressionStrength = adapted.suppression
                    engine.sceDepth            = adapted.sce
                    engine.trebleBoost         = adapted.treble
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: scene.icon)
                    .font(.title3)
                    .foregroundStyle(selected ? scene.color : Color.secondary)
                Text(scene.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? scene.color.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scene pill (nav bar — mirrors current scene)

    private var scenePill: some View {
        Menu {
            ForEach(SceneProfile.allCases) { scene in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        engine.setScene(scene)
                    }
                } label: {
                    Label(scene.rawValue, systemImage: scene.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: engine.currentScene.icon)
                    .font(.caption2)
                Text(engine.currentScene.rawValue)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(engine.currentScene.color.opacity(0.12))
            .foregroundStyle(engine.currentScene.color)
            .clipShape(Capsule())
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if engine.isRunning { engine.stop() } else { engine.start() }
            } label: {
                Label(
                    engine.isRunning ? "Stop" : "Start Processing",
                    systemImage: engine.isRunning ? "stop.circle.fill" : "play.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(engine.isRunning ? Color.red : Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(engine.micPermission == false)
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func portBadge(_ name: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.footnote)
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
        }
    }

    private func row(label: String, icon: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .running: return .green
        case .stopped: return .secondary
        case .error:   return .red
        }
    }

    private var statusLabel: String {
        switch engine.status {
        case .running: return "Processing"
        case .stopped: return "Stopped"
        case .error:   return "Error"
        }
    }
}

// MARK: - History card

extension ContentView {
    var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Session History")
                Spacer()
                Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if sessions.isEmpty {
                Text("No sessions yet. Run for ≥5 s, then rate your listening effort to record a session.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(SceneProfile.allCases) { scene in
                    let sc = sessions.filter { $0.scene == scene.rawValue }
                    if !sc.isEmpty {
                        let avg = Float(sc.map(\.effortRating).reduce(0, +)) / Float(sc.count)
                        HStack(spacing: 8) {
                            Image(systemName: scene.icon)
                                .foregroundStyle(scene.color)
                                .frame(width: 18)
                            Text(scene.rawValue)
                                .font(.subheadline)
                            Spacer()
                            effortBar(avg)
                            Text(String(format: "%.1f", avg))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(effortColor(Int(avg.rounded())))
                            Text("(\(sc.count))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Divider()

                ForEach(sessions.prefix(5)) { r in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(effortColor(r.effortRating))
                            .frame(width: 8, height: 8)
                        Text(r.scene)
                            .font(.caption)
                        Text("Effort \(r.effortRating)/5")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(r.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .card()
    }

    func effortBar(_ avg: Float) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Float(i) <= avg ? effortColor(Int(avg.rounded())) : Color(.systemFill))
                    .frame(width: 8, height: 14)
            }
        }
    }

    func effortColor(_ rating: Int) -> Color {
        switch rating {
        case 1:  return .green
        case 2:  return .mint
        case 3:  return .yellow
        case 4:  return .orange
        default: return .red
        }
    }
}

// MARK: - Level Meter

struct LevelMeterView: View {
    var levelDB: Float
    var active: Bool

    private var fraction: CGFloat {
        guard active else { return 0 }
        return CGFloat((levelDB + 80) / 80).clamped(to: 0...1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemFill))
                RoundedRectangle(cornerRadius: 4)
                    .fill(gradient)
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 0.04), value: fraction)
            }
        }
        .frame(height: 20)
    }

    private var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green,  location: 0.0),
                .init(color: .yellow, location: 0.7),
                .init(color: .red,    location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension View {
    func card() -> some View {
        self
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Share Sheet

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
