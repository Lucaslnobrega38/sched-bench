#!/usr/bin/env python3
"""Amostra o campo ipcc de um processo em intervalos fixos (uma classe por linha).

Uso: sample_ipcc.py <pid> <segundos> <intervalo_ms> <arquivo>
Para quando o processo some. Sem debounce, cada amostra é a última leitura de
classe que o kernel gravou no processo (uma por tick de usuário em P-core).
"""
import re, sys, time

pid, secs, ms, out = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
rx = re.compile(rb"^ipcc\s*:\s*(\d+)", re.M)
end = time.monotonic() + secs
n = 0
with open(out, "w") as f:
    while time.monotonic() < end:
        try:
            with open(f"/proc/{pid}/sched", "rb") as p:
                m = rx.search(p.read())
        except OSError:
            break
        if m:
            f.write(m.group(1).decode() + "\n")
            n += 1
        time.sleep(ms / 1000)
