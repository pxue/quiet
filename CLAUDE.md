# Quiet: guide for coding agents (and humans)

Quiet is a macOS menu-bar app that cleans up a microphone on-device (DeepFilterNet3 noise
reduction plus a level-based voice gate) and sends the result to a virtual microphone that
call and podcast apps select. Read this before changing anything; it says where each knob
lives, how to build and verify, and what must not be broken.

## Layout

| Path | What it is |
|---|---|
| `Sources/Quiet/QuietApp.swift` | SwiftUI menu-bar UI and `AppModel` (device choice, settings, persistence in `UserDefaults`) |
| `Sources/QuietCore/LivePipeline.swift` | Real-time path: AUHAL input → ring → DSP thread → ring → AUHAL output. `Settings` and `Stats` structs live here |
| `Sources/QuietCore/FrameProcessor.swift` | One 10 ms hop: denoiser then (optional) voice gate. Shared by app and CLI |
| `Sources/QuietCore/Denoiser.swift` | Swift wrapper over the Rust C ABI (`df_new`, `df_process`, ...) |
| `Sources/QuietCore/VoiceGate.swift` | Background-voice suppressor: all gate tunables are here |
| `Sources/QuietCore/StreamResampler.swift` | Any input rate → 48 kHz |
| `Sources/QuietCore/AudioDevices.swift` | Core Audio device enumeration, loopback detection, `quietOutputUID` |
| `Sources/CRing/` | Lock-free SPSC float ring (C). Only thing the audio callbacks touch |
| `Sources/CDFCore/` | modulemap + header for the Rust static lib |
| `dfcore/` | Rust crate: DeepFilterNet3 (libDF, tract backend, model embedded at build time) exposed as a C ABI |
| `Sources/quiet-cli/main.swift` | Offline file processor and `--live` smoke test; same chain as the app |
| `driver/` | `Quiet.driver`: BlackHole (git submodule) rebuilt with compile-time flags; install/uninstall scripts |
| `build_app.sh` | cargo build → swift build → assemble `dist/Quiet.app` (Info.plist is inline in this script) |
| `eval/` | numpy scripts that build noisy mixtures, run `quiet-cli`, and score SI-SDR / background-voice level |

## Build and verify

```bash
git submodule update --init          # driver/BlackHole
./build_app.sh                        # dist/Quiet.app (also produces .build/release/quiet-cli)
swift build -c release                # Swift only, after dfcore is built once
driver/build_driver.sh && driver/install_driver.sh   # only when driver flags change; needs sudo
```

Verification that should accompany any DSP change:

```bash
eval/make_voices.sh                                                    # once
python3 -I eval/make_and_score.py eval/audio .build/release/quiet-cli  # SI-SDR per scene + background talker
.build/release/quiet-cli --live 10                                     # real mic: ms/hop, latency, underruns
```

Compare the numbers to the tables in `README.md`. A change that improves background-voice
suppression but cuts the primary talker's own speech is a regression; the README explains why.

## Knobs, by request

### "Change the default settings" (what the app starts with)
`LivePipeline.Settings` in `Sources/QuietCore/LivePipeline.swift`: `noiseReduction`,
`attenuationLimitDb` (100 = remove as much noise as the model can, lower keeps some ambience),
`isolateVoice`, `isolationStrength` (0–1). The sliders in `QuietApp.swift` (`MenuView`) bind
to these; the slider ranges are set there. Settings are not persisted across launches; the
chosen input/output device UIDs are (`UserDefaults` keys `inputUID`, `outputUID`).

### "Make voice isolation more / less aggressive"
`VoiceGate.Parameters` in `VoiceGate.swift`. `strength(_:)` maps the 0–1 slider onto
`cutStartDb` (how far below the primary talker a frame must be to close the gate),
`cutEndDb` (reopen threshold), `holdFrames` (10 ms frames of sustained low level before closing).
`floorDb` is the gain while closed (−35 dB; set to −100 for a hard mute). The private constants
(`refRise`, `refFollowDown`, `refDecayPerFrame`) control how the "primary talker" reference
level tracks; lowering `refFollowDown` or raising `refDecayPerFrame` makes it forget peaks
faster. Also the speech detector: `isSpeech = lsnr > 0 && level > -55` in `process`.
Always re-run the eval after touching these and report both the background-only dB and the
"primary speech cut" figure.

### "Keep more / less noise"
`attenuationLimitDb` default (above). It is passed straight to DeepFilterNet's `atten_lim`.

### "Rename the virtual microphone" / "change the manufacturer"
`driver/build_driver.sh`: `kDevice_Name`, `kDevice2_Name`, `kManufacturer_Name`, `kDriver_Name`,
`bundleID`. If you change the hidden output's identity, update
`AudioDevices.quietOutputUID` (`"Quiet_2_UID"`, derived from BlackHole's
`kDriver_Name + "_" + index + "_UID"` pattern) and the display name in
`AudioDevices.virtualMicTargets()`. Rebuild and reinstall the driver.

### "Rename the app" / "change the bundle ID or version"
`build_app.sh` (Info.plist heredoc: `CFBundleIdentifier`, `CFBundleName`, version strings,
`NSMicrophoneUsageDescription`) and the target names in `Package.swift`. The menu-bar icons are
SF Symbols in `QuietApp.swift` (`waveform.badge.mic` / `mic.slash`).

### "Lower latency" / "fix dropouts"
`LivePipeline.swift`: `primeFrames` (frames queued before output starts, 960 = 20 ms) and
`maxQueuedFrames` (3840 = 80 ms; above this the jitter buffer trims). Lower both for latency,
raise for robustness. The model itself adds ~30 ms that cannot be removed. Watch `underruns`
in `quiet-cli --live`.

### "Use a different mic by default" / "hide a device from the list"
`AppModel.inputs` in `QuietApp.swift` filters devices (it already hides loopbacks and anything
named "krisp"). `AudioDevices.virtualMicTargets()` decides what counts as a valid output.

### "Swap or upgrade the model"
`dfcore/Cargo.toml` pins `deep_filter` at a git tag with the `default-model` feature (the
DeepFilterNet3 weights get embedded). Any model `libDF` supports can be used by changing the
`DfParams` in `dfcore/src/lib.rs`. The pipeline assumes mono 48 kHz with the hop size reported by
`df_frame_len`; it will adapt to a different hop but not to a different sample rate without
also changing `StreamResampler` usage in `LivePipeline` and the CLI.

### "Add stereo / inbound (speaker-side) cleanup / echo cancellation"
Not implemented. Inbound would mean a second pipeline reading a loopback of the call app's
output and writing to a virtual output device; the driver would need a second visible device
(add a `kDevice3_*` set or build a second driver). AEC needs a far-end reference, which the
current architecture does not capture.

### "Run it without the custom driver"
Install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole); the app falls back to any
loopback device. The downside is that BlackHole can be selected as system output, which
would feed Mac audio into the mic; the app warns when this happens (`outputConflict`).

## Rules that keep it real-time safe

- The AUHAL callbacks (`onInput` / `onOutput` in `LivePipeline.swift`) may only
  call `qring_*`. No allocation, locks, Swift class allocation, `print`, or Objective-C.
- All DSP runs on the worker thread in `workLoop`. Settings changes go through `update(_:)`,
  which stashes them under `lock` and the worker picks them up between hops.
- `FrameProcessor.process` must be given exactly `frameLength` samples. The CLI shows how to
  pad and resample.
- `Denoiser` is not thread safe; one instance per pipeline.

## Conventions

- Swift 5.10, macOS 14 target, no third-party Swift packages. Keep it that way unless asked.
- Comments explain why, not what; the README's measured tables are the source of truth for
  performance claims, so update them when behaviour changes.
- `eval/audio` is gitignored except `eval/audio/dog` (CC BY-SA recordings). Do not commit
  anyone's voice recordings.
- Nothing in the Krisp teardown section of the README is used by the code; it documents the
  design the app re-implements with open components.
