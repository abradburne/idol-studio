#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd -P)"
app="$root/.build/Idol Studio.app"
engine="$root/.local/engine/mlx-serve-macos-arm64"
if [[ ! -x "$engine/mlx-serve" ]]; then
    echo "Run scripts/setup.sh to fetch the bundled engine." >&2
    exit 1
fi
mkdir -p "$app/Contents/"{MacOS,Resources}

xcrun swiftc -O -swift-version 6 -parse-as-library -target arm64-apple-macosx26.2 \
    -module-cache-path "$root/.build/module-cache" Sources/*.swift -o "$app/Contents/MacOS/IdolStudio"
cp Resources/Info.plist "$app/Contents/"
cp Resources/Splats.metal "$app/Contents/Resources/"
rm -f "$app/Contents/Resources/ModelLocation"

icon_info="$root/.build/IconInfo.plist"
xcrun actool --compile "$app/Contents/Resources" --app-icon AppIcon \
    --output-partial-info-plist "$icon_info" --platform macosx \
    --minimum-deployment-target 26.2 --target-device mac "$root/Resources/AppIcon.icon"
# The asset compiler emits the icon keys in a separate plist.
/usr/libexec/PlistBuddy -c "Merge '$icon_info'" "$app/Contents/Info.plist"

ditto "$engine" "$app/Contents/Resources/Engine"
codesign --force --sign - "$app"
printf '%s\n' "$app"
