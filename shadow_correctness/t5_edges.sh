#!/bin/bash
# t5_edges.sh — bordas do ciclo de vida.
#   a. tempestade de saídas: alvos que morrem com shadow na FIFO ou no slot;
#   b. corrida no gatilho: muitas escritas simultâneas em ipcc_classify para
#      o mesmo pid (o claim NONE -> FORKING tem de manter 1 shadow por target);
#   c. falta de página com I/O: shadows que dormem fora da cpu e não veem o
#      tick (exercita deadline_not_curr e o teto de 1ms).
# Em todas: o sistema drena, as identidades fecham, o log do kernel fica limpo.
# Não coberto (precisa de intervenção manual): hotplug de um P-core com shadow
# no slot, e ativação do sched_ext com shadows vivos (ver README).
#
# Uso: sudo [READ_US=100] [LAG_MS=5] ./t5_edges.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t5_edges
command -v gcc >/dev/null || { echo "precisa de gcc"; exit 1; }

phase_end() {   # $1 = nome da fase
    wait_load
    sleep 0.3
    check_drained
    check_identities
}

# ---- a. tempestade de saídas -------------------------------------------------
echo "-- a. tempestade de saídas"
sc_reset; sc_log_on
for round in $(seq 1 8); do
    for e in "${EARR[@]}"; do
        ( for _ in $(seq 1 12); do
              # stress-ng lê "10ms" como 10 MINUTOS; a duração curta vem do timeout(1)
              timeout -k 1 "0.0$((RANDOM % 4 + 1))" taskset -c "$e" stress-ng --cpu 1 --cpu-method div16 --timeout 60 >/dev/null 2>&1 || true
          done ) &
        SC_BG+=($!)
    done
    wait_load
done
sc_log_dump "$SC_OUT/trace_a.txt"
phase_end a
check "a: houve shadows ($(stat_get inserted))" [ "$(stat_get inserted)" -gt 0 ]
sc_analyze --trace "$SC_OUT/trace_a.txt" --read-us "$READ_US" >/dev/null && pass "a: invariantes do log" || { fail "a: invariantes do log"; sc_analyze --trace "$SC_OUT/trace_a.txt" | grep FAIL; }

# ---- b. corrida no gatilho --------------------------------------------------
echo "-- b. corrida no gatilho"
sc_reset; sc_log_on
sp=""; taskset -c "${EARR[0]}" stress-ng --cpu 1 --cpu-method div16 --timeout 6s >/dev/null 2>&1 & sp=$!; SC_BG+=("$sp")
w=""; for _ in $(seq 1 30); do w=$(worker_of "$sp" || true); [[ -n $w ]] && break; sleep 0.1; done
[[ -n $w ]] || { fail "b: sem worker"; }
if [[ -n $w ]]; then
    for _ in 1 2 3 4; do
        ( for _ in $(seq 1 3000); do echo "$w" > "$DBG/ipcc_classify" 2>/dev/null || true; done ) &
        SC_BG+=($!)
    done
    wait_load
    sleep 0.3
    sc_log_dump "$SC_OUT/trace_b.txt"
    phase_end b
    # o gatilho de debugfs não passa pelo período do produtor
    out=$(sc_analyze --trace "$SC_OUT/trace_b.txt" --read-us "$READ_US" --no-period-check || true)
    if echo "$out" | grep -q 'FAIL'; then fail "b: invariantes do log (1 shadow por target / lag)"; echo "$out" | grep FAIL | sed 's/^/        /'
    else pass "b: invariantes do log (1 shadow por target / lag)"; fi
fi

# ---- c. falta de página com I/O ---------------------------------------------
echo "-- c. falta de página com I/O"
gcc -O2 -Wall -o "$SC_DIR/build/fault_touch" "$SC_DIR/fault_touch.c" 2>/dev/null || { mkdir -p "$SC_DIR/build"; gcc -O2 -Wall -o "$SC_DIR/build/fault_touch" "$SC_DIR/fault_touch.c"; }
BIGFILE="$SC_OUT/big.dat"
dd if=/dev/urandom of="$BIGFILE" bs=1M count=256 status=none
trap 'rm -f "$BIGFILE"; sc_cleanup' EXIT
sc_reset; sc_log_on
( for _ in $(seq 1 12); do sync; echo 1 > /proc/sys/vm/drop_caches; sleep 0.5; done ) &
SC_BG+=($!)
taskset -c "${EARR[0]}" "$SC_DIR/build/fault_touch" 6 "$BIGFILE" > "$SC_OUT/fault_touch.txt" 2>&1 &
SC_BG+=($!)
wait_load
sleep 0.5
sc_log_dump "$SC_OUT/trace_c.txt"
phase_end c
rm -f "$BIGFILE"
nc=$(stat_get deadline_not_curr); cap=$(stat_get cap_expired)
info "c: deadline_not_curr=$nc cap_expired=$cap (>0 mostra que o caminho de emergência foi exercitado)"
check "c: houve shadows ($(stat_get inserted))" [ "$(stat_get inserted)" -gt 0 ]
out=$(sc_analyze --trace "$SC_OUT/trace_c.txt" --read-us "$READ_US" || true)
if echo "$out" | grep -q 'FAIL'; then fail "c: invariantes do log"; echo "$out" | grep FAIL | sed 's/^/        /'; else pass "c: invariantes do log"; fi

check_dmesg_clean
sc_finish
