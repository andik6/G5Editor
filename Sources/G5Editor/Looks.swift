import SwiftUI
import G5Core

/// Colour schemes that echo the real pedal or amp an effect is modelled on.
/// Only colours are borrowed, never logos. Types without a known original keep their category colour.

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }

enum KnobStyle { case black, chrome, cream, red }

struct StompLook {
    var body: Color
    var text: Color = .white
    var knob: KnobStyle = .black
    var metallic = false          // brushed / sparkle finish
}

enum GrillePattern { case diagonal, basket, diamond, cloth, plain }

struct AmpLook {
    var tolex: Color              // cabinet covering (frame)
    var panel: [Color]            // control panel gradient, top → bottom
    var text: Color               // lettering on the panel
    var grille: Color
    var weave: Color              // thread colour of the grille cloth
    var pattern: GrillePattern
    var piping: Color? = nil      // thin trim between tolex and grille
    var knob: KnobStyle = .black
    var diamondPlate = false      // Mesa-style checker-plate panel
}

extension AmpLook {
    static let zoom = AmpLook(tolex: rgb(26, 21, 18), panel: [rgb(237, 214, 158), rgb(199, 168, 107)], text: rgb(46, 33, 20),
                              grille: rgb(41, 33, 28), weave: rgb(140, 115, 77), pattern: .diagonal)
    // Fender blackface: black tolex, black panel with white script, silver sparkle grille cloth.
    static let blackface = AmpLook(tolex: rgb(18, 18, 18), panel: [rgb(40, 40, 42), rgb(14, 14, 15)], text: rgb(235, 235, 235),
                                   grille: rgb(150, 155, 158), weave: rgb(60, 140, 150), pattern: .cloth, piping: rgb(190, 190, 190), knob: .black)
    // Fender brownface: brown tolex, brown panel, wheat grille.
    static let brownface = AmpLook(tolex: rgb(84, 52, 32), panel: [rgb(120, 78, 48), rgb(78, 48, 28)], text: rgb(240, 225, 200),
                                   grille: rgb(196, 170, 120), weave: rgb(140, 110, 70), pattern: .cloth, knob: .cream)
    // Fender tweed: lacquered tweed, chrome panel, brown linen grille with gold threads.
    static let tweed = AmpLook(tolex: rgb(196, 165, 108), panel: [rgb(225, 225, 225), rgb(150, 150, 152)], text: rgb(40, 40, 40),
                               grille: rgb(92, 62, 40), weave: rgb(200, 160, 80), pattern: .cloth, knob: .cream)
    // Vox: black tolex, copper top panel, brown diamond grille.
    static let voxBlack = AmpLook(tolex: rgb(20, 20, 20), panel: [rgb(205, 125, 70), rgb(150, 82, 40)], text: rgb(250, 240, 225),
                                  grille: rgb(82, 44, 34), weave: rgb(190, 150, 110), pattern: .diamond, piping: rgb(230, 225, 210), knob: .cream)
    // Early JMI Vox: fawn tolex.
    static let voxFawn = AmpLook(tolex: rgb(196, 172, 135), panel: [rgb(205, 125, 70), rgb(150, 82, 40)], text: rgb(250, 240, 225),
                                 grille: rgb(82, 44, 34), weave: rgb(190, 150, 110), pattern: .diamond, knob: .cream)
    // Marshall plexi: black tolex, gold panel, white piping, salt-and-pepper / basketweave grille.
    static let plexi = AmpLook(tolex: rgb(16, 16, 16), panel: [rgb(244, 214, 128), rgb(196, 152, 64)], text: rgb(30, 24, 12),
                               grille: rgb(70, 58, 44), weave: rgb(180, 160, 120), pattern: .basket, piping: rgb(235, 235, 230), knob: .black)
    // Marshall JCM2000: gold panel, black grille with gold piping.
    static let jcm = AmpLook(tolex: rgb(16, 16, 16), panel: [rgb(240, 205, 115), rgb(190, 145, 55)], text: rgb(30, 24, 12),
                             grille: rgb(24, 24, 24), weave: rgb(70, 70, 70), pattern: .basket, piping: rgb(212, 172, 80), knob: .black)
    // Mesa/Boogie Mark series: all black.
    static let mark = AmpLook(tolex: rgb(18, 18, 18), panel: [rgb(36, 36, 38), rgb(12, 12, 13)], text: rgb(225, 225, 225),
                              grille: rgb(26, 26, 26), weave: rgb(64, 64, 64), pattern: .plain, knob: .black)
    // Mesa Rectifier: chrome diamond-plate panel.
    static let rectifier = AmpLook(tolex: rgb(18, 18, 18), panel: [rgb(214, 216, 220), rgb(140, 143, 148)], text: rgb(25, 25, 25),
                                   grille: rgb(22, 22, 22), weave: rgb(60, 60, 60), pattern: .plain, knob: .black, diamondPlate: true)
    // Matchless: black tolex, chrome panel, silver-grey grille.
    static let matchless = AmpLook(tolex: rgb(20, 20, 20), panel: [rgb(230, 230, 232), rgb(158, 160, 164)], text: rgb(30, 30, 30),
                                   grille: rgb(128, 128, 126), weave: rgb(60, 60, 60), pattern: .basket, knob: .cream)
    // Carr: cream tolex, wheat grille.
    static let carr = AmpLook(tolex: rgb(232, 222, 196), panel: [rgb(232, 232, 232), rgb(170, 170, 172)], text: rgb(40, 40, 40),
                              grille: rgb(200, 176, 128), weave: rgb(150, 125, 85), pattern: .cloth, knob: .black)
    // Hiwatt: black tolex, dark grey panel with white engraving, black basketweave.
    static let hiwatt = AmpLook(tolex: rgb(18, 18, 18), panel: [rgb(70, 72, 76), rgb(38, 40, 43)], text: rgb(240, 240, 240),
                                grille: rgb(28, 28, 28), weave: rgb(80, 80, 80), pattern: .basket, knob: .black)
    // Orange: orange tolex, white graphic panel, beige basketweave.
    static let orange = AmpLook(tolex: rgb(236, 112, 24), panel: [rgb(248, 246, 240), rgb(214, 210, 200)], text: rgb(25, 25, 25),
                                grille: rgb(214, 196, 160), weave: rgb(160, 140, 105), pattern: .basket, knob: .black)
    // Bogner: black tolex, nickel panel.
    static let bogner = AmpLook(tolex: rgb(16, 16, 16), panel: [rgb(205, 207, 210), rgb(130, 132, 136)], text: rgb(20, 20, 20),
                                grille: rgb(24, 24, 24), weave: rgb(66, 66, 66), pattern: .basket, knob: .chrome)
    // Diezel: black with blue lettering.
    static let diezel = AmpLook(tolex: rgb(14, 14, 14), panel: [rgb(30, 32, 36), rgb(10, 10, 12)], text: rgb(90, 160, 255),
                                grille: rgb(20, 20, 20), weave: rgb(55, 55, 60), pattern: .plain, knob: .black)
    // ENGL: black with silver lettering, black grille.
    static let engl = AmpLook(tolex: rgb(14, 14, 14), panel: [rgb(48, 48, 50), rgb(20, 20, 22)], text: rgb(200, 205, 210),
                              grille: rgb(22, 22, 22), weave: rgb(60, 60, 60), pattern: .diamond, knob: .chrome)
    // Krank: black with red accents.
    static let krank = AmpLook(tolex: rgb(14, 14, 14), panel: [rgb(34, 34, 36), rgb(12, 12, 12)], text: rgb(225, 45, 40),
                               grille: rgb(20, 20, 20), weave: rgb(58, 58, 58), pattern: .basket, knob: .black)
    // Two-Rock: black tolex, silver panel, oxblood grille.
    static let twoRock = AmpLook(tolex: rgb(18, 18, 18), panel: [rgb(220, 220, 222), rgb(150, 150, 152)], text: rgb(30, 30, 30),
                                 grille: rgb(92, 34, 32), weave: rgb(150, 80, 70), pattern: .cloth, knob: .chrome)
}

extension EffectType {
    var ampLook: AmpLook {
        switch name {
        case "FD COMBO", "DELUXE-R": return .blackface
        case "FD VIBRO": return .brownface
        case "US BLUES": return .tweed
        case "VX COMBO": return .voxBlack
        case "VX JMI": return .voxFawn
        case "BG CRUNCH": return .mark
        case "MATCH 30": return .matchless
        case "CAR DRIVE": return .carr
        case "TW ROCK": return .twoRock
        case "HW STACK": return .hiwatt
        case "TANGERINE": return .orange
        case "B-BREAKER", "MS CRUNCH", "MS 1959": return .plexi
        case "MS DRIVE": return .jcm
        case "BGN DRIVE": return .bogner
        case "BG DRIVE": return .rectifier
        case "DZ DRIVE": return .diezel
        case "ALIEN": return .engl
        case "REVO-1": return .krank
        default: return .zoom
        }
    }

    /// The real pedal's colours, or nil to use the category colour.
    var stompLook: StompLook? {
        switch name {
        case "COMP": return StompLook(body: rgb(200, 30, 36))                                         // MXR Dyna Comp
        case "RackComp": return StompLook(body: rgb(52, 54, 58), text: rgb(220, 220, 220), knob: .chrome, metallic: true)
        case "GraphicEQ": return StompLook(body: rgb(236, 236, 232), text: rgb(30, 30, 30))          // compact 7-band EQ
        case "M-Filter": return StompLook(body: rgb(26, 26, 28), text: rgb(240, 236, 220), knob: .chrome) // Moogerfooger
        case "OverDrive": return StompLook(body: rgb(244, 206, 40), text: rgb(25, 25, 25))           // Boss OD-1
        case "T Scream": return StompLook(body: rgb(70, 160, 90), text: rgb(245, 245, 235), knob: .cream) // TS808
        case "Governor": return StompLook(body: rgb(30, 30, 32), text: rgb(226, 186, 92), knob: .black) // Guv'nor
        case "Dist+": return StompLook(body: rgb(246, 210, 30), text: rgb(25, 25, 25))               // MXR Distortion+
        case "Dist 1": return StompLook(body: rgb(240, 120, 30), text: rgb(25, 25, 25))              // Boss DS-1
        case "Squeak": return StompLook(body: rgb(24, 24, 26), text: rgb(240, 240, 240))             // ProCo RAT
        case "FuzzSmile": return StompLook(body: rgb(206, 32, 38), knob: .black)                     // Fuzz Face
        case "GreatMuff": return StompLook(body: rgb(206, 208, 212), text: rgb(200, 30, 36), metallic: true) // Big Muff
        case "MetalWRLD": return StompLook(body: rgb(38, 38, 42), text: rgb(244, 132, 40))           // Metal Zone
        case "HotBox": return StompLook(body: rgb(196, 198, 202), text: rgb(25, 25, 25), knob: .black, metallic: true) // Matchless HotBox
        case "Phaser": return StompLook(body: rgb(242, 110, 26), text: rgb(25, 25, 25))              // MXR Phase 90
        case "TheVibe": return StompLook(body: rgb(30, 30, 30), text: rgb(230, 200, 140), knob: .chrome) // Uni-Vibe
        case "VintageCE": return StompLook(body: rgb(96, 166, 220), text: rgb(20, 30, 50))           // Boss CE-series chorus
        case "TapeEcho": return StompLook(body: rgb(60, 92, 70), text: rgb(240, 236, 220), knob: .cream) // Space Echo
        case "PedalCry", "WAH 100": return StompLook(body: rgb(22, 22, 22), text: rgb(225, 225, 225), knob: .chrome, metallic: true) // Cry Baby
        case "PedalVx": return StompLook(body: rgb(190, 192, 196), text: rgb(25, 25, 25), knob: .black, metallic: true) // Vox wah
        case "Rt Closet", "Rotary-Z": return StompLook(body: rgb(120, 72, 38), text: rgb(245, 230, 200), knob: .cream) // Leslie wood
        case "Spring": return StompLook(body: rgb(30, 30, 30), text: rgb(235, 235, 235), knob: .black)  // Fender spring tank
        default: return nil
        }
    }
}

/// Knob face colours for each style.
extension KnobStyle {
    var colors: [Color] {
        switch self {
        case .black: return [Color(white: 0.30), Color(white: 0.08)]
        case .chrome: return [Color(white: 0.95), Color(white: 0.55)]
        case .cream: return [rgb(250, 244, 226), rgb(200, 188, 160)]
        case .red: return [rgb(230, 70, 60), rgb(150, 20, 20)]
        }
    }
    var pointer: Color { self == .black ? .white.opacity(0.9) : .black.opacity(0.75) }
}
