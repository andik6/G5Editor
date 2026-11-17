import SwiftUI
import G5Core

/// A small decorative knob used on the pedal drawings.
struct MiniKnob: View {
    var norm: Double
    var style: KnobStyle = .black
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom))
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1)
            Capsule().fill(style.pointer).frame(width: 2, height: 7).offset(y: -5)
                .rotationEffect(.degrees(-135 + 270 * norm))
        }
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
    }
}

/// What to draw for one slot in the chain.
struct UnitInfo {
    var type: EffectType?
    var on: Bool
    var knobs: [Double]          // first few knob positions, 0…1
    var isEmpty: Bool { type?.isEmpty ?? true }
    var group: EffectGroup { type?.group ?? .empty }

    init(_ p: PatchData, _ unit: Int) {
        type = p.type(unit)
        on = p.isOn(unit)
        knobs = (type?.editableParams ?? []).prefix(3).map { Double(p.param(unit, $0.prm)) / Double(max($0.max, 1)) }
    }
    init(type: EffectType) {
        self.type = type; on = true
        knobs = type.editableParams.prefix(3).map { Double($0.initial) / Double(max($0.max, 1)) }
    }
}

/// Stompbox drawing.
struct StompCard: View {
    let info: UnitInfo
    var selected = false
    var compact = false
    var onFootswitch: (() -> Void)?

    var body: some View {
        let look = info.type?.stompLook
        let c = look?.body ?? info.group.color
        VStack(spacing: compact ? 6 : 9) {
            Circle()
                .fill(info.on ? Palette.ledOn : Color(white: 0.25))
                .frame(width: 9, height: 9)
                .shadow(color: info.on ? Palette.ledOn : .clear, radius: 5)
                .padding(.top, compact ? 8 : 11)
            HStack(spacing: 6) {
                ForEach(Array(info.knobs.enumerated()), id: \.offset) { MiniKnob(norm: $0.element, style: look?.knob ?? .black) }
            }.frame(height: 24)
            Text(info.type?.name ?? "?")
                .font(.system(size: compact ? 12 : 13, weight: .heavy, design: .rounded))
                .foregroundStyle(look?.text ?? .white)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
            Spacer(minLength: 0)
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.95), Color(white: 0.55)], center: .topLeading, startRadius: 1, endRadius: 22))
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
                .contentShape(Circle())
                .onTapGesture { onFootswitch?() }
                .help(info.on ? "Turn off" : "Turn on")
                .padding(.bottom, compact ? 8 : 12)
        }
        .frame(width: compact ? 104 : 118, height: compact ? 140 : 168)
        .background(StompBody(color: c, real: look != nil, metallic: look?.metallic ?? false))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Palette.accent : .clear, lineWidth: 3).padding(-3))
        .saturation(info.on ? 1 : 0.35)
        .brightness(info.on ? 0 : -0.12)
    }
}

/// Amp head drawing: control panel on top, speaker grille below.
struct AmpCard: View {
    let info: UnitInfo
    var selected = false
    var compact = false
    var onFootswitch: (() -> Void)?

    var body: some View {
        let w: CGFloat = compact ? 150 : 176, h: CGFloat = compact ? 140 : 168
        let look = info.type?.ampLook ?? .zoom
        VStack(spacing: 0) {
            // control panel
            VStack(spacing: 6) {
                HStack {
                    Text(info.type?.name ?? "AMP")
                        .font(.system(size: compact ? 12 : 14, weight: .black, design: .serif)).italic()
                        .foregroundStyle(look.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    Circle()
                        .fill(info.on ? Palette.ledOn : Color(white: 0.3))
                        .frame(width: 9, height: 9)
                        .shadow(color: info.on ? Palette.ledOn : .clear, radius: 5)
                        .onTapGesture { onFootswitch?() }
                        .help(info.on ? "Turn off" : "Turn on")
                }
                HStack(spacing: 5) {
                    ForEach(Array(info.knobs.enumerated()), id: \.offset) { MiniKnob(norm: $0.element, style: look.knob).scaleEffect(0.85) }
                    Spacer()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(AmpPanel(look: look))
            if let pipe = look.piping { Rectangle().fill(pipe).frame(height: 2) }
            Grille(look: look)
                .overlay(
                    Text(cabinetLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.45), in: Capsule())
                        .padding(6), alignment: .bottomTrailing)
        }
        .frame(width: w - 10, height: h - 10)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(5)
        .background(Tolex(color: look.tolex).clipShape(RoundedRectangle(cornerRadius: 10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.6), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.accent : .clear, lineWidth: 3).padding(-3))
        .saturation(info.on ? 1 : 0.3)
        .brightness(info.on ? 0 : -0.15)
    }

    var cabinetLabel: String { info.type?.cabinet.map { String($0.prefix(4)) } ?? "" }
}

struct EmptyCard: View {
    var selected = false
    var compact = false
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle").font(.system(size: 24, weight: .light))
            Text("Empty").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(width: compact ? 90 : 100, height: compact ? 140 : 168)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color.white.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Palette.accent : .clear, lineWidth: 3).padding(-3))
        .contentShape(Rectangle())
    }
}

struct UnitCard: View {
    let info: UnitInfo
    var selected = false
    var compact = false
    var onFootswitch: (() -> Void)?
    var body: some View {
        if info.isEmpty { EmptyCard(selected: selected, compact: compact) }
        else if info.type?.amp == true { AmpCard(info: info, selected: selected, compact: compact, onFootswitch: onFootswitch) }
        else { StompCard(info: info, selected: selected, compact: compact, onFootswitch: onFootswitch) }
    }
}

// MARK: - Surfaces

/// Pedal enclosure. Real-product colours are drawn as a painted box with a soft highlight;
/// category colours keep the original gradient.
struct StompBody: View {
    let color: Color
    var real = false
    var metallic = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        ZStack {
            if real {
                shape.fill(color)
                shape.fill(LinearGradient(colors: [.white.opacity(metallic ? 0.35 : 0.18), .clear, .black.opacity(metallic ? 0.25 : 0.18)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                if metallic {
                    Canvas { ctx, size in              // brushed-metal streaks
                        var p = Path()
                        for y in stride(from: 0.0, through: size.height, by: 2) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                        ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 0.6)
                    }.clipShape(shape)
                }
            } else {
                shape.fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.62)], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

/// Amp control panel, optionally with Rectifier-style diamond plate.
struct AmpPanel: View {
    let look: AmpLook
    var body: some View {
        ZStack {
            LinearGradient(colors: look.panel, startPoint: .top, endPoint: .bottom)
            if look.diamondPlate {
                Canvas { ctx, size in
                    var p = Path()
                    for y in stride(from: 0.0, through: size.height, by: 7) {
                        for x in stride(from: (Int(y / 7) % 2 == 0 ? 0.0 : 5.0), through: size.width, by: 10) {
                            p.move(to: CGPoint(x: x, y: y + 4)); p.addLine(to: CGPoint(x: x + 5, y: y + 1))
                        }
                    }
                    ctx.stroke(p, with: .color(.white.opacity(0.55)), lineWidth: 1.2)
                    ctx.stroke(p.offsetBy(dx: 0.8, dy: 0.8), with: .color(.black.opacity(0.25)), lineWidth: 1)
                }
            }
        }
    }
}

/// Speaker grille cloth.
struct Grille: View {
    let look: AmpLook
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(look.grille))
            var p = Path()
            switch look.pattern {
            case .diagonal:
                for x in stride(from: -size.height, through: size.width, by: 6) {
                    p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                ctx.stroke(p, with: .color(look.weave.opacity(0.35)), lineWidth: 1)
            case .diamond:
                for x in stride(from: -size.height, through: size.width + size.height, by: 9) {
                    p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                }
                ctx.stroke(p, with: .color(look.weave.opacity(0.55)), lineWidth: 1.4)
            case .basket:
                let s = 4.0
                for (j, y) in stride(from: 0.0, through: size.height, by: s).enumerated() {
                    for (i, x) in stride(from: 0.0, through: size.width, by: s).enumerated() where (i + j) % 2 == 0 {
                        p.addRect(CGRect(x: x, y: y, width: s, height: s))
                    }
                }
                ctx.fill(p, with: .color(look.weave.opacity(0.28)))
            case .cloth:
                for y in stride(from: 0.0, through: size.height, by: 2.5) {
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(p, with: .color(look.weave.opacity(0.35)), lineWidth: 0.8)
                var v = Path()
                for x in stride(from: 0.0, through: size.width, by: 3.5) {
                    v.move(to: CGPoint(x: x, y: 0)); v.addLine(to: CGPoint(x: x, y: size.height))
                }
                ctx.stroke(v, with: .color(.black.opacity(0.12)), lineWidth: 0.6)
            case .plain:
                for y in stride(from: 0.0, through: size.height, by: 3) {
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(p, with: .color(look.weave.opacity(0.25)), lineWidth: 0.6)
            }
            // soft vignette so it reads as fabric stretched over a baffle
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.35)]),
                                           center: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 10, endRadius: max(size.width, size.height) * 0.75))
        }
    }
}

/// Cabinet covering with a faint grain.
struct Tolex: View {
    let color: Color
    var body: some View {
        ZStack {
            color
            Canvas { ctx, size in
                var seed: UInt64 = 7
                func r() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                for _ in 0..<Int(size.width * size.height / 14) {
                    let rect = CGRect(x: r() * size.width, y: r() * size.height, width: 1.2, height: 1.2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(r() > 0.5 ? .white.opacity(0.06) : .black.opacity(0.18)))
                }
            }
        }
    }
}
