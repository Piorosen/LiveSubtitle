#!/bin/zsh
# 강당 원거리 마이크 시뮬레이션: 잔향 + 저역통과 + 배경 잡음(SNR≈10dB), 16k mono
# usage: degrade.sh <in.wav|flac> <out.wav>
ffmpeg -loglevel error -y -i "$1" -filter_complex \
 "[0:a]aresample=16000,aecho=0.8:0.6:40|90|170:0.35|0.25|0.15,lowpass=f=3800,highpass=f=150,volume=0.9[s];
  anoisesrc=color=pink:sample_rate=16000:amplitude=0.03:seed=7:duration=60[n];
  [s][n]amix=inputs=2:duration=first:normalize=0[o]" -map "[o]" -ac 1 -ar 16000 -c:a pcm_s16le "$2"
