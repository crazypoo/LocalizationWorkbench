#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS with Xcode Command Line Tools is required to bundle the SwiftUI app." >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Install/select Xcode: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
swift build -c release --product LocalizationWorkbenchApp
BIN_DIR="$(swift build -c release --show-bin-path)"
OUT="$ROOT/dist/LocalizationWorkbench.app"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/LocalizationWorkbenchApp" "$OUT/Contents/MacOS/LocalizationWorkbenchApp"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Localization Workbench</string>
  <key>CFBundleDisplayName</key><string>Localization Workbench</string>
  <key>CFBundleIdentifier</key><string>dev.localizationworkbench.desktop</string>
  <key>CFBundleExecutable</key><string>LocalizationWorkbenchApp</string>
  <key>CFBundleVersion</key><string>100</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$OUT"
echo "App bundled at $OUT"
echo "To run: open '$OUT'"
