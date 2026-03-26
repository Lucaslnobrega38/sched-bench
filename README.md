# sched-bench

Bateria de benchmarks para avaliar os patches IPCC (Intel Thread Director) de Ricardo Neri no scheduler Linux. Hardware alvo: Intel i5-1334P (Raptor Lake-P) — 4 P-cores (CPU 0–3) + 8 E-cores (CPU 4–11).

## Uso

```bash
# Instalar dependências (Arch ou Debian/Ubuntu)
sudo ./setup_deps.sh

# Rodar bateria completa (bootar no kernel desejado antes)
sudo ./run_battery.sh --kernel <tag> --runs 50

# Comparar resultados
source .venv/bin/activate
python3 analysis/compare.py --kernels vanilla,asym_packing,ipcc
```

## Estrutura

```
run_battery.sh          orquestrador principal
setup_deps.sh           instala dependências
lib/
  00_preflight.sh       verificação de hardware e dependências
  01_placement.sh       residência nos P/E-cores por classe ITD
  02_latency.sh         schbench, cyclictest, hackbench, perf pipe
  03_throughput.sh      bogo-ops/s de workload cls2 sob contention
  04_energy.sh          ops/Joule via RAPL
  05_overhead.sh        context switches, migrations, pipe latency
  06_report.sh          gera report.txt por kernel
analysis/
  compare.py            comparação N kernels, t-test, gráficos
  placement_accuracy.py processa residency_samples
docs/
  methodology.txt       metodologia completa
  ipcc_classes_behavior.md  comportamento das classes ITD por workload
```

## Workloads

- **Classe 2 (vector):** `stress-ng --cpu-method rand48`
- **Classe 1 (integer):** `stress-ng --cpu-method div16`
- **Latência (cls0):** `schbench -t 4 -m 2`

## Kernels testados

| Tag | Configuração |
|-----|-------------|
| vanilla | CFS puro, sem asym_packing |
| asym_packing | asym_packing ativo, sem IPCC |
| ipcc | asym_packing + classes IPCC |

Resultados em `results/<tag>/`. Análise comparativa em `results/comparison/report.txt`.
