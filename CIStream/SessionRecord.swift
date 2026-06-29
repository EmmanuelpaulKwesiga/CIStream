import SwiftData
import Foundation

@Model
final class SessionRecord {
    var scene:              String
    var suppressionStrength: Float
    var sceDepth:           Float
    var trebleBoost:        Float
    var effortRating:       Int       // 1 (effortless) – 5 (exhausting)
    var timestamp:          Date
    var durationSeconds:    Double

    init(scene: String,
         suppressionStrength: Float,
         sceDepth: Float,
         trebleBoost: Float,
         effortRating: Int,
         durationSeconds: Double) {
        self.scene               = scene
        self.suppressionStrength = suppressionStrength
        self.sceDepth            = sceDepth
        self.trebleBoost         = trebleBoost
        self.effortRating        = effortRating
        self.timestamp           = Date()
        self.durationSeconds     = durationSeconds
    }
}

// MARK: – Adaptation

extension [SessionRecord] {
    /// Weighted average parameters for a scene.
    /// Weight = recency decay × inverse effort (effort 1 → weight 5, effort 5 → weight 1).
    /// Returns nil if no records exist for this scene (caller uses preset defaults).
    func adaptedParameters(for scene: SceneProfile) -> (suppression: Float, sce: Float, treble: Float)? {
        let matching = filter { $0.scene == scene.rawValue }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(15)

        guard !matching.isEmpty else { return nil }

        var totalWeight: Float = 0
        var wSup: Float = 0
        var wSce: Float = 0
        var wTre: Float = 0

        for (i, r) in matching.enumerated() {
            let recency = powf(0.85, Float(i))
            let effort  = Float(6 - r.effortRating)   // invert: low effort = high weight
            let w       = recency * effort
            totalWeight += w
            wSup += r.suppressionStrength * w
            wSce += r.sceDepth            * w
            wTre += r.trebleBoost         * w
        }

        guard totalWeight > 0 else { return nil }
        return (wSup / totalWeight, wSce / totalWeight, wTre / totalWeight)
    }

    /// CSV string of all records, newest first.
    func exportCSV() -> String {
        let fmt = ISO8601DateFormatter()
        var csv = "timestamp,scene,suppression,sce_depth,treble_boost,effort_rating,duration_s\n"
        for r in sorted(by: { $0.timestamp > $1.timestamp }) {
            csv += "\(fmt.string(from: r.timestamp)),\(r.scene),"
            csv += "\(String(format: "%.3f", r.suppressionStrength)),"
            csv += "\(String(format: "%.3f", r.sceDepth)),"
            csv += "\(String(format: "%.3f", r.trebleBoost)),"
            csv += "\(r.effortRating),\(String(format: "%.1f", r.durationSeconds))\n"
        }
        return csv
    }
}
