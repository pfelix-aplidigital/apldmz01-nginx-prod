#!/usr/bin/env bash
# Fase 9: Migração de rede para endereçamento DMZ definitivo.
# Usa `netplan try` com rollback automático em 120s se não confirmado.
#
# ════════════════════════════════════════════════════════════════
# ATENÇÃO: Este é o ÚLTIMO passo de provisionamento.
# A sessão SSH SERÁ INTERROMPIDA ao alterar o IP.
# Execute SOMENTE com console/IPMI disponível.
# ════════════════════════════════════════════════════════════════

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

DMZ_INTERFACE="${DMZ_INTERFACE:-ens3}"
DMZ_IP="${DMZ_IP:-}"
DMZ_PREFIX="${DMZ_PREFIX:-24}"
DMZ_GATEWAY="${DMZ_GATEWAY:-}"
DMZ_DNS_1="${DMZ_DNS_1:-8.8.8.8}"
DMZ_DNS_2="${DMZ_DNS_2:-1.1.1.1}"

# Validações
[[ -z "$DMZ_IP" ]]      && { log_error "DMZ_IP não definido.";      exit 1; }
[[ -z "$DMZ_GATEWAY" ]] && { log_error "DMZ_GATEWAY não definido."; exit 1; }

CURRENT_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║  ⚠  MIGRAÇÃO DE REDE — AÇÃO IRREVERSÍVEL NA SESSÃO ATUAL        ║"
echo "  ╠══════════════════════════════════════════════════════════════════╣"
echo "  ║  IP atual:   ${CURRENT_IP}"
echo "  ║  Novo IP:    ${DMZ_IP}/${DMZ_PREFIX}"
echo "  ║  Gateway:    ${DMZ_GATEWAY}"
echo "  ║  DNS:        ${DMZ_DNS_1}, ${DMZ_DNS_2}"
echo "  ║  Interface:  ${DMZ_INTERFACE}"
echo "  ╠══════════════════════════════════════════════════════════════════╣"
echo "  ║  A sessão SSH atual SERÁ INTERROMPIDA.                          ║"
echo "  ║  netplan try → rollback automático em 120s se não confirmado.   ║"
echo "  ║  Após migração: ssh apli.adm@${DMZ_IP}                  ║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo ""

read -rp "  Digite CONFIRMO para prosseguir (qualquer outra entrada cancela): " CONFIRM
if [[ "$CONFIRM" != "CONFIRMO" ]]; then
    log_info "Migração cancelada pelo operador."
    exit 0
fi

log_step "09-migrate-network: Backup pré-migração"
bash "$SCRIPT_DIR/06-backup.sh"

log_step "09-migrate-network: Gerando configuração netplan"
NETPLAN_TEMPLATE="$REPO_DIR/netplan/dmz.yaml.template"
NETPLAN_DEST=/etc/netplan/99-dmz.yaml

if [[ ! -f "$NETPLAN_TEMPLATE" ]]; then
    log_error "Template netplan não encontrado: $NETPLAN_TEMPLATE"
    exit 1
fi

# Desabilita configurações de rede antigas para evitar conflitos
for old_netplan in /etc/netplan/0*.yaml /etc/netplan/50*.yaml; do
    [[ -f "$old_netplan" ]] && backup_file "$old_netplan" && mv "$old_netplan" "${old_netplan}.disabled"
done

export DMZ_INTERFACE DMZ_IP DMZ_PREFIX DMZ_GATEWAY DMZ_DNS_1 DMZ_DNS_2
envsubst '${DMZ_INTERFACE} ${DMZ_IP} ${DMZ_PREFIX} ${DMZ_GATEWAY} ${DMZ_DNS_1} ${DMZ_DNS_2}' \
    < "$NETPLAN_TEMPLATE" > "$NETPLAN_DEST"

chmod 600 "$NETPLAN_DEST"

log_info "Configuração netplan gerada: $NETPLAN_DEST"
cat "$NETPLAN_DEST"

echo ""
log_warn "Executando 'netplan try --timeout 120'..."
log_warn "Você tem 120 segundos para confirmar a nova configuração na NOVA sessão SSH."
log_warn "Se não confirmar, o netplan fará rollback automaticamente."
echo ""

# netplan try: aplica temporariamente e aguarda confirmação
# Se o operador não confirmar em 120s, reverte automaticamente
netplan try --timeout 120 && {
    log_info "netplan try confirmado — aplicando permanentemente."
    netplan apply
    log_info "═══════════════════════════════════════════════════════"
    log_info "Migração concluída. Novo IP: ${DMZ_IP}/${DMZ_PREFIX}"
    log_info "Acesso: ssh apli.adm@${DMZ_IP}"
    log_info "═══════════════════════════════════════════════════════"
} || {
    log_warn "netplan try não confirmado ou revertido automaticamente."
    log_warn "Restaurando configurações anteriores..."
    for disabled in /etc/netplan/*.yaml.disabled; do
        mv "$disabled" "${disabled%.disabled}"
    done
    rm -f "$NETPLAN_DEST"
    netplan apply
    log_warn "Rollback concluído. IP original mantido: ${CURRENT_IP}"
}
