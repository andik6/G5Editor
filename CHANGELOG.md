# Changelog

All notable changes to G5 Editor. Versions follow [semantic versioning](https://semver.org).

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

[0.2.0]: https://github.com/andik6/G5Editor/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/andik6/G5Editor/releases/tag/v0.1.0
