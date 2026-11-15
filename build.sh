#!/bin/bash
# Build ClaudeUsageBar.app (cần Xcode Command Line Tools: xcode-select --install)
# Dùng:  ./build.sh            -> build vào ./build/ClaudeUsageBar.app
#        ./build.sh --install  -> build + copy vào /Applications và mở app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeUsageBar.app"
BIN="$APP/Contents/MacOS/ClaudeUsageBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling… (swiftc: $(xcrun -f swiftc), SDK: $(xcrun --show-sdk-path))"
xcrun swiftc -O \
  -framework AppKit -framework ServiceManagement \
  -parse-as-library Sources/ClaudeUsageBar.swift -o "$BIN"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ClaudeUsageBar 2>/dev/null || true
  rm -rf "/Applications/ClaudeUsageBar.app"
  cp -R "$APP" /Applications/
  open "/Applications/ClaudeUsageBar.app"
  echo "✓ Installed to /Applications và đã mở app"
fi
