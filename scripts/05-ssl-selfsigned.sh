#!/usr/bin/env bash
# Alternativa ao Let's Encrypt para ambientes internos/lab onde HTTP-01 não é viável:
# gera uma CA local e emite certificados autoassinados para cada FQDN em sites.list.
#
# Os certs são instalados em /etc/letsencrypt/live/$FQDN/ — mesmos caminhos
# que o certbot usa — para que deploy-sites.sh funcione sem alterações.
#
# Idempotente: não regenera certs ainda válidos (>30 dias).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

SITES_LIST="$REPO_DIR/nginx/sites.list"
CA_DIR="/etc/ssl/lab-ca"
CA_KEY="$CA_DIR/lab-ca.key"
CA_CERT="$CA_DIR/lab-ca.crt"
CA_CN="${CA_CN:-Lab Aplidigital CA}"
CERT_DAYS="${CERT_DAYS:-825}"   # 825 dias (~2.25 anos), limite do macOS/Chrome
CA_DAYS="${CA_DAYS:-3650}"      # 10 anos para o CA

log_step "05-ssl-selfsigned: Gerando CA local e certificados autoassinados"
log_warn "  Ambiente interno/lab: usando CA local em vez de Let's Encrypt."
log_warn "  Para que os clientes confiem nos certs, importe o CA em:"
log_warn "  ${CA_CERT}"

mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

# ── Gera CA local (somente se não existir) ───────────────────────────────────
if [[ ! -f "$CA_KEY" ]]; then
    log_info "  → Gerando chave do CA local..."
    openssl genrsa -out "$CA_KEY" 4096
    chmod 600 "$CA_KEY"
fi

if [[ ! -f "$CA_CERT" ]]; then
    log_info "  → Gerando certificado do CA local (válido ${CA_DAYS} dias)..."
    openssl req -new -x509 \
        -key "$CA_KEY" \
        -out "$CA_CERT" \
        -days "$CA_DAYS" \
        -subj "/CN=${CA_CN}/O=Aplidigital/C=BR" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"
    chmod 644 "$CA_CERT"
    log_info "  ✓ CA criado: ${CA_CERT}"
fi

# ── Emite certs para cada FQDN ──────────────────────────────────────────────
COUNT=0

while IFS='|' read -r fqdn _upstream _port _scheme; do
    [[ "$fqdn" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$fqdn" ]] && continue

    LIVE_DIR="/etc/letsencrypt/live/${fqdn}"
    CERT_FILE="$LIVE_DIR/fullchain.pem"

    # Pula se cert ainda válido nos próximos 30 dias
    if [[ -f "$CERT_FILE" ]]; then
        if openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_FILE" &>/dev/null; then
            log_info "  ✓ ${fqdn}: certificado válido — pulando."
            COUNT=$((COUNT + 1))
            continue
        else
            log_warn "  ! ${fqdn}: certificado próximo do vencimento — regenerando."
        fi
    fi

    log_info "  → Emitindo certificado para ${fqdn}..."

    mkdir -p "$LIVE_DIR"
    SITE_KEY="$LIVE_DIR/privkey.pem"
    SITE_CSR="$LIVE_DIR/cert.csr"
    SITE_CERT="$LIVE_DIR/cert.pem"

    # Chave privada do site
    openssl genrsa -out "$SITE_KEY" 2048
    chmod 600 "$SITE_KEY"

    # CSR com SAN (Subject Alternative Name) — obrigatório em navegadores modernos
    openssl req -new \
        -key "$SITE_KEY" \
        -out "$SITE_CSR" \
        -subj "/CN=${fqdn}/O=Aplidigital/C=BR"

    # Assina com o CA local, incluindo SAN
    openssl x509 -req \
        -in "$SITE_CSR" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$SITE_CERT" \
        -days "$CERT_DAYS" \
        -extfile <(cat <<EOF
subjectAltName=DNS:${fqdn}
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
basicConstraints=CA:FALSE
EOF
)

    # fullchain = cert + CA (nginx precisa do chain completo para OCSP/stapling)
    cat "$SITE_CERT" "$CA_CERT" > "$LIVE_DIR/fullchain.pem"

    # chain = apenas o CA (usado por ssl_trusted_certificate no site.conf.j2)
    cp "$CA_CERT" "$LIVE_DIR/chain.pem"

    # Remove CSR (não é mais necessário)
    rm -f "$SITE_CSR"

    chmod 640 "$LIVE_DIR"/*.pem

    log_info "  ✓ Certificado emitido: ${fqdn} (válido ${CERT_DAYS} dias)"
    COUNT=$((COUNT + 1))

done < "$SITES_LIST"

log_info "Total: ${COUNT} certificados prontos."

# ── Re-deploy das configs HTTPS ──────────────────────────────────────────────
log_step "05-ssl-selfsigned: Re-deploying configs HTTPS para ${COUNT} sites"
bash "$SCRIPT_DIR/04-deploy-sites.sh"

log_info ""
log_info "  ══════════════════════════════════════════════════════════════"
log_info "  CA local disponível para importação nos clientes:"
log_info "  ${CA_CERT}"
log_info ""
log_info "  Para exportar o CA e importar no browser/SO:"
log_info "  scp root@<IP>:${CA_CERT} lab-aplidigital-ca.crt"
log_info "  ══════════════════════════════════════════════════════════════"
log_info ""
log_info "05-ssl-selfsigned: Concluído."
