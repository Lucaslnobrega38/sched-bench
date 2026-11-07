#!/bin/bash
# t6_deadline_sweep.sh — o experimento empírico: para cada atraso de leitura d
# (ipcc_shadow_read_us), com um método de classe 1 e um de classe 2 nos
# E-cores, quanto da leitura é válida, quanto concorda com a classe esperada,
# quanto vive o turno e que vazão sai. d=0 desliga o timer (só o tick lê).
#
# Uso: sudo [DUR=5] [LAG_MS=5] [DELAYS="0 5 10 25 50 100 250"] \
#          [METHODS="div16:1 rand48:2"] [WORKERS=4] ./t6_deadline_sweep.sh
# Saída: tabela na tela e $SC_OUT/sweep.csv (um ponto por linha).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t6_deadline_sweep
DUR="${DUR:-5}"
DELAYS="${DELAYS:-0 5 10 25 50 100 250}"
METHODS="${METHODS:-div16:1 rand48:2}"
WORKERS="${WORKERS:-4}"
CSV="$SC_OUT/sweep.csv"
rm -f "$CSV"

for d in $DELAYS; do
    for entry in $METHODS; do
        method=${entry%:*}; expect=${entry#*:}
        sc_knob_set ipcc_shadow_read_us "$d"
        sc_reset; sc_log_on
        n=0
        for e in "${EARR[@]}"; do
            [[ $n -ge $WORKERS ]] && break
            start_load "$method" "$e"; n=$((n + 1))
        done
        wait_load
        sleep 0.4
        wait_drained 3 || true
        sc_log_dump "$SC_OUT/trace_${method}_d${d}.txt" >/dev/null
        echo "-- d=${d}us $method (classe $expect, $n workers)"
        sc_analyze --trace "$SC_OUT/trace_${method}_d${d}.txt" --read-us "$d" --expect-class "$expect" \
            --csv "$CSV" --label "d_us=$d" --label "method=$method" --label "expect=$expect" \
            --no-drain-check | grep -E 'FAIL|deadline|execução|convergência|classes|pops|pop->run' || true
        rm -f "$SC_OUT/trace_${method}_d${d}.txt"   # os logs são grandes; o CSV fica
    done
done

echo
echo "== resumo (cada linha = um ponto da varredura) =="
python3 -I - "$CSV" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
cols = [("d_us", 5), ("method", 9), ("ends", 7), ("valid_pct", 9), ("agree_pct", 9),
        ("deadline_valid", 8), ("deadline_invalid", 9), ("deadline_not_curr", 9),
        ("cap", 4), ("start_p50_us", 9), ("exec_p50_us", 9), ("pops_per_s", 8), ("idle_pop_pct", 7)]
print("  ".join(f"{c:>{w}}" for c, w in cols))
for r in rows:
    print("  ".join(f"{r.get(c, ''):>{w}}" for c, w in cols))
print("\nvalid_pct   = % dos turnos que terminaram com alguma classe")
print("agree_pct   = % dos turnos com classe que bateram com a classe esperada do método")
print("deadline_*  = leituras do timer: válidas / inválidas / shadow fora da cpu")
PY
info "tabela completa em $CSV"
sc_finish
