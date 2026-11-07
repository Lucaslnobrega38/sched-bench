#!/bin/bash
# t2_invariants.sh — contabilidade. Depois de uma carga e de o sistema
# drenar, as identidades dos contadores têm de fechar, e não pode sobrar
# shadow vivo, filho preso no ipcc-reaper nem zumbi.
#
# Uso: sudo [READ_US=100] [LAG_MS=5] [DUR=6] ./t2_invariants.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t2_invariants
DUR="${DUR:-6}"

sc_reset
for e in "${EARR[@]}"; do start_load rand48 "$e"; done
wait_load
sleep 0.5

check_drained
stat_snapshot "$SC_OUT/stats.txt"
check "houve shadows (inserted=$(stat_get inserted))" [ "$(stat_get inserted)" -gt 0 ]
check_identities

zombies=$(ps -eo stat=,ppid= | awk -v rp="$(pgrep -x ipcc-reaper | head -1)" '$1 ~ /^Z/ && $2==rp' | wc -l)
check "nenhum zumbi do ipcc-reaper ($zombies)" [ "$zombies" -eq 0 ]

# sem carga nenhuma, nada novo pode entrar
before=$(stat_get inserted); sleep 2; after=$(stat_get inserted)
info "ocioso por 2s: inserted $before -> $after (algum processo do sistema pode ter sido elegível)"
check "FIFO continua vazia com o sistema ocioso" [ "$(stat_get fifo_len)" -eq 0 ]

check_dmesg_clean
sc_finish
