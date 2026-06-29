import AVFoundation
import Observation
import Foundation

struct PendingSession: Identifiable {
    let id                  = UUID()
    let scene:              String
    let suppressionStrength: Float
    let sceDepth:           Float
    let trebleBoost:        Float
    let durationSeconds:    Double
}

@Observable
@MainActor
final class AudioEngine {

    // MARK: - Observable state

    enum Status: Equatable {
        case stopped
        case running
        case error(String)
    }

    private(set) var status: Status = .stopped
    private(set) var micPermission: Bool? = nil
    private(set) var inputLevelDB: Float = -80
    private(set) var inputPortName  = "—"
    private(set) var outputPortName = "—"
    private(set) var latencyMS: Double = 0
    var pendingSession: PendingSession? = nil

    private var sessionStart: Date? = nil

    var suppressionStrength: Float = 0 {
        didSet { processor.parameters.suppressionStrength = suppressionStrength }
    }
    var sceDepth: Float = 0 {
        didSet { processor.parameters.sceDepth = sceDepth }
    }
    var trebleBoost: Float = 0 {
        didSet { processor.parameters.trebleBoost = trebleBoost }
    }

    private(set) var currentScene: SceneProfile = .quiet

    func setScene(_ scene: SceneProfile) {
        currentScene        = scene
        suppressionStrength = scene.defaultSuppression
        sceDepth            = scene.defaultSCE
        trebleBoost         = scene.defaultTreble
        processor.resetNoiseEstimate()
    }

    var isRunning: Bool { status == .running }

    // MARK: - Audio objects (audio-thread accessible)
    // avEngine and player are not Sendable so we mark them nonisolated(unsafe).
    // processor is a Sendable final class — no annotation needed.

    nonisolated(unsafe) private let avEngine = AVAudioEngine()
    nonisolated(unsafe) private let player   = AVAudioPlayerNode()
    private              let processor       = DSPProcessor()

    // MARK: - Notification observer tokens
    // Held in a plain (nonisolated) box so deinit can remove them
    // without crossing the @MainActor boundary.
    private let tokens = ObserverTokens()

    init() { observeSystemEvents() }

    // MARK: - Public API

    func requestMicPermission() async {
        micPermission = await AVAudioApplication.requestRecordPermission()
    }

    func start() {
        guard status == .stopped, micPermission == true else { return }
        do {
            try activateSession()
            try buildGraph()
            try avEngine.start()
            player.play()
            status       = .running
            sessionStart = Date()
            refreshRouteAndLatency()
        } catch {
            let msg = (error as NSError).code == 561_017_449
                ? "Cannot start during a phone call"
                : error.localizedDescription
            status = .error(msg)
        }
    }

    func stop() {
        guard status == .running else { return }
        player.stop()
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        status       = .stopped
        inputLevelDB = -80

        let duration = Date().timeIntervalSince(sessionStart ?? Date())
        sessionStart = nil
        if duration >= 5 {
            pendingSession = PendingSession(
                scene:               currentScene.rawValue,
                suppressionStrength: suppressionStrength,
                sceDepth:            sceDepth,
                trebleBoost:         trebleBoost,
                durationSeconds:     duration
            )
        }
    }

    func clearPendingSession() { pendingSession = nil }

    // MARK: - Private — session

    private func activateSession() throws {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        // .allowBluetooth    → HFP/SCO profile used by MFi CI processors
        // .allowBluetoothA2DP → A2DP stereo streaming
        try s.setCategory(.playAndRecord,
                          mode: .measurement,
                          options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
        try s.setPreferredIOBufferDuration(256.0 / 44_100.0)   // ~5.8 ms
        try s.setActive(true)
        #endif
    }

    // MARK: - Private — graph

    private func buildGraph() throws {
        let input  = avEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        avEngine.attach(player)
        avEngine.connect(player, to: avEngine.mainMixerNode, format: format)

        // Capture nonisolated references for the audio-thread tap block.
        let playerRef    = player
        let processorRef = processor

        input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, _ in
            let level     = AudioEngine.rmsDB(buffer)
            let processed = processorRef.process(buffer)
            playerRef.scheduleBuffer(processed)
            Task { @MainActor [weak self] in
                self?.inputLevelDB = level
            }
        }
    }

    // MARK: - Private — metering

    nonisolated private static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0],
              buffer.frameLength > 0 else { return -80 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrtf(sum / Float(n))
        return rms > 0 ? max(-80, 20 * log10f(rms)) : -80
    }

    // MARK: - Private — route / latency

    private func refreshRouteAndLatency() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        inputPortName  = s.currentRoute.inputs.first?.portName  ?? "—"
        outputPortName = s.currentRoute.outputs.first?.portName ?? "—"
        let ioMs  = (s.inputLatency + s.outputLatency) * 1_000
        let bufMs =  s.ioBufferDuration * 2 * 1_000
        latencyMS = ioMs + bufMs
        #endif
    }

    // MARK: - Private — system notifications

    private func observeSystemEvents() {
        let nc = NotificationCenter.default
        #if os(iOS)
        tokens.route = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRouteAndLatency() }
        }

        tokens.interruption = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                raw == AVAudioSession.InterruptionType.ended.rawValue
            else { return }
            Task { @MainActor [weak self] in self?.start() }
        }
        #endif
    }
}

// MARK: - Observer token container
// A plain nonisolated class so its deinit can call NotificationCenter
// without crossing the @MainActor boundary of AudioEngine.

private final class ObserverTokens {
    var route: NSObjectProtocol?
    var interruption: NSObjectProtocol?

    deinit {
        if let o = route        { NotificationCenter.default.removeObserver(o) }
        if let o = interruption { NotificationCenter.default.removeObserver(o) }
    }
}
