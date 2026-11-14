#!/usr/bin/env python3
"""freq_busy.py — frequência efetiva dos cores enquanto EXECUTAM (APERF/MPERF).

Uso: python3 -I freq_busy.py <lista-de-cpus "0,1,2"> <arquivo-de-saida> [intervalo_s=0.1]
Roda até receber SIGTERM e então escreve no arquivo uma linha:
    busy_mhz=<MHz> c0_pct=<%> tsc_mhz=<MHz> n=<amostras>
busy_mhz = TSC_MHz * soma(dAPERF) / soma(dMPERF): o MPERF só conta o tempo em C0,
então é o clock durante a execução (não a média com os cores ociosos).
c0_pct   = soma(dMPERF) / (ncpus * soma(dTSC)): fração do tempo em C0.
Precisa de root e do módulo msr (/dev/cpu/N/msr). Sem isso escreve NA.
Variáveis FREQ_MSR_DIR e FREQ_MSR_STRIDE existem só para teste com arquivos comuns.
"""
import os
import signal
import sys
import time

MSR_TSC, MSR_MPERF, MSR_APERF = 0x10, 0xE7, 0xE8
base = os.environ.get("FREQ_MSR_DIR", "/dev/cpu")
STRIDE = int(os.environ.get("FREQ_MSR_STRIDE", "1"))   # so para teste com arquivo comum


def rd(fd, reg):
    return int.from_bytes(os.pread(fd, 8, reg * STRIDE), "little")


def main():
    cpus = [int(c) for c in sys.argv[1].split(",") if c]
    out = sys.argv[2]
    dt = float(sys.argv[3]) if len(sys.argv) > 3 else 0.1
    stop = []
    signal.signal(signal.SIGTERM, lambda *a: stop.append(1))
    signal.signal(signal.SIGINT, lambda *a: stop.append(1))
    try:
        fds = {c: os.open(f"{base}/{c}/msr", os.O_RDONLY) for c in cpus}
    except OSError as e:
        open(out, "w").write(f"busy_mhz=NA c0_pct=NA tsc_mhz=NA n=0 ({e})\n")
        return
    ref = cpus[0]
    prev = {c: (rd(fds[c], MSR_APERF), rd(fds[c], MSR_MPERF)) for c in cpus}
    ptsc, pt = rd(fds[ref], MSR_TSC), time.monotonic()
    sa = sm = stsc = swall = 0
    n = 0
    while not stop:
        time.sleep(dt)
        cur = {c: (rd(fds[c], MSR_APERF), rd(fds[c], MSR_MPERF)) for c in cpus}
        ctsc, ct = rd(fds[ref], MSR_TSC), time.monotonic()
        for c in cpus:
            sa += cur[c][0] - prev[c][0]
            sm += cur[c][1] - prev[c][1]
        stsc += ctsc - ptsc
        swall += ct - pt
        prev, ptsc, pt = cur, ctsc, ct
        n += 1
    if n == 0 or sm <= 0 or swall <= 0 or stsc <= 0:
        open(out, "w").write(f"busy_mhz=NA c0_pct=NA tsc_mhz=NA n={n}\n")
        return
    tsc_mhz = stsc / swall / 1e6
    busy = tsc_mhz * sa / sm
    c0 = 100.0 * sm / (len(cpus) * stsc)
    open(out, "w").write(f"busy_mhz={busy:.0f} c0_pct={c0:.1f} tsc_mhz={tsc_mhz:.0f} n={n}\n")


if __name__ == "__main__":
    main()
