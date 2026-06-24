# ─────────────────────────────────────────────────────────────────────────────
# Makefile — Provisionamento NGINX DMZ (apldmz01)
# Todos os targets são idempotentes e executam como root (via sudo).
#
# Uso:   sudo make <target> [VARIAVEL=valor]
# Docs:  make help
# ─────────────────────────────────────────────────────────────────────────────

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Diretório do Makefile (funciona mesmo com `make -C /outro/dir`)
MAKEDIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))

# Carrega .env se existir
-include $(MAKEDIR).env
export

# ── Variáveis com defaults ────────────────────────────────────────────────────
ADMIN_USER         ?= apli.adm
ADMIN_PUBKEY       ?=
ADMIN_NOPASSWD     ?= false
MGMT_NETWORK       ?=
DMZ_INTERFACE      ?= ens3
DMZ_IP             ?=
DMZ_PREFIX         ?= 24
DMZ_GATEWAY        ?=
DMZ_DNS_1          ?= 8.8.8.8
DMZ_DNS_2          ?= 1.1.1.1
CLIENT_MAX_BODY_SIZE ?= 10m
PROXY_SSL_VERIFY   ?= off
LETSENCRYPT_EMAIL  ?=
CERTBOT_METHOD     ?= certbot
BACKUP_REMOTE_HOST ?=
BACKUP_REMOTE_PATH ?= /backups/apldmz01
BACKUP_REMOTE_USER ?= backup
# Para add-site:
SITE_FQDN          ?=
UPSTREAM           ?=
UPSTREAM_PORT      ?= 443
UPSTREAM_SCHEME    ?= https

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: help all harden install-nginx ssl create-admin deploy-sites \
        add-site update-config backup check-updates apply-updates \
        migrate-network

# ─────────────────────────────────────────────────────────────────────────────
help: ## Lista todos os targets disponíveis
	@echo ""
	@echo "  ╔══════════════════════════════════════════════════════════════════╗"
	@echo "  ║        apldmz01-nginx — Provisionamento NGINX DMZ               ║"
	@echo "  ╚══════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "  Uso: sudo make <target> [VARIAVEL=valor]"
	@echo ""
	@echo "  TARGETS DE PROVISIONAMENTO"
	@echo "  ─────────────────────────"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "  VARIÁVEIS IMPORTANTES"
	@echo "  ─────────────────────"
	@echo "  ADMIN_USER          Usuário administrador         (padrão: apli.adm)"
	@echo "  ADMIN_PUBKEY        Chave pública SSH             (obrigatório)"
	@echo "  ADMIN_NOPASSWD      NOPASSWD no sudo              (padrão: false)"
	@echo "  MGMT_NETWORK        CIDR para restringir SSH      (ex: 10.50.0.0/24)"
	@echo "  LETSENCRYPT_EMAIL   E-mail Let's Encrypt          (obrigatório para ssl)"
	@echo "  PROXY_SSL_VERIFY    Verificar TLS do backend      (padrão: off)"
	@echo "  DMZ_IP / DMZ_*      Parâmetros de rede DMZ        (obrigatório para migrate-network)"
	@echo "  SITE_FQDN           FQDN do novo site             (obrigatório para add-site)"
	@echo "  UPSTREAM            IP do backend                 (obrigatório para add-site)"
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
all: install-nginx create-admin harden deploy-sites ssl backup ## Executa tudo na ordem segura (exceto migrate-network)
	@echo ""
	@echo "  ✓ Provisionamento completo. Verifique os logs acima."
	@echo "  → SSH agora somente via apli.adm: ssh apli.adm@<IP>"
	@echo "  → Último passo (muda rede, derruba SSH): sudo make migrate-network"

# ─────────────────────────────────────────────────────────────────────────────
harden: ## CIS hardening completo (filesystem, sysctl, UFW, SSH, PAM, auditd, AIDE, Lynis, OpenSCAP)
	@echo ""; echo "══ make harden ═══════════════════════════════════════════"
	@bash $(MAKEDIR)scripts/01-harden.sh

# ─────────────────────────────────────────────────────────────────────────────
install-nginx: ## Instala NGINX (repo oficial) + deploy das configs base
	@echo ""; echo "══ make install-nginx ════════════════════════════════════"
	@bash $(MAKEDIR)scripts/00-base-os.sh
	@bash $(MAKEDIR)scripts/02-install-nginx.sh

# ─────────────────────────────────────────────────────────────────────────────
create-admin: ## Cria usuário apli.adm com chave SSH e sudo
	@echo ""; echo "══ make create-admin ═════════════════════════════════════"
	@bash $(MAKEDIR)scripts/03-create-admin.sh

# ─────────────────────────────────────────────────────────────────────────────
deploy-sites: ## Gera virtual hosts para todos os FQDNs em nginx/sites.list
	@echo ""; echo "══ make deploy-sites ═════════════════════════════════════"
	@bash $(MAKEDIR)scripts/04-deploy-sites.sh

# ─────────────────────────────────────────────────────────────────────────────
ssl: ## Emite/renova certificados Let's Encrypt + configura timer de renovação
	@echo ""; echo "══ make ssl ══════════════════════════════════════════════"
	@[[ -n "$(LETSENCRYPT_EMAIL)" ]] || { echo "ERRO: LETSENCRYPT_EMAIL não definido."; exit 1; }
	@bash $(MAKEDIR)scripts/05-ssl.sh

# ─────────────────────────────────────────────────────────────────────────────
add-site: ## Adiciona novo site (SITE_FQDN= UPSTREAM= UPSTREAM_PORT= UPSTREAM_SCHEME=)
	@echo ""; echo "══ make add-site ═════════════════════════════════════════"
	@[[ -n "$(SITE_FQDN)" ]] || { echo "ERRO: SITE_FQDN não definido.";  exit 1; }
	@[[ -n "$(UPSTREAM)" ]]  || { echo "ERRO: UPSTREAM não definido.";   exit 1; }
	@SITE_FQDN=$(SITE_FQDN) UPSTREAM=$(UPSTREAM) UPSTREAM_PORT=$(UPSTREAM_PORT) \
		UPSTREAM_SCHEME=$(UPSTREAM_SCHEME) \
		bash $(MAKEDIR)scripts/add-site.sh

# ─────────────────────────────────────────────────────────────────────────────
update-config: ## Re-renderiza todos os sites e recarrega NGINX (nginx -t && reload)
	@echo ""; echo "══ make update-config ════════════════════════════════════"
	@bash $(MAKEDIR)scripts/update-config.sh

# ─────────────────────────────────────────────────────────────────────────────
backup: ## Backup das configs + letsencrypt + netplan + ssh + audit + pacotes
	@echo ""; echo "══ make backup ═══════════════════════════════════════════"
	@bash $(MAKEDIR)scripts/06-backup.sh

# ─────────────────────────────────────────────────────────────────────────────
check-updates: ## Lista atualizações pendentes sem aplicar
	@echo ""; echo "══ make check-updates ════════════════════════════════════"
	@bash $(MAKEDIR)scripts/07-check-updates.sh

# ─────────────────────────────────────────────────────────────────────────────
apply-updates: ## Aplica atualizações (com backup prévio) e reporta se reboot é necessário
	@echo ""; echo "══ make apply-updates ════════════════════════════════════"
	@bash $(MAKEDIR)scripts/08-apply-updates.sh

# ─────────────────────────────────────────────────────────────────────────────
migrate-network: ## [ÚLTIMO PASSO] Migra endereçamento para DMZ via netplan try → apply
	@echo ""; echo "══ make migrate-network ══════════════════════════════════"
	@echo ""
	@echo "  ╔══════════════════════════════════════════════════════════════╗"
	@echo "  ║  ⚠  ATENÇÃO: Este target vai alterar o endereçamento IP.    ║"
	@echo "  ║  A sessão SSH SERÁ INTERROMPIDA.                            ║"
	@echo "  ║  Tenha console/IPMI disponível antes de continuar.          ║"
	@echo "  ╚══════════════════════════════════════════════════════════════╝"
	@echo ""
	@[[ -n "$(DMZ_IP)" ]]      || { echo "ERRO: DMZ_IP não definido.";      exit 1; }
	@[[ -n "$(DMZ_GATEWAY)" ]] || { echo "ERRO: DMZ_GATEWAY não definido."; exit 1; }
	@DMZ_INTERFACE=$(DMZ_INTERFACE) DMZ_IP=$(DMZ_IP) DMZ_PREFIX=$(DMZ_PREFIX) \
		DMZ_GATEWAY=$(DMZ_GATEWAY) DMZ_DNS_1=$(DMZ_DNS_1) DMZ_DNS_2=$(DMZ_DNS_2) \
		bash $(MAKEDIR)scripts/09-migrate-network.sh
