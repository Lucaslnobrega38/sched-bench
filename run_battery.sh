#!/bin/bash
# =============================================================================
# BATERIA DE TESTES: ITD IPCC Scheduler vs asym_packing
# Detecta topologia híbrida via acpi_cppc. Fases: placement, throughput,
# heatmap (opt-in), report.
# Uso: sudo ./run_battery.sh [--kernel <tag>] [--runs <N>] [--outdir <dir>]
#                             [--phases <lista>] [--skip-to <fase>] [--oracle-pin]
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

# P-core reservado ao classificador shadow: isolado e preso na freq mínima,
# nada do workload roda nele. Vazio em kernels sem o mecanismo.
#
# O reaper em si não é pinado nesse cpu (só gerencia a fila, roda em
# qualquer housekeeping cpu) — quem fica preso lá é o shadow, sob demanda.
# O sinal estável é ipcc_pin_min_freq(): scaling_max_freq é forçado ao
# scaling_min_freq só nesse cpu, entre os P-cores já detectados.
_detect_classifier_cpu() {
    local cpu min max
    pgrep -x ipcc-reaper &>/dev/null || return 0

    local -a arr
    IFS=',' read -ra arr <<< "$PCORES"
    for cpu in "${arr[@]}"; do
        min=$(cat "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq" 2>/dev/null) || continue
        max=$(cat "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_max_freq" 2>/dev/null) || continue
        if [[ -n "$min" && "$min" == "$max" ]]; then
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

_detect_hybrid_topology

CLASSIFIER_CPU=""
_detect_classifier_cpu

TOTAL_CPUS=$(nproc --all)   # fixo: com nosmt (CPUs offline) o nº de tarefas NAO muda (12 no i5, 32 no i9)
if [[ -n "$CLASSIFIER_CPU" ]]; then
    PCORES=$(_drop_cpu_from_list "$PCORES" "$CLASSIFIER_CPU")
    ECORES=$(_drop_cpu_from_list "$ECORES" "$CLASSIFIER_CPU")
    TOTAL_CPUS=$(( TOTAL_CPUS - 1 ))
fi

N_PHYSICAL_PCORES=$(_count_physical_pcores)
ALLCORES="${PCORES}${ECORES:+,${ECORES}}"

# --oracle-pin: cls2 preso a 1 thread por P-core físico, cls1 no resto.
ORACLE_PIN=0
P_FIRST_THREADS=()
CLS1_CPUS=""

_build_oracle_sets() {
    local -A seen=()
    local -a arr
    local cpu core_id siblings=""
    IFS=',' read -ra arr <<< "$PCORES"
    for cpu in "${arr[@]}"; do
        core_id=$(cat "/sys/devices/system/cpu/cpu${cpu}/topology/core_id" 2>/dev/null) || continue
        if [[ -z "${seen[$core_id]+x}" ]]; then
            seen[$core_id]=1
            P_FIRST_THREADS+=("$cpu")
        else
            siblings="${siblings:+$siblings,}$cpu"
        fi
    done
    CLS1_CPUS="${siblings}${ECORES:+${siblings:+,}${ECORES}}"
}

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
        --oracle-pin) ORACLE_PIN=1; shift ;;
        --help)
            echo "Uso: sudo ./run_battery.sh [--kernel <tag>] [--runs <N>] [--outdir <dir>] [--oracle-pin]"
            echo "  --oracle-pin: cls2 preso a 1 thread por P-core físico, cls1 no resto (teto teórico;"
            echo "                use --kernel oracle_pin e --phases placement,throughput)"
            echo "Fases: placement, throughput, report, heatmap (opt-in: --phases heatmap;"
            echo "       1 corrida de HEATMAP_DURATION=200 s; HEATMAP_SCENARIO=contention|relaxed)"
            echo "  --phases: lista separada por vírgula (ex: --phases placement)"
            echo "  --skip-to: pula fases anteriores (ex: --skip-to report)"
            exit 0 ;;
        *) die "Argumento desconhecido: $1" ;;
    esac
done

[[ "$ORACLE_PIN" == 1 ]] && { require taskset; _build_oracle_sets; }

OUTDIR="${OUTDIR:-./results/${KERNEL_TAG}}"
LOG="${OUTDIR}/run.log"

mkdir -p "$OUTDIR"/{placement,raw,throughput}

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
if [[ "$ORACLE_PIN" == 1 ]]; then
    log " ORÁCULO PINADO: cls2 → [${P_FIRST_THREADS[*]}]  cls1 → [${CLS1_CPUS}]"
fi
if [[ -n "$CLASSIFIER_CPU" ]]; then
    log " CPU ${CLASSIFIER_CPU} reservada ao classificador shadow — excluída"
else
    log " Sem classificador shadow ativo — nenhuma CPU excluída"
fi
log "========================================================="

source "$(dirname "$0")/benchmarks/battery/preflight.sh"
source "$(dirname "$0")/benchmarks/battery/placement.sh"
source "$(dirname "$0")/benchmarks/battery/throughput.sh"
source "$(dirname "$0")/benchmarks/battery/heatmap.sh"
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
_should_run throughput && run_throughput_tests
# heatmap é opt-in (200 s por corrida): só roda com --phases heatmap
[[ ",${ONLY_PHASES}," == *",heatmap,"* ]] && run_heatmap
_should_run report     && generate_report

log "========================================================="
log " BATERIA CONCLUÍDA — resultados em: ${OUTDIR}"
log "========================================================="
