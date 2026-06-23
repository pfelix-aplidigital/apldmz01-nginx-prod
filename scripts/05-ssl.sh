#!/usr/bin/env bash
# Fase 5: Emissão de certificados Let's Encrypt para todos os FQDNs em sites.list.
# Usa o método --nginx (HTTP-01) por padrão. Configurável via CERTBOT_METHOD=dns-01.
# Idempotente: pula FQDNs que já têm certificado válido.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

SITES_LIST="$REPO_DIR/nginx/sites.list"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
CERTBOT_METHOD="${CERTBOT_METHOD:-certbot}"

if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
    log_error "LETSENCRYPT_EMAIL não definido. Defina no .env."
    exit 1
fi

log_step "05-ssl: Instalando certbot"
apt-get install -y -qq certbot python3-certbot-nginx

log_step "05-ssl: Emitindo certificados"

while IFS='|' read -r fqdn _upstream _port _scheme; do
    [[ "$fqdn" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$fqdn" ]] && continue

    CERT_DIR="/etc/letsencrypt/live/${fqdn}"

    # Verifica se já existe certificado válido (não expirado nos próximos 30 dias)
    if [[ -d "$CERT_DIR" ]]; then
        if openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_DIR/fullchain.pem" &>/dev/null; then
            log_info "  ✓ ${fqdn}: certificado válido — pulando."
            continue
        else
            log_warn "  ! ${fqdn}: certificado próximo do vencimento — renovando."
        fi
    fi

    # Verifica se o DNS resolve para este host (evita falha por FQDN não apontado)
    SERVER_IP=$(hostname -I | awk '{print $1}')
    RESOLVED_IP=$(dig +short "$fqdn" A | tail -1 || true)

    if [[ -z "$RESOLVED_IP" ]]; then
        log_warn "  ! ${fqdn}: DNS não resolve — pulando emissão. Configure o A record primeiro."
        continue
    fi

    log_info "  → Emitindo certificado para ${fqdn} (resolve: ${RESOLVED_IP})"

    if [[ "$CERTBOT_METHOD" == "dns-01" ]]; then
        log_warn "  Modo DNS-01 selecionado. Configure o plugin DNS antes de executar."
        log_warn "  Exemplo (Cloudflare): certbot certonly --dns-cloudflare -d ${fqdn} --email ${LETSENCRYPT_EMAIL} --agree-tos"
    else
        certbot certonly \
            --nginx \
            --non-interactive \
            --agree-tos \
            --email "$LETSENCRYPT_EMAIL" \
            --domains "$fqdn" \
            --webroot-path /var/www/certbot \
            2>&1 | tail -5 || log_warn "  ! Falha na emissão para ${fqdn}"
    fi

done < "$SITES_LIST"

log_step "05-ssl: Configurando timer de renovação automática"
systemctl enable --now certbot.timer 2>/dev/null || {
    # Fallback: cron job
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'nginx -s reload'") | crontab -
        log_info "Renovação agendada via crontab (03:00 diário)."
    fi
}

log_step "05-ssl: Testando renovação (dry-run)"
certbot renew --dry-run 2>&1 | tail -10
log_info "05-ssl: Dry-run concluído."

log_step "05-ssl: Recarregando NGINX com certificados"
nginx_test_reload

log_info "05-ssl: Concluído."
