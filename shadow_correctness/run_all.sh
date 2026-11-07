#!/bin/bash
# run_all.sh — roda todos os testes na ordem, com uma pasta de resultados só.
# Uso: sudo [READ_US=100] [LAG_MS=5] ./run_all.sh [t1 t2 t3 t4 t5 t6]
set -uo pipefail
cd "$(dirname "$0")"
export SC_RESULTS="${SC_RESULTS:-$PWD/results/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$SC_RESULTS"

ALL=(t1_pipeline t2_invariants t3_class t4_memory t5_edges t6_deadline_sweep)
SEL=("$@")
declare -A rc
total_fail=0
for t in "${ALL[@]}"; do
    if [[ ${#SEL[@]} -gt 0 ]]; then
        hit=0; for s in "${SEL[@]}"; do [[ $t == "$s"* ]] && hit=1; done
        [[ $hit -eq 1 ]] || continue
    fi
    ./"$t".sh; rc[$t]=$?
    echo
done

echo "================ resumo ($SC_RESULTS) ================"
for t in "${ALL[@]}"; do
    [[ -n ${rc[$t]:-} ]] || continue
    case ${rc[$t]} in
        0) s="ok" ;;
        77) s="PULADO (kernel sem o classificador)" ;;
        *) s="FALHOU"; total_fail=$((total_fail + 1)) ;;
    esac
    printf '  %-22s %s\n' "$t" "$s"
done
exit $((total_fail > 0))
