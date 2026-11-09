#!/bin/bash
# load_scaling.sh — vazão de P-cores e de E-cores com POUCOS e MUITOS cores
# carregados nos dois tipos, e o overhead do shadow fork medido na MESMA rodada.
#
# Cenário = (nE, nP): nE E-cores e nP P-cores carregados AO MESMO TEMPO, cada um
# com um worker do mesmo método, pinado. Mede-se a vazão média por worker nos P
# e nos E.
#
# Cada cenário roda nos modos
#   on  : shadows ligados (kernel com o classificador)
#   off : classificador instalado mas sem produzir (ipcc_min_lag_ms enorme), ou
#         o kernel normal, que não tem classificador
# INTERCALADOS por repetição (off,on / on,off / off,on ...) para que a ordem não
# se confunda com o efeito do shadow. O overhead é on/off dentro da mesma
# rodada, mesmas condições. Governor performance, restaurado ao sair, e turbo
# ligado ou desligado conforme NO_TURBO. A potência média do pacote (RAPL) e a
# frequência dos workers de cada execução vão no CSV para denunciar throttling.
#
# Uso: sudo ./benchmarks/275hx/load_scaling.sh <tag> [método ...]
#   tag: nome da rodada/kernel (ex: partition4, normal). Sem métodos: div16.
# Env: DUR=10 REPS=3 COOL=10 NO_TURBO=0 FREQ_CONTROL=1 E_LEVELS="1 4 all" P_LEVELS="1 all"
#      ("all" = todos os cores online daquele tipo; níveis acima do disponível
#       são cortados e deduplicados)
# Saída em 275hx/results/<tag>/:
#   load_scaling.csv        uma linha por worker (inclui o modo)
#   load_scaling_shadow.csv uma linha por execução: potência do pacote e contadores do shadow
#   load_scaling_per_p.txt  as linhas por P do debugfs, por execução com shadows
# Resumo e comparação: python3 analysis/load_scaling_compare.py --paired <tag>
#                      python3 analysis/load_scaling_compare.py <base> <teste>
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo"; exit 1; }
TAG="${1:?uso: sudo ./benchmarks/275hx/load_scaling.sh <tag> [método ...]}"
shift || true
METHODS=("$@"); [[ ${#METHODS[@]} -gt 0 ]] || METHODS=(div16)
# Padrão: governor performance e turbo LIGADO (NO_TURBO=1 desliga o turbo e fixa
# P em 1,3 GHz / E em 0,9 GHz). Com turbo, o pacote pode chegar ao PL1 (30 W,
# janela de 27 s) e a frequência cair; por isso o intervalo entre execuções é
# maior (COOL=10) e a frequência e a potência de cada execução vão no CSV.
# FREQ_CONTROL=0: não mexe no governor nem no turbo (mede "sem controle de clock";
# a frequência varia com a carga e com o PL1/PL2 do pacote). Padrão 1.
FREQ_CONTROL="${FREQ_CONTROL:-1}"
NO_TURBO="${NO_TURBO:-0}"
DUR="${DUR:-10}"; REPS="${REPS:-3}"
if [[ $FREQ_CONTROL == 1 && $NO_TURBO == 1 ]]; then COOL="${COOL:-1}"; else COOL="${COOL:-10}"; fi
E_LEVELS="${E_LEVELS:-1 4 all}"; P_LEVELS="${P_LEVELS:-1 all}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/275hx/results/$TAG"
mkdir -p "$OUT"
CSV="$OUT/load_scaling.csv"; SCSV="$OUT/load_scaling_shadow.csv"; PCSV="$OUT/load_scaling_per_p.txt"
echo "method,mode,nE,nP,rep,core_type,cpu,ops_s" > "$CSV"
: > "$PCSV"

expand() { local part lo hi IFS=','; for part in $1; do
    if [[ $part == *-* ]]; then lo=${part%-*}; hi=${part#*-}; seq "$lo" "$hi"; else echo "$part"; fi; done; }
online() { [[ ! -e /sys/devices/system/cpu/cpu$1/online ]] || [[ $(cat /sys/devices/system/cpu/cpu$1/online) == 1 ]]; }
PC=(); EC=()
for c in $(expand "$(cat /sys/devices/cpu_core/cpus 2>/dev/null)"); do online "$c" && PC+=("$c"); done
for c in $(expand "$(cat /sys/devices/cpu_atom/cpus 2>/dev/null)"); do online "$c" && EC+=("$c"); done
[[ ${#PC[@]} -gt 0 && ${#EC[@]} -gt 0 ]] || { echo "não achei P-cores e E-cores em /sys/devices/cpu_{core,atom}"; exit 1; }

levels() {   # $1 = lista de níveis, $2 = total disponível -> níveis válidos e únicos
    local l n out=" "
    for l in $1; do
        [[ $l == all ]] && n=$2 || n=$l
        (( n > $2 )) && n=$2
        (( n < 1 )) && continue
        [[ $out == *" $n "* ]] || out+="$n "
    done
    echo $out
}
ELV=$(levels "$E_LEVELS" "${#EC[@]}"); PLV=$(levels "$P_LEVELS" "${#PC[@]}")

STATS=/sys/kernel/debug/ipcc_classifier_stats
LAG=/sys/kernel/debug/ipcc_min_lag_ms
HAVE_SHADOW=0; [[ -r $STATS && -w $LAG ]] && HAVE_SHADOW=1
MODES_A="off"; [[ $HAVE_SHADOW -eq 1 ]] && MODES_A="off on"
RAPL=/sys/class/powercap/intel-rapl:0
HAVE_RAPL=0; [[ -r $RAPL/energy_uj ]] && HAVE_RAPL=1

echo "kernel: $(uname -r) | P: ${PC[*]} | E: ${EC[*]}"
echo "níveis de E: $ELV | níveis de P: $PLV | métodos: ${METHODS[*]} | ${REPS}x ${DUR}s, intervalo ${COOL}s"
if [[ $HAVE_SHADOW -eq 1 ]]; then echo "classificador presente: modos on/off intercalados"
else echo "sem classificador (kernel normal): só o modo off (é o baseline)"; fi
echo "method,mode,nE,nP,rep,pkg_w,mhz_p,mhz_e,inserted,pushed,popped_tick,popped_idle,discarded,start_late,shadows_per_s" > "$SCSV"
if [[ $FREQ_CONTROL == 1 ]]; then echo "governor performance, turbo $([[ $NO_TURBO == 1 ]] && echo desligado || echo ligado)"
else echo "SEM controle de clock: governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor), no_turbo=$(cat "$NT" 2>/dev/null)"; fi
stat_get() { awk -v n="$1" '$1==n {print $2}' "$STATS"; }

# mesmo envelope dos outros benchmarks: governor performance, turbo desligado
NT=/sys/devices/system/cpu/intel_pstate/no_turbo
old_nt=$(cat "$NT" 2>/dev/null || echo "")
old_lag=""; [[ $HAVE_SHADOW -eq 1 ]] && old_lag=$(cat "$LAG")
declare -A old_gov
if [[ $FREQ_CONTROL == 1 ]]; then
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        v=$(cat "$g" 2>/dev/null) || continue
        old_gov[$g]="$v"; echo performance > "$g" 2>/dev/null || true
    done
    [[ -n "$old_nt" ]] && echo "$NO_TURBO" > "$NT"
fi
TMP=$(mktemp -d)
restore() {
    rm -rf "$TMP"
    for g in "${!old_gov[@]}"; do echo "${old_gov[$g]}" > "$g" 2>/dev/null || true; done
    [[ $FREQ_CONTROL == 1 && -n "$old_nt" ]] && echo "$old_nt" > "$NT"
    [[ -n "$old_lag" ]] && echo "$old_lag" > "$LAG" 2>/dev/null || true
}
trap restore EXIT

energy() { [[ $HAVE_RAPL -eq 1 ]] && cat "$RAPL/energy_uj" || echo 0; }

run_one() {   # $1 método $2 modo $3 nE $4 nP $5 rep
    local m=$1 mode=$2 nE=$3 nP=$4 rep=$5 i f e0 e1 w=NA pids=()
    local -a cpus types
    for ((i = 0; i < nP; i++)); do cpus+=("${PC[i]}"); types+=(P); done
    for ((i = 0; i < nE; i++)); do cpus+=("${EC[i]}"); types+=(E); done

    if [[ $HAVE_SHADOW -eq 1 ]]; then
        # off: nenhum alvo fica elegível; on: o valor que a rodada encontrou
        [[ $mode == off ]] && echo 100000000 > "$LAG" || echo "$old_lag" > "$LAG"
        sleep 0.5
        echo 1 > /sys/kernel/debug/ipcc_classifier_reset
    fi
    e0=$(energy)
    ( sleep "$((DUR / 2))"; for i in "${!cpus[@]}"; do
          echo "${types[i]} $(cat /sys/devices/system/cpu/cpu${cpus[i]}/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)"
      done > "$TMP/freq" ) &
    local fpid=$!
    for i in "${!cpus[@]}"; do
        taskset -c "${cpus[i]}" stress-ng --cpu 1 --cpu-method "$m" --timeout "${DUR}s" --metrics-brief > "$TMP/w$i" 2>&1 &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
    wait "$fpid" 2>/dev/null || true
    local mp me
    mp=$(awk '$1=="P" && $2>0 {s+=$2;n++} END{printf "%d", n? s/n/1000 : 0}' "$TMP/freq" 2>/dev/null)
    me=$(awk '$1=="E" && $2>0 {s+=$2;n++} END{printf "%d", n? s/n/1000 : 0}' "$TMP/freq" 2>/dev/null)
    e1=$(energy)
    if [[ $HAVE_RAPL -eq 1 ]]; then
        local d=$((e1 - e0)); (( d < 0 )) && d=$((d + $(cat "$RAPL/max_energy_range_uj")))
        w=$(awk -v d="$d" -v t="$DUR" 'BEGIN{printf "%.1f", d/1e6/t}')
    fi
    for i in "${!cpus[@]}"; do
        local ops; ops=$(awk '/ cpu /{print $9}' "$TMP/w$i" | head -1)
        echo "$m,$mode,$nE,$nP,$rep,${types[i]},${cpus[i]},${ops:-NA}" >> "$CSV"
    done
    if [[ $HAVE_SHADOW -eq 1 && $mode == on ]]; then
        local ins; ins=$(stat_get inserted)
        echo "$m,on,$nE,$nP,$rep,$w,$mp,$me,$ins,$(stat_get pushed),$(stat_get popped_tick),$(stat_get popped_idle),$(stat_get discarded),$(stat_get start_late),$((ins / DUR))" >> "$SCSV"
        grep '^pq ' "$STATS" | sed "s/^/$m nE=$nE nP=$nP rep=$rep /" >> "$PCSV"
    else
        echo "$m,$mode,$nE,$nP,$rep,$w,$mp,$me,0,0,0,0,0,0,0" >> "$SCSV"
    fi
    printf '%s W, P %s MHz' "$w" "$mp"
}

for m in "${METHODS[@]}"; do
    for nE in $ELV; do
        for nP in $PLV; do
            for rep in $(seq 1 "$REPS"); do
                # alterna a ordem a cada repetição: off,on / on,off / off,on ...
                if (( rep % 2 )); then order="$MODES_A"; else order=$(echo $MODES_A | awk '{for(i=NF;i>=1;i--) printf "%s ", $i}'); fi
                for mode in $order; do
                    printf '  %-8s nE=%-2s nP=%-2s rep %s/%s %-3s ... ' "$m" "$nE" "$nP" "$rep" "$REPS" "$mode"
                    run_one "$m" "$mode" "$nE" "$nP" "$rep"
                    echo " ok"
                    sleep "$COOL"
                done
            done
        done
    done
done

echo
python3 -I "$ROOT/analysis/load_scaling_compare.py" --paired "$TAG" || true
echo "resultados em $OUT"
