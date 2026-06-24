#!/usr/bin/env bash
# Fase 5: Emissão de certificados Let's Encrypt para todos os FQDNs em sites.list.
# Usa --webroot (HTTP-01). Configurável via CERTBOT_METHOD=dns-01.
# Idempotente: pula FQDNs que já têm certificado válido.
#
# Fluxo bootstrap (primeiro uso):
#   1. Gera configs HTTP-only para sites sem cert → nginx consegue iniciar
#   2. Emite certs via --webroot (sem parar nginx)
#   3. Re-deploya configs HTTPS completas via deploy-sites.sh

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
WEBROOT="/var/www/certbot"

if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
    log_error "LETSENCRYPT_EMAIL não definido. Defina no .env."
    exit 1
fi

log_step "05-ssl: Instalando certbot"
apt-get install -y -qq certbot

mkdir -p "$WEBROOT"

# ── Fase 1: Bootstrap HTTP-only ─────────────────────────────────────────────
# Para sites sem cert, substitui a config HTTPS por uma HTTP-only que serve
# o desafio ACME. Isso permite que o nginx inicie sem erros de "cert não existe".
log_step "05-ssl: Preparando nginx em modo HTTP-only para challenge ACME"

NEEDS_RELOAD=false

while IFS='|' read -r fqdn _upstream _port _scheme; do
    [[ "$fqdn" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$fqdn" ]] && continue

    CERT_DIR="/etc/letsencrypt/live/${fqdn}"
    SITE_CONF="/etc/nginx/sites-available/${fqdn}.conf"

    if [[ ! -d "$CERT_DIR" ]]; then
        cat > "$SITE_CONF" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${fqdn};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
        ln -sf "$SITE_CONF" "/etc/nginx/sites-enabled/${fqdn}.conf"
        NEEDS_RELOAD=true
        log_info "  → Config HTTP-only criada para ${fqdn}"
    fi
done < "$SITES_LIST"

if [[ "$NEEDS_RELOAD" == "true" ]]; then
    if nginx -t 2>&1; then
        if pgrep -x nginx &>/dev/null; then
            nginx -s reload
        else
            nginx
        fi
        log_info "  NGINX recarregado em modo HTTP."
    else
        log_error "nginx -t falhou mesmo com configs HTTP-only. Verifique a configuração base."
        exit 1
    fi
fi

# ── Fase 2: Emissão dos certificados ────────────────────────────────────────
log_step "05-ssl: Emitindo certificados"

CERTS_ISSUED=0

while IFS='|' read -r fqdn _upstream _port _scheme; do
    [[ "$fqdn" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$fqdn" ]] && continue

    CERT_DIR="/etc/letsencrypt/live/${fqdn}"

    # Pula se cert válido nos próximos 30 dias
    if [[ -d "$CERT_DIR" ]]; then
        if openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_DIR/fullchain.pem" &>/dev/null; then
            log_info "  ✓ ${fqdn}: certificado válido — pulando."
            CERTS_ISSUED=$((CERTS_ISSUED + 1))
            continue
        else
            log_warn "  ! ${fqdn}: certificado próximo do vencimento — renovando."
        fi
    fi

    # Pula se DNS não resolve (FQDN não apontado ainda)
    RESOLVED_IP=$(dig +short "$fqdn" A | tail -1 || true)
    if [[ -z "$RESOLVED_IP" ]]; then
        log_warn "  ! ${fqdn}: DNS não resolve — pulando. Configure o A record e re-execute 'make ssl'."
        continue
    fi

    log_info "  → Emitindo certificado para ${fqdn} (DNS aponta para: ${RESOLVED_IP})"

    if [[ "$CERTBOT_METHOD" == "dns-01" ]]; then
        log_warn "  Modo DNS-01: configure o plugin DNS e execute manualmente:"
        log_warn "  certbot certonly --dns-cloudflare -d ${fqdn} --email ${LETSENCRYPT_EMAIL} --agree-tos"
        continue
    fi

    # --webroot não depende do nginx estar com config válida para SSL
    if certbot certonly \
        --webroot \
        --webroot-path "$WEBROOT" \
        --non-interactive \
        --agree-tos \
        --email "$LETSENCRYPT_EMAIL" \
        --domains "$fqdn" \
        2>&1 | tail -5; then
        CERTS_ISSUED=$((CERTS_ISSUED + 1))
        log_info "  ✓ Certificado emitido para ${fqdn}."
    else
        log_warn "  ! Falha na emissão para ${fqdn}."
        log_warn "    Verifique: porta 80 acessível externamente? DNS aponta para este servidor?"
    fi

done < "$SITES_LIST"

# ── Fase 3: Re-deploy das configs HTTPS completas ───────────────────────────
if [[ $CERTS_ISSUED -gt 0 ]]; then
    log_step "05-ssl: Re-deploying configs HTTPS para ${CERTS_ISSUED} site(s) com certificado"
    bash "$SCRIPT_DIR/04-deploy-sites.sh"
else
    log_warn "05-ssl: Nenhum certificado emitido. Sites permanecem em modo HTTP-only."
fi

# ── Timer de renovação automática ───────────────────────────────────────────
log_step "05-ssl: Configurando timer de renovação automática"
systemctl enable --now certbot.timer 2>/dev/null || {
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'nginx -s reload'") | crontab -
        log_info "Renovação agendada via crontab (03:00 diário)."
    fi
}

log_step "05-ssl: Testando renovação (dry-run)"
certbot renew --dry-run 2>&1 | tail -10 || true
log_info "05-ssl: Concluído."
