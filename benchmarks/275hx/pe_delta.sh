#!/bin/bash
# pe_delta.sh — vazão bruta de div16/rand48 num P-core (cpu0) e num E-core (cpu8)
# Uso: sudo ./benchmarks/275hx/pe_delta.sh <tag>      (ex: sudo ./benchmarks/275hx/pe_delta.sh original)
# Mesmo envelope do preflight do bench: governor performance, turbo desligado,
# restaurados ao sair. REPS repetições por (core, método), 15s cada.
# Saída: 275hx/results/<tag>/pe_delta.txt  (linhas: metodo core rep ops_s)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
TAG="${1:?uso: sudo ./benchmarks/275hx/pe_delta.sh <tag>}"
REPS=3; DUR=15; PCPU=0; ECPU=8
OUT="$(cd "$(dirname "$0")/../.." && pwd)/275hx/results/${TAG}"
mkdir -p "$OUT"; : > "${OUT}/pe_delta.txt"

NT=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat "$NT" 2>/dev/null || echo "")
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
[[ -n "$old_nt" ]] && echo 1 > "$NT"
restore() {
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g"; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > "$NT"
}
trap restore EXIT

for m in div16 rand48; do
  for r in $(seq 1 $REPS); do
    for pair in "P:$PCPU" "E:$ECPU"; do
      name=${pair%%:*}; cpu=${pair##*:}
      ops=$(taskset -c "$cpu" stress-ng --cpu 1 --cpu-method "$m" --timeout "${DUR}s" --metrics-brief 2>&1 | awk '/cpu /{print $9}')
      echo "$m $name $r $ops" | tee -a "${OUT}/pe_delta.txt"
    done
  done
done

echo "=== média por (método, core) ==="
awk '{s[$1" "$2]+=$4; n[$1" "$2]++} END{for(k in s) printf "%s %.1f\n", k, s[k]/n[k]}' "${OUT}/pe_delta.txt" | sort
