#!/bin/bash
# benchmarks/275hx/preflight.sh — verificação de hardware (topologia FIXA, sem detecção)

run_preflight() {
    log "=== FASE 0: PREFLIGHT ==="

    [[ $EUID -eq 0 ]] || die "Execute como root (sudo)"

    require stress-ng python3

    local cpu_model
    cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    log "CPU: ${cpu_model}"
    echo "$cpu_model" >> "${OUTDIR}/raw/hw_info.txt"

    if [[ "$cpu_model" != *"275HX"* ]]; then
        warn "CPU detectada (${cpu_model}) difere do esperado (Ultra 9 275HX) — topologia hard-coded (P=0-7, E=8-23) pode estar incorreta"
    fi

    # Sanity check apenas informativo: confere se acpi_cppc concorda com a
    # topologia fixa. NÃO é usado para decidir nada — a topologia é hard-coded.
    local _pcore_arr _ecore_arr
    IFS=',' read -ra _pcore_arr <<< "$PCORES"
    IFS=',' read -ra _ecore_arr <<< "$ECORES"

    local p_min=999 e_max=0
    for cpu in "${_pcore_arr[@]}"; do
        local v
        v=$(cat "/sys/devices/system/cpu/cpu${cpu}/acpi_cppc/highest_perf" 2>/dev/null || echo "")
        [[ -n "$v" ]] || continue
        echo "  CPU${cpu} (P, fixo): acpi_highest_perf=${v}" | tee -a "${OUTDIR}/raw/hw_info.txt"
        (( v < p_min )) && p_min=$v
    done
    for cpu in "${_ecore_arr[@]}"; do
        local v
        v=$(cat "/sys/devices/system/cpu/cpu${cpu}/acpi_cppc/highest_perf" 2>/dev/null || echo "")
        [[ -n "$v" ]] || continue
        echo "  CPU${cpu} (E, fixo): acpi_highest_perf=${v}" | tee -a "${OUTDIR}/raw/hw_info.txt"
        (( v > e_max )) && e_max=$v
    done
    if [[ "$p_min" != 999 && "$e_max" != 0 && "$p_min" -le "$e_max" ]]; then
        warn "acpi_cppc não confirma separação P/E hard-coded (min highest_perf em P=${p_min} <= max em E=${e_max}) — verifique CPUs 0-7/8-23 nesta máquina"
    fi

    {
        echo "=== uname ==="
        uname -a
        echo "=== cpuinfo ==="
        cat /proc/cpuinfo
        echo "=== lstopo ==="
        lstopo --of txt 2>/dev/null || true
        echo "=== scheduler features ==="
        cat /sys/kernel/debug/sched/features 2>/dev/null || cat /sys/kernel/debug/sched_features 2>/dev/null || true
        echo "=== HFI/ITD status ==="
        rdmsr -a 0x17d1 2>/dev/null || true   # IA32_HW_FEEDBACK_CONFIG
        rdmsr -a 0x17d4 2>/dev/null || true   # HW_FEEDBACK_THREAD_CONFIG
    } >> "${OUTDIR}/raw/hw_info.txt"

    log "Fixando CPU governor em 'performance'..."
    ORIGINAL_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    echo "$ORIGINAL_GOVERNOR" > "${OUTDIR}/raw/original_governor.txt"

    for cpu_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$cpu_path" 2>/dev/null || true
    done
    log "Governor: ${ORIGINAL_GOVERNOR} → performance"

    # turbo desativado para reduzir variância de frequência
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        cat /sys/devices/system/cpu/intel_pstate/no_turbo > "${OUTDIR}/raw/original_turbo.txt"
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
        log "Intel turbo: desativado"
    fi

    trap _restore_system EXIT

    log "Aquecimento (${WARMUP_SEC}s)..."
    stress-ng --cpu "$(nproc)" --timeout "${WARMUP_SEC}s" --quiet

    log "Preflight concluído."
}

_restore_system() {
    local orig_gov
    orig_gov=$(cat "${OUTDIR}/raw/original_governor.txt" 2>/dev/null || echo "powersave")
    log "Restaurando governor → ${orig_gov}"
    for cpu_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$orig_gov" > "$cpu_path" 2>/dev/null || true
    done

    if [[ -f "${OUTDIR}/raw/original_turbo.txt" ]]; then
        local orig_turbo
        orig_turbo=$(cat "${OUTDIR}/raw/original_turbo.txt")
        echo "$orig_turbo" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
        log "Intel turbo restaurado."
    fi
}
