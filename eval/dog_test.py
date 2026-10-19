"""Dog-bark test: real bark recordings (Wikimedia Commons, CC BY-SA) mixed over speech, run through quiet-cli.

Usage: python3 -I eval/dog_test.py <eval/audio dir> <quiet-cli path>
Reports how much bark energy is removed where the dog barks alone, and speech quality where barks overlap words.
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

import numpy as np

here = Path(__file__).parent
spec = importlib.util.spec_from_file_location("m", here / "make_and_score.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

SR, F = 48_000, 480
rng = np.random.default_rng(11)


def bark_track(n, sources, count):
    """Place `count` individual barks (energy-detected chunks of the recordings) at random times."""
    chunks = []
    for s in sources:
        lvl = m.db(np.sqrt((s[: len(s) // F * F].reshape(-1, F) ** 2).mean(1)))
        active = lvl > lvl.max() - 25
        i = 0
        while i < len(active):
            if active[i]:
                j = i
                while j < len(active) and active[j]:
                    j += 1
                if j - i >= 8:  # at least 80 ms
                    chunks.append(s[max(0, (i - 3) * F):(j + 3) * F])
                i = j
            i += 1
    track = np.zeros(n)
    for _ in range(count):
        c = chunks[rng.integers(len(chunks))]
        t = rng.integers(0, n - len(c))
        track[t:t + len(c)] += c
    return track


def frames(x):
    return x[: len(x) // F * F].reshape(-1, F)


def main():
    root, cli = Path(sys.argv[1]), sys.argv[2]
    speech = m.read(root / "primary.wav")
    n = len(speech) + SR
    clean = np.pad(speech, (0, n - len(speech)))
    clean *= 0.1 / m.rms(speech)
    barks = [m.read(p) for p in sorted((root / "dog").glob("*.wav"))]
    dog = bark_track(n, barks, 18)

    s_lvl = m.db(np.sqrt((frames(clean) ** 2).mean(1)))
    speech_on = s_lvl > -45

    print(f"{'scenario':<22}{'variant':<20}{'bark alone':>11}{'bark over words':>17}{'speech SI-SDR':>15}")
    for label, rel_db in [("dog in next room", 0), ("dog beside you", 6)]:
        d = dog * m.rms(clean[: len(speech)]) / m.rms(dog[np.abs(dog) > 1e-4]) * 10 ** (rel_db / 20)
        d_lvl = m.db(np.sqrt((frames(d) ** 2).mean(1)))
        bark_only = (d_lvl > -50) & ~speech_on
        overlap = (d_lvl > s_lvl - 6) & speech_on
        mix = clean + d
        noisy = root / f"dog_{rel_db}dB_noisy.wav"
        m.write(noisy, mix)

        def show(variant, x):
            f = frames(x)
            lvl = lambda mk: m.db(np.sqrt((f[mk] ** 2).mean()))
            ref_f = frames(clean)
            seg = lambda mk: m.si_sdr(ref_f[mk].ravel(), f[mk].ravel())
            print(f"{label:<22}{variant:<20}{lvl(bark_only):>8.1f} dB{lvl(overlap):>14.1f} dB{seg(overlap):>12.1f} dB")

        show("input", mix)
        for variant, extra in [("Quiet", []), ("Quiet + isolation", ["--isolate"])]:
            out = root / f"dog_{rel_db}dB_{'iso' if extra else 'nr'}.wav"
            subprocess.run([cli, str(noisy), str(out), *extra], check=True, capture_output=True)
            est, _ = m.align(clean, m.read(out))
            show(variant, est)
        print(f"{'':<22}({bark_only.sum() * 10} ms bark-only, {overlap.sum() * 10} ms of words with a bark on top)")


if __name__ == "__main__":
    main()
