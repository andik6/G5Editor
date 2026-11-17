# Development notes

## Toolchain
- **Package:** SwiftPM; Swift 6 tools in Swift 5 language mode; macOS 14 deployment target.
- **Xcode not needed:** the project builds with the Command Line Tools alone. `build-app.sh` assembles the `.app` bundle by hand and ad-hoc signs it.
- **No `@State`:** the Command Line Tools don't ship SwiftUI's macro plugin. View-local state therefore goes through small `ObservableObject` holders (`Box<T>`, `SidebarState`…) with `@StateObject`.

```sh
swift build                          # debug build of everything
.build/debug/g5tool <command>        # developer CLI
./build-app.sh                       # release app → dist/
```

## Architecture

```
G5Core
 ├─ MIDIConnection   CoreMIDI client, UMP → bytes, SysEx reassembly, request/wait inbox
 ├─ G5Device         protocol: identity, editor mode, read/write patches, live edit, patch select
 ├─ Packing          7-bit pack/unpack
 ├─ PatchData        bit-level patch model (units, params, level, footswitch, name, CRC, messages)
 ├─ Backup           .syx files, read-all with retries
 ├─ Catalog          effect types / params from the embedded effects.json (EffectsData.swift)
 ├─ AudioMonitor     HAL IOProcs: G5 input → ring buffer → AudioConverter → chosen output
 └─ Pitch            YIN pitch detector, note maths, AudioInputTap (G5 input → ring buffer)

G5Editor (SwiftUI)
 ├─ AppModel         connection, jobs, editing session, coalesced param sends, 2 s pedal poll
 ├─ ContentView      sidebar (device, monitor, patches, backups), BackupView
 ├─ EditorView       patch header, signal chain, unit panel
 ├─ Cards / Knob     stompbox, amp and knob drawing
 ├─ Looks            colours of the real pedals and amps each effect models
 ├─ EffectBrowser    category grid
 ├─ Monitor          MonitorController + sidebar section
 └─ Tuner            TunerController (25 Hz detection, median smoothing) + needle view
```

- **Pedal I/O:** every call goes through one serial `DispatchQueue` in `AppModel`, so MIDI requests never overlap.
- **Knob drags:** these are coalesced, so only the latest value is sent.
- **Edit flow:** the app calls `selectPatch` before editing, because the pedal auto-saves into whichever patch is active.
- **Live changes:** most edits use the `31` parameter message. A reorder or rename sends the whole edit buffer (`28`).

### Monitor engine
- **Signal path:** input and output run as separate Core Audio IOProcs on their own devices. A stereo ring buffer, guarded by an `os_unfair_lock`, joins them.
- **Sample rate:** the output side resamples with `AudioConverter` (high quality).
- **Drift:** an underrun re-primes the buffer and raises its target fill by 64 frames. If the input runs ahead, the reader skips back to the target fill.
- **Buffers:** both devices request 128-frame buffers.

## Testing hooks
The app has two environment variables for testing without clicking through the UI:

| Variable | Effect |
|---|---|
| `G5_SNAPSHOT=/path/prefix` | About 14 s after launch, renders the window to `prefix-editor.png`, `prefix-amp.png` and `prefix-browser.png` |
| `G5_GALLERY=/path.png` | Renders every amp and every pedal that has a real-product colour scheme into one image, then quits |
| `G5_TUNERSHOT=/path.png` | Renders the tuner with sample readings (flat, in tune, idle), then quits |
| `G5_SELFTEST=1` | Runs a scripted edit session on patch 1 (knob, on/off, move, type change, rename, level), checks the pedal after each step, then reverts and checks the stored patch equals the original |

Log lines go to stderr with the prefix `[G5]`.

## g5tool commands

| Command | Writes to pedal? | Purpose |
|---|---|---|
| `selftest <backup.syx>` | no (offline) | Rebuilds every patch from decoded data and compares bytes |
| `monitor <sec> [output]` | no | Runs the audio monitor and prints flow stats every second |
| `noise <sec>` | no | Records the G5's USB input; prints level, hiss and 50/60 Hz hum each second |
| `tuner <sec>` | no | Live pitch readings from the G5's USB input |
| `tunertest` | no (offline) | Pitch-detector accuracy on synthetic tones; prints the worst error in cents |
| `backup` | no | Full backup to `~/Documents/G5 Backups` |
| `scan [from] [to]` | no | Lists stored patches |
| `raw "<hex>" …` | depends | Sends raw MIDI and prints the replies |
| `edit <unit> <prm> <val>` | edit buffer | Live param change; prints the bytes that changed |
| `bits` / `sweep` | edit buffer | Maps which bits a parameter uses |
| `active ["<hex>" …]` | no | Prints the active patch name |
| `livetest` | yes, then restores | Reorder + knob test on patch 1 |
| `writeback <slot>` | yes (same data) | Writes a patch back unchanged |
| `copytest <a> <b>` | yes, then restores | Copies a patch and restores the target |
| `restore1 <syx> <slot>` | yes | Restores one slot from a backup |

The commands that write to the pedal restore what they changed, but take a backup first anyway.

## Tuner
Pitch detection is in `Sources/G5Core/Pitch.swift`.
1. **First pass:** YIN on a 1.6 kHz low-passed window (about 4.6k samples at 44.1 kHz).
2. **Second pass:** YIN again after a 6th-order low-pass at 1.45 × the first estimate. Overtones on real strings are slightly sharp (inharmonicity), and this stops them pulling the reading sharp. Without it, the low strings read 4–17 cents sharp in testing.

`g5tool tunertest` must stay under 1 cent worst-case.

## Versioning
- The project uses [semantic versioning](https://semver.org). The version lives in `VERSION`.
- `build-app.sh` writes it to `CFBundleShortVersionString`, and the git commit count to `CFBundleVersion`.
- To release:
  1. Update `VERSION` and `CHANGELOG.md`.
  2. Commit, then tag `vX.Y.Z`.
  3. Push with `--tags`.
  4. Optionally create a GitHub release with the zipped app.

## Regenerating the effect catalog
The old Edit&Share payload isn't in the repository. Extract the G5 resource folder from `E_Edit_Share_Mac_2.zip`, then:

```sh
python3 tools/make_catalog.py <G5 resource dir> Sources/G5Core/Resources/effects.json [manual.txt]
```

Then embed it into the Swift source, since the app reads it from a string rather than a resource bundle:

```sh
python3 tools/embed_catalog.py      # effects.json → Sources/G5Core/EffectsData.swift
```
