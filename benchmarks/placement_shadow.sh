#!/bin/bash
# placement_shadow.sh — placement da bateria no kernel com o shadow novo, com os
# knobs fixados e registrados no resultado, e restaurados ao sair (mesmo com Ctrl-C).
#
# Uso: sudo ./benchmarks/placement_shadow.sh <tag> [runs=15] [read_us=250] [pop_ticks=8]
#   runs: a bateria roda o DOBRO por cenário (15 -> 30 de relaxed e 30 de contention)
# Env: NO_TURBO=0 (padrão aqui: turbo ligado, governor performance pelo preflight)
#      NO_TURBO=1 desliga o turbo
# Saída: results/<tag>/ (como run_battery.sh) e results/<tag>/raw/knobs_during_run.txt
set -u
[[ $EUID -eq 0 ]] || { echo "rode com sudo: sudo $0 <tag> [runs]"; exit 1; }
TAG="${1:?uso: sudo ./benchmarks/placement_shadow.sh <tag> [runs=15] [read_us=250] [pop_ticks=8]}"
RUNS="${2:-15}"; READ_US="${3:-250}"; POP_TICKS="${4:-8}"
R=/sys/kernel/debug/ipcc_shadow_read_us; X=/sys/kernel/debug/ipcc_pop_ticks
[[ -w $R && -w $X ]] || { echo "kernel sem o classificador novo (faltam $R e $X)"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/results/$TAG"
mkdir -p "$OUT/raw"
LOGF="$OUT/raw/knobs_during_run.txt"

old_r=$(cat "$R"); old_x=$(cat "$X")
restore() { echo "$old_r" > "$R"; echo "$old_x" > "$X"; echo "knobs restaurados: read_us=$old_r pop_ticks=$old_x"; }
trap restore EXIT INT TERM

echo "$READ_US" > "$R"; echo "$POP_TICKS" > "$X"
echo 1 > /sys/kernel/debug/ipcc_classifier_reset
{
    echo "início: $(date +%F_%T)"
    echo "kernel: $(uname -r)"
    echo "read_us=$(cat "$R") pop_ticks=$(cat "$X") min_lag_ms=$(cat /sys/kernel/debug/ipcc_min_lag_ms)"
    echo "NO_TURBO=${NO_TURBO:-0}  runs=$RUNS (x2 por cenário)"
} >> "$LOGF"
cat "$LOGF"

cd "$ROOT" && NO_TURBO="${NO_TURBO:-0}" ./run_battery.sh --kernel "$TAG" --phases placement --runs "$RUNS"

{
    echo "fim: $(date +%F_%T)"
    echo "read_us=$(cat "$R") pop_ticks=$(cat "$X")"
    awk '$1 ~ /^(inserted|pushed|popped_tick|popped_idle|start_late|discarded|fork_failed)$/' /sys/kernel/debug/ipcc_classifier_stats
    grep '^pq ' /sys/kernel/debug/ipcc_classifier_stats
} >> "$LOGF"
echo "resultado: $OUT  (comparar: python3 analysis/battery_compare.py orig_nosmt $TAG)"
