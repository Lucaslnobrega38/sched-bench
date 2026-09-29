#!/usr/bin/env python3
"""class_sweep_report.py — resumo do class_sweep.sh: razão P/E por classe HFI
confirmada, estabilidade da classificação, e sugestão de pesos P/E pros
métodos usados no bench (div16=ipcc1, rand48=ipcc2). Ver context.md, seção
"Sweep completo de métodos" e 4.3 (tabela estática).

Uso: python3 class_sweep_report.py <caminho/para/summary.csv>
"""
import csv
import statistics as st
import sys
from collections import Counter, defaultdict

BENCH_METHODS = ("div16", "rand48")


def main(path):
    rows = list(csv.DictReader(open(path)))
    p, e = {}, {}
    for r in rows:
        (p if r["core"] == "p" else e)[r["method"]] = r  # última ocorrência vence (dedup de reruns manuais)

    methods = sorted(set(p) & set(e))
    data = []
    for m in methods:
        try:
            pops, eops = float(p[m]["ops_s"]), float(e[m]["ops_s"])
        except ValueError:
            continue
        data.append(dict(
            method=m, cls=p[m]["final_class"], ratio=pops / eops if eops else None,
            pops=pops, eops=eops, ntrans=int(p[m]["n_transitions"]), seen=p[m]["classes_seen"],
        ))

    print(f"{len(data)} métodos com classe + vazão nos dois cores\n")

    print("=== distribuição de classe confirmada (P-core) ===")
    print(Counter(d["cls"] for d in data), "\n")

    print("=== razão P/E por classe (>1 = favorece P) ===")
    byclass = defaultdict(list)
    for d in data:
        byclass[d["cls"]].append(d["ratio"])
    for c in sorted(byclass):
        v = byclass[c]
        print(f"  classe {c}: n={len(v):3d}  mean={st.mean(v):.3f}  median={st.median(v):.3f}  "
              f"min={min(v):.3f}  max={max(v):.3f}")

    print("\n=== classificação instável (>1 transição em 5s) ===")
    for d in sorted(data, key=lambda x: -x["ntrans"]):
        if d["ntrans"] > 1:
            print(f"  {d['method']:16s} trans={d['ntrans']:3d}  seen={d['seen']}")

    print("\n=== métodos do bench (div16/rand48) ===")
    for m in BENCH_METHODS:
        d = next(x for x in data if x["method"] == m)
        other = "E" if d["ratio"] < 1 else "P"
        weight_other = round(100 / d["ratio"]) if d["ratio"] >= 1 else round(100 * d["ratio"])
        print(f"  {m}: classe={d['cls']}  P={d['pops']:.1f}  E={d['eops']:.1f}  P/E={d['ratio']:.3f}"
              f"  → favorece {other}; peso sugerido (100/{weight_other})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "summary.csv")
