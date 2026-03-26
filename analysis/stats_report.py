#!/usr/bin/env python3
"""
analysis/stats_report.py — Análise estatística da bateria de benchmarks
Gera: tabelas CSV, Welch's t-test entre kernels, gráficos para artigo

Uso:
    python3 stats_report.py --outdir ./results/vanilla --kernel-tag vanilla
    python3 stats_report.py --outdir ./results/itd_ipcc --compare vanilla:itd_ipcc
"""

import argparse
import csv
import math
import os
import sys
from pathlib import Path

try:
    import numpy as np
    import scipy.stats as stats
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False
    print("[WARN] scipy/matplotlib não disponíveis — estatísticas básicas apenas")


# ---------------------------------------------------------------------------
# Utilitários estatísticos
# ---------------------------------------------------------------------------

def load_numeric(path):
    """Carrega arquivo com um valor numérico por linha, ignora NA/erros."""
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


def describe(vals):
    """Retorna dict com estatísticas descritivas."""
    if not vals:
        return {"n": 0, "mean": None, "std": None, "median": None,
                "p5": None, "p95": None, "min": None, "max": None}
    arr = sorted(vals)
    n = len(arr)
    mean = sum(arr) / n
    std = math.sqrt(sum((x - mean) ** 2 for x in arr) / n) if n > 1 else 0.0
    def pct(p):
        idx = (p / 100) * (n - 1)
        lo, hi = int(idx), min(int(idx) + 1, n - 1)
        return arr[lo] + (idx - lo) * (arr[hi] - arr[lo])
    return {
        "n": n,
        "mean": round(mean, 4),
        "std": round(std, 4),
        "median": round(pct(50), 4),
        "p5": round(pct(5), 4),
        "p95": round(pct(95), 4),
        "min": round(min(arr), 4),
        "max": round(max(arr), 4),
    }


def welch_ttest(a, b):
    """Welch's t-test. Retorna (t, p, significant)."""
    if not HAS_SCIPY or len(a) < 3 or len(b) < 3:
        return None, None, None
    t, p = stats.ttest_ind(a, b, equal_var=False)
    return round(float(t), 4), round(float(p), 6), p < 0.05


def cohens_d(a, b):
    """Effect size: Cohen's d."""
    if len(a) < 2 or len(b) < 2:
        return None
    mean_a, mean_b = sum(a)/len(a), sum(b)/len(b)
    std_a = math.sqrt(sum((x - mean_a)**2 for x in a) / (len(a)-1))
    std_b = math.sqrt(sum((x - mean_b)**2 for x in b) / (len(b)-1))
    pooled = math.sqrt((std_a**2 + std_b**2) / 2)
    return round((mean_a - mean_b) / pooled, 4) if pooled > 0 else 0.0


def ci95(vals):
    """Intervalo de confiança 95% (t-distribution)."""
    if not HAS_SCIPY or len(vals) < 2:
        return None, None
    mean = sum(vals) / len(vals)
    se = stats.sem(vals)
    interval = stats.t.interval(0.95, df=len(vals)-1, loc=mean, scale=se)
    return round(float(interval[0]), 4), round(float(interval[1]), 4)


# ---------------------------------------------------------------------------
# Carregamento de resultados por fase
# ---------------------------------------------------------------------------

def load_schbench_results(outdir):
    """Carrega percentis do schbench de todos os tags."""
    results = {}
    base = Path(outdir) / "latency"
    if not base.exists():
        return results
    for d in sorted(base.glob("schbench_*")):
        tag = d.name.replace("schbench_", "")
        pct_file = d / "percentiles.csv"
        if not pct_file.exists():
            continue
        p99_vals = []
        with open(pct_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    p99_vals.append(float(row["p99"]))
                except (KeyError, ValueError):
                    pass
        if p99_vals:
            results[tag] = p99_vals
    return results


def load_hackbench_results(outdir):
    results = {}
    base = Path(outdir) / "latency"
    if not base.exists():
        return results
    for d in sorted(base.glob("hackbench_*")):
        tag = d.name.replace("hackbench_", "")
        vals = load_numeric(d / "times_sec.txt")
        if vals:
            results[tag] = vals
    return results


def load_cyclictest_results(outdir):
    """Carrega latências do cyclictest (avg latency por run)."""
    results = {}
    base = Path(outdir) / "latency"
    if not base.exists():
        return results
    for d in sorted(base.glob("cyclictest_*")):
        tag = d.name.replace("cyclictest_", "")
        # Extrair avg latency de cada run_*.txt (formato: T: N ... Avg: X)
        vals = []
        for rf in sorted(d.glob("run_*.txt")):
            try:
                with open(rf) as f:
                    for line in f:
                        if "Avg:" in line:
                            # T: 0 ... Avg:   12
                            parts = line.split("Avg:")
                            if len(parts) >= 2:
                                v = parts[-1].strip().split()[0]
                                vals.append(float(v))
                                break
            except (ValueError, FileNotFoundError):
                pass
        if vals:
            results[tag] = vals
    return results


def load_perf_sched_pipe_results(outdir):
    """Carrega usecs/op do perf bench sched pipe."""
    vals = load_numeric(Path(outdir) / "latency" / "perf_sched_pipe" / "usecs_per_op.txt")
    return {"pipe": vals} if vals else {}


def load_perf_sched_msg_results(outdir):
    """Carrega tempos do perf bench sched messaging."""
    vals = load_numeric(Path(outdir) / "latency" / "perf_sched_msg" / "times_sec.txt")
    return {"messaging": vals} if vals else {}


def load_throughput_results(outdir):
    """Carrega resultados de throughput (compute, background, mixed, sysbench)."""
    results = {}
    base = Path(outdir) / "throughput"
    if not base.exists():
        return results

    # stress-ng compute: compute_w4, compute_w8
    for d in sorted(base.glob("compute_w*")):
        tag = d.name  # compute_w4, compute_w8
        vals = load_numeric(d / "bogo_ops_per_sec.txt")
        if vals:
            results[tag] = vals

    # stress-ng background: background_w8
    for d in sorted(base.glob("background_w*")):
        tag = d.name
        vals = load_numeric(d / "bogo_ops_per_sec.txt")
        if vals:
            results[tag] = vals

    # mixed contention: mixed_c4_bg8, mixed_c2_bg10, mixed_c6_bg6
    for d in sorted(base.glob("mixed_c*")):
        tag = d.name
        vals = load_numeric(d / "compute_ops.txt")
        if vals:
            results[tag] = vals

    # sysbench cpu: sysbench_cpu_t4, sysbench_cpu_t8, sysbench_cpu_t12
    for d in sorted(base.glob("sysbench_cpu_*")):
        tag = d.name
        vals = load_numeric(d / "events_per_sec.txt")
        if vals:
            results[tag] = vals

    return results


def load_energy_results(outdir):
    results = {}
    csv_path = Path(outdir) / "energy" / "rapl_summary.csv"
    if not csv_path.exists():
        return results
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            label = row.get("label", "unknown")
            try:
                ppw = float(row.get("perf_per_watt", 0))
                pkg_j = float(row.get("energy_pkg_J", 0))
                if label not in results:
                    results[label] = {"ppw": [], "pkg_j": []}
                results[label]["ppw"].append(ppw)
                results[label]["pkg_j"].append(pkg_j)
            except ValueError:
                pass
    return results


def load_overhead_results(outdir):
    base = Path(outdir) / "overhead"
    ctx = load_numeric(base / "lmbench_ctx" / "ctx_overhead_us.txt")
    csw = load_numeric(base / "ctx_switch_rate" / "ctx_switches_total.txt")
    mig = load_numeric(base / "migration_rate" / "migrations_per_run.txt")
    return {
        "ctx_switch_us": ctx,
        "ctx_switches_total": csw,
        "migrations_per_run": mig,
    }


# ---------------------------------------------------------------------------
# Geração de relatório
# ---------------------------------------------------------------------------

def write_csv_summary(outdir, all_data):
    out = Path(outdir) / "all_results.csv"
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["category", "benchmark", "tag", "n", "mean", "std",
                    "median", "p5", "p95", "min", "max", "ci95_lo", "ci95_hi"])
        for cat, benchmarks in all_data.items():
            for bname, tags in benchmarks.items():
                for tag, vals in tags.items():
                    d = describe(vals)
                    lo, hi = ci95(vals) if vals else (None, None)
                    w.writerow([cat, bname, tag, d["n"], d["mean"], d["std"],
                                d["median"], d["p5"], d["p95"], d["min"], d["max"],
                                lo, hi])
    print(f"[stats] CSV consolidado: {out}")


def _compare_section(lines, title, data_a, data_b, unit, lower_is_better=True):
    """Helper genérico para comparar uma seção entre dois kernels."""
    all_tags = sorted(set(list(data_a.keys()) + list(data_b.keys())))
    if not all_tags:
        return

    direction = "menor é melhor" if lower_is_better else "maior é melhor"
    lines.append(f"--- {title} ({unit}, {direction}) ---")
    lines.append(f"{'Tag':<25} {'A mean':>12} {'B mean':>12} {'D%':>8} {'p-val':>10} {'sig':>5} {'d':>8}")

    for tag in all_tags:
        a_vals = data_a.get(tag, [])
        b_vals = data_b.get(tag, [])
        da, db = describe(a_vals), describe(b_vals)
        if da["mean"] is not None and db["mean"] is not None:
            delta = 100 * (db["mean"] - da["mean"]) / da["mean"] if da["mean"] != 0 else 0
            t, p, sig = welch_ttest(a_vals, b_vals)
            d = cohens_d(a_vals, b_vals)
            sig_str = "Y" if sig else "N"
            p_str = f"{p:.6f}" if p is not None else "N/A"
            d_str = f"{d:.4f}" if d is not None else "N/A"
            lines.append(f"  {tag:<23} {da['mean']:>12.2f} {db['mean']:>12.2f} "
                         f"{delta:>+7.1f}% {p_str:>10} {sig_str:>5} {d_str:>8}")
        elif da["mean"] is not None:
            lines.append(f"  {tag:<23} {da['mean']:>12.2f} {'—':>12}")
        elif db["mean"] is not None:
            lines.append(f"  {tag:<23} {'—':>12} {db['mean']:>12.2f}")
    lines.append("")


def write_comparison_report(outdir, kernel_a, kernel_b):
    """Compara dois kernels lado a lado com Welch's t-test."""
    report_path = Path(outdir) / "comparison_report.txt"
    lines = []
    lines.append(f"{'='*70}")
    lines.append(f"  COMPARACAO: {kernel_a} (A)  vs  {kernel_b} (B)")
    lines.append(f"{'='*70}\n")

    base = Path(outdir).parent  # assume outdir = results/<kernel>
    dir_a = base / kernel_a
    dir_b = base / kernel_b

    def load_both(loader_fn):
        data_a = loader_fn(dir_a) if dir_a.exists() else {}
        data_b = loader_fn(dir_b) if dir_b.exists() else {}
        return data_a, data_b

    # --- Latência ---
    schb_a, schb_b = load_both(load_schbench_results)
    _compare_section(lines, "schbench p99 wakeup latency", schb_a, schb_b, "us", lower_is_better=True)

    hack_a, hack_b = load_both(load_hackbench_results)
    _compare_section(lines, "hackbench", hack_a, hack_b, "s", lower_is_better=True)

    cyc_a, cyc_b = load_both(load_cyclictest_results)
    _compare_section(lines, "cyclictest avg latency", cyc_a, cyc_b, "us", lower_is_better=True)

    pipe_a, pipe_b = load_both(load_perf_sched_pipe_results)
    _compare_section(lines, "perf sched pipe", pipe_a, pipe_b, "us/op", lower_is_better=True)

    msg_a, msg_b = load_both(load_perf_sched_msg_results)
    _compare_section(lines, "perf sched messaging", msg_a, msg_b, "s", lower_is_better=True)

    # --- Throughput ---
    thr_a, thr_b = load_both(load_throughput_results)
    _compare_section(lines, "throughput (stress-ng + sysbench)", thr_a, thr_b, "ops/s", lower_is_better=False)

    # --- Energia ---
    en_a, en_b = load_both(load_energy_results)
    # Comparar perf-per-watt
    ppw_a = {k: v["ppw"] for k, v in en_a.items()}
    ppw_b = {k: v["ppw"] for k, v in en_b.items()}
    _compare_section(lines, "performance-per-watt (RAPL)", ppw_a, ppw_b, "insn/J", lower_is_better=False)
    # Comparar energia total
    pkg_a = {k: v["pkg_j"] for k, v in en_a.items()}
    pkg_b = {k: v["pkg_j"] for k, v in en_b.items()}
    _compare_section(lines, "energia total (RAPL pkg)", pkg_a, pkg_b, "J", lower_is_better=True)

    # --- Overhead ---
    ov_a, ov_b = load_both(load_overhead_results)
    for metric, label, unit in [
        ("ctx_switch_us", "context switch latency (lmbench)", "us"),
        ("ctx_switches_total", "context switches total", "count"),
        ("migrations_per_run", "cpu migrations", "count"),
    ]:
        a_vals = ov_a.get(metric, [])
        b_vals = ov_b.get(metric, [])
        if a_vals or b_vals:
            _compare_section(lines, label,
                             {"all": a_vals} if a_vals else {},
                             {"all": b_vals} if b_vals else {},
                             unit, lower_is_better=True)

    lines.append(f"{'='*70}")
    lines.append("Legenda:")
    lines.append("  D% = (B - A) / A x 100. Negativo = B menor.")
    lines.append("  sig = Welch's t-test p<0.05. d = Cohen's d (effect size).")
    lines.append(f"{'='*70}")

    with open(report_path, "w") as f:
        f.write("\n".join(lines))
    print(f"[stats] Relatório de comparação: {report_path}")


def generate_plots(outdir, all_data):
    """Gera gráficos de box plot para schbench e barras para throughput."""
    if not HAS_SCIPY:
        return

    plots_dir = Path(outdir) / "plots"
    plots_dir.mkdir(exist_ok=True)

    # schbench p99 — box plot por tag
    schbench_data = all_data.get("latency", {}).get("schbench_p99", {})
    if schbench_data:
        fig, ax = plt.subplots(figsize=(10, 5))
        tags = sorted(schbench_data.keys())
        data = [schbench_data[t] for t in tags]
        ax.boxplot(data, labels=tags, patch_artist=True)
        ax.set_ylabel("p99 wakeup latency (us)")
        ax.set_title("schbench - p99 Wakeup Latency por Carga")
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(plots_dir / "schbench_p99_boxplot.pdf", dpi=150)
        plt.savefig(plots_dir / "schbench_p99_boxplot.png", dpi=150)
        plt.close()
        print(f"[plots] schbench boxplot -> {plots_dir}/schbench_p99_boxplot.pdf")

    # throughput — barras com erro
    throughput_data = all_data.get("throughput", {}).get("throughput", {})
    if throughput_data:
        fig, ax = plt.subplots(figsize=(12, 5))
        tags = sorted(throughput_data.keys())
        means = [describe(throughput_data[t])["mean"] or 0 for t in tags]
        stds  = [describe(throughput_data[t])["std"] or 0 for t in tags]
        x = range(len(tags))
        ax.bar(x, means, yerr=stds, capsize=4, alpha=0.8)
        ax.set_xticks(list(x))
        ax.set_xticklabels(tags, rotation=45, ha="right")
        ax.set_ylabel("ops/s")
        ax.set_title("Throughput por Workload")
        ax.grid(True, axis="y", alpha=0.3)
        plt.tight_layout()
        plt.savefig(plots_dir / "throughput_bar.pdf", dpi=150)
        plt.close()

    print(f"[plots] gráficos em {plots_dir}/")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--outdir",     required=True)
    parser.add_argument("--kernel-tag", default="unknown")
    parser.add_argument("--runs",       type=int, default=30)
    parser.add_argument("--compare",    default=None,
                        help="A:B para comparar dois kernels, ex: vanilla:itd_ipcc")
    args = parser.parse_args()

    print(f"[stats] Analisando resultados em: {args.outdir}")
    print(f"[stats] Kernel: {args.kernel_tag}  |  Runs: {args.runs}")
    print(f"[stats] scipy disponível: {HAS_SCIPY}")

    # Carregar todos os dados
    schb      = load_schbench_results(args.outdir)
    hack      = load_hackbench_results(args.outdir)
    cyclic    = load_cyclictest_results(args.outdir)
    pipe      = load_perf_sched_pipe_results(args.outdir)
    msg       = load_perf_sched_msg_results(args.outdir)
    throughput = load_throughput_results(args.outdir)
    energy    = load_energy_results(args.outdir)
    overhead  = load_overhead_results(args.outdir)

    all_data = {
        "latency": {
            "schbench_p99":    schb,
            "hackbench":       hack,
            "cyclictest":      cyclic,
            "perf_sched_pipe": pipe,
            "perf_sched_msg":  msg,
        },
        "throughput": {
            "throughput": throughput,
        },
        "energy": {
            "ppw":   {k: v["ppw"]   for k, v in energy.items()},
            "pkg_j": {k: v["pkg_j"] for k, v in energy.items()},
        },
        "overhead": {
            "ctx_switch_us":      {"all": overhead.get("ctx_switch_us", [])},
            "ctx_switches_total": {"all": overhead.get("ctx_switches_total", [])},
            "migrations_per_run": {"all": overhead.get("migrations_per_run", [])},
        },
    }

    # CSV consolidado
    write_csv_summary(args.outdir, all_data)

    # Gráficos
    generate_plots(args.outdir, all_data)

    # Comparação entre kernels (opcional)
    if args.compare:
        ka, kb = args.compare.split(":")
        write_comparison_report(args.outdir, ka, kb)

    # Checar normalidade (Shapiro-Wilk)
    if HAS_SCIPY:
        print("\n[stats] Teste de normalidade Shapiro-Wilk (p<0.05 = nao-normal):")
        for tag, vals in schb.items():
            if len(vals) >= 3:
                _, p = stats.shapiro(vals[:50])
                flag = "-> usar Mann-Whitney" if p < 0.05 else "-> t-test ok"
                print(f"  schbench/{tag}: p={p:.4f}  {flag}")

    print("\n[stats] Análise concluída.")


if __name__ == "__main__":
    main()
