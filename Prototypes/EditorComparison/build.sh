#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
npm ci --no-audit --no-fund
npm run build
swift build -c release
BIN=$(swift build -c release --show-bin-path)
for ENGINE in native crepe; do
  APP="$PWD/apps/Editor Lab $ENGINE.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN/EditorComparison" "$APP/Contents/MacOS/EditorComparison"
  # Bundle.module searches the application's resource directory on this toolchain.
  rm -rf "$APP/Contents/Resources/EditorComparison_EditorComparison.bundle"
  ditto "$BIN/EditorComparison_EditorComparison.bundle" "$APP/Contents/Resources/EditorComparison_EditorComparison.bundle"
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.notchnotes.editorlab.$ENGINE</string>
<key>CFBundleName</key><string>Editor Lab $ENGINE</string>
<key>CFBundleExecutable</key><string>EditorComparison</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LabEngine</key><string>$ENGINE</string>
</dict></plist>
EOF
  codesign --force --sign - "$APP"
  codesign --verify --deep --strict "$APP"
done
