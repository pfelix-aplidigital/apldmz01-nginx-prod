#!/usr/bin/env bash
# Fase 0: Configuração base do SO — Ubuntu 26.04 LTS
# Idempotente: pode ser executado múltiplas vezes sem efeitos colaterais.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root

log_step "00-base-os: Atualização do sistema"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

log_step "00-base-os: Instalação de pacotes essenciais"
apt-get install -y -qq \
    curl \
    wget \
    gnupg2 \
    ca-certificates \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    unattended-upgrades \
    apt-listchanges \
    chrony \
    micro \
    htop \
    net-tools \
    dnsutils \
    tcpdump \
    rsync \
    jq \
    gettext-base \
    ufw

log_step "00-base-os: Locale pt_BR.UTF-8"
if ! locale -a 2>/dev/null | grep -q "pt_BR.utf8"; then
    locale-gen pt_BR.UTF-8
fi
update-locale LANG=pt_BR.UTF-8 LC_ALL=pt_BR.UTF-8

log_step "00-base-os: Timezone America/Sao_Paulo"
timedatectl set-timezone America/Sao_Paulo

log_step "00-base-os: Configuração do chrony (NTP)"
CHRONY_CONF=/etc/chrony/chrony.conf
backup_file "$CHRONY_CONF"

# Adiciona pool brasileiro se não existir
if ! grep -q "br.pool.ntp.org" "$CHRONY_CONF"; then
    # Comenta pools padrão e adiciona o brasileiro
    sed -i 's/^pool /# pool /g' "$CHRONY_CONF"
    cat >> "$CHRONY_CONF" <<'EOF'

# Pools adicionados pelo provisionamento apldmz01
pool br.pool.ntp.org iburst maxsources 4
pool pool.ntp.br iburst maxsources 2
EOF
fi

systemctl enable --now chrony
chronyc makestep 1.0 3 || true

log_step "00-base-os: Configuração do unattended-upgrades"
# Habilita apenas security updates automáticos
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades

log_info "00-base-os: Concluído com sucesso."
