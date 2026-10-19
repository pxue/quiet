#!/bin/bash
# Generates the two speech inputs the eval scripts need, using macOS text-to-speech:
#   eval/audio/primary.wav     the "primary" talker (close to the mic)
#   eval/audio/background.wav  a second talker, mixed in quieter by make_and_score.py
# Both are 48 kHz mono 16-bit. Replace them with real recordings for a more honest test
# (the synthetic voices speak at a constant level, which flatters a level-based gate).
set -euo pipefail
cd "$(dirname "$0")/audio"

gen() {  # gen <out.wav> <voice> <text>
  say -v "$2" -o "$1.aiff" "$3"
  afconvert -f WAVE -d LEI16@48000 -c 1 "$1.aiff" "$1.wav"
  rm "$1.aiff"
}

gen primary Samantha "This is the primary speaker, sitting close to the microphone. \
I am describing the build and talking about the eval suite in a normal voice. \
Sometimes I pause. Then I keep going for a while so there is enough speech to score."
gen background Daniel "I am another person in the same room, further from the microphone. \
I keep talking over the primary speaker about something unrelated, like the weather and lunch plans. \
A good voice isolator removes me without touching the person at the desk."
echo "Wrote primary.wav and background.wav"
