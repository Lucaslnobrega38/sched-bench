#!/usr/bin/env python3
"""
analysis/placement_accuracy.py — Placement correctness via CPU residency

Lê arquivos por cenário:
  cls2_p_residency.txt  : uma linha por run (float) — % cls2 nos P-cores
  cls1_e_residency.txt  : uma linha por run (float) — % cls1 nos E-cores

Para cenários de referência (only_cls1/only_cls2) os arquivos têm 1 linha.
Para mixed têm RUNS linhas.

Produz:
  placement_summary.csv  : mean_cls2_p, mean_cls1_e, mean_score, n_runs
  placement_detail.txt   : breakdown por cenário com stats

Uso:
    python3 placement_accuracy.py \
        --input  ./results/ipcc/placement \
        --pcores 0,1,2,3 \
        --output ./results/ipcc/placement/placement_summary.csv
"""

import argparse
import csv
import math
import sys
from pathlib import Path


def read_floats(path):
    vals = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and line != "NA":
                    try:
                        vals.append(float(line))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return vals


def mean(v):
    return sum(v) / len(v) if v else None


def std(v):
    if len(v) < 2:
        return 0.0
    m = mean(v)
    return math.sqrt(sum((x - m) ** 2 for x in v) / (len(v) - 1))


def compute_metrics(scenario_dir):
    cls2_p = read_floats(scenario_dir / "cls2_p_residency.txt")
    cls1_e = read_floats(scenario_dir / "cls1_e_residency.txt")

    # scores por run (média das duas métricas quando ambas existem)
    scores = []
    n = max(len(cls2_p), len(cls1_e))
    for i in range(n):
        cp = cls2_p[i] if i < len(cls2_p) else None
        ce = cls1_e[i] if i < len(cls1_e) else None
        if cp is not None and ce is not None:
            scores.append((cp + ce) / 2)
        elif cp is not None:
            scores.append(cp)
        elif ce is not None:
            scores.append(ce)

    return {
        "cls2_p": cls2_p,
        "cls1_e": cls1_e,
        "scores": scores,
        "mean_cls2_p": mean(cls2_p),
        "mean_cls1_e": mean(cls1_e),
        "mean_score": mean(scores),
        "std_score": std(scores),
        "n_runs": len(scores),
    }


def write_csv(results, output_path):
    if not results:
        print("[placement] Nenhum dado para escrever.", file=sys.stderr)
        return
    fields = ["label", "mean_cls2_p", "mean_cls1_e", "mean_score",
              "std_score", "n_runs",
              # compat com compare.py antigo
              "cls2_p_residency", "cls1_e_residency", "placement_score"]
    with open(output_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in results:
            row = dict(r)
            # aliases para compare.py
            row["cls2_p_residency"] = row["mean_cls2_p"]
            row["cls1_e_residency"] = row["mean_cls1_e"]
            row["placement_score"]  = row["mean_score"]
            w.writerow(row)
    print(f"[placement] CSV salvo: {output_path}")


def write_detail(results, output_dir):
    path = Path(output_dir) / "placement_detail.txt"
    with open(path, "w") as f:
        f.write("=" * 60 + "\n")
        f.write("  PLACEMENT CORRECTNESS — Residência por classe IPCC\n")
        f.write("  Classe 2 (vector): rand48 → esperado em P-cores\n")
        f.write("  Classe 1 (integer): div16 → esperado em E-cores\n")
        f.write("=" * 60 + "\n\n")

        for r in results:
            f.write(f"Cenário: {r['label']}  (n={r['n_runs']} runs)\n")
            f.write("-" * 40 + "\n")

            cp = r["mean_cls2_p"]
            ce = r["mean_cls1_e"]
            sc = r["mean_score"]
            sd = r["std_score"]

            if cp is not None:
                bar = "█" * int(cp / 5) + "░" * (20 - int(cp / 5))
                f.write(f"  cls2 → P-cores: {cp:5.1f}%  [{bar}]\n")
            if ce is not None:
                bar = "█" * int(ce / 5) + "░" * (20 - int(ce / 5))
                f.write(f"  cls1 → E-cores: {ce:5.1f}%  [{bar}]\n")
            if sc is not None:
                f.write(f"  placement_score: {sc:5.1f}%  ±{sd:.1f}\n")
            f.write("\n")

        f.write("=" * 60 + "\n")
        f.write("SUMÁRIO\n")
        f.write(f"  {'Cenário':<20} {'cls2→P%':>10} {'cls1→E%':>10} {'score':>7} {'±std':>6} {'n':>4}\n")
        f.write("  " + "-" * 58 + "\n")
        for r in results:
            cp = f"{r['mean_cls2_p']:.1f}%" if r["mean_cls2_p"] is not None else "—"
            ce = f"{r['mean_cls1_e']:.1f}%" if r["mean_cls1_e"] is not None else "—"
            sc = f"{r['mean_score']:.1f}%" if r["mean_score"] is not None else "—"
            sd = f"{r['std_score']:.1f}"
            f.write(f"  {r['label']:<20} {cp:>10} {ce:>10} {sc:>7} {sd:>6} {r['n_runs']:>4}\n")

    print(f"[placement] Relatório: {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input",   required=True)
    parser.add_argument("--pcores",  required=True)
    parser.add_argument("--output",  required=True)
    args = parser.parse_args()

    input_dir = Path(args.input)
    workload_dirs = sorted(
        d for d in input_dir.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )

    if not workload_dirs:
        print(f"[placement] Nenhum subdiretório em {input_dir}", file=sys.stderr)
        sys.exit(1)

    results = []
    for wd in workload_dirs:
        m = compute_metrics(wd)
        m["label"] = wd.name
        print(f"[placement] {wd.name}: cls2→P={m['mean_cls2_p']}%  cls1→E={m['mean_cls1_e']}%  score={m['mean_score']}%  n={m['n_runs']}")
        results.append(m)

    write_csv(results, args.output)
    write_detail(results, input_dir)


if __name__ == "__main__":
    main()
