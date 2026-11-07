#!/bin/bash
# diag_start_delay.sh — por que o shadow só começa a rodar ~4ms depois do pop?
# Liga o log do ipcc junto com sched_wakeup_new, sched_switch, hrtimer e idle
# (power:cpu_idle) e imprime a linha do tempo, nessa cpu, do ciclo mais lento
# entre o pop e o deadline. Uma carga só, num E-core.
#
# Uso: sudo [READ_US=100] [METHOD=div16] [DUR=4] ./diag_start_delay.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sc_init diag_start_delay
DUR="${DUR:-4}"; METHOD="${METHOD:-div16}"

for ev in sched/sched_wakeup_new sched/sched_switch timer/hrtimer_start timer/hrtimer_expire_entry power/cpu_idle; do
    echo 1 > "$TRC/events/$ev/enable" 2>/dev/null || info "evento $ev indisponível"
done
trap 'for ev in sched/sched_wakeup_new sched/sched_switch timer/hrtimer_start timer/hrtimer_expire_entry power/cpu_idle; do echo 0 > "$TRC/events/$ev/enable" 2>/dev/null; done; sc_cleanup' EXIT

sc_reset; sc_log_on
start_load "$METHOD" "${EARR[0]}"
wait_load; sleep 0.3
sc_log_dump "$SC_OUT/trace.txt"

python3 -I - "$SC_OUT/trace.txt" "$PCPUS" <<'PY'
import re, sys
path, pcpus = sys.argv[1], {int(x) for x in sys.argv[2].split(",")}
lines = [l.rstrip() for l in open(path, errors="replace") if not l.startswith("#")]
def ns_of(l):
    m = re.search(r"ipcc ns=(\d+)", l); return int(m[1]) if m else None
def kv(l): return dict(re.findall(r"(\w+)=(\S+)", l))
pops = {}; slow = []
for i, l in enumerate(lines):
    n = ns_of(l)
    if n is None: continue
    k = kv(l)
    if " ev=pop " in l: pops[k["shadow"]] = (i, n, k)
    elif " ev=deadline " in l and k["shadow"] in pops:
        i0, n0, k0 = pops.pop(k["shadow"]); slow.append(((n - n0) / 1000, i0, i, k0))
if not slow: sys.exit("nenhum par pop->deadline no log")
slow.sort(reverse=True)
d = sorted(x[0] for x in slow)
print(f"pop->deadline: n={len(d)} p50={d[len(d)//2]:.0f}us p90={d[int(len(d)*.9)]:.0f}us max={d[-1]:.0f}us")
print("fração acima de 1ms: %.0f%%" % (100 * sum(x > 1000 for x in d) / len(d)))
# um ciclo lento típico (a mediana dos lentos, não o pior outlier)
slows = [x for x in slow if x[0] > 1000]
us, i0, i1, k0 = slows[len(slows)//2] if slows else slow[0]
cpu = int(k0["cpu"])
print(f"\nciclo lento típico: {us:.0f}us, cpu{cpu}, shadow {k0['shadow']}; eventos da cpu{cpu} no intervalo:\n")
for l in lines[max(0, i0 - 3): i1 + 3]:
    if re.search(rf"\[00?{cpu}\]", l) or "ev=" in l and f"cpu={cpu}" in l:
        print("  ", l.strip()[:200])
PY
check_dmesg_clean
sc_finish
