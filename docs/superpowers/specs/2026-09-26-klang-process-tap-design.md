# Klang — Replace BlackHole with a Core Audio Process Tap

**Date:** 2026-09-26
**Status:** Approved (design validated by spike), implementing

## Problem

Klang captures system audio by switching the default output to BlackHole and reading
BlackHole's input through a duplex AUHAL on a private aggregate. This has four costs:

1. **Third-party driver** — users must install BlackHole.
2. **Orange microphone indicator + mic permission** — opening any input device counts
   as microphone use.
3. **Hijacked default output** — any external default-output change (AirPods connect,
   monitor plugged in, sleep/wake) had to shut Klang down, and a crash left the system
   stranded on a silent BlackHole default (hence `CrashRecovery`).
4. **False "feedback" shutdowns** — the output-RMS guard (> 0.6 for 0.4 s) trips on
   loud masters with a bass-boosting correction. The spike measured corrected output
   at 0.67 RMS on ordinary music.

## Design

```
all processes except Klang ──► global process tap (stereo, mutedWhenTapped, private)
                                        │
             private aggregate: main sub-device = target output, tap list = [tap]
                                        │  (tap drift-compensated to the output clock)
                   device IOProc: tap stream → Headphone Lab AU → output stream
```

- `CATapDescription(stereoGlobalTapButExcludeProcesses: [klangProcessObject])`,
  `muteBehavior = .mutedWhenTapped`, `isPrivate = true`. Tapped processes are muted on
  their direct path, so the listener hears only the corrected signal. Klang excludes
  itself, so a feedback loop is structurally impossible.
- The aggregate holds the target output as its only sub-device plus the tap
  (`kAudioAggregateDeviceTapListKey`, drift compensation on, `tapautostart`).
- **No AUHAL.** Enabling AUHAL input triggers a microphone TCC check (verified in the
  spike: `kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input`),
  which zeroes the input. A plain `AudioDeviceCreateIOProcIDWithBlock` on the aggregate
  only needs **System Audio Recording** permission (`NSAudioCaptureUsageDescription`).
- `kAudioDevicePropertyIOProcStreamUsage` disables every aggregate input stream except
  the tap (the last input stream), so a target with its own inputs (USB interface)
  never has its hardware inputs opened.
- The effect runs at the aggregate's nominal rate; Klang no longer forces a sample rate
  on the device.
- The **default output is never touched.**

## Behavior changes

| Situation | Before | After |
|---|---|---|
| Default output changes, target = Automatic | Shut down + DAW alert | Rebuild on the new default |
| Default output changes, explicit target | Shut down + DAW alert | Keep running on the chosen device |
| Target device disappears | Deactivate | Deactivate (unchanged) |
| Klang crashes | Default stranded on BlackHole | Tap dies with the process; audio plays uncorrected |
| Loud music | Possible false "feedback" shutdown | No RMS guard (no loop is possible) |
| Indicator | Orange mic dot | Purple system-audio-recording dot |

## Removed

BlackHole matching, default-output switching, `CrashRecovery`, `SampleRateNegotiator`,
the feedback guard and safety alert, `PermissionManager` (mic), `Prefs.inputUID`,
`AudioDeviceInfo.inputChannels`, the mic entitlement, and the BlackHole-only debug
modes (`--restore`, `--diag-grab`, `--diag-safety`).

## Requirements

macOS 14.2+ (`AudioHardwareCreateProcessTap`). If System Audio Recording is denied the
tap delivers silence; there is no public preflight API, so the README documents where
to enable it.

## Testing

Pure logic in KlangCore is unit-tested: aggregate spec and output target resolution
(including the "follow the default" rule). The realtime path is verified manually,
the same way the spike was: the log shows tap RMS and corrected output RMS, and the
default output stays unchanged.
