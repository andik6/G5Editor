# Changelog

All notable changes to G5 Editor. Versions follow [semantic versioning](https://semver.org).

## [Unreleased]

### Added
- **Patches grouped by bank** in the sidebar: each bank opens and closes, and its row shows the three patch names (or the song title when the Sound Patcher wrote it). The bank being played opens by itself, open banks are remembered, search opens every matching bank, clicking a bank row opens or closes it, ⌥-click or Expand All opens or closes them all, and ← / → close or open the bank of the selected patch.
- **AI Sound Patcher** (toolbar ✨ or ⇧⌘P): a chat panel on the right. Ask for the guitar tones of a song and the AI fills one bank (three patches).
  - Uses **Claude Code** (`claude -p`) or **Codex** (`codex exec`) on this Mac, chosen in the new **Settings → Sound Patcher** tab, which also shows whether each is installed and logged in. Requests run on your own Claude or ChatGPT subscription. The assistant can research the gear and tempo but can't change files (Claude Code: web tools only; Codex: read-only sandbox).
  - The AI is given the effect catalog, the G5's rules and what the target bank holds now (read from the pedal, including your own knob tweaks), so follow-ups like "less gain on the rhythm patch" change only that.
  - Every proposal is validated against the catalog and the Z-Pedal rule. Mistakes go back to the AI automatically (twice at most).
  - A preview shows each patch's chain, notes and knob settings. Nothing is written until you click **Write to Bank**. The app then backs up every patch, writes and verifies the bank, and offers **Undo**.
  - Each written bank is also saved as JSON in `~/Documents/G5 Backups/Sound Patcher/`.

### Fixed
- **Z-Pedal slot handling.** Each G5 patch has one Z-Pedal slot, which only holds Z-Pedal effects (or ZP-None), and Z-Pedal effects only fit there. This was verified on the pedal; all 297 patches in a backup have exactly one such slot.
  - The app now recognises the slot even when it holds ZP-None. Before, it could send a Z-Pedal effect to another unit, and the pedal then emptied that unit.
  - The effect browser only offers what fits: Z-Pedal effects in the Z-Pedal slot, everything else in the other units, with a short note. "Empty Slot" on the Z-Pedal slot sets ZP-None.
  - A refused effect change no longer blames DSP power. No DSP limit was hit in tests (8 amps at once were accepted). The message now says what the pedal set instead.

### Changed
- **Monitor can play as loud as mastered music.** The volume goes up to +12 dB and is shown in dB (0 dB = the G5's own level). A guitar on its own peaks around -6 dBFS, about 8 to 10 dB quieter than a YouTube track, so 100% used to sound quiet.
  - A peak limiter on the monitor output (ceiling -1 dBFS, instant attack, 120 ms release) keeps the louder settings from clipping. A **LIMIT** light shows when it works.
  - The "Monitor volume too high" warning is gone, because the Mac side can no longer clip. "Clipping at the G5" stays.
- **Lower monitor latency:** about 9 ms instead of about 18 ms on G5 → HD USB.
  - IO buffers are now 32 frames instead of 128. Tested for 2 minutes, and under full CPU load on all cores, with no dropouts.
  - New **Latency** setting in the sidebar: Low (32), Normal (64) or Safe (128), for busy or older Macs.
  - Reserve added after an underrun now shrinks back after a calm minute, instead of staying for the rest of the session.
- **Honest delay readout:** the monitor's delay now includes the drivers' own latency and safety offsets. These added about 5 ms that weren't shown before.

### Added
- `g5tool latency`: buffer ranges, hidden driver latency and supported sample rates for the G5 and each output.
- `g5tool monitor <sec> [output] [buffer] [margin] [gainDb]`, for latency and limiter experiments.
- **Bank files (AI Sound Patcher, first step):** `g5tool apply <bank.json> <bank>` writes a 3-patch bank described by effect and knob names. It checks everything against the catalog and the Z-Pedal rule first (`--dry-run` checks only), takes a full backup, and verifies each patch by reading it back. Example: `banks/stars-switchfoot.json`.
- `g5tool catalogref` (the effect reference the AI gets) and `g5tool describe <backup> <bank>` (a bank in the bank-file format).
- `g5tool show <slot>` (a patch's knobs as the pedal displays them), `g5tool verifyall <backup>`, and `g5tool alloff <slot>` (all effects off, for noise tests; the patch is saved first).

## [0.2.1] - 2026-11-17

### Added
- **DMG download** for Apple Silicon and Intel Macs (universal binary). Built with `./make-dmg.sh`; `./build-app.sh --universal` builds the universal app alone.
- Microphone usage description in the app bundle. macOS asks before the app can read the G5's USB audio.
- **Clip warning:** a red dot on the monitor meter plus a short hint that says which setting to lower.
  - "Clipping at the G5": the pedal's own output hits 0 dB. Lower MASTER LEVEL or the patch level.
  - "Monitor volume too high": only the Mac side clips. Bring the monitor volume back toward 100%.
- Monitor volume shown as a percentage (100% plays the G5 at its own level), and a -6 dB mark on the meter.
- `g5tool devices` (list Core Audio devices and which ones the monitor picks) and `g5tool setrate` (for recovery tests).
- Developer render mode `G5_MONITORSHOT`.

### Fixed
- **Monitor recovers by itself.** It reconnects automatically when:
  - audio stops flowing for 1.5 s;
  - a device is unplugged, re-plugged or changes sample rate;
  - the Mac wakes from sleep.
  - Failed automatic starts retry quietly instead of giving up. The sidebar shows "Reconnecting…" meanwhile.
- **Wrong input device:** the G5's audio is now matched as "ZOOM G…" only. The Zoom meetings app's virtual "ZoomAudioDevice" could previously be picked instead, which left the monitor silent.
- A re-plugged G5 (new device ID) no longer leaves a dead route showing "On".

## [0.2.0] - 2026-11-17

### Added
- **Tuner** (⇧⌘T): chromatic tuner on the G5's USB audio.
  - Needle display, note and octave, frequency, and a standard-tuning string indicator.
  - A4 adjustable from 435 to 445 Hz.
  - Optionally mutes the monitor while tuning.
  - Two-pass YIN detection, accurate to within 0.7 cents on test tones.
- **App icon:** gold script "G5" on black tolex with gold piping.
- **Real-gear looks:** amps drawn in the colours of the amps they model (tolex, panel, grille cloth). Pedals modelled on a known stompbox use that pedal's colours.
- `g5tool noise`: measures level, hiss and mains hum on the G5's USB input.
- `g5tool tuner` and `g5tool tunertest`: live and offline checks for the tuner.
- Developer render modes `G5_GALLERY` and `G5_TUNERSHOT`.
- `VERSION` file, this changelog, and the version and build number in the app bundle.

### Changed
- README notes that GLOBAL → OUTPUT should be **DIRECT** when listening through the Mac, because the setting also affects the USB signal.

## [0.1.0] - 2026-11-16

### Added
- USB MIDI protocol for the original ZOOM G5 (firmware 1.20): read and write patches, live edit buffer, parameter changes, patch selection, CRC checksum.
- Visual editor:
  - signal chain of stompboxes and amps, with knobs and drag-to-reorder,
  - effect and amp browser,
  - patch name, level and control switch,
  - Revert and Save.
- Backup and restore of all 297 patches as `.syx`, verified after writing.
- Monitor: plays the G5's USB audio through any Mac output, with sample-rate conversion and drift correction (about 13 ms).
- `g5tool` developer CLI, catalog generators and protocol documentation.

[0.2.1]: https://github.com/andik6/G5Editor/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/andik6/G5Editor/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/andik6/G5Editor/releases/tag/v0.1.0
