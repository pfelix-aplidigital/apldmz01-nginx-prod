#!/usr/bin/env bash
# Re-renderiza todos os sites a partir do template e variáveis atuais,
# valida com nginx -t e recarrega.
# Uso: make update-config

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

log_step "update-config: Re-renderizando todos os virtual hosts"
bash "$SCRIPT_DIR/04-deploy-sites.sh"

log_info "update-config: Configuração atualizada e NGINX recarregado."
