#!/bin/bash
# class_sweep.sh — caracterização de workload: pra cada método do stress-ng,
# 5s num P-core (cpu0) e 5s num E-core (cpu8), vazão (ops/s) e a classe HFI
# que o Thread Director de fato atribui (lida do log de transição confirmada
# em debounce_and_update_class(), branch main — ver context.md, seção
# "Log de classe confirmada"). Precisa do kernel main com CONFIG_IPC_CLASSES=y
# e o trace_printk aplicado, rodando.
#
# Classe só é atribuída de verdade em P-core (ITD não classifica task que
# nunca roda em P-core — é o próprio problema que a shadow classification
# resolve). Em E-core o script só registra vazão; a coluna de classe fica
# vazia e não é um bug.
#
# Uso: sudo ./class_sweep.sh <tag> [método ...]
#   sem métodos extras: varre TODOS os métodos de `stress-ng --cpu-method list`
# Saída: 275hx/results/<tag>/class_sweep/{p,e}_<metodo>.txt (ops/s) e
#        275hx/results/<tag>/class_sweep/summary.csv
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }

TAG="${1:?uso: sudo ./class_sweep.sh <tag> [metodo ...]}"
shift || true
DUR=5
PCPU=0
ECPU=8
TRACE=/sys/kernel/debug/tracing/trace
TRACE_ON=/sys/kernel/debug/tracing/tracing_on

[[ -r "$TRACE" ]] || { echo "sem acesso a $TRACE — kernel sem CONFIG_IPC_CLASSES=y ou debugfs não montado"; exit 1; }

if [[ $# -gt 0 ]]; then
    METHODS=("$@")
else
    mapfile -t METHODS < <(stress-ng --cpu-method list 2>&1 \
        | sed 's/cpu-method must be one of://' \
        | tr ' ' '\n' | sed '/^$/d' | grep -v '^all$')
fi

OUT="$(cd "$(dirname "$0")" && pwd)/275hx/results/${TAG}/class_sweep"
mkdir -p "$OUT"
SUMMARY="${OUT}/summary.csv"
[[ -f "$SUMMARY" ]] || echo "method,core,ops_s,classes_seen,final_class,n_transitions" > "$SUMMARY"

# mesmo envelope de pe_delta.sh: governor performance, turbo off, restaura ao sair
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
NT=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat "$NT" 2>/dev/null || echo "")
[[ -n "$old_nt" ]] && echo 1 > "$NT"
restore() {
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g"; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > "$NT"
}
trap restore EXIT

echo 1 > "$TRACE_ON" 2>/dev/null || true

_run_one() {
    local method="$1" name="$2" cpu="$3"
    local ops tmp
    tmp=$(mktemp)
    : > "$TRACE"   # limpa o buffer antes do run — só a janela deste worker
    taskset -c "$cpu" stress-ng --cpu 1 --cpu-method "$method" \
        --timeout "${DUR}s" --metrics-brief > "$tmp" 2>&1 || true
    ops=$(awk '/cpu /{print $9}' "$tmp")
    rm -f "$tmp"
    echo "${ops:-NA}" > "${OUT}/${name}_${method}.txt"

    local classes final ntrans
    if [[ "$name" == "p" ]]; then
        # linhas "... 0 -> 2" pra esse cpu; extrai a sequência de classes novas
        classes=$(grep "IPCC CLASS" "$TRACE" 2>/dev/null | grep "cpu=${cpu} " \
            | sed -n 's/.*-> \([0-9]\+\).*/\1/p' | tr '\n' '/' | sed 's/\/$//')
        ntrans=$(grep "IPCC CLASS" "$TRACE" 2>/dev/null | grep -c "cpu=${cpu} " || echo 0)
        final="${classes##*/}"
    else
        classes=""; final=""; ntrans=0
    fi

    echo "${method},${name},${ops:-NA},${classes},${final},${ntrans}" >> "$SUMMARY"
    printf "  %-16s %s: %8s ops/s  classes=%s\n" "$method" "$name" "${ops:-NA}" "${classes:-—}"
}

echo "=== class_sweep: ${#METHODS[@]} métodos, ${DUR}s cada, P=cpu${PCPU} E=cpu${ECPU} ==="
for m in "${METHODS[@]}"; do
    _run_one "$m" p "$PCPU"
    _run_one "$m" e "$ECPU"
done

echo "=== concluído → ${SUMMARY} ==="
