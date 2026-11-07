#!/bin/bash
# t4_memory.sh — o shadow nunca toca na memória do alvo. Um writer single-thread
# no E-core (sombreado o tempo todo) escreve numa região MAP_SHARED que um
# reader num P-core vigia: o contador nunca pode andar para trás nem ficar
# incoerente (um shadow escrevendo ali com o próprio contador, defasado, seria
# exatamente isso — o "Problema A" do context.md). O writer ainda confere a
# região privada. O teste só vale se houve shadows de fato.
#
# Uso: sudo [READ_US=100] [LAG_MS=5] [DUR=10] ./t4_memory.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t4_memory
DUR="${DUR:-10}"
command -v gcc >/dev/null || { echo "precisa de gcc"; exit 1; }

BIN="$SC_DIR/build/mem_integrity"
mkdir -p "$SC_DIR/build"
[[ $BIN -nt $SC_DIR/mem_integrity.c ]] || gcc -O2 -Wall -o "$BIN" "$SC_DIR/mem_integrity.c"

SHM=/dev/shm/sc_mem_integrity.$$
rm -f "$SHM"
trap 'rm -f "$SHM"; sc_cleanup' EXIT

sc_reset
sc_log_on

taskset -c "${EARR[0]}" "$BIN" writer "$DUR" "$SHM" > "$SC_OUT/writer.txt" 2>&1 &
wpid=$!
taskset -c "${PARR[0]}" "$BIN" reader "$DUR" "$SHM" > "$SC_OUT/reader.txt" 2>&1 &
rpid=$!

wrc=0; rrc=0
wait "$wpid" || wrc=$?
wait "$rpid" || rrc=$?
sleep 0.3
sc_log_dump "$SC_OUT/trace.txt"

cat "$SC_OUT/writer.txt" "$SC_OUT/reader.txt" | sed 's/^/        /'
ins=$(stat_get inserted)
check "houve shadows durante o teste (inserted=$ins)" [ "$ins" -gt 20 ]
check "writer: região privada íntegra e sem crash (rc=$wrc)" [ "$wrc" -eq 0 ]
check "reader: contador compartilhado nunca andou para trás nem ficou à frente das palavras (rc=$rrc)" [ "$rrc" -eq 0 ]
check_drained
check_dmesg_clean
sc_finish
