#!/bin/bash
# class_sweep_ws.sh: P/E delta e classe IPC em função do working set.
# Para cada stressor com tamanho ajustável e cada tamanho (KiB), 5 s num P-core e 5 s
# num E-core; registra ops/s e a classe confirmada em debounce_and_update_class().
# Mesmo ambiente do class_sweep.sh (kernel main com trace_printk, governor performance, turbo off).
# Uso: sudo env PCPU=2 ECPU=11 ./class_sweep_ws.sh <tag> [stressor ...]
# Tamanhos (KiB) por env: SIZES="256 2048 8192 65536"; DUR (padrão 5 s).
# Saída: 275hx/results/<tag>/class_sweep_ws/summary.csv (stressor,size_kib,core,ops_s,classes_seen,final_class,n_transitions)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }

TAG="${1:?uso: sudo ./class_sweep_ws.sh <tag> [stressor ...]}"
shift || true
DUR="${DUR:-5}"
SIZES="${SIZES:-256 2048 8192 65536}"
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
# Desativa SMT se estiver ativo (restaurado ao sair). Antes do esvaziamento, pois isso muda quais CPUs estão online.
SMT_CTL=/sys/devices/system/cpu/smt/control
old_smt=$(cat "$SMT_CTL" 2>/dev/null || echo "")
if [[ "$old_smt" == "on" ]]; then
    echo "SMT ativo: desativando (será restaurado ao sair)..."
    echo off > "$SMT_CTL"
    trap 'echo on > "$SMT_CTL"' EXIT   # garante a restauração mesmo se algo falhar antes do trap final
fi
for c in "$PCPU" "$ECPU"; do
    [[ "$c" -eq 0 ]] && continue
    [[ "$(cat /sys/devices/system/cpu/cpu${c}/online 2>/dev/null)" == "0" ]] && {
        echo "cpu${c} ficou offline com SMT desligado (era irmão SMT); escolha outro PCPU/ECPU"
        [[ "$old_smt" == "on" ]] && echo on > "$SMT_CTL"
        exit 1
    }
done

echo "Esvaziando cpu${PCPU} e cpu${ECPU} (afinidade original é restaurada ao sair)..."
_clear_cpu "$PCPU"
_clear_cpu "$ECPU"

if [[ $# -gt 0 ]]; then
    STRESSORS=("$@")
else
    STRESSORS=(bsearch heapsort qsort mergesort radixsort shellsort hsearch matrix stream vm)
fi

# args do stressor para um working set de KiB kibibytes. Sorts/bsearch limitados a 8 MiB e hsearch/matrix a 16 MiB:
# acima disso há poucas operações na janela de medição
_args() {
    local st="$1" kib="$2"
    case "$st" in
        bsearch|heapsort|qsort|mergesort|radixsort|shellsort)
            (( kib > 8192 )) && return 1
            echo "--${st}-size $(( kib * 256 ))" ;;
        hsearch) (( kib > 16384 )) && return 1; echo "--hsearch-size $(( kib * 64 ))" ;;
        matrix)  (( kib > 16384 )) && return 1
                 echo "--matrix-size $(awk -v k="$kib" 'BEGIN{printf "%d", sqrt(k*1024/24)}')" ;;
        stream)  echo "--stream-l3-size ${kib}k" ;;
        vm)      echo "--vm-bytes ${kib}k --vm-method read64" ;;
        *)       return 1 ;;
    esac
}

OUT="$(cd "$(dirname "$0")" && pwd)/275hx/results/${TAG}/class_sweep_ws"
mkdir -p "$OUT"
SUMMARY="${OUT}/summary.csv"
[[ -f "$SUMMARY" ]] || echo "stressor,size_kib,core,ops_s,classes_seen,final_class,n_transitions" > "$SUMMARY"

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
    [[ "$old_smt" == "on" ]] && echo on > "$SMT_CTL"
}
trap restore EXIT

_run_one() {
    local method="$1" kib="$2" name="$3" cpu="$4" args="$5"
    local ops tmp
    tmp=$(mktemp)
    # tracing só na janela exata do teste (mesmo padrão do
    # probe_ipcc_classes_275hx.sh, validado) — não deixa capturando entre
    # métodos, mesmo a filtragem por pid já devendo bastar sozinha.
    : > "$TRACE"
    echo 1 > "$TRACE_ON"
    taskset -c "$cpu" stress-ng --"$method" 1 $args \
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
    ops=$(awk -v n="$method" '/metrc/ && $4==n {print $9}' "$tmp")
    rm -f "$tmp"
    echo "${ops:-NA}" > "${OUT}/${name}_${method}_${kib}k.txt"

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

    echo "${method},${kib},${name},${ops:-NA},${classes},${final},${ntrans}" >> "$SUMMARY"
    printf "  %-10s %7sK %s: %8s ops/s  classes=%s\n" "$method" "$kib" "$name" "${ops:-NA}" "${classes:-—}"
}

echo "=== class_sweep_ws: ${#STRESSORS[@]} stressors, tamanhos (KiB): ${SIZES}, ${DUR}s cada, P=cpu${PCPU} E=cpu${ECPU} ==="
for st in "${STRESSORS[@]}"; do
    for kib in $SIZES; do
        args=$(_args "$st" "$kib") || continue
        _run_one "$st" "$kib" p "$PCPU" "$args"
        _run_one "$st" "$kib" e "$ECPU" "$args"
    done
done

echo "=== concluído → ${SUMMARY} ==="
