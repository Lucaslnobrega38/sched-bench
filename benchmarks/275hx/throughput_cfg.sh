#!/bin/bash
# throughput_cfg.sh — vazao (ops/s por worker) para varias configs do shadow no MESMO boot,
# intercaladas por rodada, nos cenarios de placement:
#   contention : 8 cls2 (rand48) + 16 cls1 (div16)   (= o "mixed" de sempre)
#   relaxed    : 8 cls2 (rand48) +  8 cls1 (div16)
# Configs (CFGS_SEL escolhe quais):
#   d250x8   : read_us=250 pop_ticks=8   min_lag=5
#   d250x16  : read_us=250 pop_ticks=16  min_lag=5
#   off      : read_us=0   pop_ticks=9999999 min_lag=9999  (shadow efetivamente desligado)
#   oracle   : como off, mas cls2 preso a cpu0-7 e cls1 a cpu8-23 (placement perfeito, sem shadow)
# Governor performance, turbo por NO_TURBO (padrao 0 = ligado). Restaura tudo ao sair.
#
# COOL_C=<graus>: antes de cada execucao espera o pacote esfriar ate essa temperatura (max 180 s).
#
# Uso: sudo [COOL_C=60] [DUR=30] [REPS=5] [NO_TURBO=0] [CFGS_SEL="d250x16 off"] [SCEN="contention relaxed"] ./throughput_cfg.sh <tag>
# Saida: 275hx/results/<tag>/throughput_cfg/{runs.csv,summary.txt,meta.txt}
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
TAG="${1:?uso: sudo $0 <tag>}"
DUR="${DUR:-20}"; REPS="${REPS:-3}"; NT="${NO_TURBO:-0}"; SCEN="${SCEN:-contention relaxed}"; COOL_C="${COOL_C:-0}"
D=/sys/kernel/debug
K_R=$D/ipcc_shadow_read_us; K_X=$D/ipcc_pop_ticks; K_L=$D/ipcc_min_lag_ms
VANILLA=0
[[ -w $K_R && -w $K_X && -w $K_L ]] || { VANILLA=1; echo "kernel sem os knobs do shadow: modo VANILLA (uma config, sem mexer em knob)"; }

CFGS=("d250x8:250:8:5" "d250x16:250:16:5" "off:0:9999999:9999" "oracle:0:9999999:9999")
if [[ -n "${CFGS_SEL:-}" ]]; then
    sel=(); for c in "${CFGS[@]}"; do for s in $CFGS_SEL; do [[ "${c%%:*}" == "$s" ]] && sel+=("$c"); done; done
    CFGS=("${sel[@]}")
fi
[[ $VANILLA == 1 ]] && CFGS=("vanilla:0:0:0" "oracle:0:0:0")   # sem knobs: a base e o oraculo (placement perfeito)
OUT="$(cd "$(dirname "$0")/../.." && pwd)/275hx/results/${TAG}/throughput_cfg"
mkdir -p "$OUT"
echo "scen,cfg,rep,cls2_total,cls1_total,t_start,t_max,t_mean,p_mhz,e_mhz,watts,throttle" > "$OUT/runs.csv"
{ uname -srv; echo "dur=$DUR reps=$REPS no_turbo=$NT scen=$SCEN"; echo "cfgs=${CFGS[*]}"
  echo "platform_profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)"
  echo "rapl_pl1_uw=$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) pl2_uw=$(cat /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null)"
} > "$OUT/meta.txt"

[[ $VANILLA == 1 ]] || { old_r=$(cat $K_R); old_x=$(cat $K_X); old_l=$(cat $K_L); }
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
NTF=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat $NTF 2>/dev/null || echo ""); [[ -n "$old_nt" ]] && echo "$NT" > $NTF
restore() {
    [[ $VANILLA == 1 ]] || { echo "$old_r" > $K_R; echo "$old_x" > $K_X; echo "$old_l" > $K_L; }
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g"; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > $NTF
    echo "knobs/governor/turbo restaurados"
}
trap restore EXIT INT TERM

apply() {  # name:read:pop:lag
    [[ $VANILLA == 1 ]] && return 0
    IFS=: read -r _ r x l <<< "$1"
    echo "$r" > $K_R; echo "$x" > $K_X; echo "$l" > $K_L
    [[ -w $D/ipcc_classifier_reset ]] && echo 1 > $D/ipcc_classifier_reset
}

CT=""; for h in /sys/class/hwmon/hwmon*; do [[ "$(cat $h/name 2>/dev/null)" == coretemp ]] && CT=$h/temp1_input; done
RAPLE=/sys/class/powercap/intel-rapl:0/energy_uj; RAPLM=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj 2>/dev/null || echo 0)
THR=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count
temp_c() { [[ -n "$CT" ]] && echo $(( $(cat "$CT") / 1000 )) || echo 0; }
sampler() {   # $1 = arquivo; uma linha "temp pMHz eMHz" por segundo
    local c p e
    while :; do
        p=0; e=0
        for c in 0 1 2 3 4 5 6 7; do p=$(( p + $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq) )); done
        for c in $(seq 8 23); do e=$(( e + $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq) )); done
        echo "$(temp_c) $(( p / 8000 )) $(( e / 16000 ))" >> "$1"
        sleep 1
    done
}
cooldown() {
    [[ "$COOL_C" -gt 0 ]] || return 0
    local i
    for i in $(seq 1 180); do [[ "$(temp_c)" -le "$COOL_C" ]] && return 0; sleep 1; done
    echo "  (aviso: pacote nao chegou a ${COOL_C}C em 180 s; seguindo com $(temp_c)C)"
}

run_one() {  # scen cfg rep
    local scen="$1" c="${2%%:*}" rep="$3" n1 t2 t1 o2 o1
    [[ "$scen" == relaxed ]] && n1=8 || n1=16
    cooldown
    apply "$2"; sleep 2
    t2=$(mktemp); t1=$(mktemp); local sf; sf=$(mktemp)
    sampler "$sf" & local sp=$!
    local e0 e1 tt0 tt1 th0 th1 w
    e0=$(cat $RAPLE 2>/dev/null || echo 0); th0=$(cat $THR 2>/dev/null || echo 0); tt0=$(date +%s.%N)
    local pin2="" pin1=""
    [[ "$c" == oracle ]] && { pin2="taskset -c 0-7"; pin1="taskset -c 8-23"; }
    $pin2 stress-ng --cpu 8     --cpu-method rand48 --timeout "${DUR}s" --metrics-brief > "$t2" 2>&1 & local p2=$!
    $pin1 stress-ng --cpu "$n1" --cpu-method div16  --timeout "${DUR}s" --metrics-brief > "$t1" 2>&1 & local p1=$!
    wait $p2 $p1 2>/dev/null
    e1=$(cat $RAPLE 2>/dev/null || echo 0); th1=$(cat $THR 2>/dev/null || echo 0); tt1=$(date +%s.%N)
    kill $sp 2>/dev/null; wait $sp 2>/dev/null
    w=$(awk -v a="$e0" -v b="$e1" -v m="$RAPLM" -v t0="$tt0" -v t1="$tt1" 'BEGIN{d=b-a; if (d<0) d+=m; dt=t1-t0; if (dt>0) printf "%.1f", d/1e6/dt; else print "NA"}')
    local st; st=$(awk 'NR==1{t0=$1} {if($1>mx)mx=$1; s+=$1; p+=$2; e+=$3; n++} END{if(n) printf "%d,%d,%.1f,%.0f,%.0f", t0, mx, s/n, p/n, e/n; else print "NA,NA,NA,NA,NA"}' "$sf"); rm -f "$sf"
    o2=$(awk '/cpu /{print $9}' "$t2"); o1=$(awk '/cpu /{print $9}' "$t1"); rm -f "$t2" "$t1"
    echo "${scen},${c},${rep},${o2:-NA},${o1:-NA},${st},${w},$(( th1 - th0 ))" >> "$OUT/runs.csv"
    printf "  %-10s rep %d %-8s T=%sC P=%sMHz E=%sMHz %sW thr=%s  cls2/worker=%s cls1/worker=%s\n" "$scen" "$rep" "$c" "$(echo $st | cut -d, -f2)" "$(echo $st | cut -d, -f4)" "$(echo $st | cut -d, -f5)" "$w" "$(( th1 - th0 ))" \
        "$(awk -v o="${o2:-0}" 'BEGIN{printf "%.0f", o/8}')" "$(awk -v o="${o1:-0}" -v n="$n1" 'BEGIN{printf "%.0f", o/n}')"
}

echo "aquecimento de 20s (descartado)..."
stress-ng --cpu 24 --cpu-method rand48 --timeout 20s --quiet >/dev/null 2>&1

echo "=== vazao: cenarios [$SCEN] x ${#CFGS[@]} configs x ${REPS} rodadas x ${DUR}s (no_turbo=$NT) ==="
for scen in $SCEN; do
    for rep in $(seq 1 "$REPS"); do
        order=("${CFGS[@]}")
        if (( rep % 2 == 0 )); then   # inverte a ordem nas rodadas pares
            order=(); for (( i=${#CFGS[@]}-1; i>=0; i-- )); do order+=("${CFGS[i]}"); done
        fi
        for c in "${order[@]}"; do run_one "$scen" "$c" "$rep"; done
    done
done

python3 -I - "$OUT/runs.csv" <<'E' | tee "$OUT/summary.txt"
import csv, statistics as st, sys
allrows = [r for r in csv.DictReader(open(sys.argv[1])) if 'NA' not in (r['cls2_total'], r['cls1_total'])]
sd = lambda v: st.stdev(v) if len(v) > 1 else 0
for scen in dict.fromkeys(r['scen'] for r in allrows):
    n1 = 8 if scen == 'relaxed' else 16
    rows = [r for r in allrows if r['scen'] == scen]
    ncfg = len({r['cfg'] for r in rows})
    full = {rep for rep in {r['rep'] for r in rows} if sum(1 for r in rows if r['rep'] == rep) == ncfg}
    rows = [r for r in rows if r['rep'] in full]   # so rodadas completas
    cfgs = list(dict.fromkeys(r['cfg'] for r in rows))
    def pw(c, k, n): return [float(r[k]) / n for r in rows if r['cfg'] == c]
    print(f"\n##### cenario {scen}: 8 cls2 + {n1} cls1 ({len(full)} rodadas completas) #####")
    bc = 'off' if 'off' in cfgs else ('vanilla' if 'vanilla' in cfgs and len(cfgs) > 1 else None)
    has_off = bc is not None
    base2 = st.mean(pw(bc, 'cls2_total', 8)) if has_off else None
    base1 = st.mean(pw(bc, 'cls1_total', n1)) if has_off else None
    print(f"{'cfg':<9} {'cls2/worker':>12} {'vs ' + (bc or 'base'):>8} {'cls1/worker':>12} {'vs ' + (bc or 'base'):>8}   n")
    for c in cfgs:
        a, b = pw(c, 'cls2_total', 8), pw(c, 'cls1_total', n1)
        v2 = f"{100*(st.mean(a)/base2-1):>+7.2f}%" if has_off else "    n/d "
        v1 = f"{100*(st.mean(b)/base1-1):>+7.2f}%" if has_off else "    n/d "
        print(f"{c:<9} {st.mean(a):>9,.0f}±{sd(a):<4.0f}{v2} {st.mean(b):>9,.0f}±{sd(b):<4.0f}{v1}   {len(a)}")
    print("condicoes (media): cfg  T_ini  T_max  P_MHz  E_MHz  W  throttle")
    for c in cfgs:
        rc = [r for r in rows if r['cfg'] == c and r['t_max'] not in ('NA', '')]
        if rc:
            m = lambda k: st.mean(float(r[k]) for r in rc)
            print(f"  {c:<8} {m('t_start'):5.0f} {m('t_max'):6.0f} {m('p_mhz'):6.0f} {m('e_mhz'):6.0f} {m('watts'):5.1f} {sum(int(r['throttle']) for r in rc):4d}")
    xs = [(float(r['t_max']), float(r['cls1_total']) / n1) for r in rows if r['t_max'] not in ('NA', '')]
    if len(xs) > 3 and sd([x for x, _ in xs]) > 0 and sd([y for _, y in xs]) > 0:
        mx, my = st.mean(x for x, _ in xs), st.mean(y for _, y in xs)
        cov = sum((x - mx) * (y - my) for x, y in xs); vx = sum((x - mx) ** 2 for x, _ in xs); vy = sum((y - my) ** 2 for _, y in xs)
        print(f"correlacao cls1/worker x T_max (todas as execucoes do cenario): r = {cov / (vx * vy) ** 0.5:+.2f}  (n={len(xs)})")
    # pareado: cada config contra o 'off' da MESMA rodada (tira a deriva entre rodadas)
    off = {r['rep']: r for r in rows if r['cfg'] == bc}
    if not off:
        continue
    print(f"pareado contra {bc} da mesma rodada: media % ± erro-padrao (n rodadas)")
    for c in cfgs:
        if c == bc: continue
        for k, n, name in (('cls2_total', 8, 'cls2'), ('cls1_total', n1, 'cls1')):
            d = [100 * (float(r[k]) / float(off[r['rep']][k]) - 1) for r in rows if r['cfg'] == c and r['rep'] in off]
            if len(d) > 1:
                se = st.stdev(d) / len(d) ** 0.5
                print(f"  {c:<8} {name}: {st.mean(d):+.2f}% ± {se:.2f}  (n={len(d)})" + ("   <- significativo (>2 EP)" if abs(st.mean(d)) > 2 * se else ""))
E
echo "resultados em $OUT"
