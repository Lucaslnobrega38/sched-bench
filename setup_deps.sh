#!/bin/bash
# =============================================================================
# setup_deps.sh — Instala todas as dependências da bateria de testes
# Suporta: Arch Linux e Ubuntu/Debian
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log()  { echo -e ">>> $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

[[ $EUID -eq 0 ]] || { echo "Execute como root: sudo ./setup_deps.sh"; exit 1; }

# ---------------------------------------------------------------------------
# Detectar distro
# ---------------------------------------------------------------------------
if command -v pacman &>/dev/null; then
    DISTRO="arch"
elif command -v apt-get &>/dev/null; then
    DISTRO="debian"
else
    echo "Distro não suportada (precisa de pacman ou apt-get)"; exit 1
fi

log "Distro detectada: $DISTRO"

# ---------------------------------------------------------------------------
# Instalar pacotes do sistema
# ---------------------------------------------------------------------------
if [[ "$DISTRO" == "arch" ]]; then
    log "Atualizando repositórios (pacman)..."
    pacman -Sy --noconfirm

    log "Instalando ferramentas do kernel e benchmarks..."
    pacman -S --needed --noconfirm \
        perf \
        util-linux \
        cpupower \
        stress-ng \
        sysbench \
        numactl \
        hwloc \
        rt-tests \
        fio \
        bc \
        python \
        python-pip \
        jq \
        gnuplot \
        bpftrace \
        base-devel \
        git \
        wget \
        json-c \
        autoconf \
        automake \
        libtool

    # lmbench não está nos repos oficiais do Arch — build from AUR ou source
    if ! command -v lat_ctx &>/dev/null; then
        log "Compilando lmbench from source..."
        TMP=$(mktemp -d)
        git clone --depth=1 https://github.com/intel/lmbench.git "$TMP/lmbench" 2>/dev/null || \
            git clone --depth=1 https://github.com/lmbench/lmbench.git "$TMP/lmbench" || true
        if [[ -d "$TMP/lmbench" ]]; then
            cd "$TMP/lmbench"
            # lmbench usa make results — tentar build simples
            make -C src -j"$(nproc)" 2>/dev/null || warn "lmbench build falhou — continuando sem ele"
            # Copiar binários úteis se existirem
            for bin in lat_ctx lat_pipe lat_proc bw_pipe; do
                [[ -f "bin/$(uname -m)-linux-gnu/$bin" ]] && cp "bin/$(uname -m)-linux-gnu/$bin" /usr/local/bin/ 2>/dev/null || true
            done
            cd "$SCRIPT_DIR"
        fi
    fi

else
    # Debian/Ubuntu (original)
    log "Atualizando repositórios (apt)..."
    apt-get update -q

    log "Instalando ferramentas do kernel..."
    apt-get install -y \
        linux-tools-common \
        linux-tools-generic \
        linux-tools-"$(uname -r)" \
        util-linux \
        cpufrequtils \
        msr-tools \
        stress-ng \
        sysbench \
        numactl \
        hwloc \
        hwloc-nox \
        lmbench \
        rt-tests \
        fio \
        bc \
        python3 \
        python3-pip \
        python3-venv \
        jq \
        gnuplot \
        bpftrace \
        libjson-c-dev \
        autoconf \
        automake \
        libtool \
        git \
        wget
fi

# ---------------------------------------------------------------------------
# schbench (Facebook) — build from source
# ---------------------------------------------------------------------------
log "Compilando schbench..."
if ! command -v schbench &>/dev/null; then
    TMP=$(mktemp -d)
    git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/mason/schbench.git "$TMP/schbench" 2>/dev/null || \
        git clone --depth=1 https://github.com/cminyard/schbench.git "$TMP/schbench"
    make -C "$TMP/schbench" -j"$(nproc)"
    cp "$TMP/schbench/schbench" /usr/local/bin/
    ok "schbench instalado"
else
    ok "schbench já presente"
fi

# ---------------------------------------------------------------------------
# hackbench — já parte do perf-bench (linux-tools)
# ---------------------------------------------------------------------------
log "Verificando hackbench..."
if ! command -v hackbench &>/dev/null; then
    ln -sf "$(which perf)" /usr/local/bin/hackbench 2>/dev/null || true
    warn "Use 'perf bench sched messaging' como fallback para hackbench"
fi

# ---------------------------------------------------------------------------
# rt-app — ARM/Linaro workload simulator
# ---------------------------------------------------------------------------
log "Compilando rt-app..."
if ! command -v rt-app &>/dev/null; then
    TMP=$(mktemp -d)
    git clone --depth=1 https://github.com/scheduler-tools/rt-app.git "$TMP/rt-app"
    cd "$TMP/rt-app"
    autoreconf -ifv
    ./configure --prefix=/usr/local
    make -j"$(nproc)"
    make install
    cd "$SCRIPT_DIR"
    ok "rt-app instalado"
else
    ok "rt-app já presente"
fi

# ---------------------------------------------------------------------------
# turbostat
# ---------------------------------------------------------------------------
log "Verificando turbostat (opcional — energia usa RAPL sysfs)..."
command -v turbostat &>/dev/null && ok "turbostat presente" || warn "turbostat não encontrado — OK, energia usa RAPL sysfs diretamente"

# ---------------------------------------------------------------------------
# Python venv + dependências
# ---------------------------------------------------------------------------
log "Criando venv Python em ${VENV_DIR}..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install scipy numpy matplotlib pandas tabulate seaborn
deactivate
ok "venv Python criado em ${VENV_DIR}"

# Garantir que o usuário real seja dono do venv (não root)
REAL_USER="${SUDO_USER:-$(whoami)}"
if [[ "$REAL_USER" != "root" ]]; then
    chown -R "$REAL_USER:$REAL_USER" "$VENV_DIR"
fi

# ---------------------------------------------------------------------------
# Módulo MSR
# ---------------------------------------------------------------------------
log "Carregando módulo msr..."
modprobe msr && ok "módulo msr carregado" || warn "módulo msr falhou"

# ---------------------------------------------------------------------------
# Verificação final
# ---------------------------------------------------------------------------
echo ""
echo "=== Verificação de dependências ==="
for cmd in perf schbench stress-ng cyclictest turbostat bpftrace python3 numactl; do
    if command -v "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $cmd"
    else
        echo -e "  ${RED}✗${NC} $cmd — AUSENTE"
    fi
done

echo ""
echo "=== Módulo MSR ==="
lsmod | grep msr && echo -e "  ${GREEN}✓${NC} msr carregado" || echo -e "  ${RED}✗${NC} msr não carregado"

echo ""
echo "=== Python venv ==="
if [[ -f "$VENV_DIR/bin/python3" ]]; then
    echo -e "  ${GREEN}✓${NC} venv em ${VENV_DIR}"
    "$VENV_DIR/bin/python3" -c "import scipy, numpy, matplotlib, pandas; print('  pacotes OK')"
else
    echo -e "  ${RED}✗${NC} venv não encontrado"
fi

echo ""
ok "Setup concluído. Execute: sudo ./run_battery.sh"
