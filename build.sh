#!/bin/zsh
# Builds AgentLens.app (menu bar only, no Dock icon) next to this script.
set -e
cd "${0:A:h}"
swift build -c release --build-system native
# Universal binary (Apple Silicon + Intel). Falls back to Apple Silicon only if the Intel build fails.
BIN=.build/release/AgentLens
if swift build -c release --build-system native --arch x86_64 >/dev/null 2>&1; then
  mkdir -p .build/universal
  lipo -create .build/arm64-apple-macosx/release/AgentLens .build/x86_64-apple-macosx/release/AgentLens -output .build/universal/AgentLens
  BIN=.build/universal/AgentLens
  # Leave .build/release pointing at the Apple Silicon build (the Intel build re-points it).
  swift build -c release --build-system native >/dev/null 2>&1
else
  echo "note: Intel build failed; this app runs on Apple Silicon only"
fi
APP=AgentLens.app

# App icon: render the artwork, then pack every size macOS asks for.
ICONWORK=$(mktemp -d)
$BIN --snapshot $ICONWORK >/dev/null 2>&1 || true
if [[ -f $ICONWORK/AppIcon.png ]]; then
  SET=$ICONWORK/AppIcon.iconset; mkdir -p $SET
  for s in 16 32 128 256 512; do
    sips -z $s $s $ICONWORK/AppIcon.png --out $SET/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) $ICONWORK/AppIcon.png --out $SET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $SET -o $ICONWORK/AppIcon.icns
fi

rm -rf "${APP:?}"
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/
[[ -f $ICONWORK/AppIcon.icns ]] && cp $ICONWORK/AppIcon.icns $APP/Contents/Resources/
rm -rf "${ICONWORK:?}"
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AgentLens</string>
  <key>CFBundleDisplayName</key><string>AgentLens</string>
  <key>CFBundleIdentifier</key><string>local.agentlens</string>
  <key>CFBundleExecutable</key><string>AgentLens</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Sign with a stable identity when one exists, so macOS keeps permissions (Accessibility, notifications)
# across rebuilds. Ad-hoc signatures change with every build and macOS treats each build as a new app.
# One-time setup: Keychain Access → Certificate Assistant → Create a Certificate…,
# name "AgentLens Dev", Identity Type "Self Signed Root", Certificate Type "Code Signing".
if security find-identity -p codesigning 2>/dev/null | grep -q "AgentLens Dev"; then
  codesign --force --sign "AgentLens Dev" $APP
else
  # Ad-hoc, but with an explicit designated requirement naming only the bundle id. By default an ad-hoc
  # signature's requirement is its cdhash, which changes every build, so macOS treated each build as a
  # new app and dropped its Accessibility permission. With this, one grant carries over to new builds.
  codesign --force --sign - -r='designated => identifier "local.agentlens"' $APP
fi
echo "Built $PWD/$APP"
