#!/usr/bin/env bash
# Fase 1: Hardening CIS Ubuntu Server Level 1/2
# Cobre: filesystem, sysctl, UFW, SSH, PAM, auditd, serviços, AIDE, Lynis, OpenSCAP.
# Idempotente: pode ser executado múltiplas vezes sem efeitos colaterais.
#
# ATENÇÃO: antes de aplicar, abra uma 2ª sessão SSH ou de console como fallback.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_root
load_env "$REPO_DIR/.env"

ADMIN_USER="${ADMIN_USER:-apli.adm}"
MGMT_NETWORK="${MGMT_NETWORK:-}"

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 1 — Filesystem: módulos e montagens temporárias
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[1/11]: Filesystem — desabilitando módulos não utilizados"

CIS_MODPROBE=/etc/modprobe.d/CIS.conf
cat > "$CIS_MODPROBE" <<'EOF'
# CIS Ubuntu 26.04 — módulos de filesystem não necessários no servidor
install cramfs   /bin/false
install freevxfs /bin/false
install jffs2    /bin/false
install hfs      /bin/false
install hfsplus  /bin/false
install udf      /bin/false
install usb-storage /bin/false
install squashfs /bin/false
EOF

log_info "Descarregando módulos se carregados..."
for mod in cramfs freevxfs jffs2 hfs hfsplus udf usb-storage squashfs; do
    modprobe -rq "$mod" 2>/dev/null || true
done

log_step "harden[1/11]: Filesystem — /tmp e /dev/shm com nodev,nosuid,noexec"

# /tmp via systemd (Ubuntu 20.04+ usa tmp.mount)
systemctl unmask tmp.mount 2>/dev/null || true
if systemctl is-enabled tmp.mount &>/dev/null; then
    mkdir -p /etc/systemd/system/tmp.mount.d
    cat > /etc/systemd/system/tmp.mount.d/options.conf <<'EOF'
[Mount]
Options=mode=1777,strictatime,nodev,nosuid,noexec
EOF
    systemctl daemon-reload
    systemctl restart tmp.mount
else
    # Fallback: entrada no fstab
    if ! grep -q "^tmpfs /tmp" /etc/fstab; then
        echo "tmpfs /tmp tmpfs defaults,nodev,nosuid,noexec,mode=1777 0 0" >> /etc/fstab
        mount -o remount /tmp 2>/dev/null || true
    fi
fi

# /dev/shm
if ! grep -q "^tmpfs /dev/shm" /etc/fstab; then
    echo "tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0" >> /etc/fstab
fi
mount -o remount /dev/shm 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 2 — sysctl
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[2/11]: sysctl — parâmetros de rede e kernel"

cat > /etc/sysctl.d/99-cis.conf <<'EOF'
# CIS Ubuntu 26.04 — Network hardening

# Desabilita IP forwarding (este host não é roteador)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Desabilita envio de redirects ICMP
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Desabilita aceitação de redirects ICMP
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Desabilita source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log de pacotes com endereços impossíveis (martians)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignora broadcasts ICMP (evita smurf attack)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignora respostas ICMP inválidas
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Filtro de rota reversa (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# SYN cookies (proteção contra SYN flood)
net.ipv4.tcp_syncookies = 1

# Desabilita Router Advertisements IPv6
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Proteções de memória kernel
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# Limitar uso de perf
kernel.perf_event_paranoid = 3
EOF

sysctl --system
log_info "sysctl aplicado."

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 3 — UFW (ordem: SSH → portas → enable)
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[3/11]: UFW — firewall"

apt-get install -y -qq ufw

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# CRÍTICO: liberar SSH ANTES de enable para não bloquear a sessão atual
if [[ -n "$MGMT_NETWORK" ]]; then
    ufw allow from "$MGMT_NETWORK" to any port 22 proto tcp comment "SSH gerência"
    log_info "SSH restrito à rede de gerência: $MGMT_NETWORK"
else
    ufw allow 22/tcp comment "SSH"
    log_warn "SSH liberado para qualquer origem. Defina MGMT_NETWORK no .env para restringir."
fi

ufw allow 80/tcp  comment "HTTP"
ufw allow 443/tcp comment "HTTPS"

ufw --force enable
ufw status verbose
log_info "UFW habilitado."

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 4 — SSH hardening via drop-in
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[4/11]: SSH — hardening"

log_warn "ATENÇÃO: Mantenha uma 2ª sessão SSH aberta durante esta etapa!"

SSH_DROPIN=/etc/ssh/sshd_config.d/99-cis.conf
mkdir -p /etc/ssh/sshd_config.d

cat > "$SSH_DROPIN" <<EOF
# CIS Ubuntu 26.04 — SSH hardening
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
MaxAuthTries 4
LogLevel VERBOSE
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 3
LoginGraceTime 60
MaxStartups 10:30:60
TCPKeepAlive no
Banner /etc/issue.net
AllowUsers ${ADMIN_USER}
EOF

# Banner de aviso legal
cat > /etc/issue.net <<'EOF'
###############################################################################
# ACESSO AUTORIZADO SOMENTE                                                   #
# Todas as atividades são monitoradas e registradas.                          #
# Uso não autorizado está sujeito a penalidades civis e criminais.            #
###############################################################################
EOF

# Valida sintaxe ANTES de recarregar
log_step "harden[4/11]: Validando sshd_config"
if sshd -t; then
    systemctl reload sshd
    log_info "SSH recarregado com sucesso."
else
    log_error "Configuração SSH inválida! Verifique $SSH_DROPIN"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 5 — PAM / pwquality + faillock
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[5/11]: PAM — política de senhas e bloqueio de conta"

apt-get install -y -qq libpam-pwquality

PWQUALITY=/etc/security/pwquality.conf
backup_file "$PWQUALITY"
cat > "$PWQUALITY" <<'EOF'
# CIS Ubuntu 26.04 — password quality
minlen   = 14
dcredit  = -1
ucredit  = -1
ocredit  = -1
lcredit  = -1
maxrepeat = 3
gecoscheck = 1
badwords = aplidigital password senha admin
EOF

# Faillock: bloqueia após 5 tentativas por 15 minutos
FAILLOCK_CONF=/etc/security/faillock.conf
backup_file "$FAILLOCK_CONF"
cat > "$FAILLOCK_CONF" <<'EOF'
# CIS Ubuntu 26.04 — account lockout
deny = 5
fail_interval = 900
unlock_time   = 900
EOF

log_info "pwquality e faillock configurados."

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 6 — login.defs
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[6/11]: login.defs — política de expiração de senhas"

backup_file /etc/login.defs

sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   365/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'   /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   7/'   /etc/login.defs

# Prazo de inatividade para novas contas
useradd -D -f 30

log_info "login.defs atualizado."

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 7 — auditd + regras CIS
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[7/11]: auditd — instalação e regras CIS"

apt-get install -y -qq auditd audispd-plugins

AUDIT_RULES=/etc/audit/rules.d/CIS.rules
cat > "$AUDIT_RULES" <<'EOF'
# CIS Ubuntu 26.04 — audit rules

# Buffer adequado para alto volume
-b 8192

# Monitoramento de mudanças de horário
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

# Identidade de usuários
-w /etc/passwd   -p wa -k identity
-w /etc/shadow   -p wa -k identity
-w /etc/gshadow  -p wa -k identity
-w /etc/group    -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# Escopo/sudo
-w /etc/sudoers   -p wa -k scope
-w /etc/sudoers.d -p wa -k scope

# Login/logout
-w /var/log/wtmp  -p wa -k logins
-w /var/log/btmp  -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins

# Modificações de permissão
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat     -F auid>=1000 -F auid!=-1 -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=-1 -k perm_mod
-a always,exit -F arch=b64 -S setxattr,removexattr,lsetxattr,lremovexattr,fsetxattr,fremovexattr -F auid>=1000 -F auid!=-1 -k perm_mod

# Deleção de arquivos
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat,rmdir -F auid>=1000 -F auid!=-1 -k delete

# Módulos de kernel
-w /sbin/insmod    -p x -k modules
-w /sbin/rmmod     -p x -k modules
-w /sbin/modprobe  -p x -k modules
-a always,exit -F arch=b64 -S init_module,delete_module -k modules

# Acesso a arquivos sensíveis
-a always,exit -F arch=b64 -S open,openat -F exit=-EACCES  -F auid>=1000 -F auid!=-1 -k access
-a always,exit -F arch=b64 -S open,openat -F exit=-EPERM   -F auid>=1000 -F auid!=-1 -k access

# Execução privilegiada
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid
-a always,exit -F arch=b64 -S execve -C gid!=egid -F egid=0 -k setgid

# Imutabilidade: impede desativar auditoria (requer reboot para remover)
-e 2
EOF

augenrules --load
systemctl enable --now auditd
log_info "auditd configurado e em execução."

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 8 — Desabilitar serviços desnecessários
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[8/11]: Serviços — desabilitando desnecessários"

SERVICES_TO_DISABLE=(avahi-daemon cups rpcbind xinetd rsync isc-dhcp-server isc-dhcp-server6 ldap slapd nfs-server nis)

for svc in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        systemctl disable --now "$svc"
        log_info "Desabilitado: $svc"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 9 — AIDE (baseline de integridade)
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[9/11]: AIDE — instalação e baseline"

apt-get install -y -qq aide aide-common

if [[ ! -f /var/lib/aide/aide.db ]]; then
    log_info "Inicializando database AIDE (pode demorar alguns minutos)..."
    aideinit --yes --force 2>&1 | tail -5
    if [[ -f /var/lib/aide/aide.db.new ]]; then
        mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
        log_info "Database AIDE criada: /var/lib/aide/aide.db"
    fi
else
    log_info "Database AIDE já existe — pulando inicialização."
fi

# Agendamento de verificação diária via cron
if [[ ! -f /etc/cron.daily/aide ]]; then
    cat > /etc/cron.daily/aide <<'EOF'
#!/bin/sh
/usr/bin/aide --check 2>&1 | mail -s "AIDE check $(hostname)" root || true
EOF
    chmod +x /etc/cron.daily/aide
    log_info "Verificação diária AIDE agendada."
fi

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 10 — Lynis (auditoria e relatório)
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[10/11]: Lynis — auditoria de segurança"

if ! is_installed lynis; then
    apt-get install -y -qq lynis
fi

LYNIS_REPORT="$REPO_DIR/backups/reports/lynis_$(date +%Y%m%d).txt"
mkdir -p "$REPO_DIR/backups/reports"

log_info "Executando auditoria Lynis (pode demorar 2-3 minutos)..."
lynis audit system \
    --quiet \
    --no-colors \
    --log-file /var/log/lynis.log \
    2>&1 | tee "$LYNIS_REPORT" || true

HARDENING_INDEX=$(grep -oP "Hardening index : \K[0-9]+" "$LYNIS_REPORT" 2>/dev/null || echo "N/A")
log_info "Lynis concluído. Hardening index: ${HARDENING_INDEX}"
log_info "Relatório salvo em: $LYNIS_REPORT"

# ══════════════════════════════════════════════════════════════════════════════
# PARTE 11 — OpenSCAP (relatório CIS)
# ══════════════════════════════════════════════════════════════════════════════
log_step "harden[11/11]: OpenSCAP — avaliação CIS"

apt-get install -y -qq openscap-scanner

# Detecta o datastream disponível para esta versão do Ubuntu
SCAP_CONTENT_DIR=/usr/share/xml/scap/ssg/content
SCAP_STREAM=""

# Tenta Ubuntu 26.04, cai para 24.04 se indisponível
for version in 2604 2404; do
    CANDIDATE="$SCAP_CONTENT_DIR/ssg-ubuntu${version}-ds.xml"
    if [[ -f "$CANDIDATE" ]]; then
        SCAP_STREAM="$CANDIDATE"
        log_info "SCAP datastream encontrado: $CANDIDATE"
        break
    fi
done

if [[ -n "$SCAP_STREAM" ]]; then
    apt-get install -y -qq scap-security-guide 2>/dev/null || true

    oscap xccdf eval \
        --profile xccdf_org.ssgproject.content_profile_cis_level1_server \
        --results   "$REPO_DIR/backups/reports/cis_results.xml" \
        --report    "$REPO_DIR/backups/reports/cis_report.html" \
        "$SCAP_STREAM" \
        || true  # retorna != 0 quando há falhas (esperado)

    log_info "Relatório CIS HTML gerado: $REPO_DIR/backups/reports/cis_report.html"
else
    log_warn "SCAP datastream não encontrado para Ubuntu 26.04/24.04."
    log_warn "Instale scap-security-guide manualmente ou baixe de https://github.com/ComplianceAsCode/content/releases"
fi

log_info "═══════════════════════════════════════════════════"
log_info "01-harden: Hardening CIS concluído com sucesso."
log_info "Próximos passos recomendados:"
log_info "  • Revisar: $LYNIS_REPORT"
log_info "  • Abrir no browser: $REPO_DIR/backups/reports/cis_report.html"
log_info "  • Reiniciar para aplicar mudanças de kernel (sysctl/modprobe): reboot"
log_info "═══════════════════════════════════════════════════"
