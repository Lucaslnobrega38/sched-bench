#!/bin/bash
# e_sweep.sh — vazão de TODOS os métodos do stress-ng num E-core (cpu8), com
# contadores do perf em volta de cada um. Mesma pinagem e duração do
# class_sweep.sh (o lado "e" do main_class_sweep, medido no kernel main SEM
# shadow), então o resultado é pareável método a método com ele.
#
# Rode com o kernel de shadow e o stash DESLIGADO (shadow puro):
#   cat /sys/kernel/debug/ipcc_stash/enabled   # tem que ser 0
#
# Uso: sudo ./e_sweep.sh <tag> [método ...]
#   sem métodos extras: todos os de `stress-ng --cpu-method list`
# Saída: 275hx/results/<tag>/e_sweep/summary.csv e raw/<método>.perf
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
source "$(dirname "$0")/isolate_cpu.sh"

TAG="${1:?uso: sudo ./e_sweep.sh <tag> [metodo ...]}"
shift || true
DUR="${DUR:-5}"
ECPU=8
PERF="${PERF:-perf}"
EVENTS="task-clock,cycles,instructions,context-switches,cpu-migrations,page-faults"

command -v "$PERF" >/dev/null || { echo "perf não encontrado (PERF=/caminho/perf)"; exit 1; }
$PERF stat -e task-clock true >/dev/null 2>&1 || { echo "perf não roda neste kernel — compile o da árvore (tools/perf)"; exit 1; }

if [[ $# -gt 0 ]]; then
    METHODS=("$@")
else
    mapfile -t METHODS < <(stress-ng --cpu-method list 2>&1 \
        | sed 's/cpu-method must be one of://' \
        | tr ' ' '\n' | sed '/^$/d' | grep -v '^all$')
fi

OUT="$(cd "$(dirname "$0")/../.." && pwd)/275hx/results/${TAG}/e_sweep"
mkdir -p "$OUT/raw"
SUMMARY="${OUT}/summary.csv"
echo "method,ops_s,task_clock_ms,cycles,instructions,ipc,ctx_switches,cpu_migrations,page_faults" > "$SUMMARY"

# registra se o stash estava ligado: muda o que o resultado significa
STASH=/sys/kernel/debug/ipcc_stash/enabled
echo "stash_enabled=$(cat $STASH 2>/dev/null || echo n/a)" > "$OUT/meta.txt"
uname -srv >> "$OUT/meta.txt"
echo "duration_s=${DUR}" >> "$OUT/meta.txt"

# mesmo envelope do pe_delta.sh: governor performance, turbo off, restaura ao sair
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
NT=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat "$NT" 2>/dev/null || echo "")
[[ -n "$old_nt" ]] && echo 1 > "$NT"
restore() {
    restore_affinity
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g"; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > "$NT"
}
trap restore EXIT

# esvazia a cpu testada de todas as tasks fair; o stress-ng é fixado nela depois
evacuate_cpu "$ECPU"
echo "evacuated_cpu=${ECPU} moved=${EVAC_MOVED} unmovable=${EVAC_STUCK}" >> "$OUT/meta.txt"

# valor de um evento no CSV do perf (-x,): campo 1 = valor, campo 3 = nome
ev() { awk -F, -v e="$2" '$3 ~ "^"e {gsub(/[^0-9.]/,"",$1); print $1}' "$1" | head -1; }

echo "=== e_sweep: ${#METHODS[@]} métodos, ${DUR}s cada, cpu${ECPU}, stash=$(cat $STASH 2>/dev/null || echo n/a) ==="
for m in "${METHODS[@]}"; do
    tmp=$(mktemp); raw="$OUT/raw/${m}.perf"
    taskset -c "$ECPU" $PERF stat -x, -e "$EVENTS" -o "$raw" -- \
        stress-ng --cpu 1 --cpu-method "$m" --timeout "${DUR}s" --metrics-brief > "$tmp" 2>&1 || true
    ops=$(awk '/cpu /{print $9}' "$tmp"); rm -f "$tmp"

    tc=$(ev "$raw" task-clock); cy=$(ev "$raw" cycles); in=$(ev "$raw" instructions)
    ipc=$(awk -v c="${cy:-0}" -v i="${in:-0}" 'BEGIN{ if (c>0) printf "%.3f", i/c; else print "NA" }')
    echo "${m},${ops:-NA},${tc:-NA},${cy:-NA},${in:-NA},${ipc},$(ev "$raw" context-switches),$(ev "$raw" cpu-migrations),$(ev "$raw" page-faults)" >> "$SUMMARY"
    printf "  %-18s %10s ops/s  ipc=%s\n" "$m" "${ops:-NA}" "$ipc"
done
echo "=== concluído → ${SUMMARY} ==="
