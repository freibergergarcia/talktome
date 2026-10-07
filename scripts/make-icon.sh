#!/bin/bash
# Regenerate the app icon set from AppIconView.swift.
#
#   scripts/make-icon.sh
#
# Builds the app, renders the icon at 1024 px with `TalkToMe --icon`, then
# writes every size macOS needs into Assets.xcassets/AppIcon.appiconset.
set -euo pipefail
cd "$(dirname "$0")/../app"

xcodegen generate -q
xcodebuild -project TalkToMe.xcodeproj -scheme TalkToMe -configuration Debug \
  -derivedDataPath build -quiet build
tmp=$(mktemp -d)
build/Build/Products/Debug/TalkToMe.app/Contents/MacOS/TalkToMe --icon "$tmp"

set_dir=TalkToMe/Assets.xcassets/AppIcon.appiconset
mkdir -p "$set_dir"
images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    name="icon_${size}x${size}@${scale}x.png"
    sips -z "$px" "$px" "$tmp/AppIcon.png" --out "$set_dir/$name" >/dev/null
    images="$images{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
  done
done
printf '{"images":[%s],"info":{"version":1,"author":"xcode"}}\n' "${images%,}" > "$set_dir/Contents.json"
printf '{"info":{"version":1,"author":"xcode"}}\n' > TalkToMe/Assets.xcassets/Contents.json
echo "wrote $set_dir"
