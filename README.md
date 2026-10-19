# Quiet

On-device noise reduction and voice isolation for your Mac microphone, without the meeting-notes,
transcription, recording, accounts or telemetry that ship with Krisp.

Quiet is a 21 MB menu-bar app (Krisp 3.17.6 is roughly 500 MB). It uses no Krisp code or models.

## What Krisp does, roughly

Before writing this I looked at how Krisp's Mac app is put together, from its public file layout, its plaintext
configuration and the libraries it links. No Krisp code, models or decrypted data are in this repo, and the
encrypted models were left encrypted. The design-level picture:

- **Noise cancellation** is a DeepFilterNet-family model (the open-source architecture from Rikorose/DeepFilterNet)
  run in ONNX Runtime, in short frames at a fixed sample rate. The weights are proprietary and encrypted.
- **Voice isolation** ("background voice cancellation") is a separate, proprietary recurrent mask network with a
  small classifier head, followed by a level gate that mutes speech sitting well below the primary talker. It is
  only enabled on headsets and known close mics, because the approach depends on the user being much closer to the
  mic than anyone else in the room.
- **Other apps get the clean audio** through a Core Audio HAL plug-in that exposes a visible "microphone" device and
  a hidden device the app writes into. Zoom, Meet and friends read from the visible one.
- **Echo cancellation** is a WebRTC-style AEC in a native library.
- **Most of the app's size** comes from models that only serve the note-taker, transcription and recording features:
  speaker diarization, speech recognition, PII redaction, accent conversion and text normalisation.

## How Quiet does it

```
mic ──AUHAL──▶ ring ──▶ DSP thread: resample→48 kHz ▶ DeepFilterNet3 ▶ voice gate ──▶ ring ──AUHAL──▶ BlackHole 2ch
                                                                                         (Zoom/Meet: "BlackHole 2ch" as mic)
```

- **Noise reduction:** DeepFilterNet3, the open-source model family Krisp's NC models are built on
  (MIT/Apache-2.0), compiled into a Rust static lib with the tract runtime and the model embedded (`dfcore/`).
  It runs at 48 kHz with 10 ms hops and about 30 ms of algorithmic delay.
- **Voice isolation:** a level gate after the denoiser, modelled on the gate stage described above. It
  tracks the primary talker and ducks speech that stays more than N dB below them (hysteresis plus a hold
  time). This is a heuristic, not Krisp's trained GRU model. Like Krisp's BVC, it needs a headset or close mic.
- **Virtual mic:** BlackHole takes the place of Krisp's HAL driver, so no kernel or HAL code needs installing.
- **Real-time safety:** the IO callbacks only touch lock-free SPSC rings (`Sources/CRing`). The model runs
  on its own thread, and a jitter buffer keeps about 20 ms queued and trims any clock drift.

## Measured results

`python3 -I eval/make_and_score.py eval/audio .build/release/quiet-cli` (macOS `say` speech plus synthetic noise,
scored against the clean reference with SI-SDR):

| Scene | SI-SDR in | SI-SDR out | Gain |
|---|---|---|---|
| White noise, 5 dB SNR | 4.7 | 17.7 | **+13.0 dB** |
| Pink noise, 0 dB | −0.3 | 8.5 | +8.8 dB |
| Fan and mains hum, 0 dB | −0.3 | 8.8 | +9.2 dB |
| Café babble, 5 dB | 4.7 | 8.0 | +3.3 dB |
| Keyboard clicks, 5 dB | 4.7 | 6.9 | +2.3 dB |
| Clean speech (distortion check) | ∞ | 31.7 | – |

- Speed: 0.1 to 0.3 ms of compute per 10 ms frame on Apple Silicon (RTF 0.01 to 0.03).
- Live, through CoreAudio: about 0.5 ms per frame, 0 underruns, about 45 ms queued plus 30 ms model delay.

Voice isolation, with a second talker 14 dB quieter than the primary (levels relative to noise reduction alone),
plus how much of a real single talker's own speech it cuts (a 45 s Yeti recording with normal, soft, loud and
back-to-normal speech):

| Strength | Background-only speech | Primary speech | Real talker's speech cut >6 dB |
|---|---|---|---|
| **0.75 (default)** | **−1.3 dB** | 0.0 dB | 0.0% |
| 0.9 | −4.4 dB | 0.0 dB | 1.8% |

The earlier gate scored −5.6 dB on the synthetic test, but it cut 59% of the real talker's speech: it locked onto
their loudest syllables, so normal and soft speech looked like a background voice. The synthetic voices are
text-to-speech at a constant level, which hid this. A level gate can't tell a quieter second person from the
primary speaking softly. On the real recording, every 1 dB of background suppression cost about 3% of the primary's
words, so the gate now favours never cutting the primary. Leave voice isolation off unless someone else is talking
in the room.

DeepFilterNet on its own removes only about 3.7 dB of a background voice. It treats any speech as signal,
which is exactly why Krisp ships a separate BVC model.

## Build and use

Needs macOS 14+, Xcode (for `swift` and `xcodebuild`) and a Rust toolchain (`rustup`). The first
build compiles DeepFilterNet and downloads its model via cargo, which takes a few minutes.

```bash
git clone --recurse-submodules https://github.com/pxue/quiet && cd quiet
driver/build_driver.sh          # → driver/build/Quiet.driver
driver/install_driver.sh        # sudo; restarts Core Audio (~2 s of silence)
./build_app.sh                  # → dist/Quiet.app
open dist/Quiet.app
```

1. Click the menu-bar icon, pick your mic and switch Quiet on.
2. In your podcast or call app (Riverside, Zoom, OBS, Meet and so on), choose **Quiet Microphone** as the microphone.

### The virtual mic driver

`Quiet.driver` is BlackHole v0.6.1 (GPL-3.0, `driver/BlackHole`) rebuilt with compile-time flags into two devices that
share one loopback buffer:

| Device | Visible | Direction | Used by |
|---|---|---|---|
| Quiet Microphone | yes | input only | your podcast or call app |
| Quiet Output (UID `Quiet_2_UID`) | hidden | output only | Quiet.app only |

This is the same visible-input / hidden-output pattern as Krisp's driver. Because the output is hidden and
can't be the system output, Mac sounds can't leak into the mic.

- **No driver?** The app falls back to any BlackHole device.
- **Uninstall:** `driver/uninstall_driver.sh`.
- **Licensing:** if you distribute the driver, the GPL requires you to ship its source. Quiet.app only talks to it
  through Core Audio.

CLI: `quiet-cli in.wav out.wav [--atten DB] [--isolate] [--strength 0..1]` processes a file, and
`quiet-cli --live 10 [--input NAME]` runs the live path and prints stats.

### Eval

```bash
eval/make_voices.sh                                               # synthetic primary + background talker
python3 -I eval/make_and_score.py eval/audio .build/release/quiet-cli   # noise scenes + background-talker test
python3 -I eval/dog_test.py eval/audio .build/release/quiet-cli         # real dog barks (eval/audio/dog)
```

Needs `numpy`. Drop a real recording of yourself in as `eval/audio/primary.wav` (48 kHz mono) for a more
honest voice-isolation number.

## Making it your own

Everything tunable (default settings, gate behaviour, the virtual mic's name, bundle IDs, latency budget)
is listed in [CLAUDE.md](CLAUDE.md), written so you can hand the repo to Claude Code or another coding
agent and say what you want changed. It works as a human map of the code too.

## Not included (vs. Krisp)

Krisp has three things Quiet does not:

- a trained background-voice model;
- inbound (speaker-side) cleanup;
- echo cancellation.

## License

Quiet's own code (`Sources/`, `dfcore/`, `eval/`, scripts) is MIT. DeepFilterNet is MIT/Apache-2.0.
`driver/BlackHole` is a submodule of [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0);
`Quiet.driver` is a build of it and stays GPL, so ship its source if you redistribute the driver.
