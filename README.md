# Klang

System-wide **beyerdynamic Headphone Lab** correction for the DT 990 Pro X on macOS.
A tiny menu-bar app: it taps all system audio with a Core Audio process tap, runs it
through the Headphone Lab Audio Unit (flat correction) and out to your headphones.
No virtual audio driver, no microphone permission, and your default output is never
changed.

## Requirements

- macOS 14.2+ (Core Audio process taps; developed on Apple Silicon)
- beyerdynamic Headphone Lab (the AU plugin), with your headphone model selected
  once in its UI (Klang reuses that selection automatically)

## Build & install

```bash
./Scripts/bundle.sh
cp -R Klang.app /Applications/
open /Applications/Klang.app
```

## Use

Click the menu-bar waveform icon:

- **Turn on** — start the correction. On first run, allow **System Audio Recording**
  (Klang needs it to read what other apps play; nothing is recorded or stored). All
  system audio is now EQ'd on your headphones. While Klang is on, macOS shows the purple
  system-audio-recording dot in the menu bar.
- **Bypass** — toggle the correction for A/B comparison.
- **Output Device** — *Automatic* follows the system default output (switching to
  AirPods or a DAC moves the correction there); picking a device pins Klang to it.
- **Profile** — named Headphone Lab snapshots, remembered per output device.
- **Open beyerdynamic Lab…** — open the plugin to change headphone model.
- **Open at Login** — register Klang as a login item.
- **Quit** — restore normal audio and quit.

## How it works

```
every app except Klang ──► process tap (stereo, private, originals muted while tapped)
                                   │
        private aggregate: target output (clock) + tap (drift-compensated)
                                   │
          device IOProc: tap → Headphone Lab AU (manual render) → output ch 1/2
```

- A global stereo **process tap** captures every process except Klang itself and mutes
  their direct path, so you hear only the corrected signal. Because Klang is excluded,
  a feedback loop is impossible.
- The tap and the target output share one clock inside a private aggregate device, so
  there is no ring buffer; the tap is drift-compensated to the output.
- The chain runs on a plain device IOProc, not an AUHAL: enabling AUHAL input triggers a
  microphone permission check, which the tap does not need. Only the tap stream and the
  streams carrying output channels 1/2 are opened, so an interface with its own inputs
  never has them opened.
- The effect runs at the output device's current sample rate. Nothing touches the
  system default output; if Klang quits or crashes, the tap disappears and audio plays
  normally (uncorrected).

## Developer / debug flags

```bash
swift run Klang --list-devices     # list audio devices + matcher picks
swift run Klang --test-aggregate   # create/destroy the tap + private aggregate
swift run Klang --test-halsetup    # configure + initialize the chain (no audio)
swift run Klang --run-headless     # run the chain from the terminal (Ctrl-C to stop)
```

## Tests

```bash
swift test
```

Pure logic (output target resolution, aggregate spec, prefs, profiles, paths) is
unit-tested; the real-time audio path is verified manually.

## Troubleshooting

- **Klang is on but everything is silent:** System Audio Recording was denied, so the
  tap delivers silence. Enable Klang under System Settings → Privacy & Security →
  Screen & System Audio Recording → *System Audio Recording Only*, then turn Klang off
  and on. (`--run-headless` needs the same permission for your terminal app.)
- **Correction sounds off after changing the sample rate in Audio MIDI Setup:** turn
  Klang off and on; the effect is set up for the rate in use when it started.
- **Using a DAW:** the DAW's output is tapped and corrected too. If the DAW already runs
  the Headphone Lab plugin, turn Klang off to avoid applying the correction twice.
- **Upgrading from a BlackHole-based version:** Klang no longer uses BlackHole. If your
  default output was left on BlackHole, pick your headphones in the Sound settings; you
  can uninstall BlackHole if nothing else needs it.
- **AU won't load:** the app must be signed with the
  `com.apple.security.cs.disable-library-validation` entitlement — `Scripts/bundle.sh`
  does this.
- **Glitches/crackle:** the chain runs at a 4096-frame max slice; if you hear dropouts,
  reduce other CPU load or report it.

## State

App state lives in `~/Library/Application Support/Klang/`
(`prefs.json`, `profiles.json`, `profiles/`).

## License

MIT — see [LICENSE](LICENSE).
