#!/bin/bash
# heatmap.sh — 1 corrida longa (padrão 200s), amostrada no tempo, para analysis/heatmap.py.
# Opt-in: --phases heatmap. Saída em ${OUTDIR}/heatmap/{topology.txt, samples_<cenário>.csv}.

HEATMAP_DIR="${OUTDIR}/heatmap"
HEATMAP_DURATION="${HEATMAP_DURATION:-200}"
HEATMAP_SCENARIO="${HEATMAP_SCENARIO:-contention}"   # contention | relaxed
HEATMAP_INTERVAL=0.1

CLS2_METHOD="${CLS2_METHOD:-rand48}"
CLS1_METHOD="${CLS1_METHOD:-div16}"

_heatmap_write_topology() {
    local out="$1" cpu core_id
    local -a arr
    : > "$out"
    IFS=',' read -ra arr <<< "$PCORES"
    for cpu in "${arr[@]}"; do
        core_id=$(cat "/sys/devices/system/cpu/cpu${cpu}/topology/core_id" 2>/dev/null || echo "$cpu")
        echo "P ${core_id} ${cpu}" >> "$out"
    done
    IFS=',' read -ra arr <<< "$ECORES"
    for cpu in "${arr[@]}"; do
        echo "E ${cpu} ${cpu}" >> "$out"
    done
}

run_heatmap() {
    local duration="$HEATMAP_DURATION" scenario="$HEATMAP_SCENARIO"
    local n_cls2="$N_PHYSICAL_PCORES" n_cls1
    if [[ "$scenario" == relaxed ]]; then
        n_cls1="$N_PHYSICAL_PCORES"
    else
        n_cls1=$(( TOTAL_CPUS - N_PHYSICAL_PCORES ))
    fi

    log "=== HEATMAP: 1 corrida × ${duration}s, cenário ${scenario} (${n_cls2} cls2 + ${n_cls1} cls1) ==="
    mkdir -p "$HEATMAP_DIR"
    _heatmap_write_topology "${HEATMAP_DIR}/topology.txt"

    # --- lança as tarefas (mesma lógica de pinagem do placement.sh) ---
    local cls2_pids=() cls1_pids=() pin2=() pin1=() k=0
    for _ in $(seq 1 "$n_cls2"); do
        pin2=()
        [[ "${ORACLE_PIN:-0}" == 1 ]] && \
            pin2=(taskset -c "${P_FIRST_THREADS[$(( k % ${#P_FIRST_THREADS[@]} ))]}")
        "${pin2[@]}" stress-ng --cpu 1 --cpu-method "${CLS2_METHOD}" \
            --timeout "$(( duration + 3 ))s" --quiet &
        cls2_pids+=($!)
        k=$(( k + 1 ))
    done
    [[ "${ORACLE_PIN:-0}" == 1 ]] && pin1=(taskset -c "${CLS1_CPUS}")
    for _ in $(seq 1 "$n_cls1"); do
        "${pin1[@]}" stress-ng --cpu 1 --cpu-method "${CLS1_METHOD}" \
            --timeout "$(( duration + 3 ))s" --quiet &
        cls1_pids+=($!)
    done

    sleep 1

    # --- PIDs dos workers (stress-ng cria um filho por launcher) ---
    local workers=() ppid c
    for ppid in "${cls2_pids[@]}"; do
        c=$(pgrep -P "$ppid" 2>/dev/null | head -n1) || true
        workers+=("2:${c:-$ppid}")
    done
    for ppid in "${cls1_pids[@]}"; do
        c=$(pgrep -P "$ppid" 2>/dev/null | head -n1) || true
        workers+=("1:${c:-$ppid}")
    done

    # --- amostragem: campo 39 de /proc/PID/stat = CPU atual ---
    local samples="${HEATMAP_DIR}/samples_${scenario}.csv"
    echo "t_us,cls,pid,cpu" > "$samples"
    local t0=${EPOCHREALTIME/./} entry cls pid stat rest now
    local -a f
    local limit=$(( duration * 1000000 ))
    while :; do
        now=${EPOCHREALTIME/./}
        (( now - t0 >= limit )) && break
        for entry in "${workers[@]}"; do
            cls=${entry%%:*}; pid=${entry##*:}
            [[ -r /proc/$pid/stat ]] || continue
            stat=$(</proc/$pid/stat) || continue
            rest=${stat##*) }          # tira "pid (comm) " — comm pode ter espaços
            read -ra f <<< "$rest"     # f[0] = estado (campo 3)  →  campo 39 = f[36]
            [[ "${f[36]:-}" =~ ^[0-9]+$ ]] && echo "$(( now - t0 )),${cls},${pid},${f[36]}" >> "$samples"
        done
        sleep "$HEATMAP_INTERVAL"
    done

    kill "${cls2_pids[@]}" "${cls1_pids[@]}" 2>/dev/null || true
    wait "${cls2_pids[@]}" "${cls1_pids[@]}" 2>/dev/null || true

    # resumo de sanidade (mesmas métricas do placement)
    awk -F, -v pcores="${PCORES}" '
        BEGIN { n = split(pcores, pa, ","); for (i = 1; i <= n; i++) p[pa[i]] = 1 }
        NR > 1 && $2 == 2 { t2++; if ($4 in p) p2++ }
        NR > 1 && $2 == 1 { t1++; if (!($4 in p)) e1++ }
        END { printf "  cls2→P=%.1f%%  cls1→E=%.1f%%  (%d amostras)\n",
                     (t2 ? 100*p2/t2 : 0), (t1 ? 100*e1/t1 : 0), t1 + t2 }
    ' "$samples" | tee -a "$LOG"
    log "  [heatmap] ${scenario} → ${samples}"
}
