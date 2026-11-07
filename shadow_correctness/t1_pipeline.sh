#!/bin/bash
# t1_pipeline.sh — o pipeline do shadow obedece ao desenho? Carga mista nos
# E-cores (compute de duas classes e um processo que faz syscall), log por
# evento ligado, e o analisador confere as invariantes (P-core, 1 pop por
# jiffy, slot exclusivo, 1 shadow por target, lag, tudo drena).
#
# Uso: sudo [READ_US=100] [LAG_MS=5] [DUR=8] ./t1_pipeline.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t1_pipeline
DUR="${DUR:-8}"

sc_reset
sc_log_on

i=0
for e in "${EARR[@]}"; do
    case $((i % 3)) in
        0) start_load rand48 "$e" ;;
        1) start_load div16 "$e" ;;
        2) taskset -c "$e" stress-ng --getpid 1 --timeout "${DUR}s" >/dev/null 2>&1 & SC_BG+=($!) ;;
    esac
    i=$((i + 1))
done
wait_load
sleep 0.5

check_drained
sc_log_dump "$SC_OUT/trace.txt"
stat_snapshot "$SC_OUT/stats.txt"

check "houve shadows (inserted=$(stat_get inserted))" [ "$(stat_get inserted)" -gt 0 ]
check "houve shadows popados em P-core ($(( $(stat_get popped_tick) + $(stat_get popped_idle) )))" \
      [ $(( $(stat_get popped_tick) + $(stat_get popped_idle) )) -gt 0 ]
check_identities
check "nenhum shadow demorou mais de 500us para começar a rodar (start_late=$(stat_get start_late), start_us_avg=$(stat_get start_us_avg))" \
      [ "$(stat_get start_late)" -eq 0 ]

if sc_analyze --trace "$SC_OUT/trace.txt" --read-us "$READ_US" --json "$SC_OUT/analysis.json"; then
    pass "invariantes do log (analyze_log.py)"
else
    fail "invariantes do log (analyze_log.py)"
fi

check_dmesg_clean
sc_finish
