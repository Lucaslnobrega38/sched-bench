#!/bin/bash
# lib/06_report.sh — Geração de relatório

generate_report() {
    log "=== RELATÓRIO ==="

    local report="${OUTDIR}/report.txt"
    {
        echo "======================================================"
        echo "  RELATÓRIO — ${KERNEL_TAG}"
        echo "  $(date)"
        echo "======================================================"
        echo ""
        echo "Hardware: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Kernel:   $(uname -r)"
        echo "Runs:     ${RUNS}"
        echo "P-cores:  ${PCORES}  (${N_PHYSICAL_PCORES} físicos)"
        echo "E-cores:  ${ECORES}"
        echo "Total CPUs: ${TOTAL_CPUS}"
        echo ""

        echo "--- PLACEMENT ---"
        for dir in "${OUTDIR}"/placement/*/; do
            [[ -d "$dir" ]] || continue
            local tag
            tag=$(basename "$dir")
            local cp ce
            cp=$(_mean_std "${dir}/cls2_p_residency.txt")
            ce=$(_mean_std "${dir}/cls1_e_residency.txt")
            echo "  ${tag}: cls2→P=${cp}%  cls1→E=${ce}%"
        done

        echo ""
        echo "--- LATÊNCIA (schbench, μs) ---"
        for f in "${OUTDIR}"/latency/schbench_*/percentiles.csv; do
            [[ -f "$f" ]] || continue
            local tag
            tag=$(basename "$(dirname "$f")" | sed 's/schbench_//')
            local p50 p90 p99
            p50=$(tail -n +2 "$f" | awk -F, '{sum+=$2; n++} END{if(n>0) printf "%.0f", sum/n}')
            p90=$(tail -n +2 "$f" | awk -F, '{sum+=$4; n++} END{if(n>0) printf "%.0f", sum/n}')
            p99=$(tail -n +2 "$f" | awk -F, '{sum+=$6; n++} END{if(n>0) printf "%.0f", sum/n}')
            echo "  ${tag}: p50=${p50}  p90=${p90}  p99=${p99}"
        done

        echo ""
        echo "--- THROUGHPUT ---"
        for dir in "${OUTDIR}"/throughput/*/; do
            [[ -d "$dir" ]] || continue
            local tag
            tag=$(basename "$dir")
            echo "  ${tag}:"
            echo "    ops/s:   $(_mean_std "${dir}/compute_ops.txt")"
        done

        echo ""
        echo "======================================================"
    } > "$report"

    cat "$report"
    log "Relatório: ${report}"
}

_mean_std() {
    local file="$1"
    [[ -f "$file" ]] || { echo "NA"; return; }
    awk '
        /^[0-9]/ { sum+=$1; sq+=$1*$1; n++ }
        END {
            if (n>0) {
                m = sum/n
                s = (n>1) ? sqrt((sq - sum*sum/n)/(n-1)) : 0
                printf "%.1f ± %.1f (n=%d)", m, s, n
            } else { print "NA" }
        }
    ' "$file"
}
