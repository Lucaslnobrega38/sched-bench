#!/bin/bash
# shadow_probe.sh — o que acontece com o pipeline do shadow para UM método do
# stress-ng no E-core, com o stash desligado e depois ligado.
#
# Mostra onde o pipeline para: quantos ticks, quantas submissões, quantos forks
# de shadow (e com que resultado), quantos dwells; mais o stash, se existir.
#
# Uso: sudo PERF=<perf> ./shadow_probe.sh [método=rand48] [duração=5]
# Saída: tela + 275hx/results/probe_<método>/{desligado,ligado}.txt
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
source "$(dirname "$0")/isolate_cpu.sh"

METHOD="${1:-rand48}"
DUR="${2:-5}"
ECPU=8
PERF="${PERF:-perf}"
TR=/sys/kernel/debug/tracing

command -v "$PERF" >/dev/null || { echo "perf não encontrado (PERF=/caminho/perf)"; exit 1; }
[[ -w "$TR/set_ftrace_filter" ]] || { echo "sem acesso a $TR (debugfs?)"; exit 1; }

# kernels anteriores ao renome expõem o mesmo controle como ipcc_odf
SD=/sys/kernel/debug/ipcc_stash
[[ -d $SD ]] || SD=/sys/kernel/debug/ipcc_odf
[[ -d $SD ]] || { echo "nem ipcc_stash nem ipcc_odf no debugfs: kernel sem o stash"; exit 1; }
ORIG_ENABLED=$(cat "$SD/enabled")
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true

OUT="$(cd "$(dirname "$0")/../.." && pwd)/275hx/results/probe_${METHOD}"
mkdir -p "$OUT"

# funções do pipeline; as do stash existem com um dos dois prefixos
PIPE=(intel_update_ipcc ipcc_classify_tick ipcc_classify_eligible ipcc_classify_submit
      ipcc_shadow_fork_work shadow_kernel_clone ipcc_classify_dwell
      ipcc_shadow_syscall_denied ipcc_shadow_confirmed ipcc_evict ipcc_kill_parked_shadow)
STASHF=(link_shadow wrprotect_target unlink_shadow log mark_empty populate fill kill)

# mesmo envelope dos outros testes
declare -A old_gov
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do old_gov[$g]=$(cat "$g"); echo performance > "$g"; done
NT=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat "$NT" 2>/dev/null || echo "")
[[ -n "$old_nt" ]] && echo 1 > "$NT"
BT_PID=""
restore() {
    [[ -n "$BT_PID" ]] && kill -INT "$BT_PID" 2>/dev/null || true
    echo 0 > "$TR/function_profile_enabled" 2>/dev/null || true
    : > "$TR/set_ftrace_filter" 2>/dev/null || true
    echo "$ORIG_ENABLED" > "$SD/enabled" 2>/dev/null || true
    restore_affinity
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g"; done
    [[ -n "$old_nt" ]] && echo "$old_nt" > "$NT"
}
trap restore EXIT

evacuate_cpu "$ECPU"

# ---- ftrace: filtro só com o que existe como símbolo rastreável
echo 0 > "$TR/function_profile_enabled" 2>/dev/null || true
: > "$TR/set_ftrace_filter"
TRACED=()
add_filter() {
    if grep -qE "^$1([. ]|$)" "$TR/available_filter_functions"; then
        echo "$1*" >> "$TR/set_ftrace_filter" && TRACED+=("$1")
    fi
}
for f in "${PIPE[@]}"; do add_filter "$f"; done
for s in "${STASHF[@]}"; do add_filter "ipcc_stash_$s"; add_filter "ipcc_odf_$s"; done
echo "funções rastreadas: ${TRACED[*]}"

# ---- bpftrace: retorno de três pontos de decisão (só os que existem)
sym() { grep -qE " [tT] $1(\.[a-z0-9.]+)?\$" /proc/kallsyms; }
PROG=""
# Só a cpu do alvo: os shadows disparam para qualquer task de E-core do sistema.
# O bpftrace termina SOZINHO (interval + exit): um processo em segundo plano de
# um script ignora SIGINT, então esperar um sinal trava.
BT_SECS=$(( DUR + 6 ))
sym shadow_kernel_clone    && PROG+="kretprobe:shadow_kernel_clone /cpu == $ECPU/ { if ((uint64)retval >= 0xfffffffffffff000) { @clone_erro[(int64)retval] = count(); } else { @clone_ok = count(); } } "
sym ipcc_classify_submit   && PROG+="kretprobe:ipcc_classify_submit /cpu == $ECPU/ { @submit_ret[(int32)retval] = count(); } "
sym ipcc_classify_eligible && PROG+="kretprobe:ipcc_classify_eligible /cpu == $ECPU/ { @elegivel[retval & 0xff] = count(); } "
HAVE_BT=0
if command -v bpftrace >/dev/null && [[ -n "$PROG" ]]; then
    HAVE_BT=1
    PROG+="interval:s:${BT_SECS} { exit(); } "
fi
[[ $HAVE_BT -eq 1 ]] || echo "(bpftrace indisponível ou sem símbolos: só o ftrace)"

fsum() {   # -> "nome hits_total tempo_total_us hits_cpu8 tempo_cpu8_us"
    local f cpu
    for f in "$TR"/trace_stat/function*; do
        [[ -r "$f" ]] || continue
        cpu=${f##*function}
        awk -v cpu="$cpu" '$1=="Function" || $1 ~ /^-+$/ || NF<3 {next}
            {n=$1; sub(/\..*/,"",n); print n, cpu, $2, $3}' "$f"
    done | awk -v e="$ECPU" '
        {h[$1]+=$3; t[$1]+=$4; if ($2==e) {h8[$1]+=$3; t8[$1]+=$4}}
        END{for (n in h) printf "%s %d %.0f %d %.0f\n", n, h[n], t[n], h8[n]+0, t8[n]+0}'
}
pev() { awk -F, -v e="$2" '$3 ~ "^"e {gsub(/[^0-9.]/,"",$1); print $1}' "$1" | head -1; }
wait_idle() {
    local rp i; rp=$(pgrep -x ipcc-reaper | head -1 || true)
    for i in $(seq 1 25); do
        [[ -z "$rp" || -z "$(ps --ppid "$rp" -o pid= 2>/dev/null)" ]] && return 0
        sleep 0.2
    done
}

run_phase() {   # $1 = 0|1 (stash), $2 = nome
    local on="$1" name="$2" rep="$OUT/$2.txt" perfout stressout seg0 seg1 ops
    echo "$on" > "$SD/enabled"
    [[ "$(cat "$SD/enabled")" == "$on" ]] || { echo "falha ao ajustar o stash"; return 1; }
    wait_idle; sleep 1

    perfout=$(mktemp); stressout=$(mktemp); local st0 st1 btout fs
    st0=$(mktemp); st1=$(mktemp); btout=$(mktemp); fs=$(mktemp)
    cat "$SD/stats" > "$st0"
    seg0=$(dmesg | grep -c "segfault at" || true)

    echo 0 > "$TR/function_profile_enabled"; echo 1 > "$TR/function_profile_enabled"
    if [[ $HAVE_BT -eq 1 ]]; then
        bpftrace -e "$PROG" > "$btout" 2>&1 &
        BT_PID=$!
        for _ in $(seq 1 30); do grep -q "Attaching" "$btout" 2>/dev/null && break; sleep 0.1; done
        sleep 0.5
    fi

    taskset -c "$ECPU" "$PERF" stat -x, -e task-clock,context-switches,page-faults -o "$perfout" -- \
        stress-ng --cpu 1 --cpu-method "$METHOD" --timeout "${DUR}s" --metrics-brief > "$stressout" 2>&1 || true
    ops=$(awk '/cpu /{print $9}' "$stressout")

    echo 0 > "$TR/function_profile_enabled"
    fsum > "$fs"
    if [[ $HAVE_BT -eq 1 ]]; then
        # espera o bpftrace sair sozinho (interval/exit); só então força
        for _ in $(seq 1 75); do kill -0 "$BT_PID" 2>/dev/null || break; sleep 0.2; done
        if kill -0 "$BT_PID" 2>/dev/null; then
            echo "(bpftrace não saiu sozinho; encerrando)"
            kill -TERM "$BT_PID" 2>/dev/null || true; sleep 1
            kill -KILL "$BT_PID" 2>/dev/null || true
        fi
        wait "$BT_PID" 2>/dev/null || true
        BT_PID=""
    fi
    wait_idle
    cat "$SD/stats" > "$st1"
    seg1=$(dmesg | grep -c "segfault at" || true)

    {
        echo "=== ${METHOD}, ${DUR}s, cpu${ECPU}, stash=$([[ $on == 1 ]] && echo LIGADO || echo DESLIGADO) ==="
        printf "ops/s=%s  task-clock=%s ms  ctx-switches=%s  page-faults=%s\n" "${ops:-NA}" \
            "$(pev "$perfout" task-clock)" "$(pev "$perfout" context-switches)" "$(pev "$perfout" page-faults)"
        echo "(task-clock bem acima de ${DUR}000 ms = tempo de shadows herdado pelo perf)"
        echo
        printf "%-30s %10s %12s | %10s %12s\n" "função" "hits(todas)" "tempo_us" "hits(cpu${ECPU})" "tempo_us"
        for f in "${TRACED[@]}"; do
            awk -v f="$f" '$1==f {printf "%-30s %10d %12d | %10d %12d\n",$1,$2,$3,$4,$5; found=1} END{if(!found) printf "%-30s %10d %12d | %10d %12d\n",f,0,0,0,0}' "$fs"
        done
        echo
        echo "retornos (bpftrace):"
        grep -E "^@" "$btout" 2>/dev/null | sed 's/^/  /' || true
        [[ $HAVE_BT -eq 1 ]] && ! grep -qE "^@" "$btout" 2>/dev/null && echo "  (nenhum evento; saída do bpftrace:)" && head -5 "$btout" | sed 's/^/    /'
        echo
        echo "contadores do stash (delta):"
        awk 'FNR==NR{a[$1]=$2;next} NF==2 && ($1 in a) && ($2-a[$1])!=0 {printf "  %-18s %+d\n",$1,$2-a[$1]}' "$st0" "$st1"
        echo "segfaults registrados no período: $((seg1 - seg0))"
    } | tee "$rep"
    rm -f "$perfout" "$stressout" "$st0" "$st1" "$btout" "$fs"
    echo
}

run_phase 0 desligado
run_phase 1 ligado
echo "relatórios em $OUT"
