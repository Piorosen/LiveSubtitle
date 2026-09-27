#!/bin/zsh
# LiveSubtitle 빌드: ./build.sh  →  build/LiveSubtitle.app  (SwiftPM + FluidAudio/Parakeet CoreML)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E 'error|warning: unre|Compiling|Build complete' | grep -vE '^\s*$' | tail -3
BIN=.build/release
APP=build/LiveSubtitle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LiveSubtitle" "$APP/Contents/MacOS/LiveSubtitle"
# SwiftPM 리소스 번들 (FluidAudio 텍스트 정규화 데이터)
for b in "$BIN"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cp Info.plist "$APP/Contents/Info.plist"
[ -f icon/LiveSubtitle.icns ] && cp icon/LiveSubtitle.icns "$APP/Contents/Resources/LiveSubtitle.icns"
codesign --force --deep --sign - "$APP" >/dev/null
echo "빌드 완료: $APP"
