#!/bin/bash
# benchmarks/275hx/throughput.sh — Throughput (ops/s), topologia FIXA 275HX
#
# Único cenário: cls2 (rand48) e cls1 (div16) rodando ao mesmo tempo, os DOIS
# medidos no mesmo run (--metrics-brief nos dois lados, nenhum roda --quiet).
# N de tasks: P cls2 + 2×P cls1, com P = THROUGHPUT_P = 8 SEMPRE — não o
# N_PHYSICAL_PCORES do runner, que cai para 7 com core reservado ao
# classificador (isso vale só para o placement). Carga idêntica em todos os
# kernels: 8 cls2 + 16 cls1 = 24 tasks. Sem shadow são 24 tasks em 24 CPUs; com
# shadow, 24 em 23 (um P-core reservado) — essa perda aparece como custo
# medido em vez de ser escondida por uma carga menor. 2×P = 16 = E-cores.
THROUGHPUT_P=8
#
# CV medido nas 50 runs por cenário do desenho anterior (isolado/contenção
# separados, 30s): 0,1-4,5%. Estável o bastante para reduzir a amostra.

THROUGHPUT_DIR="${OUTDIR}/throughput"

CLS2_METHOD="rand48"
CLS1_METHOD="div16"
THROUGHPUT_DURATION=30
THROUGHPUT_RUNS=5

run_throughput_tests() {
    log "=== FASE 3: THROUGHPUT (cls1 + cls2, mixed) ==="

    local n_cls2="${THROUGHPUT_P}"
    local n_cls1=$(( THROUGHPUT_P * 2 ))
    local out="${THROUGHPUT_DIR}/mixed"
    mkdir -p "$out"

    log "  cls2(${CLS2_METHOD})=${n_cls2}  cls1(${CLS1_METHOD})=${n_cls1}  duração=${THROUGHPUT_DURATION}s  runs=${THROUGHPUT_RUNS}"

    local existing=0
    [[ -f "${out}/cls2_ops.txt" ]] && existing=$(wc -l < "${out}/cls2_ops.txt")
    if [[ "$existing" -ge "$THROUGHPUT_RUNS" ]]; then
        log "  [throughput] mixed — já completo (${existing} runs), pulando"
        log "Fase 3 concluída → ${THROUGHPUT_DIR}/"
        return
    fi

    local start_from=$(( existing + 1 ))
    [[ "$existing" -gt 0 ]] && log "  [throughput] mixed — resumindo do run ${start_from}"

    for i in $(seq "$start_from" "$THROUGHPUT_RUNS"); do
        local tmp_cls2 tmp_cls1
        tmp_cls2=$(mktemp)
        tmp_cls1=$(mktemp)

        # Os dois grupos rodam simultâneos; cada stress-ng agrega o bogo-ops/s
        # de TODOS os seus workers internos numa única linha "cpu" — é o
        # total do tipo, não de um worker isolado. Dividir por n_cls2/n_cls1
        # na análise dá a vazão média por worker de cada tipo.
        stress-ng --cpu "${n_cls2}" --cpu-method "${CLS2_METHOD}" \
            --timeout "${THROUGHPUT_DURATION}s" --metrics-brief > "$tmp_cls2" 2>&1 &
        local pid2=$!
        stress-ng --cpu "${n_cls1}" --cpu-method "${CLS1_METHOD}" \
            --timeout "${THROUGHPUT_DURATION}s" --metrics-brief > "$tmp_cls1" 2>&1 &
        local pid1=$!

        wait "$pid2" 2>/dev/null || true
        wait "$pid1" 2>/dev/null || true

        local ops2 ops1
        ops2=$(awk '/cpu /{print $9}' "$tmp_cls2")
        ops1=$(awk '/cpu /{print $9}' "$tmp_cls1")
        rm -f "$tmp_cls2" "$tmp_cls1"

        echo "${ops2:-NA}" >> "${out}/cls2_ops.txt"
        echo "${ops1:-NA}" >> "${out}/cls1_ops.txt"
        printf "    run %02d/%02d: cls2_total=%s ops/s (%.1f/worker)  cls1_total=%s ops/s (%.1f/worker)\n" \
            "$i" "$THROUGHPUT_RUNS" "${ops2:-NA}" "$(awk -v o="${ops2:-0}" -v n="$n_cls2" 'BEGIN{printf o/n}')" \
            "${ops1:-NA}" "$(awk -v o="${ops1:-0}" -v n="$n_cls1" 'BEGIN{printf o/n}')"
    done

    log "  [throughput] mixed → ${out}/"
    log "Fase 3 concluída → ${THROUGHPUT_DIR}/"
}
