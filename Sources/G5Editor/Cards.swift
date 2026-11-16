import SwiftUI
import G5Core

/// A small decorative knob used on the pedal drawings.
struct MiniKnob: View {
    var norm: Double
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1)
            Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 7).offset(y: -5)
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
        let c = info.group.color
        VStack(spacing: compact ? 6 : 9) {
            Circle()
                .fill(info.on ? Palette.ledOn : Color(white: 0.25))
                .frame(width: 9, height: 9)
                .shadow(color: info.on ? Palette.ledOn : .clear, radius: 5)
                .padding(.top, compact ? 8 : 11)
            HStack(spacing: 6) {
                ForEach(Array(info.knobs.enumerated()), id: \.offset) { MiniKnob(norm: $0.element) }
            }.frame(height: 24)
            Text(info.type?.name ?? "?")
                .font(.system(size: compact ? 12 : 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
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
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [c.opacity(0.95), c.opacity(0.62)], startPoint: .top, endPoint: .bottom))
        )
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
        VStack(spacing: 0) {
            // control panel
            VStack(spacing: 6) {
                HStack {
                    Text(info.type?.name ?? "AMP")
                        .font(.system(size: compact ? 12 : 14, weight: .black, design: .serif)).italic()
                        .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.08))
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
                    ForEach(Array(info.knobs.enumerated()), id: \.offset) { MiniKnob(norm: $0.element).scaleEffect(0.85) }
                    Spacer()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(LinearGradient(colors: [Color(red: 0.93, green: 0.84, blue: 0.62), Color(red: 0.78, green: 0.66, blue: 0.42)], startPoint: .top, endPoint: .bottom))
            // grille
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.16, green: 0.13, blue: 0.11)))
                var p = Path()
                stride(from: -size.height, through: size.width, by: 6).forEach { x in
                    p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                ctx.stroke(p, with: .color(Color(red: 0.55, green: 0.45, blue: 0.30).opacity(0.35)), lineWidth: 1)
            }
            .overlay(
                Text(cabinetLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.35), in: Capsule())
                    .padding(6), alignment: .bottomTrailing)
        }
        .frame(width: w, height: h)
        .background(Color(red: 0.10, green: 0.08, blue: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.25, green: 0.2, blue: 0.15), lineWidth: 4))
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
