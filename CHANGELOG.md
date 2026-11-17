# Changelog

All notable changes to G5 Editor. Versions follow [semantic versioning](https://semver.org).

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
