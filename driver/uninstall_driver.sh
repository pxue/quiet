#!/bin/bash
set -euo pipefail
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Quiet.driver
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
echo "Removed Quiet.driver."
