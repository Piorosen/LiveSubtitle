#!/bin/zsh
# Mac App Store 제출용 패키지: 샌드박스 + iCloud 컨테이너 entitlements 로 서명한 .app 을 .pkg 로 묶음
#
# 준비물 (Apple Developer Program):
#   1. App ID party.udon.livesubtitle 에 iCloud(CloudDocuments, 컨테이너 iCloud.party.udon.livesubtitle) 기능 켜기
#   2. 인증서: "3rd Party Mac Developer Application: <이름> (<TEAM_ID>)", "3rd Party Mac Developer Installer: …"  (또는 "Apple Distribution")
#   3. Mac App Store 배포용 프로비저닝 프로파일(.provisionprofile) 다운로드
#
# 사용:
#   TEAM_ID=ABCDE12345 PROFILE=~/Downloads/LiveSubtitle_AppStore.provisionprofile VERSION=1.2.0 ./build-appstore.sh
#   (APP_CERT / INSTALLER_CERT 를 지정하지 않으면 키체인에서 TEAM_ID 로 찾음)
# 결과: dist/LiveSubtitle-<VERSION>.pkg  →  Transporter 앱 또는 Xcode Organizer 로 App Store Connect 에 업로드
set -euo pipefail
cd "$(dirname "$0")"
: "${TEAM_ID:?TEAM_ID 를 지정하세요 (예: ABCDE12345)}"
: "${PROFILE:?PROFILE=<.provisionprofile 경로> 를 지정하세요}"
VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}
BUILD_NO=${BUILD_NO:-$(date +%Y%m%d%H%M)}
APP_CERT=${APP_CERT:-$(security find-identity -v -p codesigning | grep -E "3rd Party Mac Developer Application|Apple Distribution" | grep "$TEAM_ID" | head -1 | sed -E 's/.*"(.*)".*/\1/')}
INSTALLER_CERT=${INSTALLER_CERT:-$(security find-identity -v | grep -E "3rd Party Mac Developer Installer|Mac Installer Distribution" | grep "$TEAM_ID" | head -1 | sed -E 's/.*"(.*)".*/\1/')}
[ -n "$APP_CERT" ] || { echo "앱 서명 인증서를 찾지 못했습니다 (3rd Party Mac Developer Application / Apple Distribution)"; exit 1; }
[ -n "$INSTALLER_CERT" ] || { echo "인스톨러 서명 인증서를 찾지 못했습니다 (3rd Party Mac Developer Installer)"; exit 1; }

APP=build/LiveSubtitle-appstore.app
OUT=$APP ./build.sh >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NO" "$APP/Contents/Info.plist"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

ENT=build/appstore.entitlements
sed "s/TEAM_ID/$TEAM_ID/g" LiveSubtitle.appstore.entitlements > "$ENT"
# 리소스 번들 → 앱 순서로 서명 (샌드박스 entitlements 는 앱 실행 파일에만)
for b in "$APP"/Contents/Resources/*.bundle; do [ -d "$b" ] && codesign --force --sign "$APP_CERT" --timestamp "$b"; done
codesign --force --sign "$APP_CERT" --entitlements "$ENT" --timestamp --options runtime "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" | grep -E "app-sandbox|icloud" >/dev/null && echo "entitlements OK"

mkdir -p dist
PKG="dist/LiveSubtitle-$VERSION.pkg"
productbuild --component "$APP" /Applications --sign "$INSTALLER_CERT" "$PKG"
echo "패키지 완료: $PKG  →  Transporter 로 App Store Connect 에 업로드하세요."
