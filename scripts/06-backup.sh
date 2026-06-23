#!/usr/bin/env bash
# Fase 6: Backup de configurações críticas do servidor.
# Gera tar.gz com timestamp em backups/ e, opcionalmente, copia para destino remoto.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

BACKUP_REMOTE_HOST="${BACKUP_REMOTE_HOST:-}"
BACKUP_REMOTE_PATH="${BACKUP_REMOTE_PATH:-/backups/apldmz01}"
BACKUP_REMOTE_USER="${BACKUP_REMOTE_USER:-backup}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$REPO_DIR/backups"
BACKUP_FILE="$BACKUP_DIR/nginx-backup-${TIMESTAMP}.tar.gz"
TMP_DIR=$(mktemp -d)

trap 'rm -rf "$TMP_DIR"' EXIT

log_step "06-backup: Coletando dados para backup"

# Lista de pacotes instalados
dpkg --get-selections > "$TMP_DIR/dpkg-selections.txt"
log_info "  ✓ dpkg --get-selections"

# Usuários e grupos
getent passwd > "$TMP_DIR/passwd.txt"
getent group  > "$TMP_DIR/group.txt"
log_info "  ✓ passwd/group"

# Cron do root
crontab -l 2>/dev/null > "$TMP_DIR/crontab-root.txt" || true
log_info "  ✓ crontab"

log_step "06-backup: Criando arquivo $BACKUP_FILE"

# Caminhos a incluir no backup
INCLUDE_PATHS=(
    /etc/nginx
    /etc/letsencrypt
    /etc/netplan
    /etc/ssh/sshd_config
    /etc/ssh/sshd_config.d
    /etc/sysctl.d
    /etc/audit
    /etc/modprobe.d/CIS.conf
    /etc/security/pwquality.conf
    /etc/security/faillock.conf
    /etc/login.defs
    /etc/ufw
    "$TMP_DIR"
)

# Filtra apenas os que existem
EXISTING=()
for path in "${INCLUDE_PATHS[@]}"; do
    [[ -e "$path" ]] && EXISTING+=("$path")
done

tar -czf "$BACKUP_FILE" \
    --ignore-failed-read \
    --exclude='/etc/letsencrypt/accounts' \
    "${EXISTING[@]}" \
    2>/dev/null || true

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
log_info "Backup criado: $BACKUP_FILE ($BACKUP_SIZE)"

# Limpeza: mantém apenas os últimos 10 backups
log_step "06-backup: Rotação — mantendo últimos 10 backups"
ls -t "$BACKUP_DIR"/nginx-backup-*.tar.gz 2>/dev/null \
    | tail -n +11 \
    | xargs -r rm -v

# Cópia remota via rsync (opcional)
if [[ -n "$BACKUP_REMOTE_HOST" ]]; then
    log_step "06-backup: Copiando para ${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_PATH}"
    rsync -az --mkpath \
        "$BACKUP_FILE" \
        "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_PATH}/" \
        && log_info "Backup remoto concluído." \
        || log_warn "Falha na cópia remota. Backup local disponível em $BACKUP_FILE"
fi

log_info "06-backup: Concluído. Arquivo: $BACKUP_FILE"
