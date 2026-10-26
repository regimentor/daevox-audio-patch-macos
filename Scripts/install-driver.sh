#!/bin/zsh
# Run as your own user. sudo requests administrator authorization for the exact copy.
set -euo pipefail
if (( $# != 1 )); then
    print -u2 'Usage: Scripts/install-driver.sh /path/to/AudioPatch.driver'
    exit 2
fi
driver_source="${1:A}"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver_source/Contents/Info.plist")" != 'audio.audio-patch.driver' ]]; then
    print -u2 'Unexpected driver bundle ID'
    exit 1
fi
/usr/bin/codesign --verify --strict "$driver_source"
driver_staging="/Library/Audio/Plug-Ins/HAL/.AudioPatch-install-$(uuidgen)"
sudo /bin/mkdir -p /Library/Audio/Plug-Ins/HAL
sudo /usr/bin/ditto "$driver_source" "$driver_staging"
sudo /usr/sbin/chown -R root:wheel "$driver_staging"
sudo /bin/chmod -R go-w "$driver_staging"
sudo /bin/rm -rf /Library/Audio/Plug-Ins/HAL/AudioPatch.driver
sudo /bin/mv "$driver_staging" /Library/Audio/Plug-Ins/HAL/AudioPatch.driver
print 'AudioPatch.driver installed. Reboot macOS to load it. No audio service was restarted.'
