import SwiftUI
import G5Core

extension EffectGroup {
    var color: Color {
        switch self {
        case .dynamics: return Color(red: 0.16, green: 0.62, blue: 0.62)
        case .filter: return Color(red: 0.55, green: 0.33, blue: 0.80)
        case .drive: return Color(red: 0.93, green: 0.48, blue: 0.13)
        case .amp: return Color(red: 0.80, green: 0.65, blue: 0.38)
        case .modulation: return Color(red: 0.22, green: 0.48, blue: 0.90)
        case .delay: return Color(red: 0.25, green: 0.68, blue: 0.35)
        case .reverb: return Color(red: 0.36, green: 0.40, blue: 0.85)
        case .combo: return Color(red: 0.85, green: 0.33, blue: 0.55)
        case .pedal: return Color(red: 0.88, green: 0.75, blue: 0.20)
        case .zpedal: return Color(red: 0.86, green: 0.24, blue: 0.24)
        case .sfx: return Color(red: 0.20, green: 0.70, blue: 0.75)
        case .other: return Color.gray
        case .empty: return Color.gray.opacity(0.3)
        }
    }
    var symbol: String {
        switch self {
        case .dynamics: return "waveform.path.ecg"
        case .filter: return "slider.vertical.3"
        case .drive: return "flame"
        case .amp: return "hifispeaker"
        case .modulation: return "water.waves"
        case .delay: return "repeat"
        case .reverb: return "building.columns"
        case .combo: return "square.stack.3d.up"
        case .pedal: return "shoeprints.fill"
        case .zpedal: return "arrow.up.and.down.and.arrow.left.and.right"
        case .sfx: return "sparkles"
        case .other: return "questionmark"
        case .empty: return "plus"
        }
    }
}

enum Palette {
    static let background = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let panel = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let panelLine = Color.white.opacity(0.08)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let ledOn = Color(red: 1.0, green: 0.18, blue: 0.15)
}
