#!/bin/zsh
# 엔진별 전력 측정 (powermetrics, root 필요). 결과: results/power.tsv
cd "$(dirname "$0")/.."
PW="${POWER_SUDO_PW:?환경변수 POWER_SUDO_PW 에 관리자 비밀번호 필요}"
echo "$PW" | sudo -S -v 2>/dev/null || { echo "sudo failed"; exit 1; }
: > results/power.tsv
measure() {
  name=$1; audio_sec=$2; shift 2
  out=results/pm_$name.txt
  echo "$PW" | sudo -S powermetrics --samplers cpu_power,gpu_power,ane_power -i 1000 -o $out > /dev/null 2>&1 &
  t0=$(date +%s.%N)
  "$@" > results/pm_${name}.out 2>&1
  t1=$(date +%s.%N)
  echo "$PW" | sudo -S pkill -INT powermetrics 2>/dev/null
  # 마지막 프로세스가 파일을 닫을 시간
  python3 -c "import time; time.sleep(1.5)"
  python3 - "$name" "$audio_sec" "$t0" "$t1" "$out" <<'PY' >> results/power.tsv
import sys, re
name, audio, t0, t1, path = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
txt = open(path, errors='ignore').read()
def avg(label):
    v = [float(x) for x in re.findall(label + r':\s*([0-9.]+)\s*mW', txt)]
    return sum(v)/len(v) if v else float('nan'), len(v)
cpu,n = avg('CPU Power'); gpu,_ = avg('GPU Power'); ane,_ = avg('ANE Power'); comb,_ = avg(r'Combined Power \(CPU \+ GPU \+ ANE\)')
el = t1 - t0
print(f"{name}\t{el:.1f}\t{audio:.0f}\t{n}\t{cpu:.0f}\t{gpu:.0f}\t{ane:.0f}\t{comb:.0f}")
PY
}
FAR=(set/farlong/*.wav)
measure idle 0 python3 -c "import time; time.sleep(12)"
measure apple 627 ./tools/applestt $FAR
measure parakeet_v2 627 ./asreval/.build/release/asreval v2 $FAR
measure parakeet_ultra 627 ./asreval/.build/release/asreval ultra $FAR
mkdir -p set/wk3 && cp set/farlong/2414.wav set/farlong/2609.wav set/farlong/3538.wav set/wk3/ 2>/dev/null
WK3=$(for f in set/wk3/*.wav; do ffprobe -loglevel error -show_entries format=duration -of csv=p=0 $f; done | awk '{s+=$1} END{print s}')
measure whisperkit_turbo $WK3 whisperkit-cli transcribe --model large-v3-v20240930_626MB --audio-folder set/wk3 --report --report-path results/wk3
echo "$PW" | sudo -S -k 2>/dev/null
echo "name	elapsed_s	audio_s	samples	cpu_mW	gpu_mW	ane_mW	combined_mW"; cat results/power.tsv
