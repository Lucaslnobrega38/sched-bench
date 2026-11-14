#!/bin/bash
# bench_sanity.sh — estado que pode afetar medidas (trace, debug, knobs, termica). Sudo para ler o debugfs.
D=/sys/kernel/debug; w=0; warn() { echo "  ATENCAO: $*"; w=1; }
echo "kernel: $(uname -srv)"
if [[ -r $D/ipcc_log ]]; then
    echo "ipcc_log=$(cat $D/ipcc_log)  d=$(cat $D/ipcc_shadow_read_us) x=$(cat $D/ipcc_pop_ticks) lag=$(cat $D/ipcc_min_lag_ms)"
    [[ $(cat $D/ipcc_log) == 0 ]] || warn "ipcc_log ligado (trace_printk por evento): echo 0 > $D/ipcc_log"
else echo "sem knobs do IPCC (kernel vanilla/sem IPCC, ou sem root)"; fi
T=/sys/kernel/tracing; [[ -d $T ]] || T=$D/tracing
if [[ -r $T/tracing_on ]]; then
    echo "tracing_on=$(cat $T/tracing_on) tracer=$(cat $T/current_tracer) eventos=$(cat $T/events/enable 2>/dev/null)"
    [[ $(cat $T/current_tracer) == nop ]] || warn "tracer ativo"
    [[ "$(cat $T/events/enable 2>/dev/null)" == 0 ]] || warn "eventos de trace ligados"
else echo "sem tracefs (kernel sem trace, ou sem root)"; fi
p=$(pgrep -a -x "perf|bpftrace|turbostat|trace-cmd|stress-ng" | head -3); [[ -z "$p" ]] || warn "processos de medida/trace rodando: $p"
echo "schedstats=$(cat /proc/sys/kernel/sched_schedstats) nmi_watchdog=$(cat /proc/sys/kernel/nmi_watchdog) autogroup=$(cat /proc/sys/kernel/sched_autogroup_enabled)"
[[ $(cat /proc/sys/kernel/sched_schedstats) == 0 ]] || warn "schedstats ligado"
echo "perfil Acer: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a) | no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo) | governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
for h in /sys/class/hwmon/hwmon*; do [[ "$(cat $h/name)" == coretemp ]] && echo "temp pacote: $(( $(cat $h/temp1_input) / 1000 )) C"; done
echo "package_throttle_count=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count)"
[[ $w == 0 ]] && echo "OK: nada que afete a medida" || echo "ha avisos acima"
