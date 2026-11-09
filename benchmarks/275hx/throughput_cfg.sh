#!/bin/bash
# throughput_cfg.sh — vazao "mixed" (8 cls2 rand48 + 16 cls1 div16) para varias
# configs do shadow no MESMO boot, intercaladas por rodada.
#   d250x8   : read_us=250 pop_ticks=8   min_lag=5
#   d250x16  : read_us=250 pop_ticks=16  min_lag=5
#   off      : read_us=0   pop_ticks=9999999 min_lag=9999  (shadow efetivamente desligado)
#   oracle   : como off, mas cls2 preso a cpu0-7 e cls1 a cpu8-23 (placement perfeito, sem shadow)
# Turbo ligado (NO_TURBO=0 por padrao aqui), governor performance. Restaura tudo ao sair.
#
# Uso: sudo ./throughput_cfg.sh <tag>     (DUR=20 REPS=3 NO_TURBO=0)
# Saida: 275hx/results/<tag>/throughput_cfg/{runs.csv,summary.txt,meta.txt}
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
TAG="${1:?uso: sudo $0 <tag>}"
DUR="${DUR:-20}"; REPS="${REPS:-3}"; NT="${NO_TURBO:-0}"
D=/sys/kernel/debug
K_R=$D/ipcc_shadow_read_us; K_X=$D/ipcc_pop_ticks; K_L=$D/ipcc_min_lag_ms
[[ -w $K_R && -w $K_X && -w $K_L ]] || { echo "kernel sem os knobs do shadow"; exit 1; }

CFGS=("d250x8:250:8:5" "d250x16:250:16:5" "off:0:9999999:9999" "oracle:0:9999999:9999")
OUT="$(cd "$(dirname "$0")/../.." && pwd)/275hx/results/${TAG}/throughput_cfg"
mkdir -p "$OUT"
echo "cfg,rep,cls2_total,cls1_total" > "$OUT/runs.csv"
{ uname -srv; echo "dur=$DUR reps=$REPS no_turbo=$NT"; echo "cfgs=${CFGS[*]}"
  echo "platform_profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)"
  echo "rapl_pl1_uw=$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) pl2_uw=$(cat /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null)"
} > "$OUT/meta.txt"

old_r=$(cat $K_R); old_x=$(cat $K_X); old_l=$(cat $K_L)
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
NTF=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat $NTF 2>/dev/null || echo ""); [[ -n "$old_nt" ]] && echo "$NT" > $NTF
restore() {
    echo "$old_r" > $K_R; echo "$old_x" > $K_X; echo "$old_l" > $K_L
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g"; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > $NTF
    echo "knobs/governor/turbo restaurados"
}
trap restore EXIT INT TERM

apply() {  # name:read:pop:lag
    IFS=: read -r _ r x l <<< "$1"
    echo "$r" > $K_R; echo "$x" > $K_X; echo "$l" > $K_L
    [[ -w $D/ipcc_classifier_reset ]] && echo 1 > $D/ipcc_classifier_reset
}

run_one() {  # cfg rep
    local c="${1%%:*}" t2 t1 o2 o1
    apply "$1"; sleep 2
    t2=$(mktemp); t1=$(mktemp)
    local pin2="" pin1=""
    [[ "$c" == oracle ]] && { pin2="taskset -c 0-7"; pin1="taskset -c 8-23"; }
    $pin2 stress-ng --cpu 8  --cpu-method rand48 --timeout "${DUR}s" --metrics-brief > "$t2" 2>&1 & local p2=$!
    $pin1 stress-ng --cpu 16 --cpu-method div16  --timeout "${DUR}s" --metrics-brief > "$t1" 2>&1 & local p1=$!
    wait $p2 $p1 2>/dev/null
    o2=$(awk '/cpu /{print $9}' "$t2"); o1=$(awk '/cpu /{print $9}' "$t1"); rm -f "$t2" "$t1"
    echo "${c},$2,${o2:-NA},${o1:-NA}" >> "$OUT/runs.csv"
    printf "  rep %d %-8s cls2/worker=%s cls1/worker=%s\n" "$2" "$c" \
        "$(awk -v o="${o2:-0}" 'BEGIN{printf "%.0f", o/8}')" "$(awk -v o="${o1:-0}" 'BEGIN{printf "%.0f", o/16}')"
}

echo "aquecimento de 20s (descartado)..."
stress-ng --cpu 24 --cpu-method rand48 --timeout 20s --quiet >/dev/null 2>&1

echo "=== vazao mixed: ${#CFGS[@]} configs x ${REPS} rodadas x ${DUR}s (turbo no_turbo=$NT) ==="
for rep in $(seq 1 "$REPS"); do
    order=("${CFGS[@]}")
    if (( rep % 2 == 0 )); then   # inverte a ordem nas rodadas pares
        order=(); for (( i=${#CFGS[@]}-1; i>=0; i-- )); do order+=("${CFGS[i]}"); done
    fi
    for c in "${order[@]}"; do run_one "$c" "$rep"; done
done

python3 -I - "$OUT/runs.csv" <<'E' | tee "$OUT/summary.txt"
import csv, statistics as st, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if 'NA' not in (r['cls2_total'], r['cls1_total'])]
ncfg = len({r['cfg'] for r in rows})
full = {rep for rep in {r['rep'] for r in rows} if sum(1 for r in rows if r['rep'] == rep) == ncfg}
rows = [r for r in rows if r['rep'] in full]   # so rodadas completas
cfgs = []
for r in rows:
    if r['cfg'] not in cfgs: cfgs.append(r['cfg'])
def pw(c, k, n): return [float(r[k]) / n for r in rows if r['cfg'] == c]
base2 = st.mean(pw('off', 'cls2_total', 8)); base1 = st.mean(pw('off', 'cls1_total', 16))
print(f"\n{'cfg':<9} {'cls2/worker':>12} {'vs off':>8} {'cls1/worker':>12} {'vs off':>8}   n")
for c in cfgs:
    a, b = pw(c, 'cls2_total', 8), pw(c, 'cls1_total', 16)
    sd = lambda v: st.stdev(v) if len(v) > 1 else 0
    print(f"{c:<9} {st.mean(a):>9,.0f}±{sd(a):<4.0f}{100*(st.mean(a)/base2-1):>+7.2f}% {st.mean(b):>9,.0f}±{sd(b):<4.0f}{100*(st.mean(b)/base1-1):>+7.2f}%   {len(a)}")

# pareado: cada config contra o 'off' da MESMA rodada (tira a deriva entre rodadas)
off = {r['rep']: r for r in rows if r['cfg'] == 'off'}
print("\npareado contra off da mesma rodada: media % ± erro-padrao (n rodadas)")
for c in cfgs:
    if c == 'off': continue
    for k, n, name in (('cls2_total', 8, 'cls2'), ('cls1_total', 16, 'cls1')):
        d = [100 * (float(r[k]) / float(off[r['rep']][k]) - 1) for r in rows if r['cfg'] == c and r['rep'] in off]
        if len(d) > 1:
            se = st.stdev(d) / len(d) ** 0.5
            print(f"  {c:<8} {name}: {st.mean(d):+.2f}% ± {se:.2f}  (n={len(d)})" + ("   <- significativo (>2 EP)" if abs(st.mean(d)) > 2 * se else ""))
E
echo "resultados em $OUT"
