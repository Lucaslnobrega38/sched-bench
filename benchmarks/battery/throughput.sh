#!/bin/bash
# lib/03_throughput.sh — Throughput (ops/s)

THROUGHPUT_DIR="${OUTDIR}/throughput"

CLS2_METHOD="rand48"
CLS1_METHOD="div16"
THROUGHPUT_DURATION=12

_bench_throughput() {
    local label="$1" n_cls2="$2" n_cls1="$3"
    local out="${THROUGHPUT_DIR}/${label}"
    mkdir -p "$out"

    local existing=0
    [[ -f "${out}/compute_ops.txt" ]] && existing=$(wc -l < "${out}/compute_ops.txt")
    if [[ "$existing" -ge "$RUNS" ]]; then
        log "  [throughput] ${label} — já completo, pulando"
        return
    fi

    local start_from=$(( existing + 1 ))
    [[ "$existing" -gt 0 ]] && log "  [throughput] ${label} — resumindo do run ${start_from}"
    log "  [throughput] ${label}: ${n_cls2} cls2 + ${n_cls1} cls1, ${THROUGHPUT_DURATION}s"

    for i in $(seq "$start_from" "$RUNS"); do
        local bg_pid=""

        if (( n_cls1 > 0 )); then
            stress-ng --cpu "$n_cls1" --cpu-method "${CLS1_METHOD}" \
                --timeout $(( THROUGHPUT_DURATION + 3 ))s --quiet &>/dev/null &
            bg_pid=$!
            sleep 0.3
        fi

        local ops
        ops=$(stress-ng --cpu "$n_cls2" --cpu-method "${CLS2_METHOD}" \
            --timeout "${THROUGHPUT_DURATION}s" --metrics-brief \
            2>&1 | awk '/cpu /{print $9}')

        [[ -n "$bg_pid" ]] && { wait "$bg_pid" 2>/dev/null || true; }

        echo "${ops:-NA}" >> "${out}/compute_ops.txt"
        printf "    run %02d/%02d: %s ops/s\n" "$i" "$RUNS" "${ops:-NA}"
    done

    log "  [throughput] ${label} → ${out}/"
}

run_throughput_tests() {
    log "=== FASE 3: THROUGHPUT ==="
    log "  cls2: ${CLS2_METHOD}  |  cls1: ${CLS1_METHOD}"
    log "  P-cores físicos: ${N_PHYSICAL_PCORES}  |  Total CPUs: ${TOTAL_CPUS}"

    local n_bg=$(( TOTAL_CPUS - N_PHYSICAL_PCORES ))

    _bench_throughput "c2_alone"       "${N_PHYSICAL_PCORES}" 0
    _bench_throughput "c2_contention"  "${N_PHYSICAL_PCORES}" "${n_bg}"

    log "Fase 3 concluída → ${THROUGHPUT_DIR}/"
}
