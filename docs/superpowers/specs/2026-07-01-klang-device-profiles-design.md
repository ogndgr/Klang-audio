# Klang — Output Device Selection + Named EQ Profiles

**Date:** 2026-07-01
**Status:** Approved (design), pending implementation plan

## Problem

Klang routes all system audio through the beyerdynamic Headphone Lab AudioUnit and
out to a physical output device. Today the physical output is **auto-selected**
(`AppController.activate` takes the current default output, falling back to
`DeviceMatcher.physicalOutput` — the first non-virtual output — when the default is
BlackHole). There is no UI to choose the target device, and the EQ state is a single
global snapshot (`headphonelab.fullstate.plist`).

A user with an external sound card (USB audio interface / DAC) cannot reliably target
it, and cannot keep different EQ settings for different outputs (e.g. DT 990 correction
on the interface, flat on studio monitors).

## Goals

1. Let the user pick the output device Klang routes to, from the menu-bar menu.
2. Support **named EQ profiles** (snapshots of the Headphone Lab AU state).
3. **Assign** a profile per output device; selecting a device loads its profile.

## Non-goals (YAGNI)

- Profile import/export or sharing.
- Automatic device switching (auto-target the interface when plugged in).
- Any change to the audio DSP itself — Klang still hosts whatever the Headphone Lab
  plugin is configured to; a "profile" is just a saved snapshot of that plugin's state.

## Conceptual model

- **Output device** — the physical destination (Scarlett, Built-in Output, AirPods…).
  Chosen by the user, persisted as `outputUID`. When unset, current behavior (default
  output / first physical output) remains the fallback.
- **Profile** — a Headphone Lab AU `ClassInfo` snapshot plus a name (DT 990, Flat,
  Studio monitors…).
- **Assignment** — `deviceUID → profileID`, keyed on the **resolved active output
  device UID** (the device actually in use, which equals `outputUID` when set or the
  fallback device's UID otherwise). Selecting a device loads its assigned profile into
  the live AU.

Key property: **profile switching is cheap** (write `ClassInfo` to the live AU,
instant A/B, no chain rebuild). **Device switching is expensive** (rebuild the
aggregate with the new output as clock master).

## UI surface — in-menu submenus

Chosen over a preferences window to stay true to the minimalist menu-bar design and
minimize new code/state.

```
 Klang ▾
 ├ ● Active — turn off
 │   Bypass
 ├──────────────────────────────
 │ Output Device        ▸   →  ✓ Scarlett 2i2 / Built-in Output / AirPods Pro …
 │ Profile              ▸   →  ✓ DT 990 Pro X / Flat / Studio monitors
 │                             ──────────
 │                             New from current… / Rename… / Delete
 ├──────────────────────────────
 │ Open beyerdynamic Lab…
 │ Open at Login        ✓
 ├──────────────────────────────
 │ Scarlett 2i2 · DT 990   (statusText — active device · active profile)
 │ Quit                 ⌘Q
```

- **Output Device** submenu — lists selectable outputs; checkmark on the active target.
  Enabled always (offline selection persists for next activation).
- **Profile** submenu — lists profiles (checkmark on the one assigned to the current
  device) plus `New from current…`, `Rename…`, `Delete`. Enabled **only while active**,
  mirroring "Open beyerdynamic Lab…", because profile create/edit needs the live AU.
- `New from current…`, `Rename…` use `NSAlert` with an accessory text field.

## Data model

### `Prefs.swift` (backward-compatible decode required)

```swift
public struct Prefs: Codable, Equatable {
    public var autoStart: Bool
    public var bufferFrames: Int
    public var outputUID: String?              // now the user-selected target
    public var inputUID: String?
    public var deviceProfiles: [String: String] // deviceUID -> profileID  (new, default [:])
}
```

Swift's synthesized `Codable` does **not** fill defaults for missing keys, so an old
`prefs.json` without `deviceProfiles` would fail to decode. Add a custom
`init(from:)` that uses `decodeIfPresent(...) ?? default` for every field so old prefs
upgrade in place rather than resetting to `.defaults`.

### `ProfileStore.swift` (new, in KlangCore — unit-testable)

```swift
public struct Profile: Codable, Equatable {
    public let id: String     // UUID().uuidString
    public var name: String
}
```

- Index persisted to `Application Support/Klang/profiles.json` as `[Profile]`.
- Each profile's AU state at `Application Support/Klang/profiles/<id>.plist`.
- API: `list() / create(name:) -> Profile / rename(id:to:) / delete(id:) / stateURL(id:)`.
- `ProfileStore` takes the support dir (or `home`) via init for testability; no
  singletons.

### `AppPaths.swift`

Add `profilesIndexURL(home:)` and `profileStateURL(home:id:)`. Keep `fullStateURL`
for migration only.

## Routing changes (`AppController`)

- `activate`: resolve target as
  1. `prefs.outputUID` if that device currently exists, else
  2. current behavior (default output, or `physicalOutput` when default is BlackHole).
- `setOutputDevice(_ uid: String)`: persist `prefs.outputUID`; if active, fully
  `deactivate()` then `activate(...)` targeting the new device. Sequence so the
  intermediate default-output writes never false-trigger the safety guard (guard is
  already gated on `isActive`, which is false between stop and start).

## Profile binding (`AudioChain` + `AppController`)

- `AudioChain.loadState` / `saveState` take an **explicit URL** instead of the hardcoded
  `fullStateURL`.
- On `activate`: with the resolved active device UID, look up `deviceProfiles[uid]` →
  profile (or the migrated "Default" when unassigned), load its plist into the AU after
  `AudioUnitInitialize`.
- Selecting a profile in the submenu while active: write that profile's `ClassInfo` to
  the live AU — instant, no rebuild. Update `deviceProfiles[currentDeviceUID]` and
  persist.
- Saving (Lab window closes / `saveStateNow` / quit): write the live AU `ClassInfo` to
  the **currently active profile's** URL.
- `New from current…`: snapshot the live AU into a new profile file, add to index,
  assign to the current device.
- `Delete`: remove profile file + index entry; any device pointing at it falls back to
  "Default".

## Safety guard interaction

- Active target device unplugged → `outputUID` device disappears →
  `observeDeviceChanges` already calls `deactivate()`. Add a menu refresh so the device
  list updates.
- Default output changing away from BlackHole still triggers the feedback/DAW guard —
  **unchanged**.
- Device swap performs deactivate→activate in order; the guard stays gated on
  `isActive`, so mid-swap default-output writes do not fire it.

## Migration

On first launch after the update: if `headphonelab.fullstate.plist` exists and
`profiles.json` does not, create a **"Default"** profile from it. Devices remain
unassigned and use "Default". Non-destructive (old file left in place).

## `statusText`

Replace the hardcoded `"BlackHole → DT 990 Pro X"` with the active device name · active
profile name (e.g. `"Scarlett 2i2 · DT 990 Pro X"`).

## Tests (KlangCore)

- `ProfileStore`: create/list/rename/delete + persistence round-trip.
- Migration: old `fullstate` present + no index → a "Default" profile is produced.
- `Prefs`: `deviceProfiles` round-trip; **old JSON without `deviceProfiles` decodes**
  with the field defaulting to `[:]` and other fields preserved.
- `DeviceMatcher.selectableOutputs(in:)`: returns physical, non-virtual, non-BlackHole
  outputs for the picker.

Real-time audio path (device swap, live profile load) verified manually, consistent
with the existing testing approach.

## Files touched

- `Sources/KlangCore/Prefs.swift` — new field + custom decode.
- `Sources/KlangCore/ProfileStore.swift` — **new**.
- `Sources/KlangCore/AppPaths.swift` — profile paths.
- `Sources/KlangCore/DeviceMatcher.swift` — `selectableOutputs`.
- `Sources/Klang/AppController.swift` — target resolution, `setOutputDevice`, profile
  resolve/load/save, migration.
- `Sources/Klang/AudioChain.swift` — `loadState`/`saveState` take a URL.
- `Sources/Klang/StatusItemController.swift` — device + profile submenus, dialogs,
  `statusText` wiring.
- `Tests/KlangCoreTests/` — ProfileStore, Prefs backward-compat, migration, matcher.
