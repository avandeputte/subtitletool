#!/bin/bash
# Builds "Extract Subtitles.app" with Xcode and (optionally) installs it to /Applications.
#   ./build.sh            build only  -> build/Extract Subtitles.app
#   ./build.sh --install  build, copy to /Applications, register with Finder, launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Extract Subtitles"
SCHEME="ExtractSubtitles"

# 1. Generate the Xcode project (needs XcodeGen: brew install xcodegen)
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install xcodegen; else
    echo "XcodeGen is required: brew install xcodegen"; exit 1; fi
fi

# 2. Pick the signing team. The team ID is the OU of the signing certificate
#    (the ID shown in parentheses in the identity name is not always the team).
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  for kind in "Developer ID Application" "Apple Development" "Mac Developer"; do
    DEVELOPMENT_TEAM=$(security find-certificate -c "$kind" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -Eo 'OU ?= ?[A-Z0-9]{10}' | grep -Eo '[A-Z0-9]{10}$' | head -1 || true)
    [[ -n "$DEVELOPMENT_TEAM" ]] && break
  done
fi
export DEVELOPMENT_TEAM
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  echo "==> Signing with team $DEVELOPMENT_TEAM"
  SIGN_ARGS=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic)
else
  echo "==> No developer identity found; using ad-hoc signing"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="")
fi

# 3. App icon from Resources/icon-1024.png (if present)
if [[ -f Resources/icon-1024.png ]]; then
  ICONSET="build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  mkdir -p Resources/Assets.xcassets/AppIcon.appiconset
  python3 - "$ICONSET" <<'PY'
import json, os, shutil, sys
iconset = sys.argv[1]; dest = "Resources/Assets.xcassets/AppIcon.appiconset"
images = []
for s in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{s}x{s}" + ("@2x" if scale == 2 else "") + ".png"
        shutil.copy(os.path.join(iconset, name), os.path.join(dest, name))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{s}x{s}"})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(dest, "Contents.json"), "w"), indent=2)
PY
fi
mkdir -p Resources/Assets.xcassets
[[ -f Resources/Assets.xcassets/Contents.json ]] || echo '{"info":{"author":"xcode","version":1}}' > Resources/Assets.xcassets/Contents.json

echo "==> Generating Xcode project"
xcodegen generate --quiet

echo "==> Building (Release)"
rm -rf build/DerivedData
xcodebuild -project ExtractSubtitles.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build/DerivedData "${SIGN_ARGS[@]}" build 2>&1 | grep -E "error:|warning: .*Swift|BUILD|Signing" || true

BUILT="build/DerivedData/Build/Products/Release/$APP_NAME.app"
[[ -d "$BUILT" ]] || { echo "Build failed (see xcodebuild output above)."; exit 1; }
rm -rf "build/$APP_NAME.app"; cp -R "$BUILT" "build/$APP_NAME.app"
echo "==> Built build/$APP_NAME.app"
codesign -dv "build/$APP_NAME.app" 2>&1 | grep -E "Authority|TeamIdentifier" || true

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "build/$APP_NAME.app" "/Applications/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app"
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  open "/Applications/$APP_NAME.app"
  cat <<MSG

Installed. Right-click an .mkv in Finder -> Services -> Extract Subtitles
(also: drag MKVs onto the app window or its Dock icon, or Open With).
Settings (Cmd-,): IMDb rename on/off, conversion Off or Locally.
If the Services entry is missing, log out and back in, or enable it in
System Settings > Keyboard > Keyboard Shortcuts > Services > Files and Folders.
MSG
fi
