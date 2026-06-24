# Klang

System-wide **beyerdynamic Headphone Lab** correction for the DT 990 Pro X on macOS.
A tiny menu-bar app: it routes all system audio through the Headphone Lab Audio Unit
(flat correction) and out to your headphones, at 96 kHz.

## Requirements

- macOS 14+ (developed on 26.5.1, Apple Silicon)
- [BlackHole 2ch](https://existential.audio/blackhole/) installed
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

- **Turn on** — start the correction. Grant the microphone prompt on first run (required
  to read an input device; your real mic is never recorded). All system audio is now
  EQ'd on your headphones.
- **Bypass** — toggle the correction for A/B comparison.
- **Open beyerdynamic Lab…** — open the plugin to change headphone model.
- **Open at Login** — register Klang as a login item.
- **Quit** — restore normal audio and quit.

## How it works

```
system audio → (default output = BlackHole) → BlackHole 2ch ─┐
                                                              │ private aggregate
                          DT 990 Pro X (headphones) ──────────┘ (headphones = master clock,
                                                                  BlackHole drift-compensated)
        ▲
        │ one HALOutput AudioUnit, duplex on the aggregate
        └── input(BlackHole) → Headphone Lab AU (manual render) → output(headphones)
```

A single CoreAudio HALOutput unit captures BlackHole and renders the Headphone Lab
effect into the headphone output, all in one clock domain (the aggregate), so there
is no ring buffer and no drift. AVAudioEngine is intentionally *not* used: on macOS
it cannot point its input node at an arbitrary capture device without hijacking the
system default input.

## Developer / debug flags

```bash
swift run Klang --list-devices     # list audio devices + matcher picks
swift run Klang --test-aggregate   # create/destroy the private aggregate
swift run Klang --test-halsetup    # configure + initialize the chain (no audio)
swift run Klang --run-headless     # run the chain from the terminal (Ctrl-C to stop)
swift run Klang --restore          # force default output back to the headphones
```

## Tests

```bash
swift test
```

Pure logic (device matching, sample-rate negotiation, aggregate spec, prefs, crash
recovery, paths) is unit-tested; the real-time audio path is verified manually.

## Troubleshooting

- **No sound after a crash / stuck on BlackHole:** `swift run Klang --restore`, or
  relaunch the app (it detects a stranded BlackHole default output and restores the
  headphones on launch).
- **AU won't load:** the app must be signed with the
  `com.apple.security.cs.disable-library-validation` entitlement — `Scripts/bundle.sh`
  does this.
- **Glitches/crackle:** the chain runs at a 4096-frame max slice; if you hear dropouts,
  reduce other CPU load or report it.

## State

App state lives in `~/Library/Application Support/Klang/`
(`prefs.json`, `headphonelab.fullstate.plist`).

## License

MIT — see [LICENSE](LICENSE).
