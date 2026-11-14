#!/bin/bash
# t6_deadline_sweep.sh — o experimento empírico: para cada atraso de leitura d
# (ipcc_shadow_read_us), com um método de classe 1 e um de classe 2 nos
# E-cores, quanto da leitura é válida, quanto concorda com a classe esperada,
# quanto vive o turno e que vazão sai. d=0 desliga o timer (só o tick lê).
#
# Uso: sudo [PLOAD=1] [PFMAX=1] [DUR=5] [LAG_MS=5] [DELAYS="0 5 10 25 50 100 250"] \
#          [METHODS="rand48:2 py_float:2 py_dict:2 py_sort:2"] [WORKERS=4] ./t6_deadline_sweep.sh
# Saída: tabela na tela e $SC_OUT/sweep.csv (um ponto por linha).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t6_deadline_sweep
DUR="${DUR:-5}"
DELAYS="${DELAYS:-0 5 10 25 50 100 250}"
METHODS="${METHODS:-rand48:2 py_float:2 py_dict:2 py_sort:2}"
WORKERS="${WORKERS:-4}"
CSV="$SC_OUT/sweep.csv"
rm -f "$CSV"

# PLOAD=1: um rand48 pinado em cada P-core durante cada ponto (P "trabalhando", como no benchmark)
# PFMAX=1: scaling_min_freq dos P = scaling_max_freq (restaurado ao sair)
PLOAD="${PLOAD:-0}"; PFMAX="${PFMAX:-0}"
declare -A PF_SAVE
pfmax_set() {
    local c f
    for c in "${PARR[@]}"; do
        f=/sys/devices/system/cpu/cpu$c/cpufreq
        PF_SAVE[$c]=$(cat $f/scaling_min_freq)
        cat $f/scaling_max_freq > $f/scaling_min_freq
    done
}
pfmax_restore() {
    local c
    for c in "${!PF_SAVE[@]}"; do echo "${PF_SAVE[$c]}" > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq 2>/dev/null || true; done
}
PL_PIDS=()
pload_start() {
    local c
    for c in "${PARR[@]}"; do
        taskset -c "$c" stress-ng --cpu 1 --cpu-method rand48 --timeout "$((DUR + 4))s" >/dev/null 2>&1 &
        PL_PIDS+=($!)
    done
    sleep 1
}
pload_stop() {
    local p
    for p in "${PL_PIDS[@]:-}"; do [[ -n $p ]] && { kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; }; done
    PL_PIDS=()
}
trap 'pload_stop; pfmax_restore; sc_cleanup' EXIT
[[ $PFMAX == 1 ]] && pfmax_set
echo "   PLOAD=$PLOAD PFMAX=$PFMAX  perfil_acer=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)"

modprobe msr 2>/dev/null || true   # frequencia efetiva por APERF/MPERF (freq_busy.py)

# cargas Python (metodos py_*): um processo python3 por E-core, no lugar do stress-ng
PYDIR="$SC_OUT/work"; mkdir -p "$PYDIR"
cat > "$PYDIR/py_float.py" <<'PY'
import math
x = 0.0
while True:
    for i in range(1, 2000):
        x += math.sin(i) * math.sqrt(i)
PY
cat > "$PYDIR/py_dict.py" <<'PY'
d = {}
i = 0
while True:
    d[i % 50000] = str(i) * 3
    i += 1
PY
cat > "$PYDIR/py_sort.py" <<'PY'
import random
while True:
    a = [random.random() for _ in range(200000)]
    a.sort()
PY
start_work() {   # $1 = metodo  $2 = cpu
    case "$1" in
        py_*) taskset -c "$2" timeout "$DUR" python3 "$PYDIR/$1.py" >/dev/null 2>&1 &
              SC_BG+=($!) ;;
        *)    start_load "$1" "$2" ;;
    esac
}

# frequencia media (MHz) dos P e dos E durante a carga: amostra scaling_cur_freq a cada 0,2 s
freq_sample() {   # $1 = arquivo de saida (uma linha "P|E kHz" por cpu por amostra)
    local f="$1" c
    : > "$f"
    while :; do
        for c in "${PARR[@]}"; do echo "P $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq)" >> "$f"; done
        for c in "${EARR[@]}"; do echo "E $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq)" >> "$f"; done
        sleep 0.2
    done
}
freq_mean() { awk -v k="$2" '$1==k{s+=$2;n++} END{if(n) printf "%.0f", s/n/1000; else print "NA"}' "$1"; }

for d in $DELAYS; do
    for entry in $METHODS; do
        method=${entry%:*}; expect=${entry#*:}
        sc_knob_set ipcc_shadow_read_us "$d"
        sc_reset; sc_log_on
        [[ $PLOAD == 1 ]] && pload_start
        FQ="$SC_OUT/freq_${method}_d${d}.txt"
        freq_sample "$FQ" & FQPID=$!
        taskset -c "${EARR[-1]}" python3 -I "$SC_DIR/freq_busy.py" "$PCPUS" "$FQ.busy" 0.1 & BZPID=$!
        n=0
        for e in "${EARR[@]}"; do
            [[ $n -ge $WORKERS ]] && break
            start_work "$method" "$e"; n=$((n + 1))
        done
        wait_load
        kill "$FQPID" 2>/dev/null || true; wait "$FQPID" 2>/dev/null || true
        kill -TERM "$BZPID" 2>/dev/null || true; wait "$BZPID" 2>/dev/null || true
        pload_stop
        P_MHZ=$(freq_mean "$FQ" P); E_MHZ=$(freq_mean "$FQ" E); rm -f "$FQ"
        P_BUSY=$(sed -n 's/.*busy_mhz=\([^ ]*\).*/\1/p' "$FQ.busy" 2>/dev/null); P_BUSY=${P_BUSY:-NA}
        P_C0=$(sed -n 's/.*c0_pct=\([^ ]*\).*/\1/p' "$FQ.busy" 2>/dev/null); P_C0=${P_C0:-NA}
        rm -f "$FQ.busy"
        sleep 0.4
        wait_drained 3 || true
        sc_log_dump "$SC_OUT/trace_${method}_d${d}.txt" >/dev/null
        echo "-- d=${d}us $method (classe $expect, $n workers)  P=${P_MHZ} MHz (cpufreq)  P_ocupado=${P_BUSY} MHz (C0 ${P_C0}%)  E=${E_MHZ} MHz"
        sc_analyze --trace "$SC_OUT/trace_${method}_d${d}.txt" --read-us "$d" --expect-class "$expect" \
            --csv "$CSV" --label "d_us=$d" --label "method=$method" --label "expect=$expect" --label "p_mhz=$P_MHZ" --label "e_mhz=$E_MHZ" --label "p_busy_mhz=$P_BUSY" --label "p_c0_pct=$P_C0" \
            --no-drain-check | grep -E 'FAIL|deadline|execução|convergência|classes|pops|pop->run' || true
        rm -f "$SC_OUT/trace_${method}_d${d}.txt"   # os logs são grandes; o CSV fica
    done
done

echo
echo "== resumo (cada linha = um ponto da varredura) =="
python3 -I - "$CSV" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
cols = [("d_us", 5), ("method", 10), ("p_busy_mhz", 10), ("p_c0_pct", 8), ("p_mhz", 6), ("ends", 7), ("valid_pct", 9), ("agree_pct", 9),
        ("deadline_valid", 8), ("deadline_invalid", 9), ("deadline_not_curr", 9),
        ("cap", 4), ("start_p50_us", 9), ("exec_p50_us", 9), ("pops_per_s", 8), ("idle_pop_pct", 7)]
print("  ".join(f"{c:>{w}}" for c, w in cols))
for r in rows:
    print("  ".join(f"{r.get(c, ''):>{w}}" for c, w in cols))
print("\nvalid_pct   = % dos turnos que terminaram com alguma classe")
print("agree_pct   = % dos turnos com classe que bateram com a classe esperada do método")
print("deadline_*  = leituras do timer: válidas / inválidas / shadow fora da cpu")
PY
info "tabela completa em $CSV"
sc_finish
