#!/usr/bin/env bash
# Funções comuns reutilizadas por todos os scripts de provisionamento.

set -euo pipefail

# ─── Cores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO $(date '+%H:%M:%S')]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC}  $*"; }
log_error() { echo -e "${RED}[ERRO $(date '+%H:%M:%S')]${NC}  $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP $(date '+%H:%M:%S')]${NC}  ── $* ──"; }

# ─── Segurança ───────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script precisa ser executado como root (sudo)."
        exit 1
    fi
}

# ─── Verificação de pacotes ──────────────────────────────────────────────────
is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# ─── Backup de arquivo antes de modificar ────────────────────────────────────
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local bak="${file}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$file" "$bak"
        log_info "Backup: $bak"
    fi
}

# ─── Validar e recarregar NGINX ──────────────────────────────────────────────
# Nunca usa restart quando reload é suficiente.
nginx_test_reload() {
    log_step "Validando configuração NGINX"
    if nginx -t 2>&1; then
        log_info "Configuração válida. Recarregando..."
        nginx -s reload
        log_info "NGINX recarregado com sucesso."
    else
        log_error "Configuração NGINX inválida. Reload cancelado."
        return 1
    fi
}

# ─── Carregar .env se existir ────────────────────────────────────────────────
load_env() {
    local env_file="${1:-.env}"
    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        set -o allexport
        source "$env_file"
        set +o allexport
        log_info ".env carregado: $env_file"
    else
        log_warn ".env não encontrado em $env_file — usando variáveis do ambiente."
    fi
}
