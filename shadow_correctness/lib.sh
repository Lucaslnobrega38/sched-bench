#!/bin/bash
# lib.sh — para `source`. Funções comuns dos testes de corretude do shadow fork.
#
# Convenções: cada teste faz `source lib.sh; sc_init <nome>`, usa pass/fail/info
# e termina com `sc_finish`. Código de saída: 0 tudo certo, 1 alguma falha,
# 77 kernel sem o classificador (teste pulado).

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBG=/sys/kernel/debug
TRC=/sys/kernel/tracing
[[ -d $TRC/events ]] || TRC=$DBG/tracing
STATS=$DBG/ipcc_classifier_stats

SC_PASS=0
SC_FAIL=0
SC_NAME=""
SC_OUT=""
SC_BG=()

_expand_cpulist() {   # "0-3,5" -> "0 1 2 3 5"
    local part lo hi IFS=','
    for part in $1; do
        if [[ $part == *-* ]]; then lo=${part%-*}; hi=${part#*-}; seq -s' ' "$lo" "$hi" | tr '\n' ' '
        else printf '%s ' "$part"; fi
    done
}

_cpu_online() { [[ ! -e /sys/devices/system/cpu/cpu$1/online ]] || [[ $(cat /sys/devices/system/cpu/cpu$1/online) == 1 ]]; }

# PCPUS / ECPUS: cpus online de cada tipo, como listas separadas por vírgula
detect_cpus() {
    local c p="" e=""
    for c in $(_expand_cpulist "$(cat /sys/devices/cpu_core/cpus 2>/dev/null)"); do
        _cpu_online "$c" && p+="$c,"
    done
    for c in $(_expand_cpulist "$(cat /sys/devices/cpu_atom/cpus 2>/dev/null)"); do
        _cpu_online "$c" && e+="$c,"
    done
    PCPUS=${p%,}
    ECPUS=${e%,}
    [[ -n $PCPUS && -n $ECPUS ]] || { echo "não achei P-cores e E-cores em /sys/devices/cpu_{core,atom}"; exit 77; }
    IFS=, read -ra PARR <<< "$PCPUS"
    IFS=, read -ra EARR <<< "$ECPUS"
}

sc_knob_get() { cat "$DBG/$1"; }
sc_knob_set() { echo "$2" > "$DBG/$1"; }

sc_init() {
    SC_NAME="$1"
    [[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
    [[ -r $STATS ]] || { echo "SKIP: sem $STATS (kernel sem o classificador novo, ou debugfs não montado)"; exit 77; }
    detect_cpus

    SC_OUT="${SC_RESULTS:-$SC_DIR/results/$(date +%Y%m%d_%H%M%S)}/$SC_NAME"
    mkdir -p "$SC_OUT"

    # guarda os knobs e restaura ao sair
    SC_SAVE_LAG=$(sc_knob_get ipcc_min_lag_ms)
    SC_SAVE_AGE=$(sc_knob_get ipcc_max_age_ms)
    SC_SAVE_READ=$(sc_knob_get ipcc_shadow_read_us)
    SC_SAVE_LOG=$(sc_knob_get ipcc_log)
    SC_DMESG0=$(dmesg | wc -l)
    trap sc_cleanup EXIT

    # parâmetros comuns, sobrescrevíveis por ambiente
    LAG_MS="${LAG_MS:-5}"
    READ_US="${READ_US:-100}"
    sc_knob_set ipcc_min_lag_ms "$LAG_MS"
    sc_knob_set ipcc_shadow_read_us "$READ_US"
    sc_knob_set ipcc_max_age_ms 0

    echo "== $SC_NAME  (P: $PCPUS | E: $ECPUS | lag=${LAG_MS}ms read=${READ_US}us)"
    echo "   saída: $SC_OUT"
}

sc_cleanup() {
    local p
    for p in "${SC_BG[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null || true; done
    sc_log_off
    sc_knob_set ipcc_min_lag_ms "$SC_SAVE_LAG" 2>/dev/null || true
    sc_knob_set ipcc_max_age_ms "$SC_SAVE_AGE" 2>/dev/null || true
    sc_knob_set ipcc_shadow_read_us "$SC_SAVE_READ" 2>/dev/null || true
    sc_knob_set ipcc_log "$SC_SAVE_LOG" 2>/dev/null || true
}

# ---- resultado --------------------------------------------------------------
pass() { SC_PASS=$((SC_PASS + 1)); printf '  \e[32mPASS\e[0m  %s\n' "$1"; echo "PASS $1" >> "$SC_OUT/result.txt"; }
fail() { SC_FAIL=$((SC_FAIL + 1)); printf '  \e[31mFAIL\e[0m  %s\n' "$1"; echo "FAIL $1" >> "$SC_OUT/result.txt"; }
info() { printf '  ....  %s\n' "$1"; echo "INFO $1" >> "$SC_OUT/result.txt"; }
check() { # check "descrição" <comando de teste...>
    local desc="$1"; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}
sc_finish() {
    echo "-- $SC_NAME: $SC_PASS passou, $SC_FAIL falhou"
    [[ $SC_FAIL -eq 0 ]]
}

# ---- contadores -------------------------------------------------------------
stat_get() { awk -v n="$1" '$1==n {print $2}' "$STATS"; }
sc_reset() { echo 1 > "$DBG/ipcc_classifier_reset"; }
stat_snapshot() { cp "$STATS" "$1"; }

# ---- log por evento ---------------------------------------------------------
sc_log_on() {
    echo 0 > "$TRC/tracing_on"
    : > "$TRC/trace"
    echo 32768 > "$TRC/buffer_size_kb" 2>/dev/null || true
    sc_knob_set ipcc_log 1
    echo 1 > "$TRC/tracing_on"
}
sc_log_off() { sc_knob_set ipcc_log 0 2>/dev/null || true; }
# sc_log_dump <arquivo>: só as linhas de evento, mais o cabeçalho de perdas
sc_log_dump() {
    echo 0 > "$TRC/tracing_on"
    sc_log_off
    cp "$TRC/trace" "$1"
    info "log: $(grep -c ' ev=' "$1") eventos em $1 ($(grep -m1 'entries-in-buffer' "$1" | sed 's/#//'))"
}

# ---- cargas -----------------------------------------------------------------
# start_load <método> <cpu> [duração]: um stress-ng de 1 worker pinado em <cpu>
start_load() {
    local method="$1" cpu="$2" dur="${3:-$DUR}"
    taskset -c "$cpu" stress-ng --cpu 1 --cpu-method "$method" --timeout "${dur}s" >/dev/null 2>&1 &
    SC_BG+=($!)
}
wait_load() { local p; for p in "${SC_BG[@]:-}"; do [[ -n $p ]] && wait "$p" 2>/dev/null || true; done; SC_BG=(); }

# pid do worker (filho) de um stress-ng
worker_of() { pgrep -P "$1" | head -1; }

proc_sched() { awk -v k="$2" '$1==k {print $NF; exit}' "/proc/$1/sched"; }

# ---- drenagem e limpeza -----------------------------------------------------
# espera a FIFO esvaziar e os slots liberarem (até <s> segundos)
wait_drained() {
    local s="${1:-3}" i
    for i in $(seq 1 $((s * 10))); do
        [[ $(stat_get fifo_len) == 0 && $(stat_get slots_busy) == 0 ]] && return 0
        sleep 0.1
    done
    return 1
}

reaper_children() {
    local rp; rp=$(pgrep -x ipcc-reaper | head -1)
    [[ -n $rp ]] || { echo 0; return; }
    # sem filhos o ps sai com 1: sob `set -e -o pipefail` isso matava o script
    { ps --ppid "$rp" -o pid= 2>/dev/null || true; } | wc -l
}

# estado dos filhos presos do ipcc-reaper (um shadow que não terminou)
dump_stuck() {
    local rp p; rp=$(pgrep -x ipcc-reaper | head -1); [[ -n $rp ]] || return 0
    {
        echo "--- $(date +%T) slots_busy=$(stat_get slots_busy) fifo_len=$(stat_get fifo_len)"
        for p in $({ ps --ppid "$rp" -o pid= 2>/dev/null || true; }); do
            echo "== shadow $p"
            ps -o pid,stat,psr,wchan:32,etime,time -p "$p" 2>/dev/null
            grep -E 'ipcc_shadow_status|^policy|se.nr_migrations' "/proc/$p/sched" 2>/dev/null
            cat "/proc/$p/stack" 2>/dev/null | head -12
        done
        grep -E 'cap_expired|deadline_not_curr|deadline_invalid' "$STATS"
    } >> "$SC_OUT/stuck.txt"
    info "estado do shadow preso gravado em $SC_OUT/stuck.txt"
}

# erros novos no log do kernel desde sc_init
dmesg_bad() {
    dmesg | tail -n +$((SC_DMESG0 + 1)) | grep -E -i 'BUG:|WARNING:|Oops|segfault at|lockdep|possible .* deadlock|RCU.*stall|hung task|general protection|kernel NULL' || true
}
check_dmesg_clean() {
    local bad; bad=$(dmesg_bad)
    if [[ -z $bad ]]; then pass "log do kernel sem BUG/WARNING/segfault/lockdep"
    else fail "log do kernel tem problemas:"; echo "$bad" | head -10 | sed 's/^/        /'; echo "$bad" > "$SC_OUT/dmesg_bad.txt"; fi
}

# identidades dos contadores; só valem com o sistema drenado
check_identities() {
    local ins ptk pid dis fl con sys tmo oth busy popped ended hist_sum
    ins=$(stat_get inserted); ptk=$(stat_get popped_tick); pid=$(stat_get popped_idle)
    dis=$(stat_get discarded); fl=$(stat_get fifo_len); con=$(stat_get confirmed)
    sys=$(stat_get syscall); tmo=$(stat_get timeout); oth=$(stat_get other)
    busy=$(stat_get slots_busy)
    popped=$((ptk + pid)); ended=$((con + sys + tmo + oth))
    hist_sum=$(awk '$1=="hist" {s+=$3} END{print s+0}' "$STATS")

    check "inserted ($ins) = popped ($popped) + discarded ($dis) + fifo_len ($fl)" [ "$ins" -eq $((popped + dis + fl)) ]
    check "popped ($popped) = terminados ($ended) + slots ocupados ($busy)" [ "$popped" -eq $((ended + busy)) ]
    check "histograma de vida soma os terminados ($hist_sum = $ended)" [ "$hist_sum" -eq "$ended" ]
}

check_drained() {
    if wait_drained 4; then pass "FIFO vazia e nenhum slot ocupado depois da carga"
    else fail "FIFO/slots não drenaram: fifo_len=$(stat_get fifo_len) slots_busy=$(stat_get slots_busy)"; dump_stuck; fi
    local kids; kids=$(reaper_children)
    check "nenhum filho preso no ipcc-reaper ($kids)" [ "$kids" -eq 0 ]
}

# roda o analisador de log; $@ = argumentos extras
sc_analyze() {
    python3 -I "$SC_DIR/analyze_log.py" --pcpus "$PCPUS" --lag-ms "$LAG_MS" "$@"
}
