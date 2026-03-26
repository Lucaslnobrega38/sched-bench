#!/bin/bash
# lib/02_latency.sh — Latência de wakeup (schbench)

LATENCY_DIR="${OUTDIR}/latency"
CLS1_METHOD="div16"

_schbench_parse_csv() {
    local dir="$1"
    python3 - <<'PYEOF' "$dir" > "${dir}/percentiles.csv"
import sys, os, re, csv

d = sys.argv[1]
rows = []
for fname in sorted(f for f in os.listdir(d) if f.startswith("run_") and f.endswith(".txt")):
    with open(os.path.join(d, fname)) as f:
        data = {}
        for line in f:
            m = re.match(r'\s*([\d.]+)th:\s+(\d+)', line)
            if m:
                data[float(m.group(1))] = int(m.group(2))
        if data:
            rows.append(data)

w = csv.writer(sys.stdout)
w.writerow(["run", "p50", "p75", "p90", "p95", "p99", "p99.5", "p99.9"])
for i, r in enumerate(rows, 1):
    w.writerow([i,
        r.get(50.0, "NA"), r.get(75.0, "NA"), r.get(90.0, "NA"),
        r.get(95.0, "NA"), r.get(99.0, "NA"), r.get(99.5, "NA"),
        r.get(99.9, "NA")])
PYEOF
}

_bench_schbench() {
    local tag="$1" bg_workers="${2:-0}"
    local out="${LATENCY_DIR}/schbench_${tag}"
    mkdir -p "$out"

    local existing
    existing=$(find "$out" -maxdepth 1 -name "run_*.txt" 2>/dev/null | wc -l)
    if [[ "$existing" -ge "$RUNS" ]]; then
        log "  [schbench] ${tag} — já completo, pulando"
        return
    fi

    local _start=$(( existing + 1 ))
    if (( bg_workers > 0 )); then
        log "  [schbench] ${tag} — 4 workers + ${bg_workers} ${CLS1_METHOD} bg (run ${_start})"
    else
        log "  [schbench] ${tag} — 4 workers, sem contention (run ${_start})"
    fi

    for i in $(seq "$_start" "$RUNS"); do
        local bg_pid=""
        if (( bg_workers > 0 )); then
            stress-ng --cpu "$bg_workers" --cpu-method "${CLS1_METHOD}" \
                --timeout 20s --quiet &>/dev/null &
            bg_pid=$!
            sleep 0.5
        fi

        timeout 30 taskset -c "${ALLCORES}" schbench -t 4 -m 2 --runtime 15 \
            > "${out}/run_${i}.txt" 2>&1 || [[ -s "${out}/run_${i}.txt" ]] || echo "NA" > "${out}/run_${i}.txt"

        [[ -n "$bg_pid" ]] && { wait "$bg_pid" 2>/dev/null || true; }
        printf "    run %02d/%02d\n" "$i" "$RUNS"
    done

    _schbench_parse_csv "$out"
    log "  [schbench] ${tag}: ${out}/percentiles.csv"
}

run_latency_tests() {
    log "=== FASE 2: LATÊNCIA ==="

    _bench_schbench "baseline" 0

    log "Fase 2 concluída → ${LATENCY_DIR}/"
}
