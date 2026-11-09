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
#   PCPU/ECPU (env, default 0/8): sudo env PCPU=2 ECPU=11 ./class_sweep.sh <tag>
# Saída: 275hx/results/<tag>/class_sweep/{p,e}_<metodo>.txt (ops/s) e
#        275hx/results/<tag>/class_sweep/summary.csv
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }

TAG="${1:?uso: sudo ./class_sweep.sh <tag> [metodo ...]}"
shift || true
DUR=5
PCPU="${PCPU:-0}"
ECPU="${ECPU:-8}"
TRACE=/sys/kernel/tracing/trace
TRACE_ON=/sys/kernel/tracing/tracing_on
[[ -r "$TRACE" ]] || { TRACE=/sys/kernel/debug/tracing/trace; TRACE_ON=/sys/kernel/debug/tracing/tracing_on; }

[[ -r "$TRACE" ]] || { echo "sem acesso a $TRACE — kernel sem CONFIG_IPC_CLASSES=y, tracefs não montado, ou faltou sudo"; exit 1; }

# Esvazia PCPU/ECPU antes de tudo: migra pra fora qualquer thread não-kernel
# atualmente ali (kworker/migration/ksoftirqd/idle_inject/cpuhp per-cpu não
# são migráveis e ficam de fora). Restaura a afinidade original ao sair.
declare -A _orig_affinity
_clear_cpu() {
    local cpu="$1" pid mask
    for pid in $(ps -eLo psr,lwp --no-headers | awk -v c="$cpu" '$1==c{print $2}' | sort -u); do
        [[ -d "/proc/$pid" ]] || continue
        mask=$(taskset -p "$pid" 2>/dev/null | awk -F': ' '{print $2}') || continue
        [[ -n "$mask" ]] || continue
        _orig_affinity[$pid]="$mask"
        taskset -p "$((0xffffffff & ~(1<<cpu)))" "$pid" &>/dev/null || true
    done
}
_restore_affinity() {
    local pid
    for pid in "${!_orig_affinity[@]}"; do
        [[ -d "/proc/$pid" ]] && taskset -p "${_orig_affinity[$pid]}" "$pid" &>/dev/null || true
    done
}
echo "Esvaziando cpu${PCPU} e cpu${ECPU} (afinidade original é restaurada ao sair)..."
_clear_cpu "$PCPU"
_clear_cpu "$ECPU"

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
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    v=$(cat "$g" 2>/dev/null) || continue   # cpu offline (nosmt): sysfs fica "busy"
    old_gov[$g]="$v"
    echo performance > "$g" 2>/dev/null || true
done
NT=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat "$NT" 2>/dev/null || echo "")
[[ -n "$old_nt" ]] && echo 1 > "$NT"
restore() {
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g" 2>/dev/null || true; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > "$NT"
    _restore_affinity
}
trap restore EXIT

_run_one() {
    local method="$1" name="$2" cpu="$3"
    local ops tmp
    tmp=$(mktemp)
    # tracing só na janela exata do teste (mesmo padrão do
    # probe_ipcc_classes_275hx.sh, validado) — não deixa capturando entre
    # métodos, mesmo a filtragem por pid já devendo bastar sozinha.
    : > "$TRACE"
    echo 1 > "$TRACE_ON"
    taskset -c "$cpu" stress-ng --cpu 1 --cpu-method "$method" \
        --timeout "${DUR}s" --metrics-brief > "$tmp" 2>&1 &
    local launcher=$!
    sleep 0.3
    # cpu=X do trace pega QUALQUER processo escalonado ali (ex.: o terminal),
    # não só o worker — filtra pelo pid real do stress-ng, não pela cpu.
    local worker
    worker=$(pgrep -P "$launcher" | head -1) || true
    [[ -n "$worker" ]] || worker="$launcher"
    wait "$launcher" 2>/dev/null || true
    echo 0 > "$TRACE_ON"
    ops=$(awk '/cpu /{print $9}' "$tmp")
    rm -f "$tmp"
    echo "${ops:-NA}" > "${OUT}/${name}_${method}.txt"

    local classes final ntrans lines raw
    if [[ "$name" == "p" ]]; then
        # aceita tanto "IPCC UPDATE: pid=N ... class = N" (formato atual em
        # sched_ipcc.c) quanto um eventual "IPCC CLASS ... -> N" de outra branch.
        # Uma vez confirmada, o commit reemite a MESMA classe a cada tick (não
        # é uma transição de verdade) — comprime em runs (NxK) e só conta
        # transição real (mudança de valor), senão o CSV incha e o número não
        # significa nada.
        lines=$(grep -E "IPCC (UPDATE|CLASS): pid=${worker}\b" "$TRACE" 2>/dev/null) || true
        raw=$(echo "$lines" | sed -nE 's/.*(class ?= ?|-> ?)([0-9]+).*/\2/p')
        classes=$(echo "$raw" | awk '
            NF==0 { next }
            $0==prev { cnt++; next }
            NR>1   { printf "%s%sx%d", (out?"/":""), prev, cnt; out=1 }
            { prev=$0; cnt=1 }
            END { if (prev != "") printf "%s%sx%d", (out?"/":""), prev, cnt }')
        ntrans=$(echo "$classes" | awk -F/ 'NF==1 && $1==""{print 0; next}{print NF-1}')
        final=$(echo "$raw" | tail -1)
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
