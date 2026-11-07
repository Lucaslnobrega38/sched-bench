#!/usr/bin/env python3
"""Analisa o log por evento do classificador de shadows (ipcc_log).

Cada linha de interesse do /sys/kernel/tracing/trace tem a forma
    ipcc ns=<monotônico> ev=<evento> campo=valor ...
com os eventos submit, fork, pop, run, deadline, end, cap, slot_free e discard.

Invariantes verificadas (cada uma vira PASS/FAIL):
  1. todo pop, end e deadline acontece num P-core;
  2. no máximo um pop por jiffy por cpu;
  3. nunca dois shadows no mesmo slot ao mesmo tempo, e a ordem por shadow é
     pop -> end -> slot_free;
  4. no máximo um shadow por target em qualquer estágio
     (submit -> fork -> pop -> end, ou discard / fork com erro);
  5. o lag: do fim de um turno de um target até o próximo submit dele passa
     pelo menos --lag-ms;
  6. todo shadow que foi popado terminou (só vale com o sistema drenado);
  7. o shadow começa a rodar logo depois do pop (p99 de pop->run abaixo de
     --max-start-us): regressão do bug em que o idle ignorava o shadow.

Além disso calcula a vida do turno, a taxa de leituras válidas no deadline e a
concordância com a classe esperada (--expect-class).

Uso: python3 -I analyze_log.py --trace trace.txt --pcpus 0,2 --lag-ms 5
       [--expect-class 1] [--read-us 10] [--no-drain-check]
       [--csv out.csv --label d=10 --label method=div16] [--json out.json]
Saída: tabela na tela; código 1 se alguma invariante falhou.
"""
import argparse
import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict

LINE = re.compile(r"ipcc ns=(\d+) ev=(\w+)(.*)$")
KV = re.compile(r"(\w+)=(\S+)")
LAG_SLACK_NS = 50_000          # o log do end é tirado um pouco antes do carimbo do lag


def parse(path):
    events = []
    lost = None
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("# entries-in-buffer/entries-written:"):
                m = re.search(r":\s*(\d+)/(\d+)", line)
                if m:
                    lost = int(m.group(2)) - int(m.group(1))
                continue
            m = LINE.search(line)
            if not m:
                continue
            ev = {"ns": int(m.group(1)), "ev": m.group(2)}
            for k, v in KV.findall(m.group(3)):
                try:
                    ev[k] = int(v)
                except ValueError:
                    ev[k] = v
            events.append(ev)
    events.sort(key=lambda e: e["ns"])
    return events, lost


def pct(vals, p):
    if not vals:
        return 0
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(len(vals) * p / 100))]


class Report:
    def __init__(self):
        self.rows = []
        self.failed = 0

    def check(self, name, ok, detail=""):
        self.rows.append((name, ok, detail))
        if not ok:
            self.failed += 1

    def info(self, name, detail):
        self.rows.append((name, None, detail))

    def show(self):
        for name, ok, detail in self.rows:
            tag = "\x1b[32mPASS\x1b[0m" if ok else "\x1b[31mFAIL\x1b[0m" if ok is False else "...."
            print(f"  {tag}  {name}" + (f"  [{detail}]" if detail else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--pcpus", required=True, help="P-cores, separados por vírgula")
    ap.add_argument("--lag-ms", type=float, default=5)
    ap.add_argument("--read-us", type=float, default=0)
    ap.add_argument("--expect-class", type=int, default=0)
    ap.add_argument("--max-start-us", type=int, default=1000)
    ap.add_argument("--no-drain-check", action="store_true")
    ap.add_argument("--csv")
    ap.add_argument("--label", action="append", default=[])
    ap.add_argument("--json")
    a = ap.parse_args()

    pcpus = {int(x) for x in a.pcpus.split(",") if x}
    events, lost = parse(a.trace)
    rep = Report()
    if not events:
        print("  FAIL  nenhum evento no log (o kernel imprimiu? ipcc_log ligado?)")
        return 1

    span_s = max((events[-1]["ns"] - events[0]["ns"]) / 1e9, 1e-9)
    counts = Counter(e["ev"] for e in events)
    rep.info("eventos", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) + f", janela {span_s:.2f}s")
    if lost:
        rep.info("AVISO", f"{lost} eventos perdidos no ring buffer (os mais antigos); órfãos são tolerados")

    # 1. P-cores
    bad_cpu = [e for e in events if e["ev"] in ("pop", "run", "end", "deadline", "slot_free", "cap") and e.get("cpu") not in pcpus]
    rep.check("todo pop/run/end/deadline/slot_free/cap acontece num P-core", not bad_cpu,
              f"{len(bad_cpu)} fora; ex: {bad_cpu[0]}" if bad_cpu else f"{counts['pop']} pops")

    # 2. um pop por jiffy por cpu
    seen = defaultdict(set)
    dup_j = []
    for e in events:
        if e["ev"] == "pop":
            key = e["j"]
            if key in seen[e["cpu"]]:
                dup_j.append(e)
            seen[e["cpu"]].add(key)
    rep.check("no máximo um pop por jiffy por P-core", not dup_j,
              f"{len(dup_j)} repetidos; ex: {dup_j[0]}" if dup_j else "")

    # 3. slot exclusivo e ordem pop -> end -> slot_free
    slot = {}                      # cpu -> [shadow, ended]
    overlap, order, orphan = [], [], 0
    shadow_of_pop = set()
    for e in events:
        c = e.get("cpu")
        if e["ev"] == "pop":
            if c in slot:
                overlap.append(e)
            slot[c] = [e["shadow"], False]
            shadow_of_pop.add(e["shadow"])
        elif e["ev"] == "end":
            s = slot.get(c)
            if s is None:
                orphan += 1
            elif s[0] != e["shadow"] or s[1]:
                order.append(e)
            else:
                s[1] = True
        elif e["ev"] == "slot_free":
            s = slot.get(c)
            if s is None:
                orphan += 1
            elif s[0] != e["shadow"] or not s[1]:
                order.append(e)
                slot.pop(c, None)
            else:
                slot.pop(c)
    rep.check("nunca dois shadows no mesmo slot", not overlap,
              f"{len(overlap)} sobrepostos; ex: {overlap[0]}" if overlap else "")
    rep.check("ordem por shadow: pop -> end -> slot_free", not order,
              f"{len(order)} fora de ordem; ex: {order[0]}" if order else (f"{orphan} órfãos do início" if orphan else ""))
    if not a.no_drain_check:
        rep.check("todo shadow popado terminou e liberou o slot", not slot,
                  f"{len(slot)} ainda no slot: {dict(slot)}" if slot else "")

    # 4 e 5. por target
    state = {}                     # target -> estado
    last_turn = {}                 # target -> ns do fim do último turno
    viol_state, viol_lag = [], []
    lag_ns = a.lag_ms * 1e6
    lag_gaps = []
    for e in events:
        t = e.get("target")
        ev = e["ev"]
        if t is None:
            continue
        st = state.get(t)
        if ev == "submit":
            if st not in (None, "none"):
                viol_state.append((e, st))
            state[t] = "forking"
            if t in last_turn:
                gap = e["ns"] - last_turn[t]
                lag_gaps.append(gap)
                if gap < lag_ns - LAG_SLACK_NS:
                    viol_lag.append((e, gap))
        elif ev == "fork":
            if e.get("err", 0) != 0:
                state[t] = "none"
                last_turn[t] = e["ns"]
            else:
                if st not in (None, "forking"):
                    viol_state.append((e, st))
                state[t] = "queued"
        elif ev == "pop":
            if st not in (None, "queued"):
                viol_state.append((e, st))
            state[t] = "running"
        elif ev == "discard":
            if st not in (None, "queued"):
                viol_state.append((e, st))
            state[t] = "none"
            last_turn[t] = e["ns"]
        elif ev == "end":
            if st not in (None, "running"):
                viol_state.append((e, st))
            state[t] = "none"
            last_turn[t] = e["ns"]
    rep.check("no máximo um shadow por target em qualquer estágio", not viol_state,
              f"{len(viol_state)} violações; ex: {viol_state[0]}" if viol_state else f"{len(state)} targets")
    rep.check(f"lag mínimo de {a.lag_ms:g}ms entre o fim de um turno e o próximo submit do mesmo target",
              not viol_lag,
              f"{len(viol_lag)} abaixo; pior {min(g for _, g in viol_lag) / 1e3:.0f}us" if viol_lag
              else (f"menor intervalo {min(lag_gaps) / 1e6:.2f}ms em {len(lag_gaps)}" if lag_gaps else ""))

    # estatísticas
    ends = [e for e in events if e["ev"] == "end"]
    pops = [e for e in events if e["ev"] == "pop"]
    life = [e["life_us"] for e in ends if isinstance(e.get("life_us"), int)]
    why = Counter(e["why"] for e in ends)
    classes = Counter(e.get("class", 0) for e in ends)
    with_class = sum(v for k, v in classes.items() if k)
    dl = Counter(e.get("valid") for e in events if e["ev"] == "deadline")
    dl_valid, dl_inv, dl_notcurr = dl.get(1, 0), dl.get(0, 0), dl.get(-1, 0)
    caps = counts["cap"]
    idle_pops = sum(1 for e in pops if e.get("idle") == 1)
    waits = [e["wait_us"] for e in pops if isinstance(e.get("wait_us"), int)]
    forks = [e["fork_us"] for e in events if e["ev"] == "fork" and e.get("err", 1) == 0]
    fork_fail = sum(1 for e in events if e["ev"] == "fork" and e.get("err", 0) != 0)

    starts = [e["start_us"] for e in events if e["ev"] == "run" and isinstance(e.get("start_us"), int)]
    execs = [(e["exec_us"], e.get("class", 0)) for e in ends if isinstance(e.get("exec_us"), int) and e["exec_us"] > 0]
    if starts:
        late = sum(1 for x in starts if x > a.max_start_us)
        rep.check(f"o shadow começa a rodar em até {a.max_start_us}us do pop (pop->run)", pct(starts, 99) <= a.max_start_us,
                  f"p50={pct(starts, 50)}us p99={pct(starts, 99)}us max={max(starts)}us; {late} de {len(starts)} acima do limite")
    never = sum(1 for e in ends if e.get("exec_us") == 0)
    if events and any(e["ev"] == "run" for e in events):
        rep.check("todo shadow que terminou chegou a rodar", never == 0,
                  f"{never} terminaram sem nunca rodar" if never else f"{len(execs)} rodaram")
    rep.info("tempo de execução até o fim (run->end)",
             f"p50={pct([x for x, _ in execs], 50)}us p90={pct([x for x, _ in execs], 90)}us p99={pct([x for x, _ in execs], 99)}us" if execs else "sem dados")

    rep.info("fins por motivo", ", ".join(f"{k}={v}" for k, v in sorted(why.items())) or "nenhum")
    rep.info("vida do turno (pop->fim)",
             f"p50={pct(life, 50)}us p90={pct(life, 90)}us p99={pct(life, 99)}us max={max(life) if life else 0}us")
    rep.info("espera na FIFO", f"p50={pct(waits, 50)}us p99={pct(waits, 99)}us")
    rep.info("fork", f"p50={pct(forks, 50)}us p99={pct(forks, 99)}us, {fork_fail} com erro")
    rep.info("deadline", f"valido={dl_valid} invalido={dl_inv} fora_da_cpu={dl_notcurr}; cap de 1ms={caps}")
    rep.info("classes dos fins", ", ".join(f"cls{k}={v}" for k, v in sorted(classes.items())))
    rep.info("pops", f"{len(pops)} ({idle_pops} no idle), {len(pops) / span_s:.0f}/s")

    agree = None
    if a.expect_class:
        agree = classes.get(a.expect_class, 0) / with_class if with_class else 0.0
        rep.check(f"fins com classe: todos na classe esperada ({a.expect_class})",
                  with_class > 0 and agree >= 0.99,
                  f"{agree * 100:.1f}% de {with_class} com classe, {len(ends) - with_class} sem classe")

    curve = []
    if a.expect_class and execs:
        edges = [10, 25, 50, 100, 250, 500, 1000, 10**9]
        lo = 0
        for hi in edges:
            sel = [c for x, c in execs if lo < x <= hi and c]
            if sel:
                curve.append((lo, hi, len(sel), 100 * sum(1 for c in sel if c == a.expect_class) / len(sel)))
            lo = hi
        rep.info("convergência: % na classe esperada por tempo de execução",
                 "; ".join(f"{lo}-{'inf' if hi >= 10**9 else hi}us: {pc:.0f}% (n={n})" for lo, hi, n, pc in curve))

    rep.show()

    row = {
        **dict(x.split("=", 1) for x in a.label),
        "ends": len(ends),
        "valid_pct": round(100 * with_class / len(ends), 2) if ends else 0,
        "agree_pct": round(100 * agree, 2) if agree is not None else "",
        "deadline_valid": dl_valid,
        "deadline_invalid": dl_inv,
        "deadline_not_curr": dl_notcurr,
        "cap": caps,
        "life_p50_us": pct(life, 50),
        "life_p99_us": pct(life, 99),
        "start_p50_us": pct(starts, 50),
        "start_p99_us": pct(starts, 99),
        "exec_p50_us": pct([x for x, _ in execs], 50),
        "wait_p50_us": pct(waits, 50),
        "pops_per_s": round(len(pops) / span_s),
        "idle_pop_pct": round(100 * idle_pops / len(pops), 1) if pops else 0,
        "fork_p50_us": pct(forks, 50),
        "checks_failed": rep.failed,
    }
    if a.csv:
        new = not os.path.exists(a.csv)
        with open(a.csv, "a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(row))
            if new:
                w.writeheader()
            w.writerow(row)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(row, f, indent=1)
    return 1 if rep.failed else 0


if __name__ == "__main__":
    sys.exit(main())
