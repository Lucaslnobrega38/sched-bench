#!/bin/bash
# =============================================================================
# BATERIA DE TESTES: ITD IPCC Scheduler vs asym_packing
# Detecta automaticamente a topologia híbrida (P-cores/E-cores) via acpi_cppc.
# Uso: sudo ./run_battery.sh [--kernel <tag>] [--runs <N>] [--outdir <dir>]
#
# Fases:
#   1. Placement  — cls2→P-core, cls1→E-core (relaxed + contention)
#   2. Latência   — schbench baseline
#   3. Throughput — N cls2 alone + N cls2 + M cls1 contention
# =============================================================================

set -euo pipefail

RUNS=50
KERNEL_TAG="${KERNEL_TAG:-$(uname -r)}"
WARMUP_SEC=5

_detect_hybrid_topology() {
    local total cpu val f online_f
    total=$(nproc --all)

    local pcores="" ecores="" found=0
    for cpu in $(seq 0 "$(( total - 1 ))"); do
        online_f="/sys/devices/system/cpu/cpu${cpu}/online"
        if [[ "$cpu" -ne 0 ]] && [[ "$(cat "$online_f" 2>/dev/null)" != "1" ]]; then
            continue
        fi
        f="/sys/devices/system/cpu/cpu${cpu}/acpi_cppc/highest_perf"
        [[ -r "$f" ]] || continue
        val=$(< "$f")
        found=1
        if [[ "$val" -gt 50 ]]; then
            pcores="${pcores:+$pcores,}$cpu"
        else
            ecores="${ecores:+$ecores,}$cpu"
        fi
    done

    [[ $found -eq 0 ]] && die "Topologia híbrida não detectada (acpi_cppc indisponível)"

    PCORES="$pcores"
    ECORES="$ecores"
}

# desconta SMT contando core_id únicos
_count_physical_pcores() {
    local -A seen count=0
    IFS=',' read -ra arr <<< "$PCORES"
    for cpu in "${arr[@]}"; do
        local core_id
        core_id=$(cat "/sys/devices/system/cpu/cpu${cpu}/topology/core_id" 2>/dev/null) || continue
        if [[ -z "${seen[$core_id]+x}" ]]; then
            seen[$core_id]=1
            (( count++ ))
        fi
    done
    echo "$count"
}

_detect_hybrid_topology

TOTAL_CPUS=$(nproc --all)
N_PHYSICAL_PCORES=$(_count_physical_pcores)
ALLCORES="${PCORES}${ECORES:+,${ECORES}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
die()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }

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
            echo "Uso: sudo ./run_battery.sh [--kernel <tag>] [--runs <N>] [--outdir <dir>]"
            echo "Fases: placement, latency, throughput, report"
            echo "  --phases: lista separada por vírgula (ex: --phases latency,throughput)"
            echo "  --skip-to: pula fases anteriores (ex: --skip-to throughput)"
            exit 0 ;;
        *) die "Argumento desconhecido: $1" ;;
    esac
done

OUTDIR="${OUTDIR:-./results/${KERNEL_TAG}}"
LOG="${OUTDIR}/run.log"

mkdir -p "$OUTDIR"/{placement,latency,throughput,raw}

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "${SCRIPT_DIR}/.venv/bin/activate" ]] && source "${SCRIPT_DIR}/.venv/bin/activate"

log "========================================================="
log " BATERIA SCHEDULER — kernel: ${KERNEL_TAG}"
log " Runs por teste: ${RUNS}"
log " Output: ${OUTDIR}"
log " P-cores lógicos: [${PCORES}]  (${N_PHYSICAL_PCORES} físicos)"
log " E-cores: [${ECORES}]"
log " Total CPUs: ${TOTAL_CPUS}"
log "========================================================="

source "$(dirname "$0")/benchmarks/battery/preflight.sh"
source "$(dirname "$0")/benchmarks/battery/placement.sh"
source "$(dirname "$0")/benchmarks/battery/latency.sh"
source "$(dirname "$0")/benchmarks/battery/throughput.sh"
source "$(dirname "$0")/benchmarks/battery/report.sh"

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
_should_run latency    && run_latency_tests
_should_run throughput && run_throughput_tests
_should_run report     && generate_report

log "========================================================="
log " BATERIA CONCLUÍDA — resultados em: ${OUTDIR}"
log "========================================================="
