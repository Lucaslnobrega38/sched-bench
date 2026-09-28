#!/usr/bin/env python3
"""
analysis/heatmap.py — heatmap de placement no tempo (uma corrida longa por kernel).

Cada painel é um kernel; eixo x = tempo, eixo y = CPUs lógicas (threads de cada
P-core físico juntas, depois os E-cores); cor = classe da tarefa que ocupou a CPU
naquele intervalo (laranja = classe 2, azul = classe 1, cinza = ociosa).

Entrada: diretórios de resultado do run_battery.sh que contêm heatmap/
(topology.txt + samples_<cenário>.csv, gerados por `--phases heatmap`).

Uso:
    python3 analysis/heatmap.py \
        --run "asym_packing=i5/vanilla_smt" --run "icas=i5/orig_smt" \
        --run "pinned=i5/oracle_pin" --out heatmap-i5.pdf

    # amostras de teste (sem hardware): ver --demo
"""

import argparse
import csv
import sys
from pathlib import Path

import numpy as np

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import ListedColormap
    from matplotlib.patches import Patch
except ImportError:
    sys.exit("matplotlib é necessário: pip install matplotlib numpy")

# Paleta segura para daltonismo (Okabe-Ito): ociosa, classe 1, classe 2
COLORS = ["#EDEDED", "#0072B2", "#E69F00"]
LABELS = ["idle", "class 1", "class 2"]


def read_topology(path):
    """Devolve [(rótulo, cpu)] na ordem de exibição e o índice da fronteira P/E."""
    p_rows, e_rows = [], []
    for line in Path(path).read_text().split("\n"):
        parts = line.split()
        if len(parts) != 3:
            continue
        kind, core, cpu = parts[0], int(parts[1]), int(parts[2])
        (p_rows if kind == "P" else e_rows).append((core, cpu))
    p_rows.sort()                       # threads do mesmo core_id ficam adjacentes
    rows = [cpu for _, cpu in p_rows] + [cpu for _, cpu in sorted(e_rows, key=lambda x: x[1])]
    return rows, len(p_rows)


def build_matrix(samples_csv, cpus, duration, bin_s):
    """Matriz [cpu x bin] com a classe majoritária amostrada (0 = ociosa)."""
    n_bins = int(np.ceil(duration / bin_s))
    idx = {cpu: i for i, cpu in enumerate(cpus)}
    counts = np.zeros((len(cpus), n_bins, 3), dtype=np.int32)   # [cpu, bin, classe]
    with open(samples_csv) as f:
        for row in csv.DictReader(f):
            try:
                t = int(row["t_us"]) / 1e6
                cls, cpu = int(row["cls"]), int(row["cpu"])
            except (KeyError, ValueError):
                continue
            b = int(t // bin_s)
            if cpu in idx and 0 <= b < n_bins and cls in (1, 2):
                counts[idx[cpu], b, cls] += 1
    mat = np.zeros((len(cpus), n_bins), dtype=np.int8)
    total = counts.sum(axis=2)
    # empate entre classes → a classe 2 (a que importa) vence
    mat[(counts[:, :, 1] > 0) & (counts[:, :, 1] > counts[:, :, 2])] = 1
    mat[(counts[:, :, 2] > 0) & (counts[:, :, 2] >= counts[:, :, 1])] = 2
    mat[total == 0] = 0
    return mat


def load_run(spec, scenario):
    label, _, path = spec.partition("=")
    base = Path(path).expanduser() / "heatmap"
    return label, base / "topology.txt", base / f"samples_{scenario}.csv"


def plot(runs, scenario, duration, bin_s, out, width, panel_h, fontsize):
    plt.rcParams.update({"font.size": fontsize, "axes.titlesize": fontsize,
                         "axes.labelsize": fontsize, "xtick.labelsize": fontsize - 0.5,
                         "ytick.labelsize": fontsize - 1})
    cmap = ListedColormap(COLORS)
    n = len(runs)
    top_in, bottom_in, gap_in = 0.16, 0.58, 0.20      # margens fixas, em polegadas
    fig_h = panel_h * n + top_in + bottom_in + gap_in * (n - 1)
    fig, axes = plt.subplots(n, 1, sharex=True, squeeze=False, figsize=(width, fig_h),
                             gridspec_kw={"hspace": gap_in / panel_h})
    for ax, (label, topo, samples) in zip(axes[:, 0], runs):
        cpus, n_p = read_topology(topo)
        mat = build_matrix(samples, cpus, duration, bin_s)
        ax.imshow(mat, aspect="auto", interpolation="nearest", cmap=cmap, vmin=0, vmax=2,
                  extent=[0, duration, len(cpus), 0])
        ax.axhline(n_p, color="black", lw=0.8)                     # fronteira P | E
        step = 1 if len(cpus) <= 16 else 4
        ax.set_yticks([i + 0.5 for i in range(0, len(cpus), step)])
        ax.set_yticklabels([str(cpus[i]) for i in range(0, len(cpus), step)])
        ax.tick_params(length=1.5, pad=1)
        ax.set_title(label, loc="left", pad=1.5)
        ax.text(1.005, 1 - (n_p / 2) / len(cpus), "P", transform=ax.transAxes,
                va="center", fontsize=fontsize - 0.5, fontweight="bold")
        ax.text(1.005, 1 - (n_p + (len(cpus) - n_p) / 2) / len(cpus), "E",
                transform=ax.transAxes, va="center", fontsize=fontsize - 0.5, fontweight="bold")
        # o marcador de fronteira só faz sentido se houver P e E
    axes[-1, 0].set_xlabel("time (s)")
    axes[n // 2, 0].set_ylabel("logical CPU", labelpad=2)
    fig.legend(handles=[Patch(facecolor=c, edgecolor="none", label=l)
                        for c, l in zip(COLORS, LABELS)],
               loc="lower center", ncol=3, frameon=False, fontsize=fontsize - 0.5,
               handlelength=1.0, columnspacing=1.2, borderaxespad=0)
    fig.subplots_adjust(left=0.085, right=0.965, top=1 - top_in / fig_h, bottom=bottom_in / fig_h)
    fig.savefig(out)
    print(f"[heatmap] gravado {out}")


def make_demo(dirpath, n_p_cores, n_e, seed, favor_p):
    """Amostras sintéticas SÓ para testar o gráfico (não são dados reais)."""
    d = Path(dirpath) / "heatmap"
    d.mkdir(parents=True, exist_ok=True)
    p_cpus = list(range(2 * n_p_cores))
    e_cpus = list(range(2 * n_p_cores, 2 * n_p_cores + n_e))
    with open(d / "topology.txt", "w") as f:
        for i, c in enumerate(p_cpus):
            f.write(f"P {i // 2} {c}\n")
        for c in e_cpus:
            f.write(f"E {c} {c}\n")
    rng = np.random.default_rng(seed)
    n_cls2, n_cls1 = n_p_cores, 2 * n_p_cores + n_e - n_p_cores
    with open(d / "samples_contention.csv", "w") as f:
        f.write("t_us,cls,pid,cpu\n")
        pos = {("2", i): int(rng.integers(0, len(p_cpus + e_cpus))) for i in range(n_cls2)}
        pos.update({("1", i): int(rng.integers(0, len(p_cpus + e_cpus))) for i in range(n_cls1)})
        allc = p_cpus + e_cpus
        for step in range(2000):
            t = int(step * 0.1 * 1e6)
            for (cls, i), cpu in list(pos.items()):
                if rng.random() < 0.02:   # migração ocasional
                    pool = p_cpus if (cls == "2" and favor_p) else allc
                    pos[(cls, i)] = int(rng.choice(pool))
                f.write(f"{t},{cls},{1000 + i},{pos[(cls, i)]}\n")


def main():
    ap = argparse.ArgumentParser(description="Heatmap de placement no tempo")
    ap.add_argument("--run", action="append", default=[],
                    help='"rótulo=diretório" (repita para vários kernels, na ordem dos painéis)')
    ap.add_argument("--scenario", default="contention", choices=["contention", "relaxed"])
    ap.add_argument("--duration", type=float, default=200.0, help="segundos da corrida")
    ap.add_argument("--bin", type=float, default=1.0, help="largura do bin de tempo (s)")
    ap.add_argument("--out", default="heatmap.pdf")
    ap.add_argument("--width", type=float, default=3.45, help="polegadas (3.45 = 1 coluna IEEE)")
    ap.add_argument("--panel-height", type=float, default=0.9, help="polegadas por painel")
    ap.add_argument("--fontsize", type=float, default=6.5)
    ap.add_argument("--demo", metavar="DIR", help="gera dados SINTÉTICOS de teste em DIR/{a,b}")
    ap.add_argument("--demo-topology", default="2,8", help="P-cores físicos,E-cores do --demo")
    args = ap.parse_args()

    if args.demo:
        p, e = (int(x) for x in args.demo_topology.split(","))
        make_demo(Path(args.demo) / "a", p, e, 1, favor_p=False)
        make_demo(Path(args.demo) / "b", p, e, 2, favor_p=True)
        args.run = [f"asym_packing={Path(args.demo) / 'a'}", f"icas={Path(args.demo) / 'b'}"]

    if not args.run:
        ap.error("informe ao menos um --run rótulo=diretório")
    runs = [load_run(r, args.scenario) for r in args.run]
    for _, topo, samples in runs:
        for p in (topo, samples):
            if not Path(p).exists():
                sys.exit(f"arquivo ausente: {p}  (rodou `--phases heatmap` nesse kernel?)")
    plot(runs, args.scenario, args.duration, args.bin, args.out,
         args.width, args.panel_height, args.fontsize)


if __name__ == "__main__":
    main()
