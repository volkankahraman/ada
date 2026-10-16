#!/bin/sh
# Builds build/Ada.app (menu-bar-less agent app, ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64 # universal: Apple Silicon and Intel
APP=build/Ada.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Ada "$APP/Contents/MacOS/Ada"
cp hook.sh "$APP/Contents/Resources/hook.sh" # installed to ~/.ada on launch

# App icon from assets/logo.png (1024x1024).
ICONSET=$(mktemp -d)/Ada.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/logo.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/logo.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Ada.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.volkankahraman.ada</string>
  <key>CFBundleName</key><string>Ada</string>
  <key>CFBundleExecutable</key><string>Ada</string>
  <key>CFBundleIconFile</key><string>Ada</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force -s - "$APP"
echo "Built $APP"
