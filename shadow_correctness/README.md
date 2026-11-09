# shadow_correctness — testes do shadow fork em todos os P-cores

Testes de corretude e o experimento empírico do deadline de leitura para o classificador de shadows do kernel (`branch shadow_classification`). O mecanismo está em `context.md` (seções 2 e 3) e o modelo de vazão e custo em `README.md`, ambos na raiz do repositório do kernel.

Resumo do que se testa: cada E-core tem um P-core fixo (partição ⌊i·qtd_P/qtd_E⌋) e submete no máximo uma vez a cada `ipcc_pop_ticks · k_P` jiffies; depois do fork, o shadow vai direto para o slot do P (`via=push`) se ele está ocioso e o `cmpxchg` do slot dá certo, senão para a fila daquele P, que o P esvazia no tick ou ao entrar em idle. O shadow roda em `rq->ipcc_shadow` (classe própria acima de fair, fora de `nr_running`), um hrtimer lê o hardware `d` µs depois (`ipcc_shadow_read_us`) e a classe volta ao alvo. Os testes conferem a partição (`--emap`, montado pelo `lib.sh` com a mesma fórmula) e o período do produtor (`--pop-ticks`).

## Pré-requisitos

- Kernel do branch `shadow_classification` **com o classificador novo** (`CONFIG_IPC_CLASSES_ACTIVE_CLASSIFIER=y`), em boot com `nosmt`, sem `nohz_full=` nos P-cores. Sem os arquivos abaixo no debugfs o teste termina com código 77 (pulado).
- root, `stress-ng`, `gcc`, `python3`, debugfs montado em `/sys/kernel/debug` e tracefs em `/sys/kernel/tracing`.
- Recomendado no primeiro boot: `CONFIG_PROVE_LOCKING` e `CONFIG_DEBUG_ATOMIC_SLEEP` (o pop roda em hardirq e no idle).

Interface do kernel usada (tudo em `/sys/kernel/debug/`):

| Arquivo | Para quê |
|---|---|
| `ipcc_classifier_stats` | contadores, `fifo_len`, `slots_busy`, histograma `life_hist_us` |
| `ipcc_classifier_reset` | escrever qualquer coisa zera contadores e histograma |
| `ipcc_log` | 1 liga o log por evento no ftrace (`/sys/kernel/tracing/trace`) |
| `ipcc_shadow_read_us` | atraso da leitura, em µs (0 = timer desligado, só o tick lê) |
| `ipcc_min_lag_ms` | lag mínimo desde a morte do último shadow do mesmo alvo |
| `ipcc_pop_ticks` | x: cada P consome 1000/x shadows/s; um E submete no máximo a cada x·k_P jiffies (boot: `ipcc_pop_ticks=`) |
| `ipcc_max_age_ms` | descarta shadows parados na FIFO há mais que isso (0 = nunca) |
| `ipcc_classify` | escrever um pid submete aquele processo |

`/proc/<pid>/sched` mostra `ipcc`, `ipcc_confirm_count`, `ipcc_class_weight[0..4]`, `ipcc_shadow_status`.

## Como rodar

```
sudo ./run_all.sh                  # tudo, na ordem
sudo ./run_all.sh t1 t3            # só alguns
sudo READ_US=25 LAG_MS=2 ./t1_pipeline.sh
```

Variáveis comuns: governor `performance` com turbo ligado durante o teste, como o `load_scaling.sh`, restaurados ao sair (`NO_TURBO=1` desliga o turbo; `FIX_FREQ=0` não mexe na frequência), `READ_US` (padrão 100), `LAG_MS` (padrão 5), `DUR` (duração da carga, em s). Os knobs do kernel são guardados e restaurados ao sair. Resultados em `results/<data>/<teste>/` (`result.txt`, `stats.txt`, `trace*.txt`, `analysis.json`).

## O que cada teste verifica

| Teste | Verifica | Passa se |
|---|---|---|
| `t1_pipeline.sh` | carga mista nos E-cores (duas classes + syscall), analisa o log por evento | todo pop/end em P-core; no máximo 1 pop por jiffy por cpu; nunca 2 shadows no mesmo slot e ordem pop→end→slot_free; 1 shadow por target; lag respeitado; tudo drena; log do kernel limpo |
| `t2_invariants.sh` | contabilidade depois de drenar | `inserted = popped + discarded + fifo_len`; `popped = terminados + slots`; histograma soma os terminados; sem filho preso no `ipcc-reaper`, sem zumbi |
| `t3_class.sh` | a classe de um worker de E-core (só shadows) é a que um P-core daria (oráculo pinado) | `div16`/`double` → classe 1 e `rand48`/`fft` → classe 2, no oráculo, no worker sombreado e no argmax do vetor de pesos |
| `t4_memory.sh` + `mem_integrity.c` | o shadow nunca escreve na memória do alvo | com shadows de fato, o contador na região `MAP_SHARED` nunca anda para trás no reader e a região privada do writer fica íntegra |
| `t5_edges.sh` + `fault_touch.c` | (a) alvos que morrem com shadow na FIFO/slot; (b) 12 000 escritas concorrentes em `ipcc_classify` para o mesmo pid; (c) shadows dormindo em falta de página com I/O | em todas: drena, identidades fecham, 1 shadow por target, log limpo; em (c) mostra se `deadline_not_curr`/`cap_expired` foram exercitados |
| `t6_deadline_sweep.sh` | a varredura de `d` (ver abaixo) | não é pass/fail: gera a tabela e `sweep.csv` |

### O experimento do deadline (`t6`)

`d` é empírico: quanto tempo depois de começar a rodar um shadow já tem uma leitura válida do ITD? Para `d` em `0 5 10 25 50 100 250` µs e um método de classe 1 (`div16`) e um de classe 2 (`rand48`), com 4 workers em E-cores, a tabela mostra:

- `start_p50_us`, `exec_p50_us`: atraso pop→run (deve ser µs) e tempo de execução até a leitura;
- `valid_pct`: % dos turnos que terminaram com alguma classe (o resto foi leitura inválida);
- `agree_pct`: % dos turnos com classe que bateram com a classe esperada do método;
- `deadline_valid / deadline_invalid / deadline_not_curr`: leituras do timer;
- `life_p50_us`, `life_p99_us`: vida do turno, do pop ao fim;
- `pops_per_s`, `idle_pop_pct`: vazão e quanto dela veio da entrada em idle;
- `cap`: quantas vezes o teto de emergência de 1 ms agiu (em operação normal deveria ser 0).

O analisador também imprime a **curva de convergência**: % na classe esperada por faixa de tempo de execução (`exec_us`), o dado direto de quanto o ITD precisa rodar para acertar. O ponto procurado é o menor `d` com `valid_pct ≈ 100` e `agree_pct ≈ 100`. Com `d = 0` a leitura vem só do tick seguinte, para comparar o custo.

## Como ler o log por evento

Cada linha tem `ipcc ns=<ns monotônico> ev=<evento> campo=valor`:

| Evento | Campos | Quando |
|---|---|---|
| `submit` | target, cpu | tick de E-core aceitou o alvo |
| `fork` | target, shadow, err, fork_us | fork do shadow terminou (err≠0 = falhou) |
| `pop` | cpu, via, ecpu, target, shadow, wait_us, j | o shadow foi iniciado no P `cpu` (`via` = push pelo E, tick ou idle pelo P; `ecpu` = E que pediu) |
| `run` | cpu, shadow, start_us | o shadow entrou na cpu pela primeira vez (`start_us` = pop→run, deve ser µs) |
| `deadline` | cpu, shadow, valid | o timer disparou (valid=-1: shadow fora da cpu) |
| `end` | why, cpu, target, shadow, class, k, life_us, exec_us | o turno acabou (`why` = confirmed/syscall/timeout/other); `exec_us` = run→end |
| `cap` | cpu, shadow | o teto de 1 ms encerrou o turno |
| `slot_free` | cpu, shadow, target | o slot da rq foi liberado |
| `discard` | target, shadow, age_us | descartado ainda na FIFO |

`analyze_log.py` pode ser usado sozinho: `python3 -I analyze_log.py --trace trace.txt --pcpus 0,2 --lag-ms 5`.

## O que não está coberto

- `sched_setscheduler`/`chrt` num shadow devolvendo `-EPERM` e `taskset` não movendo: o shadow vive microssegundos, sem como acertar um pid de fora.
- Hotplug de um P-core com shadow no slot e ativação do sched_ext com shadows vivos: não tratados no kernel; testar à mão (`echo 0 > /sys/devices/system/cpu/cpuN/online` durante uma carga).
- Contaminação do histórico do ITD entre a task anterior e o shadow num P-core compartilhado (o `hreset` na entrada existe para isso). `BUSY_P=1 sudo ./t3_class.sh` mostra o efeito indiretamente: com os outros P-cores ocupados (o shadow preempta uma task real) a classe tem de continuar batendo com o oráculo.
