#!/bin/bash
# throughput_stable.sh — vazao com potencia do pacote ESTABILIZADA em todas as amostras.
# Igual ao throughput_cfg.sh (mesmos cenarios, configs, turbo, perfil), mas:
#  1. por cenario, aquece com a propria carga e COMECA AS RUNS no primeiro segundo em que a potencia do
#     pacote fica abaixo de START_W (126 W), contando so depois de MIN_HEAT (15 s) de carga;
#  2. so aceita uma run se a potencia dela, por segundo, esta estavel:
#       boost  : media (sem os 3 primeiros s) > START_W
#       deriva : |media da 1a metade - media da 2a metade| > FLAT_W
#       oscila : max - min > BAND_W
#  3. run rejeitada e refeita na hora (sem pausa, o pacote segue quente) ATE COMPLETAR (MAX_TRY=0, ilimitado;
#     >0 limita as tentativas por celula); a cada RECAL_EVERY (4) rejeicoes seguidas recalibra o Pref;
#     teto global MAX_MIN (240 min). As rejeitadas ficam em rejected.csv. REPS = runs ACEITAS por config e cenario.
#
# SEED_TAGS="tagA tagB": aproveita runs de rodadas anteriores (throughput_cfg ou throughput_stable) do MESMO
#   kernel: importa as que tem potencia media < SEED_MAX_W (126) e roda so o que falta para completar REPS
#   por config e cenario (rep a rep; a run que falta herda o numero da rep). Runs importadas: try=0.
#
# Uso: sudo [SEED_TAGS="..."] [SEED_MAX_W=126] [REPS=8] [DUR=30] [NO_TURBO=0] [CFGS_SEL="d250x16 off"] [SCEN="contention relaxed"] \
#           [START_W=126] [MIN_HEAT=15] [FLAT_W=2.5] [BAND_W=8] [CAL_WIN=10] [CAL_MAX=60] [MAX_TRY=0] [MAX_MIN=240] [RECAL_EVERY=4] ./throughput_stable.sh <tag>
# Sem knobs do shadow (kernel sem IPCC): configs vanilla e oracle.
# Saida: 275hx/results/<tag>/throughput_stable/{runs.csv,rejected.csv,summary.txt,meta.txt}
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
TAG="${1:?uso: sudo $0 <tag>}"
DUR="${DUR:-30}"; REPS="${REPS:-8}"; NT="${NO_TURBO:-0}"; SCEN="${SCEN:-contention relaxed}"
START_W="${START_W:-126}"; MIN_HEAT="${MIN_HEAT:-15}"; FLAT_W="${FLAT_W:-2.5}"; BAND_W="${BAND_W:-8}"
CAL_WIN="${CAL_WIN:-10}"; CAL_MAX="${CAL_MAX:-60}"; MAX_TRY="${MAX_TRY:-0}"; MAX_MIN="${MAX_MIN:-240}"; RECAL_EVERY="${RECAL_EVERY:-4}"; SKIP_S=3
SEED_TAGS="${SEED_TAGS:-}"; SEED_MAX_W="${SEED_MAX_W:-126}"
D=/sys/kernel/debug
K_R=$D/ipcc_shadow_read_us; K_X=$D/ipcc_pop_ticks; K_L=$D/ipcc_min_lag_ms
VANILLA=0
[[ -w $K_R && -w $K_X && -w $K_L ]] || { VANILLA=1; echo "kernel sem os knobs do shadow: modo VANILLA (vanilla + oracle)"; }

CFGS=("d250x8:250:8:5" "d250x16:250:16:5" "off:0:9999999:9999" "oracle:0:9999999:9999")
if [[ -n "${CFGS_SEL:-}" ]]; then
    sel=(); for c in "${CFGS[@]}"; do for s in $CFGS_SEL; do [[ "${c%%:*}" == "$s" ]] && sel+=("$c"); done; done
    CFGS=("${sel[@]}")
fi
[[ $VANILLA == 1 ]] && CFGS=("vanilla:0:0:0" "oracle:0:0:0")
OUT="$(cd "$(dirname "$0")/../.." && pwd)/275hx/results/${TAG}/throughput_stable"
mkdir -p "$OUT"
HDR="scen,cfg,rep,try,cls2_total,cls1_total,t_start,t_max,t_mean,p_mhz,e_mhz,watts,throttle,w_h1,w_h2,w_min,w_max,pref"
echo "$HDR" > "$OUT/runs.csv"; echo "$HDR,reason" > "$OUT/rejected.csv"
{ uname -srv; echo "dur=$DUR reps_aceitas=$REPS no_turbo=$NT scen=$SCEN"; echo "cfgs=${CFGS[*]}"
  echo "start_w=$START_W min_heat=$MIN_HEAT flat_w=$FLAT_W band_w=$BAND_W cal_win=$CAL_WIN cal_max=$CAL_MAX max_try=$MAX_TRY skip=${SKIP_S}s"
  echo "seed_tags=${SEED_TAGS:-nenhum} seed_max_w=$SEED_MAX_W"
  echo "platform_profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)"
  echo "rapl_pl1_uw=$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) pl2_uw=$(cat /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null)"
} > "$OUT/meta.txt"

if [[ -n "$SEED_TAGS" ]]; then
    CFGN=""; for c in "${CFGS[@]}"; do CFGN+="${c%%:*} "; done
    echo "=== importando runs anteriores (potencia < ${SEED_MAX_W} W): $SEED_TAGS ==="
    python3 -I - "$OUT" "$(cd "$(dirname "$0")/../.." && pwd)/275hx/results" "$SEED_TAGS" "$SEED_MAX_W" "$SCEN" "$CFGN" "$REPS" <<'PYSEED' | tee "$OUT/seed_report.txt"
import csv, os, sys
out, res, tags, maxw, scens, cfgs, reps = sys.argv[1:8]
maxw = float(maxw); scens = scens.split(); cfgs = cfgs.split(); reps = int(reps)
seen, kept, dropped = set(), [], []
for tag in tags.split():
    for sub in ("throughput_stable", "throughput_cfg"):
        p = f"{res}/{tag}/{sub}/runs.csv"
        if os.path.exists(p): break
    else:
        print(f"  seed {tag}: sem runs.csv"); continue
    for r in csv.DictReader(open(p)):
        if r['scen'] not in scens or r['cfg'] not in cfgs or int(r['rep']) > reps: continue
        key = (r['scen'], r['cfg'], r['rep'])
        if key in seen: continue
        try: w = float(r['watts']); float(r['cls2_total']); float(r['cls1_total'])
        except ValueError: dropped.append((tag, *key, "sem-dados")); continue
        if w >= maxw: dropped.append((tag, *key, f"{w:.1f} W")); continue
        seen.add(key); kept.append(r)
with open(f"{out}/runs.csv", "a") as f:
    for r in kept:
        g = lambda k: r.get(k) or 'NA'
        f.write(",".join([r['scen'], r['cfg'], r['rep'], "0", g('cls2_total'), g('cls1_total'), g('t_start'), g('t_max'), g('t_mean'),
                          g('p_mhz'), g('e_mhz'), g('watts'), g('throttle'), g('w_h1'), g('w_h2'), g('w_min'), g('w_max'), g('pref')]) + "\n")
from collections import Counter
for scen in scens:
    for c in cfgs:
        k = sum(1 for r in kept if r['scen'] == scen and r['cfg'] == c)
        d = [(t, rp, why) for (t, s_, c_, rp, why) in dropped if s_ == scen and c_ == c]
        print(f"  {scen:<10} {c:<8} importadas={k}  descartadas={len(d)}" + ("  (" + ", ".join(f"rep{rp}:{why}" for _, rp, why in d) + ")" if d else ""))
PYSEED
fi

[[ $VANILLA == 1 ]] || { old_r=$(cat $K_R); old_x=$(cat $K_X); old_l=$(cat $K_L); }
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
NTF=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat $NTF 2>/dev/null || echo ""); [[ -n "$old_nt" ]] && echo "$NT" > $NTF
HP=(); SP=""
stop_bg() {
    local p
    for p in "${HP[@]:-}" $SP; do [[ -n "$p" ]] && { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done
    HP=(); SP=""
}
restore() {
    stop_bg
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
sampler() {   # $1 = arquivo; uma linha "temp pMHz eMHz watts" por segundo (watts = RAPL do ultimo segundo)
    local c p e e0 e1 t0 t1 w
    e0=$(cat $RAPLE); t0=$(date +%s.%N)
    while :; do
        sleep 1
        p=0; e=0
        for c in 0 1 2 3 4 5 6 7; do p=$(( p + $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq) )); done
        for c in $(seq 8 23); do e=$(( e + $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq) )); done
        e1=$(cat $RAPLE); t1=$(date +%s.%N)
        w=$(awk -v a="$e0" -v b="$e1" -v m="$RAPLM" -v t0="$t0" -v t1="$t1" 'BEGIN{d=b-a; if (d<0) d+=m; dt=t1-t0; if (dt>0) printf "%.1f", d/1e6/dt; else print 0}')
        echo "$(temp_c) $(( p / 8000 )) $(( e / 16000 )) $w" >> "$1"
        e0=$e1; t0=$t1
    done
}
scen_n1() { [[ "$1" == relaxed ]] && echo 8 || echo 16; }

PREF=0
calibrate() {  # scen -> aquece com a carga do cenario e retorna no 1o segundo (apos MIN_HEAT) com potencia < START_W
    local scen="$1" n1 sf t=0 n w ok=0
    n1=$(scen_n1 "$scen"); sf=$(mktemp)
    apply "${CFGS[0]}"
    stress-ng --cpu 8     --cpu-method rand48 --timeout "$((CAL_MAX + 5))s" --quiet >/dev/null 2>&1 & HP+=($!)
    stress-ng --cpu "$n1" --cpu-method div16  --timeout "$((CAL_MAX + 5))s" --quiet >/dev/null 2>&1 & HP+=($!)
    sampler "$sf" & SP=$!
    echo "  [$scen] aquecendo ate a potencia do pacote ficar < ${START_W} W (a partir de ${MIN_HEAT}s de carga, max ${CAL_MAX}s)..."
    while (( t < CAL_MAX )); do
        sleep 1; t=$(( t + 1 ))
        n=$(wc -l < "$sf"); (( n > MIN_HEAT )) || continue
        w=$(tail -1 "$sf" | awk '{print $4}')
        (( t % 10 == 0 )) && echo "      t=${t}s  potencia=${w} W  T=$(temp_c)C"
        if awk -v w="$w" -v lim="$START_W" 'BEGIN{exit !(w+0 < lim+0)}'; then ok=1; break; fi
    done
    stop_bg; rm -f "$sf"
    PREF=$START_W
    if (( ok )); then echo "  [$scen] t=${t}s: potencia ${w} W < ${START_W} W -> comecando as runs"
    else echo "  [$scen] AVISO: potencia nao ficou < ${START_W} W em ${CAL_MAX}s; comecando as runs mesmo assim"; fi
}

measure() {  # scen cfgspec rep try -> 0 se aceita (e grava em runs.csv), 1 se rejeitada (grava em rejected.csv)
    local scen="$1" spec="$2" rep="$3" try="$4" c n1 t2 t1 sf o2 o1 e0 e1 tt0 tt1 th0 th1 w st pw reason line
    c="${spec%%:*}"; n1=$(scen_n1 "$scen")
    apply "$spec"; sleep 2
    t2=$(mktemp); t1=$(mktemp); sf=$(mktemp)
    sampler "$sf" & SP=$!
    e0=$(cat $RAPLE 2>/dev/null || echo 0); th0=$(cat $THR 2>/dev/null || echo 0); tt0=$(date +%s.%N)
    local pin2="" pin1=""
    [[ "$c" == oracle ]] && { pin2="taskset -c 0-7"; pin1="taskset -c 8-23"; }
    $pin2 stress-ng --cpu 8     --cpu-method rand48 --timeout "${DUR}s" --metrics-brief > "$t2" 2>&1 & local p2=$!
    $pin1 stress-ng --cpu "$n1" --cpu-method div16  --timeout "${DUR}s" --metrics-brief > "$t1" 2>&1 & local p1=$!
    wait $p2 $p1 2>/dev/null
    e1=$(cat $RAPLE 2>/dev/null || echo 0); th1=$(cat $THR 2>/dev/null || echo 0); tt1=$(date +%s.%N)
    stop_bg
    w=$(awk -v a="$e0" -v b="$e1" -v m="$RAPLM" -v t0="$tt0" -v t1="$tt1" 'BEGIN{d=b-a; if (d<0) d+=m; dt=t1-t0; if (dt>0) printf "%.1f", d/1e6/dt; else print "NA"}')
    st=$(awk 'NR==1{t0=$1} {if($1>mx)mx=$1; s+=$1; p+=$2; e+=$3; n++} END{if(n) printf "%d,%d,%.1f,%.0f,%.0f", t0, mx, s/n, p/n, e/n; else print "NA,NA,NA,NA,NA"}' "$sf")
    pw=$(awk -v skip="$SKIP_S" 'NR>skip {a[++n]=$4; s+=$4; if (n==1||$4>mx) mx=$4; if (n==1||$4<mn) mn=$4}
        END{if (n<4) {print "NA,NA,NA,NA,NA"; exit} h=int(n/2); for(i=1;i<=h;i++) s1+=a[i]; for(i=h+1;i<=n;i++) s2+=a[i];
            printf "%.1f,%.1f,%.1f,%.1f,%.1f", s/n, s1/h, s2/(n-h), mn, mx}' "$sf")
    rm -f "$sf"
    o2=$(awk '/cpu /{print $9}' "$t2"); o1=$(awk '/cpu /{print $9}' "$t1"); rm -f "$t2" "$t1"
    local wm wh1 wh2 wmin wmax; IFS=, read -r wm wh1 wh2 wmin wmax <<< "$pw"
    reason=$(awk -v m="$wm" -v a="$wh1" -v b="$wh2" -v mn="$wmin" -v mx="$wmax" -v pref="$START_W" -v flat="$FLAT_W" -v band="$BAND_W" \
        'BEGIN{if (m=="NA") {print "sem-amostras"; exit} d=a-b; if (d<0) d=-d;
               if (m>pref) print "boost"; else if (d>flat) print "deriva"; else if (mx-mn>band) print "oscila"; else print "ok"}')
    [[ -n "${o2:-}" && -n "${o1:-}" ]] || reason="sem-vazao"
    line="${scen},${c},${rep},${try},${o2:-NA},${o1:-NA},${st},${w},$(( th1 - th0 )),${wh1},${wh2},${wmin},${wmax},${PREF}"
    printf "  %-10s rep %d try %d %-8s T=%sC %sW (1a/2a metade %s/%s, Pref %s) cls2/w=%s cls1/w=%s -> %s\n" "$scen" "$rep" "$try" "$c" \
        "$(echo $st | cut -d, -f2)" "$w" "$wh1" "$wh2" "$PREF" \
        "$(awk -v o="${o2:-0}" 'BEGIN{printf "%.0f", o/8}')" "$(awk -v o="${o1:-0}" -v n="$n1" 'BEGIN{printf "%.0f", o/n}')" "$reason"
    if [[ "$reason" == ok ]]; then echo "$line" >> "$OUT/runs.csv"; return 0; fi
    echo "$line,$reason" >> "$OUT/rejected.csv"; return 1
}

echo "aquecimento inicial de 20s (descartado)..."
stress-ng --cpu 24 --cpu-method rand48 --timeout 20s --quiet >/dev/null 2>&1

T0=$SECONDS; TIMEOUT=
echo "=== vazao estabilizada: cenarios [$SCEN] x ${#CFGS[@]} configs x ${REPS} runs aceitas x ${DUR}s (no_turbo=$NT) ==="
for scen in $SCEN; do
    cal=0
    for rep in $(seq 1 "$REPS"); do
        order=("${CFGS[@]}")
        if (( rep % 2 == 0 )); then   # inverte a ordem nas rodadas pares
            order=(); for (( i=${#CFGS[@]}-1; i>=0; i-- )); do order+=("${CFGS[i]}"); done
        fi
        for spec in "${order[@]}"; do
            if awk -F, -v s="$scen" -v c="${spec%%:*}" -v r="$rep" '$1==s && $2==c && $3==r {f=1} END{exit !f}' "$OUT/runs.csv"; then continue; fi
            (( cal )) || { calibrate "$scen"; cal=1; }
            ok=0; try=0; fails=0
            while :; do
                try=$(( try + 1 ))
                if measure "$scen" "$spec" "$rep" "$try"; then ok=1; break; fi
                fails=$(( fails + 1 ))
                if (( MAX_TRY > 0 && try >= MAX_TRY )); then break; fi
                if (( SECONDS - T0 > MAX_MIN * 60 )); then TIMEOUT=1; break; fi
                (( fails % RECAL_EVERY == 0 )) && { echo "  [$scen] $fails rejeicoes seguidas em ${spec%%:*} rep $rep: recalibrando Pref"; calibrate "$scen"; }
            done
            [[ $ok == 1 ]] || echo "  AVISO: [$scen] ${spec%%:*} rep $rep sem run estabilizada ($try tentativas${TIMEOUT:+; teto de ${MAX_MIN} min atingido}); celula fica com n menor"
            [[ -n "$TIMEOUT" ]] && break 3
        done
    done
    (( cal )) || echo "  [$scen] completo com as runs anteriores: nada a medir"
done

python3 -I - "$OUT" <<'E' | tee "$OUT/summary.txt"
import csv, statistics as st, sys
out = sys.argv[1]
allrows = [r for r in csv.DictReader(open(f"{out}/runs.csv")) if 'NA' not in (r['cls2_total'], r['cls1_total'])]
rej = list(csv.DictReader(open(f"{out}/rejected.csv")))
sd = lambda v: st.stdev(v) if len(v) > 1 else 0
for scen in dict.fromkeys(r['scen'] for r in allrows):
    n1 = 8 if scen == 'relaxed' else 16
    rows = [r for r in allrows if r['scen'] == scen]
    ncfg = len({r['cfg'] for r in rows})
    full = {rep for rep in {r['rep'] for r in rows} if sum(1 for r in rows if r['rep'] == rep) == ncfg}
    rows = [r for r in rows if r['rep'] in full]   # so rodadas completas
    cfgs = list(dict.fromkeys(r['cfg'] for r in rows))
    def pw(c, k, n): return [float(r[k]) / n for r in rows if r['cfg'] == c]
    print(f"\n##### cenario {scen}: 8 cls2 + {n1} cls1 ({len(full)} rodadas completas, so runs com potencia estabilizada) #####")
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
    print("potencia e condicoes (media das runs aceitas): cfg  Pref  W_med  W_1a_met  W_2a_met  T_max  P_MHz  E_MHz  throttle")
    for c in cfgs:
        rc = [r for r in rows if r['cfg'] == c]
        def m(k, f="{:6.1f}"):
            v = [float(r[k]) for r in rc if r[k] not in ('NA', '')]
            return f.format(st.mean(v)) if v else "   n/d"
        nseed = sum(1 for r in rc if r['try'] == '0')
        print(f"  {c:<8} {m('pref', '{:5.1f}')} {m('watts')} {m('w_h1', '{:8.1f}')} {m('w_h2', '{:8.1f}')} {m('t_max', '{:6.0f}')} {m('p_mhz', '{:6.0f}')} {m('e_mhz', '{:6.0f}')} {sum(int(r['throttle']) for r in rc if r['throttle'] not in ('NA', '')):6d}   ({nseed} anteriores + {len(rc) - nseed} novas)")
    rj = [r for r in rej if r['scen'] == scen]
    if rj:
        from collections import Counter
        cnt = Counter((r['cfg'], r['reason']) for r in rj)
        print("rejeitadas por instabilidade de potencia: " + ", ".join(f"{c}/{why}={n}" for (c, why), n in sorted(cnt.items())))
    else:
        print("rejeitadas: nenhuma")
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
