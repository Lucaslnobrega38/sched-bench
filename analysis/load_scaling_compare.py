#!/usr/bin/env python3
"""Resume e compara as rodadas de load_scaling.sh.

  load_scaling_compare.py --paired <tag>        overhead de on sobre off DENTRO da rodada
  load_scaling_compare.py --summary <tag>       tabela de uma rodada (todos os modos)
  load_scaling_compare.py <base> <teste> [...]  overhead de <teste> (modo on) sobre <base>

A vazão de um cenário é a média de ops/s por worker, separada em P e E. O
overhead é (teste/base - 1) em %, negativo = perda. Cada execução tem modo `on`
(shadows ligados) ou `off` (sem shadows: classificador parado, ou o kernel
normal); rodadas antigas, sem a coluna `mode`, valem como `on`. Como <base> usa
o modo `off` se ele existir, a comparação entre kernels usa o baseline medido
nas mesmas condições. Lê 275hx/results/<tag>/load_scaling*.csv.
"""
import csv
import os
import statistics as st
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def path(tag, name):
    return os.path.join(ROOT, "275hx", "results", tag, name)


def load(tag):
    """(method, mode, nE, nP, type) -> [ops de cada worker-rep]"""
    cell = defaultdict(list)
    with open(path(tag, "load_scaling.csv")) as f:
        for r in csv.DictReader(f):
            try:
                ops = float(r["ops_s"])
            except ValueError:
                continue
            cell[(r["method"], r.get("mode", "on"), int(r["nE"]), int(r["nP"]), r["core_type"])].append(ops)
    return cell


def runs(tag):
    """(method, mode, nE, nP) -> {'w': [..], 'sh': [..]}"""
    acc = defaultdict(lambda: {"w": [], "sh": [], "mp": [], "me": []})
    p = path(tag, "load_scaling_shadow.csv")
    if not os.path.exists(p):
        return acc
    with open(p) as f:
        for r in csv.DictReader(f):
            k = (r["method"], r.get("mode", "on"), int(r["nE"]), int(r["nP"]))
            try:
                acc[k]["w"].append(float(r["pkg_w"]))
            except (ValueError, KeyError):
                pass
            try:
                acc[k]["sh"].append(float(r.get("shadows_per_s", r.get("per_s_inserted"))))
            except (ValueError, TypeError):
                pass
            for col, key in (("mhz_p", "mp"), ("mhz_e", "me")):
                try:
                    acc[k][key].append(float(r[col]))
                except (ValueError, KeyError):
                    pass
    return acc


def cv(v):
    return 100 * st.pstdev(v) / st.mean(v) if len(v) > 1 and st.mean(v) else 0.0


def mean(v):
    return st.mean(v) if v else None


def fmt(v, w=9, d=0):
    return f"{v:{w}.{d}f}" if v is not None else f"{'-':>{w}}"


def delta(b, t):
    return f"{100 * (t / b - 1):+6.1f}%" if b and t else f"{'':>7}"


def paired(tag):
    cell, rn = load(tag), runs(tag)
    keys = sorted({k[:1] + k[2:4] for k in cell})
    print(f"== {tag}: overhead de on sobre off, mesma rodada (negativo = perda)")
    print(f"{'método':8} {'nE':>3} {'nP':>3} | {'P off':>9} {'P on':>9} {'P Δ':>7} | {'E off':>9} {'E on':>9} {'E Δ':>7} | {'sh/s':>5} | {'W off':>5} {'W on':>5} | {'MHz P off':>9} {'on':>5} | cv% P/E (off,on)")
    for m, nE, nP in keys:
        po, pn = cell.get((m, "off", nE, nP, "P"), []), cell.get((m, "on", nE, nP, "P"), [])
        eo, en = cell.get((m, "off", nE, nP, "E"), []), cell.get((m, "on", nE, nP, "E"), [])
        empty = {"w": [], "sh": [], "mp": [], "me": []}
        ro, rn_ = rn.get((m, "off", nE, nP), empty), rn.get((m, "on", nE, nP), empty)
        cvs = "/".join(f"{cv(v):.1f}" for v in (po, pn, eo, en) if v)
        print(f"{m:8} {nE:>3} {nP:>3} | {fmt(mean(po))} {fmt(mean(pn))} {delta(mean(po), mean(pn))} | "
              f"{fmt(mean(eo))} {fmt(mean(en))} {delta(mean(eo), mean(en))} | {fmt(mean(rn_['sh']), 5)} | "
              f"{fmt(mean(ro['w']), 5, 1)} {fmt(mean(rn_['w']), 5, 1)} | {fmt(mean(ro['mp']), 9)} {fmt(mean(rn_['mp']), 5)} | {cvs}")
    print("\nW = potência média do pacote (RAPL); MHz = frequência dos P no meio da execução. Se W ou MHz de off e on "
          "diferirem, ou W chegar perto do PL1 (30 W), o Δ mistura efeito de frequência com o do shadow.")


def summary(tag):
    cell, rn = load(tag), runs(tag)
    print(f"== {tag}: vazão média por worker (ops/s) e cv%")
    print(f"{'método':8} {'modo':>4} {'nE':>3} {'nP':>3} | {'P ops/s':>9} {'cv%':>5} | {'E ops/s':>9} {'cv%':>5} | {'sh/s':>5} {'W':>5}")
    for m, mode, nE, nP in sorted({k[:4] for k in cell}):
        p, e = cell.get((m, mode, nE, nP, "P"), []), cell.get((m, mode, nE, nP, "E"), [])
        r = rn.get((m, mode, nE, nP), {"w": [], "sh": [], "mp": [], "me": []})
        print(f"{m:8} {mode:>4} {nE:>3} {nP:>3} | {fmt(mean(p))} {cv(p):5.1f} | {fmt(mean(e))} {cv(e):5.1f} | "
              f"{fmt(mean(r['sh']), 5)} {fmt(mean(r['w']), 5, 1)}")


def compare(base, tests):
    cb = load(base)
    base_mode = "off" if any(k[1] == "off" for k in cb) else "on"
    for t in tests:
        ct, rt = load(t), runs(t)
        print(f"\n== overhead de '{t}' (on) sobre '{base}' (modo {base_mode}); negativo = perda de vazão")
        print(f"{'método':8} {'nE':>3} {'nP':>3} | {'P base':>9} {'P teste':>9} {'P Δ':>7} | {'E base':>9} {'E teste':>9} {'E Δ':>7} | {'sh/s':>5}")
        keys = {k[:1] + k[2:4] for k in cb if k[1] == base_mode} & {k[:1] + k[2:4] for k in ct if k[1] == "on"}
        for m, nE, nP in sorted(keys):
            row = []
            for typ in ("P", "E"):
                b, x = mean(cb.get((m, base_mode, nE, nP, typ), [])), mean(ct.get((m, "on", nE, nP, typ), []))
                row.append(f"{fmt(b)} {fmt(x)} {delta(b, x)}")
            sh = mean(rt.get((m, "on", nE, nP), {"sh": []})["sh"])
            print(f"{m:8} {nE:>3} {nP:>3} | {row[0]} | {row[1]} | {fmt(sh, 5)}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--paired":
        paired(a[1])
    elif len(a) == 2 and a[0] == "--summary":
        summary(a[1])
    elif len(a) >= 2:
        compare(a[0], a[1:])
    else:
        sys.exit(__doc__)
