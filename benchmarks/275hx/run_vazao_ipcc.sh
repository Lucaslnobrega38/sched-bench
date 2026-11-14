#!/bin/bash
# run_vazao_ipcc.sh — no kernel IPCC: mesmo benchmark do noipcc_*, d250x16 vs off alternando (sem oracle).
# Uso: sudo ./run_vazao_ipcc.sh      (resultados: ipcc_perf_turboon / ipcc_perf_turbooff)
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
cd "$(dirname "$0")" || exit 1
D=/sys/kernel/debug
[[ -r $D/ipcc_pop_ticks ]] || { echo "kernel sem os knobs do IPCC: nao e o kernel certo"; exit 1; }
echo "kernel $(uname -r) | perfil $(cat /sys/firmware/acpi/platform_profile 2>/dev/null) | d=$(cat $D/ipcc_shadow_read_us) x=$(cat $D/ipcc_pop_ticks) lag=$(cat $D/ipcc_min_lag_ms)"
for nt in 0 1; do
    NO_TURBO=$nt DUR=30 REPS=8 CFGS_SEL="d250x16 off" ./throughput_cfg.sh ipcc_perf_turbo$([ $nt = 0 ] && echo on || echo off)
done
