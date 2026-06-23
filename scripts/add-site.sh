#!/usr/bin/env bash
# Adiciona um novo site ao NGINX via template e emite certificado SSL.
# Uso via Makefile:
#   make add-site SITE_FQDN=novo.exemplo.com UPSTREAM=10.50.0.99 \
#                 UPSTREAM_PORT=443 UPSTREAM_SCHEME=https

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

SITE_FQDN="${SITE_FQDN:-}"
UPSTREAM="${UPSTREAM:-}"
UPSTREAM_PORT="${UPSTREAM_PORT:-443}"
UPSTREAM_SCHEME="${UPSTREAM_SCHEME:-https}"
PROXY_SSL_VERIFY="${PROXY_SSL_VERIFY:-off}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

# Validações
[[ -z "$SITE_FQDN" ]]    && { log_error "SITE_FQDN não definido.";    exit 1; }
[[ -z "$UPSTREAM" ]]     && { log_error "UPSTREAM não definido.";     exit 1; }
[[ -z "$LETSENCRYPT_EMAIL" ]] && { log_error "LETSENCRYPT_EMAIL não definido."; exit 1; }

TEMPLATE="$REPO_DIR/templates/site.conf.j2"
DEST=/etc/nginx/sites-available/${SITE_FQDN}.conf

log_step "add-site: ${SITE_FQDN} → ${UPSTREAM_SCHEME}://${UPSTREAM}:${UPSTREAM_PORT}"

# Gera o arquivo de configuração
export SITE_FQDN UPSTREAM UPSTREAM_PORT UPSTREAM_SCHEME PROXY_SSL_VERIFY
envsubst '${SITE_FQDN} ${UPSTREAM} ${UPSTREAM_PORT} ${UPSTREAM_SCHEME} ${PROXY_SSL_VERIFY}' \
    < "$TEMPLATE" > "$DEST"

ln -sf "$DEST" /etc/nginx/sites-enabled/${SITE_FQDN}.conf
log_info "Virtual host criado: $DEST"

# Valida e recarrega antes de tentar emitir certificado
nginx_test_reload

# Emite certificado SSL
log_step "add-site: Emitindo certificado Let's Encrypt"
certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    --email "$LETSENCRYPT_EMAIL" \
    --domains "$SITE_FQDN" \
    2>&1 | tail -5 || log_warn "Falha na emissão do certificado. Configure DNS e tente: certbot certonly --nginx -d ${SITE_FQDN}"

# Adiciona ao sites.list se ainda não existir
SITES_LIST="$REPO_DIR/nginx/sites.list"
if ! grep -q "^${SITE_FQDN}|" "$SITES_LIST" 2>/dev/null; then
    echo "${SITE_FQDN}|${UPSTREAM}|${UPSTREAM_PORT}|${UPSTREAM_SCHEME}" >> "$SITES_LIST"
    log_info "Adicionado a $SITES_LIST"
fi

# Reload final com certificado
nginx_test_reload

log_info "add-site: ${SITE_FQDN} publicado com sucesso."
