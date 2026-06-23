#!/usr/bin/env bash
# Fase 7: Lista pacotes e security updates pendentes sem aplicar nada.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root

log_step "07-check-updates: Atualizando índice de pacotes"
apt-get update -qq

log_step "07-check-updates: Pacotes com atualizações disponíveis"
UPGRADABLE=$(apt-get --just-print upgrade 2>/dev/null | grep "^Inst" | wc -l)
log_info "Total de pacotes atualizáveis: $UPGRADABLE"

if [[ $UPGRADABLE -gt 0 ]]; then
    apt-get --just-print upgrade 2>/dev/null | grep "^Inst" | head -50
fi

log_step "07-check-updates: Security updates (unattended-upgrades)"
if command -v unattended-upgrades &>/dev/null; then
    unattended-upgrades --dry-run --debug 2>&1 \
        | grep -E "(Checking|Downloading|Upgrading|packages will)" \
        || true
fi

log_step "07-check-updates: Status de reboot"
if [[ -f /var/run/reboot-required ]]; then
    log_warn "REBOOT NECESSÁRIO após atualizações anteriores."
    [[ -f /var/run/reboot-required.pkgs ]] && cat /var/run/reboot-required.pkgs
else
    log_info "Sem reboot pendente."
fi

log_step "07-check-updates: Versão do NGINX"
if command -v nginx &>/dev/null; then
    CURRENT=$(nginx -v 2>&1)
    AVAILABLE=$(apt-cache policy nginx 2>/dev/null | grep "Candidate:" | awk '{print $2}')
    log_info "Instalado: $CURRENT"
    log_info "Disponível: $AVAILABLE"
fi

log_info "07-check-updates: Verificação concluída. Use 'make apply-updates' para aplicar."
