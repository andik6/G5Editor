import SwiftUI
import G5Core

/// Large editable knob: drag up/down (or left/right) to turn, double-click to type a value.
struct Knob: View {
    let param: EffectParam
    let value: Int
    let tint: Color
    let onChange: (Int) -> Void

    @StateObject private var dragStart = Box<Int?>(nil)
    @StateObject private var editing = Box(false)
    @StateObject private var text = Box("")

    private var norm: Double { Double(value) / Double(max(param.max, 1)) }
    private var pointsPerStep: Double { min(12, max(220.0 / Double(max(param.max, 1)), 0.12)) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().trim(from: 0, to: 0.75).rotation(.degrees(135))
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Circle().trim(from: 0, to: 0.75 * norm).rotation(.degrees(135))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
                    .padding(9)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                Capsule().fill(Color.white).frame(width: 3, height: 12).offset(y: -16)
                    .rotationEffect(.degrees(-135 + 270 * norm))
            }
            .frame(width: 66, height: 66)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragStart.value == nil { dragStart.value = value }
                        let dist = Double(-g.translation.height + g.translation.width)
                        let v = min(param.max, max(0, dragStart.value! + Int(dist / pointsPerStep)))
                        if v != value { onChange(v) }
                    }
                    .onEnded { _ in dragStart.value = nil }
            )
            .onTapGesture(count: 2) { text.value = "\(value + param.offset)"; editing.value = true }
            .popover(isPresented: $editing.value) { editor }
            .help("Drag to turn · double-click to type a value")

            Text(param.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(param.display(value)).font(.system(size: 13, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 96)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(param.name).font(.headline)
            HStack {
                if param.choices == nil && param.syncFrom == nil {
                    TextField("Value", text: $text.value)
                        .frame(width: 80)
                        .onSubmit { commitText() }
                }
                Stepper("", onIncrement: { onChange(min(param.max, value + 1)) }, onDecrement: { onChange(max(0, value - 1)) })
                    .labelsHidden()
                Text(param.display(value)).monospacedDigit().frame(minWidth: 70, alignment: .leading)
            }
            Text("Range \(param.display(0)) – \(param.display(param.max))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func commitText() {
        if let n = Int(text.value.trimmingCharacters(in: .whitespaces)) {
            onChange(min(param.max, max(0, n - param.offset)))
        }
        editing.value = false
    }
}

/// Menu for settings that are a short list of named choices.
struct ChoiceControl: View {
    let param: EffectParam
    let value: Int
    let onChange: (Int) -> Void
    var body: some View {
        VStack(spacing: 8) {
            Picker(param.name, selection: Binding(get: { value }, set: onChange)) {
                ForEach(Array((param.choices ?? []).enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
            }
            .labelsHidden()
            .frame(width: 120)
            Text(param.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(height: 104)
    }
}
