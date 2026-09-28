#!/bin/bash
# =============================================================================
# probe_ipcc_classes_275hx.sh — Verifica empiricamente a classificação IPCC
# (Intel Thread Director) neste hardware: Intel Core Ultra 9 275HX.
#
# Pergunta que este script responde: cls1 (div16) e cls2 (rand48) são
# realmente classificados assim pelo hardware NESTE chip, e isso difere
# entre P-core e E-core? Método idêntico ao usado historicamente no i5
# (docs/ipcc_classes_behavior.txt): trace_printk em debounce_and_update_class(),
# filtrado por PID do worker.
#
# Cada combinação (core-type, método) roda --reps vezes (padrão 3), em
# medições independentes (trace zerado entre cada uma). O resumo reporta o
# agregado (soma de todas as reps) e também min/max/desvio-padrão do cls2%
# entre as reps — para diferenciar comportamento real e estável de um fluke
# de uma única rodada (variação térmica/de frequência do CPU sondado).
#
# PRÉ-REQUISITO: o kernel rodando precisa ter o trace_printk de
# arch/x86/kernel/sched_ipcc.c::debounce_and_update_class() HABILITADO e
# terminado em "\n" (sem \n, os eventos ficam colados um no outro no arquivo
# de trace e a contagem por linha fica errada).
#
# Também captura o trace_printk "IPCC SCORE" de
# drivers/thermal/intel/intel_hfi.c::intel_hfi_get_ipcc_score() (adicionado
# pra expor score/nr_classes reais por (cpu, classe), inclusive o path
# OUT-OF-RANGE quando ipcc >= nr_classes+1).
#
# Topologia FIXA (Intel Core Ultra 9 275HX, sem SMT): P-cores CPU0-7, E-cores
# CPU8-23. Não detectada em runtime.
#
# Uso: sudo ./benchmarks/275hx/probe_ipcc_classes_275hx.sh [--duration N] [--reps N]
#                                                          [--methods m1,m2,...]
#                                                          [--pcore CPU] [--ecore CPU]
# =============================================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Execute como root (sudo)"; exit 1; }

TRACE_DIR="/sys/kernel/debug/tracing"
[[ -d "$TRACE_DIR" ]] || { echo "ftrace indisponível (${TRACE_DIR} não existe)"; exit 1; }

DURATION=5
REPS=3
METHODS="rand48,div16,collatz,ackermann,fft,matrixprod,hamming"
PCORE_CPU=0     # CPU 0-7 = P-core [FIXO, ver run_battery_275hx.sh]
ECORE_CPU=8     # CPU 8-23 = E-core [FIXO]
OUTDIR="./275hx/ipcc_probe/$(date +%Y%m%d_%H%M%S)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --duration) DURATION="$2";  shift 2 ;;
        --reps)     REPS="$2";      shift 2 ;;
        --methods)  METHODS="$2";   shift 2 ;;
        --pcore)    PCORE_CPU="$2"; shift 2 ;;
        --ecore)    ECORE_CPU="$2"; shift 2 ;;
        --outdir)   OUTDIR="$2";    shift 2 ;;
        --help)
            echo "Uso: sudo ./benchmarks/275hx/probe_ipcc_classes_275hx.sh [--duration N] [--reps N] [--methods m1,m2,...] [--pcore CPU] [--ecore CPU]"
            echo "  Métodos padrão: ${METHODS}"
            echo "  P-core padrão: CPU${PCORE_CPU}  |  E-core padrão: CPU${ECORE_CPU}"
            echo "  Reps padrão: ${REPS}  |  duração padrão: ${DURATION}s"
            exit 0 ;;
        *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$OUTDIR"
SUMMARY="${OUTDIR}/summary.csv"
RUNS_CSV="${OUTDIR}/runs.csv"
SCORES_CSV="${OUTDIR}/scores.csv"
DETAIL="${OUTDIR}/detail.txt"
echo "cpu_type,cpu,method,reps,total_samples,cls1,cls2,cls3plus,cls2_pct,cls3plus_pct,transitions,cls2_pct_min,cls2_pct_max,cls2_pct_std" > "$SUMMARY"
echo "cpu_type,cpu,method,rep,samples,cls1,cls2,cls3plus,cls2_pct,cls3plus_pct,transitions" > "$RUNS_CSV"
echo "cpu_type,cpu,method,rep,ipcc,nr_classes,score_min,score_max,samples,out_of_range_count" > "$SCORES_CSV"

# buffer maior: com IPCC SCORE somado ao IPCC UPDATE o volume de trace ~triplica
echo 8192 > "${TRACE_DIR}/buffer_size_kb" 2>/dev/null || true

echo "=== Preflight ===" | tee "$DETAIL"
echo "Kernel: $(uname -r)" | tee -a "$DETAIL"
echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)" | tee -a "$DETAIL"
echo "P-core sonda: CPU${PCORE_CPU}  |  E-core sonda: CPU${ECORE_CPU}" | tee -a "$DETAIL"
echo "Métodos: ${METHODS}  |  duração: ${DURATION}s cada  |  reps: ${REPS}" | tee -a "$DETAIL"
echo "Saída: ${OUTDIR}/" | tee -a "$DETAIL"
echo "" | tee -a "$DETAIL"

# --- Sanity check: o trace_printk precisa estar habilitado (e com \n) no kernel atual ---
echo 0 > "${TRACE_DIR}/tracing_on"
: > "${TRACE_DIR}/trace"
echo 1 > "${TRACE_DIR}/tracing_on"
taskset -c "$PCORE_CPU" stress-ng --cpu 1 --cpu-method rand48 --timeout 2s --quiet
sleep 0.5
echo 0 > "${TRACE_DIR}/tracing_on"

_preflight_lines=$(grep -c "IPCC UPDATE" "${TRACE_DIR}/trace" || true)
if [[ "${_preflight_lines:-0}" -eq 0 ]]; then
    echo "ERRO: nenhuma linha 'IPCC UPDATE' encontrada no trace." | tee -a "$DETAIL"
    echo "  O kernel rodando agora ($(uname -r)) não tem o trace_printk habilitado" | tee -a "$DETAIL"
    echo "  em arch/x86/kernel/sched_ipcc.c::debounce_and_update_class()." | tee -a "$DETAIL"
    echo "  Habilite a linha do trace_printk (terminada em \\n), recompile e reinicie" | tee -a "$DETAIL"
    echo "  nesse kernel antes de rodar esta sonda." | tee -a "$DETAIL"
    exit 1
fi
if [[ "$_preflight_lines" -lt 100 ]]; then
    echo "AVISO: só ${_preflight_lines} linhas 'IPCC UPDATE' em ~2s — esperado ~2000+ (1 por tick)." | tee -a "$DETAIL"
    echo "  Verifique se o trace_printk termina em \\n (ver probe_ipcc_classes_275hx.sh)." | tee -a "$DETAIL"
fi
echo "OK: trace 'IPCC UPDATE' confirmado (${_preflight_lines} linhas em ~2s de preflight)." | tee -a "$DETAIL"
echo "" | tee -a "$DETAIL"

# _raw_probe <cpu_type> <cpu> <method> <rep> — roda UMA medição, imprime
# "n,c1,c2,c3,trans" no stdout (classificação) e, como efeito colateral,
# grava a tabela de score (IPCC SCORE) observada para esse cpu em $SCORES_CSV.
_raw_probe() {
    local cpu_type="$1" cpu="$2" method="$3" rep="$4"

    : > "${TRACE_DIR}/trace"
    echo 1 > "${TRACE_DIR}/tracing_on"

    taskset -c "$cpu" stress-ng --cpu 1 --cpu-method "$method" \
        --timeout "${DURATION}s" --quiet &
    local ppid=$!
    sleep 0.3
    local wpid
    wpid=$(pgrep -P "$ppid" 2>/dev/null | head -1)
    [[ -z "$wpid" ]] && wpid="$ppid"

    wait "$ppid" 2>/dev/null || true
    echo 0 > "${TRACE_DIR}/tracing_on"

    local tmp
    tmp=$(mktemp)
    grep -E "IPCC UPDATE: pid=${wpid}\b" "${TRACE_DIR}/trace" > "$tmp" || true

    awk '
    {
        # linha ex.: "... IPCC UPDATE: pid=1234 class = 2 cpu=0"
        if (match($0, /class = [0-9]+/)) {
            cls = substr($0, RSTART+8, RLENGTH-8) + 0
        } else {
            next
        }
        n++
        if (cls == 1) c1++
        else if (cls == 2) c2++
        else if (cls >= 3) c3++
        if (prev != "" && prev != cls) trans++
        prev = cls
    }
    END {
        printf "%d,%d,%d,%d,%d\n", n+0, c1+0, c2+0, c3+0, trans+0
    }' "$tmp"

    rm -f "$tmp"

    # --- tabela de score (IPCC SCORE) pra este cpu, mesma janela de captura ---
    # Não é filtrada por pid: intel_hfi_get_ipcc_score() não tem acesso à task,
    # só a (ipcc, cpu). Filtramos por "cpu=$cpu" no texto do trace, o que é
    # correto mesmo quando disparado por um scan de load-balance rodando em
    # outra CPU (ele consulta o score do cpu candidato, não do cpu atual).
    local tmp2
    tmp2=$(mktemp)
    grep -E "IPCC SCORE: cpu=${cpu}\b" "${TRACE_DIR}/trace" > "$tmp2" || true

    awk -v cpu_type="$cpu_type" -v cpu="$cpu" -v method="$method" -v rep="$rep" -v out="$SCORES_CSV" '
    {
        if (!match($0, /ipcc=[0-9]+/)) next
        ipcc = substr($0, RSTART+5, RLENGTH-5) + 0

        if (match($0, /nr_classes=[0-9]+/))
            last_nrc = substr($0, RSTART+11, RLENGTH-11) + 0

        if (match($0, /OUT-OF-RANGE/)) {
            oor[ipcc]++
            next
        }

        if (!match($0, /score=-?[0-9]+/)) next
        sc = substr($0, RSTART+6, RLENGTH-6) + 0

        if (!(ipcc in seen) || sc < mn[ipcc]) mn[ipcc] = sc
        if (!(ipcc in seen) || sc > mx[ipcc]) mx[ipcc] = sc
        seen[ipcc] = 1
        n[ipcc]++
    }
    END {
        for (i = 1; i <= 5; i++) {
            if ((i in seen) || (i in oor)) {
                smin = (i in seen) ? mn[i] : "NA"
                smax = (i in seen) ? mx[i] : "NA"
                printf "%s,%s,%s,%s,%d,%d,%s,%s,%d,%d\n", \
                    cpu_type, cpu, method, rep, i, last_nrc+0, smin, smax, n[i]+0, oor[i]+0 >> out
            }
        }
    }' "$tmp2"

    rm -f "$tmp2"
}

# _probe_combo <cpu_type P|E> <cpu> <method> — roda REPS medições, agrega e loga
_probe_combo() {
    local cpu_type="$1" cpu="$2" method="$3"
    local -a pcts=()
    local total_n=0 total_c1=0 total_c2=0 total_c3=0 total_trans=0

    for ((r = 1; r <= REPS; r++)); do
        local raw n c1 c2 c3 trans pct pct3
        raw=$(_raw_probe "$cpu_type" "$cpu" "$method" "$r")
        IFS=',' read -r n c1 c2 c3 trans <<< "$raw"

        if [[ "$n" -gt 0 ]]; then
            pct=$(awk -v c="$c2" -v n="$n" 'BEGIN{printf "%.2f", 100*c/n}')
            pct3=$(awk -v c="$c3" -v n="$n" 'BEGIN{printf "%.2f", 100*c/n}')
        else
            pct="NA"; pct3="NA"
        fi
        pcts+=("$pct")

        echo "${cpu_type},${cpu},${method},${r},${n},${c1},${c2},${c3},${pct},${pct3},${trans}" >> "$RUNS_CSV"
        printf "    rep %d/%d: n=%-5s cls1=%-5s cls2=%-5s cls3+=%-5s cls2%%=%-6s trans=%s\n" \
            "$r" "$REPS" "$n" "$c1" "$c2" "$c3" "$pct" "$trans"

        total_n=$((total_n + n))
        total_c1=$((total_c1 + c1))
        total_c2=$((total_c2 + c2))
        total_c3=$((total_c3 + c3))
        total_trans=$((total_trans + trans))
    done

    local agg_cls2_pct agg_cls3_pct
    if [[ "$total_n" -gt 0 ]]; then
        agg_cls2_pct=$(awk -v c="$total_c2" -v n="$total_n" 'BEGIN{printf "%.1f", 100*c/n}')
        agg_cls3_pct=$(awk -v c="$total_c3" -v n="$total_n" 'BEGIN{printf "%.1f", 100*c/n}')
    else
        agg_cls2_pct="NA"; agg_cls3_pct="NA"
    fi

    local stats
    stats=$(printf "%s\n" "${pcts[@]}" | awk '
        $1 != "NA" {
            n++; sum += $1; sumsq += $1*$1
            if (mn == "" || $1 < mn) mn = $1
            if (mx == "" || $1 > mx) mx = $1
        }
        END {
            if (n == 0) { print "NA,NA,NA"; exit }
            std = (n > 1) ? sqrt((sumsq - sum*sum/n)/(n-1)) : 0
            printf "%.1f,%.1f,%.2f", mn, mx, std
        }')

    echo "${cpu_type},${cpu},${method},${REPS},${total_n},${total_c1},${total_c2},${total_c3},${agg_cls2_pct},${agg_cls3_pct},${total_trans},${stats}" >> "$SUMMARY"

    local line
    line=$(tail -1 "$SUMMARY")
    printf "  [%s CPU%-2s] %-12s -> %s\n" "$cpu_type" "$cpu" "$method" "$line"
}

IFS=',' read -ra method_arr <<< "$METHODS"

echo "=== Sondagem (${REPS} reps por combinação) ===" | tee -a "$DETAIL"
for method in "${method_arr[@]}"; do
    _probe_combo "P" "$PCORE_CPU" "$method" | tee -a "$DETAIL"
    _probe_combo "E" "$ECORE_CPU" "$method" | tee -a "$DETAIL"
done

echo "" | tee -a "$DETAIL"
echo "=== Resumo agregado (cpu_type,cpu,method,reps,total_samples,cls1,cls2,cls3plus,cls2_pct,cls3plus_pct,transitions,cls2_pct_min,cls2_pct_max,cls2_pct_std) ===" | tee -a "$DETAIL"
column -s, -t "$SUMMARY" | tee -a "$DETAIL"

# --- tabela de score deduplicada por (cpu_type,cpu,ipcc): o score é uma
# lookup de hardware, não deveria variar por método/rep. Agregar todo
# scores.csv confirma se de fato é constante (ou se varia, o que seria
# outro achado interessante).
SCORES_TABLE="${OUTDIR}/scores_table.csv"
echo "cpu_type,cpu,ipcc,nr_classes,score_min,score_max,total_samples,total_out_of_range" > "$SCORES_TABLE"
tail -n +2 "$SCORES_CSV" | awk -F, '
{
    key = $1","$2","$5
    nrc[key] = $6
    if ($7 != "NA") {
        if (!(key in seen) || $7+0 < mn[key]+0) mn[key] = $7
        if (!(key in seen) || $8+0 > mx[key]+0) mx[key] = $8
        seen[key] = 1
    }
    n[key] += $9
    oor[key] += $10
    order[++c] = key
}
END {
    for (i = 1; i <= c; i++) {
        key = order[i]
        if (done[key]++) continue
        smin = (key in seen) ? mn[key] : "NA"
        smax = (key in seen) ? mx[key] : "NA"
        print key","nrc[key]","smin","smax","n[key]+0","oor[key]+0
    }
}' >> "$SCORES_TABLE"

echo "" | tee -a "$DETAIL"
echo "=== Tabela de score IPCC deduplicada (cpu_type,cpu,ipcc,nr_classes,score_min,score_max,total_samples,total_out_of_range) ===" | tee -a "$DETAIL"
column -s, -t "$SCORES_TABLE" | tee -a "$DETAIL"

echo ""
echo "Resumo agregado:  ${SUMMARY}"
echo "Detalhe por rep:  ${RUNS_CSV}"
echo "Scores (bruto):   ${SCORES_CSV}"
echo "Scores (tabela):  ${SCORES_TABLE}"
echo "Log completo:     ${DETAIL}"
