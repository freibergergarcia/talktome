#!/bin/bash
# Build and install to /Applications (or ~/Applications if that is not
# writable). A fixed path plus a stable signing identity keeps macOS
# permissions (mic, Input Monitoring) across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate -q
xcodebuild -project TalkToMe.xcodeproj -scheme TalkToMe -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates -quiet build
pkill -x TalkToMe 2>/dev/null || true
# Wait for the old copy to exit, or `open` below races it and fails (-600).
for _ in $(seq 1 20); do pgrep -x TalkToMe >/dev/null || break; sleep 0.25; done
dest=/Applications
[ -w "$dest" ] || { dest=~/Applications; mkdir -p "$dest"; }
rm -rf "$dest/TalkToMe.app"
cp -R build/Build/Products/Release/TalkToMe.app "$dest/"
open "$dest/TalkToMe.app"
echo "installed $dest/TalkToMe.app"
