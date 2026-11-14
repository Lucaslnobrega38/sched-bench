#!/usr/bin/env python3
"""vazao_final.py — tabela final de vazao: vanilla (kernel sem IPCC), x16d250 (IPCC d=250 x=16) e oraculo
(placement perfeito, kernel sem IPCC), nos cenarios contention (8 cls2 + 16 cls1) e relaxed (8 + 8).

Regra de selecao (potencia do pacote estabilizada):
  turbo LIGADO : runs das rodadas *_perf_turboon com potencia media < MAXW (126 W). As descartadas (boost de
                 curta duracao, 129-145 W) sao substituidas, em ordem de rep, por runs das rodadas
                 *_fill_turboon que passam no mesmo corte (so a quantidade que falta para completar 8).
  turbo DESLIGADO: todas as runs de *_perf_turbooff (pacote a ~36 W, sem throttle).
A escolha vem da regra, nao do valor da vazao. A secao final mostra a sensibilidade a escolhas alternativas.

Uso: python3 -I analysis/vazao_final.py [--maxw 126] [--results 275hx/results]
"""
import argparse
import csv
import math
import os
import statistics as st

ap = argparse.ArgumentParser()
ap.add_argument('--maxw', type=float, default=126.0)
ap.add_argument('--results', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '275hx', 'results'))
ap.add_argument('--reps', type=int, default=8)
a = ap.parse_args()
R, MAXW, REPS = a.results, a.maxw, a.reps


def load(tag):
    p = f"{R}/{tag}/throughput_cfg/runs.csv"
    return [r for r in csv.DictReader(open(p)) if 'NA' not in (r['cls2_total'], r['cls1_total'])]


def pick(main, fill, scen, cfg, maxw=MAXW, skip_fill=()):
    """runs de (scen, cfg): boas da rodada principal + as primeiras boas da rodada de reposicao."""
    good = [r for r in load(main) if r['scen'] == scen and r['cfg'] == cfg and float(r['watts']) < maxw]
    out, info = list(good), []
    for r in load(main):
        if r['scen'] == scen and r['cfg'] == cfg and float(r['watts']) >= maxw:
            info.append(f"{main} rep{r['rep']} {float(r['watts']):.0f}W (descartada)")
    if fill and len(out) < REPS:
        for r in sorted((r for r in load(fill) if r['scen'] == scen and r['cfg'] == cfg), key=lambda r: int(r['rep'])):
            if len(out) >= REPS: break
            if r['rep'] in skip_fill or float(r['watts']) >= maxw: continue
            out.append(r); info.append(f"{fill} rep{r['rep']} {float(r['watts']):.1f}W (entrou)")
    return out, info


def vals(rs, k, n): return [float(r[k]) / n for r in rs]
def ms(v): return (st.mean(v), st.stdev(v) / math.sqrt(len(v))) if len(v) > 1 else (v[0], 0.0)


def table(title, sets, scen, n1):
    """sets = {nome: runs}; imprime vanilla / x16d250 / oraculo e a fracao do gap do oraculo capturada."""
    print(f"\n== {title} | {scen} (8 cls2 + {n1} cls1)")
    res = {}
    for k, n, nm in (('cls2_total', 8, 'cls2'), ('cls1_total', n1, 'cls1')):
        van, x16, ora = (ms(vals(sets[c], k, n)) for c in ('vanilla', 'x16d250', 'oracle'))
        gain, gap = x16[0] - van[0], ora[0] - van[0]
        seg, seo = math.hypot(x16[1], van[1]), math.hypot(ora[1], van[1])
        frac = gain / gap if gap else float('nan')
        sef = abs(frac) * math.hypot(seg / gain if gain else 0, seo / gap) if gap else float('nan')
        print(f"  {nm}: vanilla {van[0]:7.0f}±{van[1]:4.0f} (n={len(sets['vanilla'])}) | x16d250 {x16[0]:7.0f}±{x16[1]:4.0f} (n={len(sets['x16d250'])}, {100*gain/van[0]:+5.1f}% ± {100*seg/van[0]:.1f})"
              f" | oracle {ora[0]:7.0f}±{ora[1]:4.0f} (n={len(sets['oracle'])}, {100*gap/van[0]:+5.1f}% ± {100*seo/van[0]:.1f}) | x16d250 capta {100*frac:3.0f}% ± {100*sef:.0f} do gap")
        res[nm] = (van, x16, ora, frac)
    for c in ('vanilla', 'x16d250', 'oracle'):
        w = [float(r['watts']) for r in sets[c]]
        print(f"     {c:<8} potencia: media {st.mean(w):5.1f} W, min {min(w):5.1f}, max {max(w):5.1f}")
    return res


print(f"vazao_final: corte de potencia {MAXW:.0f} W (turbo ligado); reps por celula = {REPS}")
for tb, tags in (("TURBO LIGADO", dict(nm='noipcc_perf_turboon', nf='noipcc_fill_turboon', im='ipcc_perf_turboon', if_='ipcc_fill_turboon', cut=True)),
                 ("TURBO DESLIGADO", dict(nm='noipcc_perf_turbooff', nf=None, im='ipcc_perf_turbooff', if_=None, cut=False))):
    for scen, n1 in (("contention", 16), ("relaxed", 8)):
        mw = MAXW if tags['cut'] else 1e9
        sets, notes = {}, []
        for name, main, fill, cfg in (('vanilla', tags['nm'], tags['nf'], 'vanilla'), ('oracle', tags['nm'], tags['nf'], 'oracle'),
                                      ('x16d250', tags['im'], tags['if_'], 'd250x16')):
            sets[name], info = pick(main, fill, scen, cfg, maxw=mw)
            notes += [f"{name}: {i}" for i in info]
        table(tb, sets, scen, n1)
        for n in notes: print(f"     ajuste: {n}")

# sensibilidade (turbo ligado, contention): escolhas alternativas das runs de reposicao
print("\n== Sensibilidade (turbo LIGADO, contention): reposicao alternativa")
base = {c: pick(m, f, 'contention', cfg)[0] for c, m, f, cfg in (('vanilla', 'noipcc_perf_turboon', 'noipcc_fill_turboon', 'vanilla'),
                                                              ('oracle', 'noipcc_perf_turboon', 'noipcc_fill_turboon', 'oracle'),
                                                              ('x16d250', 'ipcc_perf_turboon', 'ipcc_fill_turboon', 'd250x16'))}
alt = dict(base)
alt['oracle'] = pick('noipcc_perf_turboon', 'noipcc_fill_turboon', 'contention', 'oracle', skip_fill=('1',))[0]       # sem a rep1 (124.6 W, no limite)
alt['x16d250'] = pick('ipcc_perf_turboon', 'ipcc_fill_turboon', 'contention', 'd250x16', skip_fill=('4',))[0]         # rep5 no lugar da rep4
only_old = {c: [r for r in load(m) if r['scen'] == 'contention' and r['cfg'] == cfg and float(r['watts']) < MAXW]
            for c, m, cfg in (('vanilla', 'noipcc_perf_turboon', 'vanilla'), ('oracle', 'noipcc_perf_turboon', 'oracle'), ('x16d250', 'ipcc_perf_turboon', 'd250x16'))}
for nm, ss in (("regra (padrao)", base), ("oracle sem a rep1 de 124,6 W; x16d250 com a rep5", alt), ("so as runs antigas boas (sem reposicao)", only_old)):
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        res = table(nm, ss, 'contention', 16)
    print(f"  {nm:<52} cls2: x16d250 {100*(res['cls2'][1][0]/res['cls2'][0][0]-1):+5.1f}% capta {100*res['cls2'][3]:3.0f}%  |  cls1: x16d250 {100*(res['cls1'][1][0]/res['cls1'][0][0]-1):+5.1f}% capta {100*res['cls1'][3]:3.0f}%")
