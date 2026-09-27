#!/bin/zsh
# 빌드 후 실행
cd "$(dirname "$0")"
./build.sh && open build/LiveSubtitle.app
