# Klang — Design Spec

**Date:** 2026-06-24
**Status:** Draft (awaiting review)
**Author:** Ogün Doğru (with Claude)

## 1. Goal

Klang is a minimal macOS menu-bar app that applies the **beyerdynamic Headphone Lab**
correction (flat target for the DT 990 PRO X) to **all system audio**, not just inside a DAW.

It hosts the Headphone Lab Audio Unit headlessly in a tiny background process and bridges
system audio (captured via BlackHole) through the plugin to the physical headphone output.
One menu-bar toggle turns the whole chain on/off; a second menu item opens the plugin's own
UI for changing headphone model.

## 2. Context & Constraints (verified on this machine)

| Item | Value |
|---|---|
| OS | macOS 26.5.1 (Tahoe), arm64 (Apple Silicon) |
| Virtual device | BlackHole 2ch v0.7.0 (already installed) |
| Plugin | beyerdynamic Headphone Lab v1.1.0 — AU effect (`aufx` / mfr `Beyd` / sub `BdHL`), JUCE-based |
| Plugin config | Selected headphone stored globally in `~/Library/Application Support/Beyerdynamic/HEADPHONE LAB.cfg` (`LastHeadphone = 1001629:DT 990 PRO X`) → loads automatically when instantiated headless |
| Physical output | Built-in headphone jack ("Harici Kulaklık"), DT 990 Pro X plugged in |
| Sample rate | **96 kHz** target (headphones run native 96k; no resample). Fallback: highest rate both devices share |

## 3. Architecture

### Signal flow

```
All system audio
   │  (system default output = BlackHole — Klang sets this on activate)
   ▼
BlackHole 2ch (input) ──┐
                        │  Private Aggregate Device
Headphones (output) ────┘  master clock = headphones, drift comp on BlackHole
   ▲
   │  AVAudioEngine runs duplex on the aggregate (single IO callback)
   │
   inputNode (BlackHole 2ch) → [Headphone Lab AU] → mainMixerNode → outputNode (headphones)
```

### Why an aggregate device

BlackHole and the headphone output are independent CoreAudio clocks. Combining them into one
**private aggregate device** (headphones as master, drift compensation on BlackHole) gives a
single shared timeline, so one AVAudioEngine IO callback both reads input and writes output —
CoreAudio handles drift. This is the smallest robust design. (Rejected alternatives:
user-made aggregate in Audio MIDI Setup = fragile; two AUHALs + ring buffer = more code, manual
drift handling. The ring-buffer approach is kept only as a documented fallback if AVAudioEngine
duplex on an aggregate proves unreliable.)

## 4. Components

Six small, independently-testable modules (each target < 200 lines).

| Module | Responsibility | Key surface | Depends on |
|---|---|---|---|
| `DeviceManager` | Find devices by UID/name; get/set nominal sample rate; get/set system default output; device hotplug listener | `device(uid:) -> AudioDeviceID?`, `setSampleRate(_:on:)`, `defaultOutput get/set`, `onDevicesChanged(_:)` | CoreAudio |
| `AggregateDevice` | Build/create/destroy the private aggregate | `makeDescription(output:input:) -> CFDictionary` (pure), `create() -> AudioDeviceID`, `destroy()` | CoreAudio, DeviceManager |
| `AudioChain` | Own AVAudioEngine; instantiate Headphone Lab AU; wire input→effect→mixer→output; start/stop; bypass; fullState save/load | `start(on:) throws`, `stop()`, `bypass: Bool`, `loadState()/saveState()` | AVFoundation, AudioToolbox |
| `PluginWindowController` | Host the AU's Cocoa view in an NSWindow | `show(for: AUAudioUnit)` | AppKit |
| `Persistence` | Read/write prefs + AU fullState to `~/Library/Application Support/Klang/` | `prefs get/set`, `fullState get/set` | Foundation |
| `AppDelegate` + `StatusItemController` | NSStatusItem menu, wire toggles, login item (SMAppService), permission requests, error UI, crash-recovery check | menu actions | AppKit, ServiceManagement |

### Headphone Lab discovery

```swift
let acd = AudioComponentDescription(
  componentType:         kAudioUnitType_Effect, // 'aufx'
  componentSubType:      0x4264484C,            // 'BdHL'
  componentManufacturer: 0x42657964,            // 'Beyd'
  componentFlags: 0, componentFlagsMask: 0)
AVAudioUnit.instantiate(with: acd, options: []) { unit, _ in /* attach to engine */ }
```
The plugin reads `DT 990 PRO X` from its global cfg on init. We additionally persist/restore
`auAudioUnit.fullState` so any in-plugin parameter (target curve, gain, bypass) survives restarts.

### AVAudioEngine device binding (chosen mechanism)

Bind the engine to the aggregate before start:
```swift
var dev = aggregateID
AudioUnitSetProperty(engine.outputNode.audioUnit!,
  kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
  &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
```
Then `engine.attach(effect)`, connect `inputNode → effect → mainMixerNode` with a 2ch float 96k
format. *Implementation must verify inputNode exposes BlackHole's 2 channels on the aggregate;
if AVAudioEngine misbehaves, fall back to the two-AUHAL + CARingBuffer path (see §10).*

## 5. Behavior

### Activate ("Aç")
1. Read current system default output. If it is BlackHole (leftover state), use `prefs.outputUID`
   or the first physical (non-virtual) output; else **target output = current default output**.
2. Save target UID → `prefs.outputUID` ("whatever you were listening on becomes the EQ target").
3. Locate BlackHole (input).
4. Set both devices to 96 kHz (fallback: highest common supported rate).
5. Create the private aggregate (master = target output, BlackHole sub-device with drift comp).
6. Point AVAudioEngine at the aggregate, build the chain, load fullState, `start()`.
7. Set system default output = BlackHole.
8. Menu icon → active.

### Deactivate ("Kapa")
1. Set system default output = `prefs.outputUID` (headphones) — normal audio resumes.
2. `engine.stop()`, destroy the aggregate.
3. Menu icon → inactive.

### Quit
Run Deactivate, unregister observers, terminate. (Default output is always restored.)

### Crash recovery (on launch)
If system default output == BlackHole **and** the engine is not running → restore default output
to `prefs.outputUID` (or first physical output). Prevents "silent Mac" if a previous run crashed
while active.

### Bypass
Toggles `effect.bypass` in place (engine keeps running) for instant A/B of corrected vs raw.

### Plugin UI
Menu → "beyerdynamic Lab'i aç" → `auAudioUnit.requestViewController { vc in … }` hosted in an
NSWindow. On window close, `saveState()`.

### Auto-start
Menu toggle "Açılışta başlat" → `SMAppService.mainApp.register()/.unregister()`. Optional;
default off.

### Device selection
Auto-detected (input = BlackHole; output = default-at-activation). An "Cihazlar ▸" submenu lets
the user override input/output from the live device list if auto-detect is wrong. Chosen UIDs
persist in prefs.

## 6. Menu layout

```
[icon: filled = active / outline = inactive]
  ●  Aktif                         (toggle activate/deactivate)
     Bypass                        (A/B; only enabled when active)
     ───────────────
     beyerdynamic Lab'i aç…
     Cihazlar ▸                    (input/output override, auto by default)
     Açılışta başlat   ✓
     ───────────────
     BlackHole → DT 990 Pro X · 96kHz · ok    (status line)
     Çıkış
```

## 7. Permissions, entitlements, packaging

| Concern | Decision |
|---|---|
| Microphone (TCC) | Reading any input device triggers macOS mic permission. Add `NSMicrophoneUsageDescription`; call `AVCaptureDevice.requestAccess(for: .audio)` before first input use. |
| Library validation | Headphone Lab is AUv2 (in-process), signed by beyerdynamic (different team). Hardened runtime ON + entitlement `com.apple.security.cs.disable-library-validation = true`. |
| Sandbox | **Off.** Aggregate-device creation and default-output switching are not sandbox-friendly. Acceptable for a personal tool. |
| App type | `LSUIElement = true` (menu-bar only, no Dock icon). |
| Signing | Development cert, hardened runtime. Local/personal distribution. |
| Deployment target | macOS 14.0+ (uses `SMAppService`, AU view APIs); developed/tested on 26.5.1. |

## 8. Persistence

Location: `~/Library/Application Support/Klang/`
- `prefs.json` — `{ autoStart: Bool, activateOnLaunch: Bool, bufferFrames: Int, outputUID: String?, inputUID: String? }`
- `headphonelab.fullstate.plist` — serialized AU `fullState`.

## 9. Resource budget

- Audio thread: one JUCE EQ pass per buffer @96k → ~2–5% of one core worst case, typically lower.
- RAM: tens of MB (framework + AU).
- No UI redraw while the menu is closed.
- Buffer size default 256 frames (≈2.7 ms @96k) — configurable; raise to 512 if glitching.

## 10. Risks & fallbacks

| Risk | Mitigation |
|---|---|
| AVAudioEngine duplex on aggregate exposes no/zero input channels | Fall back to two AUHAL units + `CARingBuffer`, rendering the effect via `AudioUnitRender` (CAPlayThrough pattern). Same DSP, more code. |
| Crash leaves default output on BlackHole (silent Mac) | Crash-recovery check on launch (§5) + restore on quit. |
| Headphone unplugged mid-session | Hotplug listener: stop engine, do not switch default to BlackHole; auto-rebuild when it returns. |
| Device rejects 96k | Negotiate highest common rate; never hard-fail on 96k. |
| Plugin fails to instantiate | Alert with the OSStatus, stay inactive, do not switch default output. |

## 11. Testing

- **Unit (pure logic, ~80% of testable surface):** UID/name lookup, aggregate `makeDescription`
  dictionary builder, sample-rate negotiation, prefs/fullState (de)serialization, crash-recovery
  decision function.
- **Manual / integration (audio path):** play pink noise, toggle Bypass, confirm the EQ curve is
  applied (by ear + a loopback measurement). Real-time IO is not unit-testable.
- Coverage stance: pure helpers meet the 80% bar; the CoreAudio IO glue is verified manually
  (MVP 60% project threshold respected).

## 12. Out of scope (YAGNI / future)

- Multiple headphone profiles with quick-switch (use the plugin UI for now).
- Per-app EQ.
- macOS 14.4+ Core Audio **process taps** (no-BlackHole capture) — possible v2 to drop the
  BlackHole dependency.
- Notarization / public distribution.
- Custom EQ beyond the beyerdynamic correction.

## 13. Build & project

- Xcode project (Swift, AppKit menu-bar app), located at `~/apps/Klang/`.
- Git repo initialized on `main`.
- Module files organized by responsibility (§4), feature-grouped.
