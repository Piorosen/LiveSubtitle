#!/bin/zsh
# LiveSubtitle 빌드: ./build.sh  →  build/LiveSubtitle.app  (SwiftPM + FluidAudio/Parakeet CoreML, ad-hoc 서명, 비샌드박스)
#   SANDBOX=1 ./build.sh  →  build/LiveSubtitle-sandbox.app  (App Sandbox entitlements 로 ad-hoc 서명: App Store 동작 검증용, iCloud 컨테이너 제외)
#   App Store 제출용은 ./build-appstore.sh
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E 'error|warning: unre|Compiling|Build complete' | grep -vE '^\s*$' | tail -3
BIN=.build/release
if [ "${SANDBOX:-0}" = "1" ]; then
  APP=${OUT:-build/LiveSubtitle-sandbox.app}
  ENT=LiveSubtitle.sandbox.entitlements
else
  APP=${OUT:-build/LiveSubtitle.app}
  ENT=""
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LiveSubtitle" "$APP/Contents/MacOS/LiveSubtitle"
# SwiftPM 리소스 번들 (FluidAudio 텍스트 정규화 데이터)
for b in "$BIN"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cp Info.plist "$APP/Contents/Info.plist"
[ -f icon/LiveSubtitle.icns ] && cp icon/LiveSubtitle.icns "$APP/Contents/Resources/LiveSubtitle.icns"
if [ -n "$ENT" ]; then
  codesign --force --deep --sign - --entitlements "$ENT" "$APP" >/dev/null
  echo "빌드 완료 (App Sandbox): $APP"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "빌드 완료: $APP"
fi
