#!/bin/zsh
set -euo pipefail
sudo /bin/rm -rf /Library/Audio/Plug-Ins/HAL/AudioPatch.driver
print 'AudioPatch.driver removed. Reboot macOS to unload it. Saved user configuration is retained.'
