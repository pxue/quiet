#!/bin/bash
# Builds Quiet.driver: a renamed BlackHole (GPL-3.0, ./BlackHole) with
#   "Quiet Microphone" – visible, input only (what call/podcast apps select)
#   "Quiet Output"     – hidden, output only (only Quiet.app writes here; UID Quiet_2_UID)
# Both share one loopback buffer, the same visible-input / hidden-output pattern Krisp uses.
set -euo pipefail
cd "$(dirname "$0")"

bundleID="ltd.spacestationlabs.quiet.driver"
rm -rf build
xcodebuild -quiet \
  -project BlackHole/BlackHole.xcodeproj \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$PWD/build" \
  PRODUCT_NAME=Quiet \
  PRODUCT_BUNDLE_IDENTIFIER=$bundleID \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
  kDriver_Name=\"Quiet\"
  kPlugIn_BundleID=\"'$bundleID'\"
  kPlugIn_Icon=\"BlackHole.icns\"
  kManufacturer_Name=\"Quiet\"
  kHas_Driver_Name_Format=false
  kNumber_Of_Channels=2
  kDevice_Name=\"Quiet\ Microphone\"
  kDevice_IsHidden=false
  kDevice_HasInput=true
  kDevice_HasOutput=false
  kDevice2_Name=\"Quiet\ Output\"
  kDevice2_IsHidden=true
  kDevice2_HasInput=false
  kDevice2_HasOutput=true
  kCanBeDefaultSystemDevice=false'
codesign --force --deep --sign - build/Quiet.driver
echo "Built $(pwd)/build/Quiet.driver"
