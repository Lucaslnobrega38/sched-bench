#!/bin/bash
# e_profile.sh — onde o tempo do E-core (cpu8) vai, para métodos escolhidos do
# stress-ng. Duas visões ao mesmo tempo:
#   1. perf record do cpu8 inteiro (-C 8), com pilha: kernel + usuário.
#   2. function_profile do ftrace, filtrado nas funções do shadow: contagem e
#      tempo por chamada NO cpu8 (trace_stat/function8).
# O ftrace tem overhead próprio: use os tempos para comparar funções entre si,
# não como valor absoluto. A vazão de referência é a do e_sweep.sh.
#
# Uso: sudo ./e_profile.sh <tag> <método> [método ...]
# Saída: 275hx/results/<tag>/e_profile/<método>.{report,dso,fprofile}.txt
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }

TAG="${1:?uso: sudo ./e_profile.sh <tag> <metodo> [metodo ...]}"
shift
[[ $# -ge 1 ]] || { echo "passe ao menos um método"; exit 1; }
DUR=5
ECPU=8
PERF="${PERF:-perf}"
TR=/sys/kernel/debug/tracing

command -v "$PERF" >/dev/null || { echo "perf não encontrado (PERF=/caminho/perf)"; exit 1; }
[[ -w "$TR/set_ftrace_filter" ]] || { echo "sem acesso a $TR (debugfs?)"; exit 1; }
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true

# funções do caminho do shadow que importam; as que não existirem como
# símbolo rastreável (inlined, estáticas removidas) são ignoradas.
CANDIDATES=(shadow_kernel_clone shadow_copy_process dup_mmap copy_page_range
            wake_up_new_task ipcc_shadow_fork_work ipcc_classify_submit
            ipcc_classify_tick ipcc_classify_dwell intel_update_ipcc
            ipcc_stash_link_shadow ipcc_stash_wrprotect_target
            ipcc_stash_unlink_shadow ipcc_stash_log ipcc_stash_populate
            exit_mmap)

OUT="$(cd "$(dirname "$0")/../.." && pwd)/275hx/results/${TAG}/e_profile"
mkdir -p "$OUT"
{ echo "stash_enabled=$(cat /sys/kernel/debug/ipcc_stash/enabled 2>/dev/null || echo n/a)"; uname -srv; } > "$OUT/meta.txt"

# mesmo envelope do pe_delta.sh
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
NT=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat "$NT" 2>/dev/null || echo "")
[[ -n "$old_nt" ]] && echo 1 > "$NT"
restore() {
    echo 0 > "$TR/function_profile_enabled" 2>/dev/null || true
    : > "$TR/set_ftrace_filter" 2>/dev/null || true
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g"; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > "$NT"
}
trap restore EXIT

echo 0 > "$TR/function_profile_enabled" 2>/dev/null || true
: > "$TR/set_ftrace_filter"
ok=()
for f in "${CANDIDATES[@]}"; do
    if echo "$f" >> "$TR/set_ftrace_filter" 2>/dev/null; then ok+=("$f"); fi
done
echo "funções rastreadas: ${ok[*]:-nenhuma}" | tee "$OUT/funcs.txt"

for m in "$@"; do
    echo "=== $m ==="
    echo 0 > "$TR/function_profile_enabled"; echo 1 > "$TR/function_profile_enabled"
    $PERF record -q -C "$ECPU" -F 2999 -g -o "$OUT/${m}.data" -- \
        taskset -c "$ECPU" stress-ng --cpu 1 --cpu-method "$m" --timeout "${DUR}s" >/dev/null 2>&1 || true
    echo 0 > "$TR/function_profile_enabled"

    cat "$TR/trace_stat/function${ECPU}" > "$OUT/${m}.fprofile.txt" 2>/dev/null || true
    $PERF report -q -i "$OUT/${m}.data" --stdio --no-children --sort sym 2>/dev/null | head -60 > "$OUT/${m}.report.txt" || true
    $PERF report -q -i "$OUT/${m}.data" --stdio --no-children --sort dso 2>/dev/null | head -10 > "$OUT/${m}.dso.txt" || true
    echo "  dso:"; sed 's/^/    /' "$OUT/${m}.dso.txt"
    echo "  shadow (cpu${ECPU}):"; sed 's/^/    /' "$OUT/${m}.fprofile.txt" | head -12
done
echo "=== concluído → $OUT ==="
