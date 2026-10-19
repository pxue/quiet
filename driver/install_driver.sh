#!/bin/bash
# Installs Quiet.driver and restarts Core Audio (all audio on the Mac drops for ~2 s). Needs sudo.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)/build/Quiet.driver"
[ -d "$src" ] || { echo "Run build_driver.sh first"; exit 1; }
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Quiet.driver
sudo cp -R "$src" /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/Quiet.driver
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
echo "Installed. \"Quiet Microphone\" should now appear as an input device."
