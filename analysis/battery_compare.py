#!/usr/bin/env python3
"""Compara kernels na bateria (run_battery.sh): placement e vazão.

Uso: python3 analysis/battery_compare.py <tag_base> <tag2> [<tag3> ...]
Cada tag é uma pasta results/<tag>/ ou i5/<tag>/ (a primeira que existir).
Métricas (média, IC95% e n; Δ contra o primeiro kernel):
  placement relaxed e contention: % de amostras do cls2 em P-core e do cls1 em E-core
  vazão: ops/s por worker cls2 sob contenção (throughput/c2_contention/compute_ops.txt)
"""
import math, os, statistics as st, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def base(tag):
    for p in (os.path.join(ROOT, "results", tag), os.path.join(ROOT, "i5", tag), os.path.join(ROOT, tag)):
        if os.path.isdir(p):
            return p
    sys.exit(f"não achei a pasta de {tag} em results/ ou i5/")


def vals(path):
    try:
        out = []
        for l in open(path):
            try:
                out.append(float(l.split()[0]))
            except (ValueError, IndexError):
                pass
        return out
    except OSError:
        return []


METRICS = [
    ("placement relaxed    cls2→P %", "placement/relaxed/cls2_p_residency.txt"),
    ("placement relaxed    cls1→E %", "placement/relaxed/cls1_e_residency.txt"),
    ("placement contention cls2→P %", "placement/contention/cls2_p_residency.txt"),
    ("placement contention cls1→E %", "placement/contention/cls1_e_residency.txt"),
    ("vazão cls2 contention ops/s",   "throughput/c2_contention/compute_ops.txt"),
]


def stat(v):
    if not v:
        return None
    m = st.mean(v)
    ci = 1.96 * st.stdev(v) / math.sqrt(len(v)) if len(v) > 1 else 0.0
    return m, ci, len(v)


tags = sys.argv[1:]
if len(tags) < 2:
    sys.exit(__doc__)
data = {t: {name: stat(vals(os.path.join(base(t), rel))) for name, rel in METRICS} for t in tags}
w = max(len(t) for t in tags) + 2
print(f"{'métrica':32}" + "".join(f"{t:>{w+16}}" for t in tags))
for name, _ in METRICS:
    line = f"{name:32}"
    b = data[tags[0]][name]
    for t in tags:
        s = data[t][name]
        if s is None:
            line += f"{'-':>{w+16}}"
            continue
        m, ci, n = s
        d = "" if t == tags[0] or b is None else f" ({100*(m/b[0]-1):+.1f}%)"
        line += f"{m:>{w-4}.1f}±{ci:<4.1f} n={n:<3}{d:>9}"[:w+16].rjust(w + 16)
    print(line)
print("\n± = IC95% da média; (Δ%) é a variação relativa contra o primeiro kernel.")
