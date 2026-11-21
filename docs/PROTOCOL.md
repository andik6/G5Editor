# ZOOM G5 MIDI protocol & patch format

These notes come from testing a G5 running firmware 1.20, and the code in `Sources/G5Core` relies on them. Zoom has not published this protocol. Everything below was checked against the real pedal unless it is marked *unverified*.

## Transport
- USB class-compliant MIDI. The port is named **"ZOOM G Series"**.
- The pedal is also a USB audio interface: 2 in / 2 out, 44.1 kHz, 16-bit.
- Every SysEx message starts with `F0 52 00 5B`: Zoom's manufacturer ID is `52`, device `00`, and the G5's model ID is `5B`.

## Messages

`hdr` = `F0 52 00 5B`. All values are hex.

| Send | Reply | Meaning |
|---|---|---|
| `F0 7E 7F 06 01 F7` | `F0 7E … 06 02 52 5B …`, firmware version as ASCII in bytes 10–13 | Universal identity request |
| `hdr 50 F7` / `hdr 51 F7` | – | Editor mode on / off |
| `hdr 29 F7` | `hdr 28 <158 packed bytes> F7` | Read the **edit buffer** (the patch being played) |
| `hdr 28 <packed> F7` | – | Replace the edit buffer; the sound changes immediately |
| `hdr 09 00 <bank> <idx> F7` | `hdr 08 00 <bank> <idx> 0A 01 <packed> <crc×5> F7` (174 bytes) | Read a **stored patch** |
| `hdr 08 00 <bank> <idx> 0A 01 <packed> <crc×5> F7` | `hdr 00 00 F7` | **Write** a stored patch |
| `hdr 31 <unit> <prm> <lo> <hi> F7` | – | Change one parameter live |
| `hdr 33 F7` | `B0 00 00`, `B0 20 <bank>`, `C0 <idx>` | Ask for the active patch |

`0A 01` is the length of the data: 138 bytes, encoded as a 7-bit pair.

### Patch numbering
- 297 patches = 99 banks × 3. `slot = bank × 3 + idx`.
- The display label is `BB-I`, e.g. `01-1`, which is slot 0.

### Selecting a patch
1. Turn editor mode **off**. The G5 ignores program changes while it is on.
2. On channel 1, send `B0 00 00` (bank MSB), `B0 20 <bank>` (bank LSB, 0–98), then `C0 <idx>` (program change 0–2).
3. Turn editor mode back on.

### Live parameter changes (`31`)
- `unit` 0–8 is an effect slot:
  - `prm 0` on/off
  - `prm 1` effect type
  - `prm 2…` knobs, in the order listed in the catalog
- `unit 9` holds the patch settings: `prm 2` patch level, `prm 3` control-switch assignment.
- The value is 14-bit, sent as `lo` (bits 0–6) and `hi` (bits 7–13).

### Auto-save
The G5 writes edit-buffer changes into the **active** slot by itself about 5 seconds after the last change. That's why the editor always switches the pedal to the patch being edited.

## 7-bit packing
Raw data is split into groups of up to 7 bytes. Each group is sent as one high-bit byte followed by the 7 data bytes with their top bit cleared. Bit 6 of the high-bit byte belongs to the **first** data byte:

```
data[j] |= ((hi >> (6 - j)) & 1) << 7     // j = 0…6
```

So 138 bytes pack to 158.

## Checksum
- It is a CRC-32: polynomial `0xEDB88320`, initial value `0xFFFFFFFF`, **no final XOR**.
- It is computed over the 138 *unpacked* bytes.
- It is sent as five 7-bit chunks, least significant first.
- This was checked against all 297 factory patches.

## Patch layout (138 bytes)

Bits are numbered LSB-first within each byte (bit `n` = byte `n/8`, bit `n%8`).

### Effect units
Bytes 0–107 hold 9 effect units of 12 bytes (96 bits) each. The order of the blocks is the order of the signal chain.

| Bits in unit | Width | Field |
|---|---|---|
| 0 | 1 | On/off |
| 1–8 | 8 | Effect type ID (Zoom's `EfxNoOnMachine`) |
| 9 | 13 | Parameter 2 |
| 22 | 11 | Parameter 3 |
| 35 | 11 | Parameter 4 |
| 48, 56, 64, 72, 80 | 8 each | Parameters 5–9 |

Bits 33–34, 46–47 and 88–95 have always been 0.

### Patch settings

| Bits / bytes | Field |
|---|---|
| bit 864, 7 bits | Patch level (0–120) |
| bits 871–874 | Control-switch assignment: 0 off, 1–9 unit 1–9, 10 tap tempo, 11 bypass/mute |
| bits 878–885, 946–953, bytes 124–126 | Unknown. The app keeps them as they are. |
| bytes 127–136 | Name, 10 ASCII characters padded with spaces |

### Rules the pedal enforces
- Each patch has exactly one **Z-Pedal slot**: the unit holding a Z-Pedal effect or ZP-None (165).
  That unit only accepts Z-Pedal types; any other type turns it into ZP-None. A Z-Pedal type (incl. ZP-None) sent to
  any other unit is refused and that unit becomes type 107 (empty), losing its previous effect. (Verified on firmware 1.20.)
- If the DSP is full, the pedal refuses a type change; the edit buffer still holds the old type afterwards.

## Effect catalog
- `tools/make_catalog.py` builds `effects.json` from the old Edit&Share resources: `Module.xml` and the `.zrc` files.
- Amp cabinet text and short descriptions are added from the operation manual.
- There are 147 effect types, including 22 amps and 21 Z-Pedal effects. Each of the 9 units accepts any non-Z-Pedal type, except the Z-Pedal slot (see above).
- No DSP limit was hit over MIDI: 8 of the heaviest amps plus a Z-Pedal effect, all enabled, were accepted with normal sound and no "DSP FULL" (2026-11-21).
- **Displayed value** = raw value + `offset`. For choice parameters, `choices[raw]` is the label.
- **Tempo sync:** a raw value ≥ `syncFrom` means a note value instead of a time or rate. The note names are *unverified* on the G5.
