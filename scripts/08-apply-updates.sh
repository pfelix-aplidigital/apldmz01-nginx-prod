#!/usr/bin/env bash
# Fase 8: Aplica atualizações do sistema com backup automático pré-update.
# Verifica se reboot é necessário após aplicar.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root

log_step "08-apply-updates: Backup pré-atualização"
bash "$SCRIPT_DIR/06-backup.sh"

log_step "08-apply-updates: Aplicando atualizações"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

log_step "08-apply-updates: Limpeza de pacotes órfãos"
apt-get autoremove -y -qq
apt-get autoclean -qq

log_step "08-apply-updates: Verificando necessidade de reboot"
if [[ -f /var/run/reboot-required ]]; then
    log_warn "╔══════════════════════════════════════════════╗"
    log_warn "║  REBOOT NECESSÁRIO para aplicar o kernel.    ║"
    log_warn "║  Execute: sudo reboot                        ║"
    log_warn "╚══════════════════════════════════════════════╝"
    [[ -f /var/run/reboot-required.pkgs ]] && {
        log_warn "Pacotes que requerem reboot:"
        cat /var/run/reboot-required.pkgs
    }
else
    log_info "Sem reboot necessário."
fi

# NGINX: reload se foi atualizado (não precisa de restart se reload basta)
if systemctl is-active --quiet nginx; then
    nginx_test_reload || true
fi

log_info "08-apply-updates: Atualizações aplicadas com sucesso."
