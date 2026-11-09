#!/usr/bin/env python3
"""Placement antigo da bateria (relaxed/contention) com a série no tempo dos pesos de classe.

Mesmos cenários e cargas de benchmarks/battery/placement.sh: relaxed = nP cls2
(rand48) + nP cls1 (div16); contention = nP cls2 + (total de cpus - nP) cls1,
30 s por run, sem pin. A cada 100 ms amostra, de cada worker, a cpu (psr) e o
ipcc e os pesos de classe de /proc/<pid>/sched. A carga ipcc de uma task é
load_avg * baseline(cpu) / score(pesos, cpu), função dos pesos; aqui medimos como
a mistura de classes normalizada (w_c / soma w) converge: t50 e t90 até 50% e 90%
do valor final da classe dominante, e quantas vezes ela cai abaixo de 50% do final
depois de ter chegado a 90% (reduções espúrias).

Uso: placement_timeline.py <saida_dir> <runs_por_cenario> [duracao_s=30]
"""
import csv, os, re, statistics as st, subprocess, sys, time

out, runs = sys.argv[1], int(sys.argv[2])
dur = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
os.makedirs(out, exist_ok=True)


def cpus(path):
    s = open(path).read().strip()
    r = []
    for part in s.split(","):
        a, _, b = part.partition("-")
        r += list(range(int(a), int(b or a) + 1))
    return [c for c in r if c == 0 or open(f"/sys/devices/system/cpu/cpu{c}/online").read().strip() == "1"]


P = cpus("/sys/devices/cpu_core/cpus")
E = cpus("/sys/devices/cpu_atom/cpus")
NP, TOTAL = len(P), len(P) + len(E)
RX = {i: re.compile(rb"^ipcc_class_weight\[%d\]\s*:\s*(\d+)" % i, re.M) for i in range(5)}
RI = re.compile(rb"^ipcc\s*:\s*(\d+)", re.M)


def workers(parents):
    pids = []
    for p in parents:
        try:
            kids = open(f"/proc/{p}/task/{p}/children").read().split()
        except OSError:
            kids = []
        pids += [int(k) for k in kids] if kids else [p]
    return pids


def sample(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            st_ = f.read()
        psr = int(st_[st_.rindex(")") + 2:].split()[36])
        with open(f"/proc/{pid}/sched", "rb") as f:
            s = f.read()
        w = [int(RX[i].search(s)[1]) for i in range(5)]
        return psr, int(RI.search(s)[1]), w
    except (OSError, TypeError, IndexError, ValueError):
        return None


rows = []
for scen, n2, n1 in (("relaxed", NP, NP), ("contention", NP, TOTAL - NP)):
    for run in range(1, runs + 1):
        procs = []
        t0 = time.monotonic()
        for kind, method, n in (("cls2", "rand48", n2), ("cls1", "div16", n1)):
            for _ in range(n):
                procs.append((kind, subprocess.Popen(
                    ["stress-ng", "--cpu", "1", "--cpu-method", method, "--timeout", f"{int(dur)}s", "--quiet"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)))
        wk, seen = [], set()
        end = t0 + dur - 1
        # amostra desde o início: os workers (filhos do stress-ng) aparecem em dezenas de ms
        while time.monotonic() < end:
            if len(wk) < len(procs):
                for kind, pr in procs:
                    for pid in workers([pr.pid]):
                        if pid != pr.pid and pid not in seen:
                            seen.add(pid); wk.append((kind, pid))
            t = time.monotonic() - t0
            for kind, pid in wk:
                s_ = sample(pid)
                if s_:
                    rows.append((scen, run, round(t, 2), kind, pid, s_[0], s_[1], *s_[2]))
            time.sleep(0.05)
        for _, pr in procs:
            pr.wait()
        print(f"  {scen} {run}/{runs} ok", flush=True)

with open(os.path.join(out, "timeline.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario", "run", "t", "kind", "pid", "psr", "ipcc", "w0", "w1", "w2", "w3", "w4"])
    w.writerows(rows)

# ---------------------------------------------------------------- análise
Pset = set(P)
byw = {}
for r in rows:
    byw.setdefault((r[0], r[1], r[4]), []).append(r)


def exp_share(r, cls):
    tot = sum(r[8:12])
    return r[7 + cls] / tot if tot else None   # None = ainda sem peso (w todos zero)


print(f"\nP={P} E={E} | {dur:.0f}s por run, amostra a cada ~50 ms desde o lançamento, runs por cenário: {runs}")
CHECK = [0.1, 0.25, 0.5, 1, 2, 3, 5, 10, 20]
for scen in ("relaxed", "contention"):
    print(f"\n=== {scen} ===")
    for kind, cls in (("cls2", 2), ("cls1", 1)):
        ws = [rs for (sc, run, pid), rs in byw.items() if sc == scen and rs[0][3] == kind]
        if not ws:
            continue
        print(f"  {kind}: {len(ws)} workers; parcela da classe {cls} no vetor de pesos (média dos workers) e % já com algum peso:")
        line1 = "      t(s):  " + " ".join(f"{t:>5}" for t in CHECK)
        vals, have = [], []
        for t in CHECK:
            xs, hv = [], []
            for rs in ws:
                r = min(rs, key=lambda r: abs(r[2] - t))
                if abs(r[2] - t) > 0.15:
                    continue
                v = exp_share(r, cls)
                hv.append(0 if v is None else 1)
                xs.append(0.0 if v is None else v)
            vals.append(f"{st.mean(xs):5.2f}" if xs else "    -")
            have.append(f"{100*st.mean(hv):5.0f}" if hv else "    -")
        print(line1); print("      parcela: " + " ".join(vals)); print("      c/ peso%:" + " ".join(have))
        # primeiro instante com algum peso, por worker
        first = [next((r[2] for r in rs if sum(r[8:12]) > 0), None) for rs in ws]
        first = [f for f in first if f is not None]
        if first:
            print(f"      primeiro instante com peso != 0: mediana {st.median(first):.2f}s (máx {max(first):.2f}s)")
        # regime (t >= 10 s): média e desvio da parcela, separando onde a task estava
        for where, test in (("em P", lambda r: r[5] in Pset), ("em E", lambda r: r[5] not in Pset)):
            xs = [exp_share(r, cls) for rs in ws for r in rs if r[2] >= 10 and test(r)]
            xs = [x for x in xs if x is not None]
            if len(xs) > 20:
                print(f"      regime (t>=10s) {where}: parcela média {st.mean(xs):.2f}, desvio {st.pstdev(xs):.2f}, mín {min(xs):.2f} ({len(xs)} amostras)")
        res, early, late = [], [], []
        for rs in ws:
            onp = [1 if r[5] in Pset else 0 for r in rs]
            f = (lambda v: v) if kind == "cls2" else (lambda v: 1 - v)
            res.append(100 * f(st.mean(onp)))
            ea = [o for o, r in zip(onp, rs) if r[2] <= 5]; la = [o for o, r in zip(onp, rs) if r[2] >= 20]
            if ea: early.append(100 * f(st.mean(ea)))
            if la: late.append(100 * f(st.mean(la)))
        nm = "cls2→P" if kind == "cls2" else "cls1→E"
        print(f"      residência {nm}: {st.mean(res):.1f}%  (0-5 s: {st.mean(early):.1f}%, >=20 s: {st.mean(late):.1f}%)")
