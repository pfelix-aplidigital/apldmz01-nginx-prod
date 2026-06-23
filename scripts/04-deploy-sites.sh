#!/usr/bin/env bash
# Fase 4: Geração dos virtual hosts para todos os sites em nginx/sites.list.
# Usa envsubst para renderizar templates/site.conf.j2.
# Idempotente: regenera todos os arquivos e recarrega.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

SITES_LIST="$REPO_DIR/nginx/sites.list"
TEMPLATE="$REPO_DIR/templates/site.conf.j2"
SITES_AVAILABLE=/etc/nginx/sites-available
SITES_ENABLED=/etc/nginx/sites-enabled

if [[ ! -f "$SITES_LIST" ]]; then
    log_error "Arquivo $SITES_LIST não encontrado."
    exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
    log_error "Template $TEMPLATE não encontrado."
    exit 1
fi

mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED"

PROXY_SSL_VERIFY="${PROXY_SSL_VERIFY:-off}"
COUNT=0

log_step "04-deploy-sites: Gerando virtual hosts"

while IFS='|' read -r fqdn upstream port scheme; do
    # Ignora comentários e linhas vazias
    [[ "$fqdn" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$fqdn" ]] && continue

    export SITE_FQDN="$fqdn"
    export UPSTREAM="$upstream"
    export UPSTREAM_PORT="$port"
    export UPSTREAM_SCHEME="$scheme"
    export PROXY_SSL_VERIFY

    DEST="$SITES_AVAILABLE/${fqdn}.conf"
    envsubst '${SITE_FQDN} ${UPSTREAM} ${UPSTREAM_PORT} ${UPSTREAM_SCHEME} ${PROXY_SSL_VERIFY}' \
        < "$TEMPLATE" > "$DEST"

    # Cria symlink em sites-enabled
    ln -sf "$DEST" "$SITES_ENABLED/${fqdn}.conf"

    log_info "  ✓ ${fqdn} → ${scheme}://${upstream}:${port}"
    (( COUNT++ ))

done < "$SITES_LIST"

log_info "Total: $COUNT sites gerados."

log_step "04-deploy-sites: Validando e recarregando NGINX"
nginx_test_reload

log_info "04-deploy-sites: Concluído."
