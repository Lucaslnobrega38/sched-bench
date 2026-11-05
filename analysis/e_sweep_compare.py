#!/usr/bin/env python3
"""e_sweep_compare.py — vazão no E-core, kernel com shadow vs kernel main (sem
shadow), método a método. Referência: o lado "e" do class_sweep (main_class_sweep).

Uso: python3 e_sweep_compare.py <ref class_sweep/summary.csv> <e_sweep/summary.csv>
"""
import csv
import statistics as st
import sys


def load_ref(path):
    out = {}
    for r in csv.DictReader(open(path)):
        if r["core"] == "e":
            try:
                out[r["method"]] = float(r["ops_s"])  # última ocorrência vence
            except ValueError:
                pass
    return out


def load_new(path):
    out = {}
    for r in csv.DictReader(open(path)):
        try:
            out[r["method"]] = (float(r["ops_s"]), r["ipc"], r["ctx_switches"], r["page_faults"])
        except ValueError:
            pass
    return out


def main(ref_path, new_path):
    ref, new = load_ref(ref_path), load_new(new_path)
    rows = []
    for m in sorted(set(ref) & set(new)):
        r, (n, ipc, ctx, pf) = ref[m], new[m]
        rows.append((100 * (n / r - 1), m, r, n, ipc, ctx, pf))
    rows.sort()
    d = [x[0] for x in rows]
    print(f"{len(rows)} métodos pareados (kernel com shadow vs main, cpu8, 5s)")
    print(f"perda mediana {st.median(d):+.1f}%  média {st.mean(d):+.1f}%  "
          f"pior {min(d):+.1f}%  melhor {max(d):+.1f}%")
    print(f"{sum(1 for x in d if x < -5)} métodos perdem >5%,  "
          f"{sum(1 for x in d if abs(x) <= 2)} dentro de ±2% (ruído)\n")
    print(f"{'método':<18}{'main':>12}{'shadow':>12}{'Δ%':>8}{'ipc':>7}{'ctx':>7}{'pf':>9}")
    for dd, m, r, n, ipc, ctx, pf in rows:
        print(f"{m:<18}{r:>12.1f}{n:>12.1f}{dd:>+8.1f}{ipc:>7}{ctx:>7}{pf:>9}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
