#!/bin/bash
# Package TalkToMe as a drag-to-Applications disk image.
#
#   scripts/make-dmg.sh        # writes dist/TalkToMe-<version>.dmg
#
# Always builds with the public bundle ID and ad-hoc signing, whatever
# Local.xcconfig says, so a personal identity never ends up in a download.
# The image is not notarized: on first launch macOS asks people to allow it
# in System Settings → Privacy & Security (see README).
#
# Finder lays out the window, so the first run asks to let your terminal
# control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
name=TalkToMe

cd app
xcodegen generate -q
xcodebuild -project TalkToMe.xcodeproj -scheme TalkToMe -configuration Release \
  -derivedDataPath build/dmg -quiet build \
  PRODUCT_BUNDLE_IDENTIFIER=dev.talktome.TalkToMe CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
app="$PWD/build/dmg/Build/Products/Release/$name.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
codesign --verify --strict "$app"

work=$(mktemp -d)
# Mounted in /Volumes: Finder only lays out disks it lists there.
mount_dir="/Volumes/$name"
attached=
trap '[ -n "$attached" ] && hdiutil detach -quiet "$mount_dir"; rm -rf "$work"' EXIT

# Stage: the app, a shortcut to /Applications, and the background art.
mkdir -p "$work/stage/.background"
cp -R "$app" "$work/stage/"
ln -s /Applications "$work/stage/Applications"
"$app/Contents/MacOS/$name" --dmg-background "$work/art"
tiffutil -cathidpicheck "$work/art/background.png" "$work/art/background@2x.png" \
  -out "$work/stage/.background/background.tiff" 2>/dev/null
cp "$app/Contents/Resources/AppIcon.icns" "$work/stage/.VolumeIcon.icns"

# A writable image first, so Finder can save the window layout into it.
if [ -d "/Volumes/$name" ]; then
  echo "error: /Volumes/$name is already mounted; eject it first" >&2
  exit 1
fi
hdiutil create -quiet -srcfolder "$work/stage" -volname "$name" -fs HFS+ \
  -format UDRW -size 200m "$work/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$mount_dir" "$work/rw.dmg"
attached=1
xcrun SetFile -a C "$mount_dir"   # use .VolumeIcon.icns
# Finder lists a new disk a moment after it mounts (about 1 s on macOS 27);
# asking for it sooner fails with "Can't get disk" (-1728).
for _ in $(seq 1 20); do
  [ "$(osascript -e "tell application \"Finder\" to exists disk \"$name\"")" = true ] && break
  sleep 0.5
done

# Window: 660 × 400 content plus the 32 pt title bar (macOS 26); icons over
# the background's marks (DMGBackgroundView.appCenter / applicationsCenter).
osascript <<EOF
tell application "Finder"
  tell disk "$name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {200, 120, 860, 552}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$name.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    update without registering applications
    -- Finder writes the layout to .DS_Store when the window closes; close,
    -- reopen and close again so the window size is saved too.
    close
    open
    delay 1
    close
  end tell
end tell
EOF
for _ in $(seq 1 20); do [ -f "$mount_dir/.DS_Store" ] && break; sleep 0.5; done
sleep 2
sync
hdiutil detach -quiet "$mount_dir"
attached=

mkdir -p "$root/dist"
out="$root/dist/$name-$version.dmg"
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out"
echo "wrote $out"
