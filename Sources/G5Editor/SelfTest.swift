import Foundation
import G5Core

/// Debug aid: with G5_SELFTEST=1, exercises the editor actions on the open patch,
/// checks the pedal matches after each step, then reverts. Results go to stderr.
enum SelfTest {
    @MainActor static func schedule(_ model: AppModel) {
        guard ProcessInfo.processInfo.environment["G5_SELFTEST"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { Task { await run(model) } }
    }

    @MainActor static func pedal(_ model: AppModel) async -> PatchData? {
        await withCheckedContinuation { c in
            model.queue.async { c.resume(returning: try? model.device.readEditBuffer()) }
        }
    }

    @MainActor static func step(_ model: AppModel, _ name: String, wait: Double = 1.0, _ action: () -> Void) async {
        action()
        try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        let p = await pedal(model)
        log("selftest \(name): pedal matches editor = \(p == model.editing?.patch)")
    }

    @MainActor static func run(_ model: AppModel) async {
        guard let e = model.editing else { log("selftest: no patch open"); return }
        log("selftest on \(AppModel.label(e.slot)) \(e.patch.name)")
        let amp = (0..<9).first { e.patch.type($0)?.amp == true } ?? 0
        await step(model, "knob") { model.setParam(amp, 2, min(100, e.patch.param(amp, 2) + 7)) }
        await step(model, "on/off") { model.setOn(0, !e.patch.isOn(0)) }
        await step(model, "move amp to front") { model.move(amp, to: 0) }
        await step(model, "change type", wait: 1.5) { model.setType(1, 53) }
        log("selftest   effect 2 is now \(model.editing?.patch.type(1)?.name ?? "?")")
        await step(model, "rename") { model.rename("SelfTest") }
        await step(model, "level") { model.setLevel(90) }
        await step(model, "revert", wait: 2.5) { model.revert() }
        let stored = await withCheckedContinuation { c in model.queue.async { c.resume(returning: try? model.device.readPatch(e.slot).patchData) } }
        log("selftest after revert: editor == original \(model.editing?.patch == e.original), stored == original \(stored == e.original)")
    }
}
