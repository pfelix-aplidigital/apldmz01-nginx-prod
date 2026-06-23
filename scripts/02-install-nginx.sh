#!/usr/bin/env bash
# Fase 2: Instalação do NGINX (repositório oficial nginx.org) + deploy das configs.
# Idempotente: instala apenas se necessário; sempre re-aplica as configs do repo.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_SOURCES=/etc/apt/sources.list.d/nginx.list
CODENAME="$(lsb_release -cs)"

log_step "02-install-nginx: Adicionando repositório oficial nginx.org"

if [[ ! -f "$NGINX_KEYRING" ]]; then
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o "$NGINX_KEYRING"
    log_info "Chave GPG nginx adicionada."
fi

if [[ ! -f "$NGINX_SOURCES" ]]; then
    echo "deb [signed-by=${NGINX_KEYRING}] https://nginx.org/packages/ubuntu ${CODENAME} nginx" \
        > "$NGINX_SOURCES"
    # Pina o repositório oficial acima do Ubuntu default
    cat > /etc/apt/preferences.d/99nginx <<EOF
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF
    log_info "Repositório nginx.org configurado para ${CODENAME}."
fi

log_step "02-install-nginx: Instalando NGINX"
apt-get update -qq
apt-get install -y nginx

log_step "02-install-nginx: Gerando parâmetros DH (4096 bits) — pode demorar alguns minutos"
if [[ ! -f /etc/nginx/dhparam.pem ]]; then
    openssl dhparam -out /etc/nginx/dhparam.pem 2048
    log_info "dhparam.pem gerado."
fi

log_step "02-install-nginx: Habilitando referência dhparam no ssl-params.conf"
# Descomenta a linha ssl_dhparam no arquivo de configuração
sed -i 's|^# ssl_dhparam|ssl_dhparam|' /etc/nginx/conf.d/ssl-params.conf 2>/dev/null || true

log_step "02-install-nginx: Criando estrutura de diretórios NGINX"
mkdir -p /etc/nginx/{conf.d,sites-available,sites-enabled,snippets}
mkdir -p /var/www/certbot

log_step "02-install-nginx: Copiando configurações do repositório para /etc/nginx/"

# nginx.conf principal
backup_file /etc/nginx/nginx.conf
cp "$REPO_DIR/nginx/nginx.conf" /etc/nginx/nginx.conf

# Configs de conf.d
cp "$REPO_DIR/nginx/conf.d/"*.conf /etc/nginx/conf.d/

# Snippets
cp "$REPO_DIR/nginx/snippets/proxy.conf" /etc/nginx/snippets/

# Remove o default do NGINX para evitar conflitos
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/default.conf

log_step "02-install-nginx: Validando configuração"
nginx -t

log_step "02-install-nginx: Habilitando e iniciando NGINX"
systemctl enable nginx
systemctl is-active --quiet nginx && nginx -s reload || systemctl start nginx

log_info "02-install-nginx: Concluído. NGINX $(nginx -v 2>&1 | awk '{print $3}') em execução."
