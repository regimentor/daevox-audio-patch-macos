#!/bin/zsh
# Opt-in test: installs no software and restarts no services. Creates a real virtual mic.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/HardwareTests
xcrun swiftc -O -swift-version 6 -parse-as-library \
  DaevoxAudioPatch/Models/AudioModels.swift DaevoxAudioPatch/Audio/AudioDeviceManager.swift \
  DaevoxAudioPatch/Audio/AudioRoutingEngine.swift DaevoxAudioPatch/Audio/AudioCaptureEngine.swift \
  DaevoxAudioPatch/Services/ConfigurationManager.swift DaevoxAudioPatch/Services/VirtualDriverController.swift \
  HardwareTests/HALIntegration.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker HardwareTests/ProbeInfo.plist \
  -o build/HardwareTests/AudioPatchIntegrationProbe
codesign --force --sign - build/HardwareTests/AudioPatchIntegrationProbe
build/HardwareTests/AudioPatchIntegrationProbe "$@"
