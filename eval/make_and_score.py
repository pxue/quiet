"""Build noisy test mixtures, run quiet-cli on them, and score the results.

Usage: python3 -I eval/make_and_score.py <eval/audio dir> <quiet-cli path>

Metrics
  SI-SDR (dB): scale-invariant signal-to-distortion vs. the clean primary speech. Higher is better.
  Background voice level (dB): energy where only the background talker speaks, relative to the primary.
Outputs are aligned to the reference by cross-correlation before scoring (DeepFilterNet adds ~30 ms delay).
"""
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

SR = 48_000
rng = np.random.default_rng(7)


def read(path):
    if path.suffix == ".aiff":
        out = path.with_suffix(".tmp.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1", str(path), str(out)], check=True)
        path = out
    with wave.open(str(path)) as w:
        assert w.getframerate() == SR, w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    return x


def write(path, x):
    y = np.clip(x, -1, 1)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((y * 32767).astype(np.int16).tobytes())


def rms(x):
    return np.sqrt(np.mean(x ** 2) + 1e-12)


def db(x):
    return 20 * np.log10(x + 1e-12)


def pink(n):
    f = np.fft.rfftfreq(n, 1 / SR); f[0] = 1
    spec = (rng.standard_normal(len(f)) + 1j * rng.standard_normal(len(f))) / np.sqrt(f)
    return np.fft.irfft(spec, n)


def keyboard(n):
    x = np.zeros(n)
    for t in rng.integers(0, n - 2000, size=int(n / SR * 9)):
        click = rng.standard_normal(600) * np.exp(-np.arange(600) / 80)
        x[t:t + 600] += click * rng.uniform(0.5, 1.0)
    return x


def fan(n):
    t = np.arange(n) / SR
    hum = sum(np.sin(2 * np.pi * f0 * t) / k for k, f0 in enumerate([120, 240, 360, 480], 1))
    return hum + 0.6 * pink(n)


def cafe(n, voice):
    # Babble: several time-shifted, pitch-unchanged copies of other speech plus clatter.
    x = np.zeros(n)
    for _ in range(6):
        s = np.roll(np.resize(voice, n), rng.integers(0, n)) * rng.uniform(0.5, 1)
        x += s
    return x + 0.3 * keyboard(n)


def align(ref, est):
    n = len(ref)
    est = np.pad(est, (0, max(0, n - len(est))))
    c = np.fft.irfft(np.fft.rfft(est, 2 * n) * np.conj(np.fft.rfft(ref, 2 * n)))
    lag = int(np.argmax(c[:SR // 5]))  # model delay is a few tens of ms
    return est[lag:lag + n], lag


def si_sdr(ref, est):
    a = np.dot(est, ref) / np.dot(ref, ref)
    target = a * ref
    return 10 * np.log10(np.sum(target ** 2) / np.sum((est - target) ** 2))


def main():
    root, cli = Path(sys.argv[1]), sys.argv[2]
    primary = read(root / "primary.wav")
    background = read(root / "background.wav")
    n = len(primary) + SR  # one second of tail for the background talker
    clean = np.pad(primary, (0, n - len(primary)))
    clean *= 0.1 / rms(primary)

    scenes = {
        "white_5dB": (rng.standard_normal(n), 5),
        "pink_0dB": (pink(n), 0),
        "keyboard_5dB": (keyboard(n), 5),
        "fan_hum_0dB": (fan(n), 0),
        "cafe_babble_5dB": (cafe(n, background), 5),
    }
    rows = []
    for name, (noise, snr) in scenes.items():
        noise = noise * rms(clean[: len(primary)]) / rms(noise) / 10 ** (snr / 20)
        mix = clean + noise
        write(root / f"{name}_noisy.wav", mix)
        out = root / f"{name}_quiet.wav"
        log = subprocess.run([cli, str(root / f"{name}_noisy.wav"), str(out)], check=True,
                             capture_output=True, text=True).stdout.strip()
        est, lag = align(clean, read(out))
        rows.append((name, si_sdr(clean, mix), si_sdr(clean, est), lag, log))

    print(f"{'scene':<18}{'SI-SDR in':>11}{'SI-SDR out':>12}{'gain':>8}   model delay")
    for name, before, after, lag, _ in rows:
        print(f"{name:<18}{before:>10.1f} {after:>11.1f} {after - before:>+7.1f}   {lag / 48:.1f} ms")
    print("\nCLI timing:", rows[0][4])

    # Background talker: primary close to the mic, a second person 14 dB quieter starting 1.5 s later.
    bg = np.zeros(n)
    start = int(1.5 * SR)
    seg = background[: n - start]
    bg[start:start + len(seg)] = seg
    bg *= rms(clean[: len(primary)]) / rms(seg) / 10 ** (14 / 20)
    mix = clean + bg + 0.02 * pink(n) * rms(clean) / rms(pink(n))
    write(root / "background_talker_noisy.wav", mix)

    # "Background only" = frames where the background talker is active and the primary is (near) silent.
    frame = 480
    def frames(x):
        k = len(x) // frame
        return x[: k * frame].reshape(k, frame)
    p_lvl = db(np.sqrt((frames(clean) ** 2).mean(1)))
    b_lvl = db(np.sqrt((frames(bg) ** 2).mean(1)))
    bg_only = (b_lvl > p_lvl + 20) & (b_lvl > -60)
    both = p_lvl > -45

    print(f"\nBackground talker test ({bg_only.sum() * 10} ms of background-only speech):")
    print(f"{'variant':<22}{'bg-only level':>14}{'primary level':>15}{'SI-SDR':>9}")
    def report(label, x):
        f = frames(x)
        lvl = lambda m: db(np.sqrt((f[m] ** 2).mean()))
        print(f"{label:<22}{lvl(bg_only):>11.1f} dB{lvl(both):>12.1f} dB{si_sdr(clean[:len(x)], x[:len(clean)]):>9.1f}")
    report("input", mix)
    for label, extra in [("noise reduction only", []), ("+ voice isolation", ["--isolate"]),
                         ("+ isolation strong", ["--isolate", "--strength", "0.9"])]:
        out = root / f"background_talker_{'_'.join(a.strip('-') for a in extra) or 'nr'}.wav"
        log = subprocess.run([cli, str(root / "background_talker_noisy.wav"), str(out), *extra],
                             check=True, capture_output=True, text=True).stdout.strip()
        est, _ = align(clean, read(out))
        report(label, est)


if __name__ == "__main__":
    main()
