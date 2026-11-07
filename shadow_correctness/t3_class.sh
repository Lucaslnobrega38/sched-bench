#!/bin/bash
# t3_class.sh — a classe que os shadows dão a uma task de E-core é a que o
# hardware daria a ela num P-core? Para cada método: um oráculo (o mesmo
# método pinado num P-core, classe lida pelo ITD de verdade) e o mesmo método
# pinado num E-core, onde só os shadows classificam. As duas têm de coincidir
# entre si e com a classe esperada do método (docs/ipcc_classes_behavior.txt).
#
# A classe é lida de /proc/<pid>/sched (campos ipcc e ipcc_class_weight[i],
# que este kernel expõe); os shadows daquele worker são contados no log.
#
# BUSY_P=1 deixa os outros P-cores ocupados durante a fase dos shadows: é o
# caso em que o shadow preempta uma task real e o hreset na entrada importa.
#
# Uso: sudo [READ_US=100] [LAG_MS=5] [DUR=6] [BUSY_P=1] [METHODS="div16:1 rand48:2"] ./t3_class.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t3_class
DUR="${DUR:-6}"
METHODS="${METHODS:-div16:1 double:1 rand48:2 fft:2}"
PCPU=${PARR[0]}
ECPU=${EARR[0]}

weights() { local pid="$1" i out=""; for i in 0 1 2 3 4; do out+="$(proc_sched "$pid" "ipcc_class_weight[$i]") "; done; echo "$out"; }
argmax() { echo "$1" | awk '{m=-1; for(i=1;i<=NF;i++) if($i>m){m=$i; k=i-1} print (m>0)?k:0}'; }

read_worker() {   # $1 = cpu, $2 = método; deixa o worker rodando e imprime "pid"
    local sp
    taskset -c "$1" stress-ng --cpu 1 --cpu-method "$2" --timeout "${DUR}s" >/dev/null 2>&1 &
    sp=$!; SC_BG+=("$sp")
    local w=""
    for _ in $(seq 1 30); do w=$(worker_of "$sp" || true); [[ -n $w ]] && break; sleep 0.1; done
    echo "$w"
}

for entry in $METHODS; do
    method=${entry%:*}; expect=${entry#*:}
    echo "-- $method (classe esperada $expect)"

    # oráculo: P-core
    w=$(read_worker "$PCPU" "$method")
    sleep $((DUR - 2))
    oc=$(proc_sched "$w" ipcc); ow=$(weights "$w")
    wait_load
    info "$method oráculo em cpu$PCPU: ipcc=$oc pesos=[$ow]"

    # shadows: E-core
    sc_reset; sc_log_on
    if [[ "${BUSY_P:-0}" == 1 ]]; then
        for p in "${PARR[@]:1}"; do start_load matrixprod "$p" "$DUR"; done
    fi
    w=$(read_worker "$ECPU" "$method")
    [[ -n $w ]] || { fail "$method: não achei o worker do stress-ng"; continue; }
    sleep $((DUR - 2))
    sc=$(proc_sched "$w" ipcc); sw=$(weights "$w"); sk=$(proc_sched "$w" ipcc_confirm_count)
    wait_load; sleep 0.3
    sc_log_dump "$SC_OUT/trace_$method.txt"
    nshadow=$(grep -c "ev=end .*target=$w " "$SC_OUT/trace_$method.txt" || true)
    nclass=$(grep "ev=end .*target=$w " "$SC_OUT/trace_$method.txt" | grep -vc 'class=0 ' || true)
    top=$(argmax "$sw")
    info "$method na E-core cpu$ECPU (pid $w): ipcc=$sc k=$sk pesos=[$sw] argmax=$top; $nshadow shadows, $nclass com classe"

    check "$method: oráculo em P-core deu a classe esperada ($oc = $expect)" [ "$oc" -eq "$expect" ]
    check "$method: o worker de E-core recebeu classe ($sc) por shadows" [ "$sc" -ne 0 ]
    check "$method: classe do shadow = classe do oráculo ($sc = $oc)" [ "$sc" -eq "$oc" ]
    check "$method: classe dominante do vetor de pesos = esperada ($top = $expect)" [ "$top" -eq "$expect" ]
    check "$method: o worker foi sombreado ($nshadow turnos)" [ "$nshadow" -gt 0 ]
    wait_drained 3 || true
done

check_dmesg_clean
sc_finish
