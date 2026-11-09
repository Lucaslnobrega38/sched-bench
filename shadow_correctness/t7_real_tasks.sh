#!/bin/bash
# t7_real_tasks.sh — tasks reais (não stress-ng) recebem a classe certa pelos shadows?
# Sem debounce, cada leitura de classe é uma amostra instantânea; o que se
# compara é a DISTRIBUIÇÃO. Para cada programa: (1) oráculo: roda DUR s num
# P-core e amostra o ipcc a cada SAMPLE_MS ms (~DUR*1000/SAMPLE_MS amostras);
# (2) roda DUR s num E-core, e cada shadow contribui com uma amostra (a classe
# que leu). A distância de variação total TV entre as duas distribuições (sobre
# as leituras válidas) decide: ok se TV <= TV_MAX. O relatório mostra também
# como cada shadow terminou (syscall ou timer) e quanto executou. Programas
# multithread nunca são elegíveis (sem shadows): aparecem como "não elegível".
#
# Uso: sudo [DUR=6] [SAMPLE_MS=10] [TV_MAX=0.25] [GROUPS_SEL="hash compress lang compile db io mt"] \
#            [PROGS="sha1sum zstd ..."] ./t7_real_tasks.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init t7_real_tasks
DUR="${DUR:-6}"; SAMPLE_MS="${SAMPLE_MS:-10}"; TV_MAX="${TV_MAX:-0.25}"
PCPU=${PARR[0]}; ECPU=${EARR[0]}
SAMPCPU=${EARR[-1]}   # o amostrador roda num E-core que não é o do alvo
D="$SC_OUT/work"; mkdir -p "$D"

# ---- arquivos de apoio (aspas internas ficam fora da linha de comando)
cat > "$D/py_float.py" <<'PY'
import math
x = 0.0
while True:
    for i in range(1, 2000):
        x += math.sin(i) * math.sqrt(i)
PY
cat > "$D/py_dict.py" <<'PY'
d = {}
i = 0
while True:
    d[i % 50000] = str(i) * 3
    i += 1
PY
cat > "$D/py_sort.py" <<'PY'
import random
while True:
    a = [random.random() for _ in range(200000)]
    a.sort()
PY
cat > "$D/pl_loop.pl" <<'PL'
my $x = 0;
while (1) { $x += sqrt($_) for 1..1000; }
PL
cat > "$D/loop.lua" <<'LUA'
local x = 0
while true do
  for i = 1, 100000 do x = x + math.sin(i) * i % 7 end
end
LUA
cat > "$D/pi.bc" <<'BC'
scale=20000
4*a(1)
BC
printf 'scale=3000\n4*a(1)\n' > "$D/pi3000.bc"
cat > "$D/gen_c.py" <<'PY'
import sys
n = 40000
out = []
for i in range(n):
    out.append(f"int f{i}(int a, int b) {{ int s = 0; for (int k = 0; k < a; k++) s += (k * {i % 97 + 1}) ^ (b + k); return s + a * b; }}")
open(sys.argv[1], "w").write("\n".join(out) + "\n")
PY
python3 "$D/gen_c.py" "$D/big.c"
CC1=$(gcc -print-prog-name=cc1 2>/dev/null || true)

declare -A CMD GRP FIN
add() { CMD[$1]="$3"; GRP[$1]="$2"; ORDER+=("$1"); }
# programas FINITOS: rodam até terminar nos dois cores e a distribuição é a da
# execução inteira. Necessário quando o programa tem fases: o E-core anda mais
# devagar que o P, e uma janela fixa de relógio compara fases diferentes.
addfin() { add "$@"; FIN[$1]=1; }
ORDER=()
# hash / checksum (quase todos fazem read() em /dev/zero: syscall com frequência)
add sha1sum    hash     "sha1sum /dev/zero"
add sha256sum  hash     "sha256sum /dev/zero"
add sha512sum  hash     "sha512sum /dev/zero"
add md5sum     hash     "md5sum /dev/zero"
add b2sum      hash     "b2sum /dev/zero"
add cksum      hash     "cksum /dev/zero"
add base64     hash     "base64 /dev/zero"
# compressão
add gzip       compress "gzip -c /dev/urandom"
add bzip2      compress "bzip2 -c /dev/urandom"
add xz         compress "xz -T1 -6 -c /dev/urandom"
add zstd       compress "zstd -T1 -3 -c /dev/urandom"
add lz4        compress "lz4 -c /dev/urandom"
add brotli     compress "brotli -c /dev/urandom"
# linguagens / cálculo sem syscall
add python_int lang     "python3 $D/py_float.py"
add python_dic lang     "python3 $D/py_dict.py"
add python_srt lang     "python3 $D/py_sort.py"
add perl       lang     "perl $D/pl_loop.pl"
add lua        lang     "lua $D/loop.lua"
add luajit     lang     "luajit $D/loop.lua"
add awk_sin    lang     "awk BEGIN{for(;;)x+=sin(x+1)}"
add bc_pi      lang     "bc -l $D/pi.bc"
addfin bc_fin  finito   "bc -l $D/pi3000.bc"
add openssl_aes crypto  "openssl speed -seconds 3600 -evp aes-256-cbc"
add openssl_sha crypto  "openssl speed -seconds 3600 -evp sha256"
add openssl_rsa crypto  "openssl speed -seconds 3600 rsa2048"
add openssl_chacha crypto "openssl speed -seconds 3600 -evp chacha20-poly1305"
# compilador de verdade e banco
[[ -n $CC1 && -x $CC1 ]] && add gcc_cc1 compile "$CC1 -quiet -O2 $D/big.c -o /dev/null"
add sqlite     db       "sqlite3 :memory:"
# E/S pura e diretórios
add dd         io       "dd if=/dev/zero of=/dev/null bs=4k"
add cat        io       "cat /dev/zero"
add find       io       "find / -xdev -type f"
# multithread (nunca elegíveis)
add ffmpeg     mt       "ffmpeg -loglevel quiet -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3600 -c:v mpeg4 -f null -"
add convert    mt       "convert -size 6000x6000 plasma:fractal -blur 0x12 /dev/null"
[[ -n "${PROGS:-}" ]] && read -ra ORDER <<< "$PROGS"
SEL="${GROUPS_SEL:-}"

run_one() {   # $1 = cpu, $2 = nome, $3 = arquivo de amostras; imprime o pid
    local cpu=$1 name=$2 out=$3 pid tp sp tmo=$((DUR + 3))
    [[ -n ${FIN[$name]:-} ]] && tmo=90
    if [[ $name == sqlite ]]; then
        taskset -c "$cpu" timeout "$((DUR + 3))" sqlite3 :memory: \
          "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<2000000000) SELECT count(*) FROM c;" >/dev/null 2>&1 </dev/null &
    elif [[ $name == find ]]; then
        taskset -c "$cpu" timeout "$((DUR + 3))" find / -xdev -type f >/dev/null 2>&1 </dev/null &
    else
        # shellcheck disable=SC2086
        taskset -c "$cpu" timeout "$tmo" ${CMD[$name]} >/dev/null 2>&1 </dev/null &
    fi
    tp=$!
    sleep 0.3
    pid=$(pgrep -P "$tp" | head -1 || true); [[ -n $pid ]] || pid=$tp
    if [[ -n ${FIN[$name]:-} ]]; then
        # até o programa terminar (o amostrador para sozinho quando o pid some)
        taskset -c "$SAMPCPU" python3 -I "$SC_DIR/sample_ipcc.py" "$pid" 90 "$SAMPLE_MS" "$out" &
        sp=$!
        wait "$sp" 2>/dev/null || true
    else
        taskset -c "$SAMPCPU" python3 -I "$SC_DIR/sample_ipcc.py" "$pid" "$DUR" "$SAMPLE_MS" "$out" &
        sp=$!
        sleep "$DUR"; wait "$sp" 2>/dev/null || true
    fi
    echo "$pid"
    kill "$tp" 2>/dev/null || true; wait "$tp" 2>/dev/null || true
}

MAPF="$SC_OUT/map.txt"; : > "$MAPF"
sc_reset; sc_log_on
for name in "${ORDER[@]}"; do
    [[ -n $SEL && " $SEL " != *" ${GRP[$name]} "* ]] && continue
    bin=${CMD[$name]%% *}
    command -v "$bin" >/dev/null || { info "$name: $bin não instalado, pulado"; continue; }
    run_one "$PCPU" "$name" "$SC_OUT/samples_orc_$name.txt" >/dev/null     # oráculo em P-core
    pid=$(run_one "$ECPU" "$name" "$SC_OUT/samples_e_$name.txt")           # shadows num E-core
    echo "$name ${GRP[$name]} $pid" >> "$MAPF"
    echo "  $name ($pid): oráculo $(wc -l < "$SC_OUT/samples_orc_$name.txt") amostras"
done
wait_load; sleep 0.3
sc_log_dump "$SC_OUT/trace.txt"

python3 -I "$SC_DIR/real_tasks_report.py" --trace "$SC_OUT/trace.txt" --map "$MAPF" --dir "$SC_OUT" \
    --csv "$SC_OUT/real_tasks.csv" --verdict "$SC_OUT/verdict.txt" --tv-max "$TV_MAX" | tee "$SC_OUT/report.txt"

while read -r name tv tot; do
    if [[ $tot -eq 0 ]]; then info "$name: sem shadows (não elegível: multithread ou terminou antes)"; continue; fi
    [[ $tv == -1 ]] && { info "$name: sem oráculo"; continue; }
    check "$name: distribuição de classes dos shadows ≈ a do P (TV=$tv ≤ $TV_MAX)" awk -v t="$tv" -v m="$TV_MAX" 'BEGIN{exit !(t<=m)}'
done < "$SC_OUT/verdict.txt"
check_drained
check_dmesg_clean
sc_finish
