#!/usr/bin/env bash
# Fase 3: Criação do usuário administrador apli.adm com autenticação por chave SSH.
# Idempotente: não recria o usuário se já existir; atualiza chave e sudo.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

ADMIN_USER="${ADMIN_USER:-apli.adm}"
ADMIN_PUBKEY="${ADMIN_PUBKEY:-}"
ADMIN_NOPASSWD="${ADMIN_NOPASSWD:-false}"

if [[ -z "$ADMIN_PUBKEY" ]]; then
    log_error "ADMIN_PUBKEY não definida. Defina no .env ou exporte a variável."
    exit 1
fi

log_step "03-create-admin: Usuário ${ADMIN_USER}"

if id "$ADMIN_USER" &>/dev/null; then
    log_info "Usuário ${ADMIN_USER} já existe — atualizando configurações."
else
    useradd \
        --create-home \
        --shell /bin/bash \
        --comment "Administrador Aplidigital" \
        "$ADMIN_USER"
    log_info "Usuário ${ADMIN_USER} criado."
fi

log_step "03-create-admin: Adicionando ao grupo sudo"
usermod -aG sudo "$ADMIN_USER"

log_step "03-create-admin: Configurando chave SSH"
SSH_DIR="/home/${ADMIN_USER}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Adiciona a chave se ainda não estiver presente
if ! grep -qF "$ADMIN_PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "$ADMIN_PUBKEY" >> "$AUTH_KEYS"
    log_info "Chave pública adicionada."
else
    log_info "Chave pública já presente."
fi

chmod 600 "$AUTH_KEYS"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "$SSH_DIR"

log_step "03-create-admin: Configuração de sudo"
SUDOERS_FILE="/etc/sudoers.d/${ADMIN_USER}"
if [[ "$ADMIN_NOPASSWD" == "true" ]]; then
    echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    log_warn "NOPASSWD habilitado para ${ADMIN_USER}. Use apenas em ambiente de lab."
else
    # Garante que o arquivo de sudoers não tenha NOPASSWD se a variável mudou
    rm -f "$SUDOERS_FILE"
    log_info "Sudo com senha para ${ADMIN_USER} (via grupo sudo)."
fi

log_step "03-create-admin: Bloqueando senha do usuário (apenas SSH key)"
# Coloca '!' no shadow para impossibilitar login por senha
passwd -l "$ADMIN_USER" || true

log_info "03-create-admin: Concluído."
log_warn "Teste o acesso SSH com a chave antes de fechar esta sessão:"
log_warn "  ssh ${ADMIN_USER}@<IP_DO_SERVIDOR>"
