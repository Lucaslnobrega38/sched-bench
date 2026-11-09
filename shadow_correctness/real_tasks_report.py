#!/usr/bin/env python3
"""Relatório do t7: distribuição de classes do oráculo (P-core) contra a dos shadows.

Sem debounce, cada leitura é uma amostra. Oráculo: amostras de ipcc do processo
no P-core ao longo de vários segundos (samples_orc_<nome>.txt). Shadows: a
classe que cada shadow leu (um por turno, do log de eventos). Compara as duas
distribuições sobre as classes válidas (>= 1) pela distância de variação total
TV = 0,5 * soma(|p - q|): 0 = iguais, 1 = disjuntas.
--map: linhas "nome grupo pid_E". Escreve CSV e verdict.txt ("nome TV shadows").
"""
import argparse, csv, os, re, statistics as st
from collections import Counter

ap = argparse.ArgumentParser()
ap.add_argument("--trace", required=True)
ap.add_argument("--map", required=True)
ap.add_argument("--dir", required=True)
ap.add_argument("--csv")
ap.add_argument("--verdict")
ap.add_argument("--tv-max", type=float, default=0.25)
a = ap.parse_args()


def load(path):
    try:
        return [int(x) for x in open(path).read().split()]
    except OSError:
        return []


def dist(vals):
    valid = [v for v in vals if v >= 1]
    c = Counter(valid)
    n = len(valid)
    return {k: c[k] / n for k in c} if n else {}, n, vals.count(0)


def tv(p, q):
    ks = set(p) | set(q)
    return 0.5 * sum(abs(p.get(k, 0) - q.get(k, 0)) for k in ks)


def fmt(d):
    c1, c2 = d.get(1, 0), d.get(2, 0)
    oth = 1 - c1 - c2
    return f"{100*c1:3.0f}/{100*c2:3.0f}/{100*max(oth,0):3.0f}"


def med(v):
    return f"{st.median(v):.0f}" if v else "-"


ends = {}
for l in open(a.trace, errors="replace"):
    m = re.search(r"ev=end why=(\w+) cpu=\d+ target=(\d+) shadow=\d+ class=(\d+) k=\d+ life_us=-?\d+ exec_us=(-?\d+)", l)
    if m:
        ends.setdefault(int(m[2]), []).append((m[1], int(m[3]), int(m[4])))

print(f"{'programa':14} {'grupo':9} | {'oráculo n':>9} {'c1/c2/ou %':>11} {'inv%':>5} | {'shadows n':>9} {'c1/c2/ou %':>11} {'inv%':>5} | {'TV':>5} {'ok':>3} | {'sys%':>4} | exec µs sys/timer")
rows, verdict, byg = [], [], {}
for l in open(a.map):
    n, g, pid = l.split(); pid = int(pid)
    orc = load(os.path.join(a.dir, f"samples_orc_{n}.txt"))
    e = ends.get(pid, [])
    sh = [x[1] for x in e]
    po, no, z_o = dist(orc)
    ps, ns, z_s = dist(sh)
    sysx = [x[2] for x in e if x[0] == "syscall"]
    rdx = [x[2] for x in e if x[0] == "confirmed"]
    t = max(len(e), 1)
    if not e:
        d, ok = None, "-"
    elif not po:
        d, ok = None, "?"
    elif not ps:
        d, ok = 1.0, "NÃO"
    else:
        d = tv(po, ps)
        ok = "sim" if d <= a.tv_max else "NÃO"
    inv_o = 100 * z_o / max(len(orc), 1)
    inv_s = 100 * z_s / max(len(sh), 1)
    print(f"{n:14} {g:9} | {len(orc):>9} {fmt(po):>11} {inv_o:5.0f} | {len(sh):>9} {fmt(ps):>11} {inv_s:5.0f} | "
          f"{('%.2f' % d) if d is not None else '  - ':>5} {ok:>3} | {100*sum(1 for x in e if x[0]=='syscall')/t:4.0f} | {med(sysx)} / {med(rdx)}")
    rows.append(dict(program=n, group=g, oracle_n=len(orc), oracle_c1=round(po.get(1, 0), 3), oracle_c2=round(po.get(2, 0), 3),
                     oracle_invalid=round(inv_o / 100, 3), shadow_n=len(sh), shadow_c1=round(ps.get(1, 0), 3),
                     shadow_c2=round(ps.get(2, 0), 3), shadow_invalid=round(inv_s / 100, 3),
                     tv=("" if d is None else round(d, 3)), ok=ok,
                     exec_syscall_p50=med(sysx), exec_timer_p50=med(rdx)))
    verdict.append(f"{n} {-1 if d is None else round(d, 3)} {len(e)}")
    if d is not None:
        byg.setdefault(g, []).append((n, d, po))

print(f"\nTV = distância entre as distribuições (0 = iguais, 1 = disjuntas); ok se TV <= {a.tv_max}.")
print("colunas c1/c2/ou = % das leituras válidas nas classes 1, 2 e outras; inv% = leituras com classe 0 (inválidas).")
print("\nresumo por grupo:")
allv = []
for g, vs in byg.items():
    oks = sum(1 for _, d, _ in vs if d <= a.tv_max)
    print(f"  {g:9} {oks}/{len(vs)} ok; TV médio {sum(d for _, d, _ in vs)/len(vs):.2f}")
    allv += vs
mixed = [v for v in allv if max(v[2].values(), default=1) < 0.9]
pure2 = [v for v in allv if v[2].get(2, 0) >= 0.9]
pure1 = [v for v in allv if v[2].get(1, 0) >= 0.9]
for nm, vs in (("oráculo ~100% classe 1", pure1), ("oráculo ~100% classe 2", pure2), ("oráculo misto (nenhuma ≥90%)", mixed)):
    if vs:
        print(f"  {nm:30} {sum(1 for _, d, _ in vs if d <= a.tv_max)}/{len(vs)} ok")
if a.csv and rows:
    with open(a.csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
if a.verdict:
    open(a.verdict, "w").write("\n".join(verdict) + "\n")
