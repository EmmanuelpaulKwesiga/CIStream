import SwiftUI

enum SceneProfile: String, CaseIterable, Identifiable {
    case quiet     = "Quiet"
    case meeting   = "Meeting"
    case cafeteria = "Cafeteria"
    case street    = "Street"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .quiet:     return "moon.stars.fill"
        case .meeting:   return "person.3.fill"
        case .cafeteria: return "fork.knife"
        case .street:    return "car.fill"
        }
    }

    var color: Color {
        switch self {
        case .quiet:     return .blue
        case .meeting:   return .purple
        case .cafeteria: return .orange
        case .street:    return .red
        }
    }

    // Default suppression preset for this environment
    var defaultSuppression: Float {
        switch self {
        case .quiet:     return 0.00   // off — no noise, no artifacts
        case .meeting:   return 0.35   // moderate stationary noise (HVAC, projector)
        case .cafeteria: return 0.50   // louder, more variable crowd noise
        case .street:    return 0.25   // broadband traffic — over-suppression distorts
        }
    }

    var defaultSCE: Float {
        switch self {
        case .quiet:     return 0.0
        case .meeting:   return 0.2
        case .cafeteria: return 0.3
        case .street:    return 0.1
        }
    }

    var defaultTreble: Float {
        switch self {
        case .quiet:     return 0.0
        case .meeting:   return 0.2
        case .cafeteria: return 0.25
        case .street:    return 0.15
        }
    }

    var description: String {
        switch self {
        case .quiet:
            return "No suppression. Clean signal, no artifacts."
        case .meeting:
            return "Moderate suppression for stationary room noise and HVAC."
        case .cafeteria:
            return "Stronger suppression for crowd noise and background chatter."
        case .street:
            return "Light suppression only — heavy traffic noise is broadband and over-suppression distorts speech."
        }
    }
}
