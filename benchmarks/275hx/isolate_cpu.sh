#!/bin/bash
# isolate_cpu.sh — para `source`. Esvazia uma cpu de todas as tasks fair
# (SCHED_OTHER/BATCH/IDLE) trocando a afinidade delas, e devolve tudo no fim.
#
#   evacuate_cpu <cpu>    move as tasks; preenche EVAC_MOVED, EVAC_STUCK
#   restore_affinity      restaura as afinidades guardadas (chamar no trap EXIT)
#
# Não move: kthreads por-cpu (o kernel recusa), tasks RT/deadline, IRQs, nem
# tasks criadas depois da chamada. Destino = cpus permitidas ao ipcc-reaper
# (todas menos o core do classificador, se houver) menos a cpu testada.
# Precisa de root.

ISOLATE_SAVE=""
EVAC_MOVED=0
EVAC_STUCK=0

_cpu_in_list() {
    local cpu="$1" list="$2" part lo hi
    local IFS=','
    for part in $list; do
        if [[ "$part" == *-* ]]; then
            lo="${part%-*}"; hi="${part#*-}"
        else
            lo="$part"; hi="$part"
        fi
        (( cpu >= lo && cpu <= hi )) && return 0
    done
    return 1
}

# lista "0-6,8-23" sem a cpu $2, expandida: "0,1,2,..."
_list_minus() {
    local list="$1" drop="$2" out="" part lo hi c
    local IFS=','
    for part in $list; do
        if [[ "$part" == *-* ]]; then
            lo="${part%-*}"; hi="${part#*-}"
        else
            lo="$part"; hi="$part"
        fi
        for (( c = lo; c <= hi; c++ )); do
            [[ "$c" -eq "$drop" ]] || out+="${out:+,}$c"
        done
    done
    echo "$out"
}

evacuate_cpu() {
    local cpu="$1" allowed="" target rp tid cls cur comm
    local stuck_names
    stuck_names=$(mktemp)
    ISOLATE_SAVE=$(mktemp)
    EVAC_MOVED=0
    EVAC_STUCK=0

    rp=$(pgrep -x ipcc-reaper | head -1 || true)
    if [[ -n "$rp" ]]; then
        allowed=$(awk '/^Cpus_allowed_list:/ {print $2}' "/proc/${rp}/status" 2>/dev/null || true)
    fi
    [[ -n "$allowed" ]] || allowed="0-$(( $(nproc --all) - 1 ))"
    target=$(_list_minus "$allowed" "$cpu")
    if [[ -z "$target" ]]; then
        echo "evacuate_cpu: nenhuma cpu de destino" >&2
        rm -f "$stuck_names"
        return 1
    fi

    while read -r tid cls; do
        case "$cls" in TS|B|IDL) ;; *) continue ;; esac
        # gancho de teste: restringe a algumas threads (lista separada por espaço)
        if [[ -n "${ISOLATE_ONLY_TIDS:-}" && " ${ISOLATE_ONLY_TIDS} " != *" ${tid} "* ]]; then
            continue
        fi
        cur=$(taskset -pc "$tid" 2>/dev/null | sed 's/.*: //') || continue
        [[ -n "$cur" ]] || continue
        _cpu_in_list "$cpu" "$cur" || continue
        comm=$(cat "/proc/${tid}/comm" 2>/dev/null || true)
        if taskset -pc "$target" "$tid" >/dev/null 2>&1; then
            printf '%s\t%s\t%s\n' "$tid" "$cur" "$comm" >> "$ISOLATE_SAVE"
            EVAC_MOVED=$(( EVAC_MOVED + 1 ))
        else
            echo "$comm" >> "$stuck_names"
            EVAC_STUCK=$(( EVAC_STUCK + 1 ))
        fi
    done < <(ps -eLo tid=,cls=)

    echo "cpu${cpu}: ${EVAC_MOVED} threads fair movidas para [${target}]; ${EVAC_STUCK} imóveis (kthreads por-cpu):"
    sort "$stuck_names" | uniq -c | sort -nr | head -8 | sed 's/^/    /'
    rm -f "$stuck_names"
}

restore_affinity() {
    local tid orig comm
    [[ -n "$ISOLATE_SAVE" && -f "$ISOLATE_SAVE" ]] || return 0
    while IFS=$'\t' read -r tid orig comm; do
        # só devolve se o número ainda é a mesma task
        [[ "$(cat "/proc/${tid}/comm" 2>/dev/null)" == "$comm" ]] || continue
        taskset -pc "$orig" "$tid" >/dev/null 2>&1 || true
    done < "$ISOLATE_SAVE"
    rm -f "$ISOLATE_SAVE"
    ISOLATE_SAVE=""
}
