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
compile() { # $1 = target triple (rỗng = kiến trúc máy hiện tại), $2 = output
  xcrun swiftc -O ${1:+-target "$1"} \
    -framework AppKit -framework ServiceManagement \
    -parse-as-library Sources/ClaudeUsageBar.swift -o "$2"
}

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  # Build cho cả Apple Silicon và Intel
  compile arm64-apple-macos13 "build/arm64"
  compile x86_64-apple-macos13 "build/x86_64"
  lipo -create build/arm64 build/x86_64 -output "$BIN"
  rm -f build/arm64 build/x86_64
else
  compile "" "$BIN"
fi

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
