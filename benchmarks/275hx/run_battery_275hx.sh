#!/bin/bash
# =============================================================================
# BATERIA DE TESTES: ITD IPCC Scheduler vs asym_packing
# Específica para Intel Core Ultra 9 275HX — topologia HARD-CODED (não detectada
# em runtime):
#   P-cores: CPU 0-7   (8 cores físicos, sem SMT)
#   E-cores: CPU 8-23  (16 cores físicos)
#
# Uso: sudo ./benchmarks/275hx/run_battery_275hx.sh [--kernel <tag>] [--runs <N>] [--outdir <dir>]
#
# Fases (apenas estas duas):
#   1. Placement  — cls2→P-core, cls1→E-core (relaxed + contention)
#   2. Throughput — cls2 e cls1, isolados e sob contenção cruzada
#
# Cada cenário roda com uma quantidade de tasks igual à quantidade de cores
# físicos da classe correspondente. Sem oversubscrição (não há mais variante
# 1.5x).
# =============================================================================

set -euo pipefail

RUNS=50
KERNEL_TAG="${KERNEL_TAG:-$(uname -r)}"
WARMUP_SEC=5

# --- Topologia FIXA: Intel Core Ultra 9 275HX (Arrow Lake HX) ---
# Não detectar em runtime via acpi_cppc/highest_perf: nesta CPU os E-cores
# reportam highest_perf=65 e os P-cores 85-87 — o método "genérico" herdado
# do i5 (threshold highest_perf > 50) classifica os DOIS grupos como P-core
# aqui, porque 65 > 50 também. Confirmado ao vivo via
# /sys/devices/system/cpu/cpu*/acpi_cppc/highest_perf. Por isso fixo, não
# detectado.
PCORES="0,1,2,3,4,5,6,7"
ECORES="8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23"
N_PHYSICAL_PCORES=8
readonly N_PHYSICAL_ECORES_FIXED=16

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
die()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }

# P-core reservado ao classificador shadow: isolado e preso na freq mínima,
# nada do workload roda nele. Vazio em kernels sem o mecanismo. Portado de
# run_battery.sh (origin) — mesma lógica, aplicada aqui sobre a topologia
# fixa em vez da detectada, já que a detecção não serve nesta CPU (acima).
#
# NÃO existe mais pin de frequência (scaling_min == scaling_max), que era o
# sinal usado antes. O sinal agora: o ipcc-reaper é um kthread, e kthreads só
# rodam em housekeeping cpus — ipcc_isolate_classifier_cpu() tira o core
# classificador dessa máscara via housekeeping_update(). Logo o
# Cpus_allowed_list do reaper é "todos menos o classificador"
# (ex: 0-6,8-23 => classificador = cpu7). Processos de userspace NÃO são
# afetados (nproc segue 24), por isso o sinal é o do kthread e não o do shell.
#
# Cuidado com set -e/pipefail: nada aqui pode retornar não-zero sem `|| return 0`.
_cpu_in_list() {
    local cpu="$1" list="$2" part lo hi
    local IFS=','
    for part in $list; do
        if [[ "$part" == *-* ]]; then
            lo="${part%-*}"; hi="${part#*-}"
            (( cpu >= lo && cpu <= hi )) && return 0
        else
            (( cpu == part )) && return 0
        fi
    done
    return 1
}

_detect_classifier_cpu() {
    local pid allowed cpu

    pid=$(pgrep -x ipcc-reaper | head -1) || return 0
    [[ -n "$pid" ]] || return 0

    allowed=$(awk '/^Cpus_allowed_list:/ {print $2}' "/proc/${pid}/status" 2>/dev/null) || return 0
    [[ -n "$allowed" ]] || return 0

    local -a arr
    IFS=',' read -ra arr <<< "$PCORES"
    for cpu in "${arr[@]}"; do
        if ! _cpu_in_list "$cpu" "$allowed"; then
            CLASSIFIER_CPU="$cpu"
            return 0
        fi
    done
    return 0
}

_drop_cpu_from_list() {
    local list="$1" drop="$2" out="" c
    local -a arr
    IFS=',' read -ra arr <<< "$list"
    for c in "${arr[@]}"; do
        [[ "$c" == "$drop" ]] && continue
        out="${out:+$out,}$c"
    done
    echo "$out"
}

CLASSIFIER_CPU=""
_detect_classifier_cpu

TOTAL_CPUS=24
N_PHYSICAL_ECORES="$N_PHYSICAL_ECORES_FIXED"
if [[ -n "$CLASSIFIER_CPU" ]]; then
    PCORES=$(_drop_cpu_from_list "$PCORES" "$CLASSIFIER_CPU")
    ECORES=$(_drop_cpu_from_list "$ECORES" "$CLASSIFIER_CPU")
    TOTAL_CPUS=$(( TOTAL_CPUS - 1 ))
    # A CPU reservada só pode ter saído do lado P (P-cores 0-7 é onde
    # ipcc_isolate_classifier_cpu() sempre escolhe, ver sched_ipcc_classifier.c).
    # Vale para o PLACEMENT (P=7 com shadow). O throughput ignora isto e usa
    # THROUGHPUT_P=8 fixo (ver throughput.sh).
    N_PHYSICAL_PCORES=$(( N_PHYSICAL_PCORES - 1 ))
fi

readonly ALLCORES="${PCORES}${ECORES:+,${ECORES}}"

require() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Dependência ausente: $cmd"
    done
}

SKIP_TO=""
ONLY_PHASES=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel)   KERNEL_TAG="$2"; shift 2 ;;
        --runs)     RUNS="$2";       shift 2 ;;
        --outdir)   OUTDIR="$2";     shift 2 ;;
        --skip-to)  SKIP_TO="$2";    shift 2 ;;
        --phases)   ONLY_PHASES="$2"; shift 2 ;;
        --help)
            echo "Uso: sudo ./benchmarks/275hx/run_battery_275hx.sh [--kernel <tag>] [--runs <N>] [--outdir <dir>]"
            echo "Bateria fixa para Intel Core Ultra 9 275HX (P: CPU0-7, E: CPU8-23)"
            echo "Fases: placement, throughput, report"
            echo "  --phases: lista separada por vírgula (ex: --phases throughput)"
            echo "  --skip-to: pula fases anteriores (ex: --skip-to throughput)"
            exit 0 ;;
        *) die "Argumento desconhecido: $1" ;;
    esac
done

OUTDIR="${OUTDIR:-./275hx/results/${KERNEL_TAG}}"
LOG="${OUTDIR}/run.log"

mkdir -p "$OUTDIR"/{placement,throughput,raw}

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
[[ -f "${REPO_ROOT}/.venv/bin/activate" ]] && source "${REPO_ROOT}/.venv/bin/activate"

log "========================================================="
log " BATERIA SCHEDULER — Intel Core Ultra 9 275HX (kernel: ${KERNEL_TAG})"
log " Runs por teste: ${RUNS}"
log " Output: ${OUTDIR}"
log " P-cores [FIXO]: [${PCORES}]  (${N_PHYSICAL_PCORES} físicos, sem SMT)"
log " E-cores [FIXO]: [${ECORES}]  (${N_PHYSICAL_ECORES} físicos)"
log " Total CPUs: ${TOTAL_CPUS}"
log " Quantidade de tasks por classe = cores físicos da classe (sem oversubscrição)"
log "========================================================="

source "${SCRIPT_DIR}/preflight.sh"
source "${SCRIPT_DIR}/placement.sh"
source "${SCRIPT_DIR}/throughput.sh"
source "${SCRIPT_DIR}/report.sh"

_phase_reached=""
_should_run() {
    local phase="$1"
    if [[ -n "$ONLY_PHASES" ]]; then
        echo ",$ONLY_PHASES," | grep -q ",$phase," && return 0
        log "  [skip] $phase"
        return 1
    fi
    if [[ -z "$SKIP_TO" ]] || [[ -n "$_phase_reached" ]]; then return 0; fi
    if [[ "$phase" == "$SKIP_TO" ]]; then _phase_reached=1; return 0; fi
    log "  [skip] $phase"
    return 1
}

run_preflight

_should_run placement  && run_placement_tests
_should_run throughput && run_throughput_tests
_should_run report     && generate_report

log "========================================================="
log " BATERIA CONCLUÍDA — resultados em: ${OUTDIR}"
log "========================================================="
