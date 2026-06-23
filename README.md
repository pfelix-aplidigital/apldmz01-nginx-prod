# apldmz01-nginx — NGINX Reverse Proxy / TLS Terminator (DMZ)

Repositório de infraestrutura como código para o servidor **apldmz01**, responsável por terminar TLS e fazer proxy reverso de 10 aplicações Imperva na DMZ da Aplidigital.

---

## Arquitetura

```
Internet / Usuários externos
         │
         ▼ 80/443
  ┌──────────────────┐
  │    apldmz01      │  Ubuntu 26.04 LTS
  │  NGINX + certbot │  IP atual: 10.50.0.X (Rede Servidores)
  │  CIS Hardened    │  IP futuro: DMZ (via make migrate-network)
  └──────────────────┘
         │
         ├──► auto.lab.aplidigital.com.br        → 10.50.0.70:443
         ├──► dam-std.lab.aplidigital.com.br     → 192.168.255.71:8083
         ├──► dam-ls.lab.aplidigital.com.br      → 192.168.255.74:8083
         ├──► dsf.lab.aplidigital.com.br         → 192.168.255.77:8443
         ├──► dsf-gw1.lab.aplidigital.com.br     → 192.168.255.78:8443
         ├──► dsf-gw2.lab.aplidigital.com.br     → 192.168.255.79:8443
         ├──► dra.lab.aplidigital.com.br         → 192.168.255.80:8443
         ├──► waf.lab.aplidigital.com.br         → 192.168.255.82:8083
         ├──► ciphertrust.lab.aplidigital.com.br → 192.168.255.84:443
         └──► ddc.lab.aplidigital.com.br         → 192.168.255.85:443
```

### Componentes

| Componente | Descrição |
|------------|-----------|
| NGINX (nginx.org stable) | Reverse proxy + TLS terminator |
| Let's Encrypt / certbot | Certificados TLS automáticos |
| UFW | Firewall (apenas 22/80/443 incoming) |
| auditd | Auditoria de sistema (regras CIS) |
| AIDE | Detecção de alterações de integridade |
| Lynis | Auditoria de segurança |
| OpenSCAP | Avaliação CIS Level 1/2 |

---

## Pré-requisitos

- Ubuntu 26.04 LTS instalado e acessível via SSH
- DNS dos FQDNs apontando para o IP externo do servidor (necessário para Let's Encrypt)
- Arquivo `.env` criado a partir de `.env.example` com os valores reais
- Acesso root (ou usuário com sudo)
- Para `migrate-network`: acesso via console/IPMI disponível

```bash
cp .env.example .env
micro .env  # preencher com valores reais
```

---

## Ordem de execução

Execute os targets **nessa sequência** em um servidor limpo:

```bash
# 1. Tudo de uma vez (recomendado para novo servidor)
sudo make all

# OU, passo a passo:
sudo make install-nginx          # base OS + NGINX oficial
sudo make harden                 # CIS hardening completo
sudo make create-admin           # usuário apli.adm + chave SSH
sudo make deploy-sites           # virtual hosts para os 10 FQDNs
sudo make ssl                    # certificados Let's Encrypt
sudo make backup                 # backup inicial

# Por último — DERRUBA A SESSÃO SSH:
sudo make migrate-network        # muda IP para a DMZ
```

> `make all` não executa `migrate-network`. A migração de rede é **sempre manual** por segurança.

---

## Targets do Makefile

| Target | Descrição |
|--------|-----------|
| `make help` | Lista todos os targets e variáveis |
| `make all` | Executa tudo na ordem: harden → install-nginx → create-admin → deploy-sites → ssl → backup |
| `make harden` | Hardening CIS completo (filesystem, sysctl, UFW, SSH, PAM, auditd, AIDE, Lynis, OpenSCAP) |
| `make install-nginx` | Base OS + instala NGINX do repositório oficial nginx.org |
| `make create-admin` | Cria usuário `apli.adm` com chave SSH e sudo |
| `make deploy-sites` | Gera virtual hosts para todos os FQDNs em `nginx/sites.list` |
| `make ssl` | Emite/renova certificados Let's Encrypt + configura timer de renovação |
| `make add-site` | Adiciona novo site via template (requer `SITE_FQDN=`, `UPSTREAM=`) |
| `make update-config` | Re-renderiza todos os sites e recarrega NGINX |
| `make backup` | Backup tar.gz de configurações críticas |
| `make check-updates` | Lista updates pendentes sem aplicar |
| `make apply-updates` | Aplica updates (com backup prévio) e reporta necessidade de reboot |
| `make migrate-network` | **[ÚLTIMO PASSO]** Migra IP para a DMZ via `netplan try` |

---

## Variáveis de configuração

Todas as variáveis podem ser definidas no `.env` ou passadas diretamente na linha de comando:

```bash
sudo make create-admin ADMIN_PUBKEY="ssh-ed25519 AAAA..."
```

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `ADMIN_USER` | `apli.adm` | Nome do usuário administrador |
| `ADMIN_PUBKEY` | — | Chave pública SSH (obrigatório) |
| `ADMIN_NOPASSWD` | `false` | NOPASSWD no sudo |
| `MGMT_NETWORK` | — | CIDR para restringir SSH (ex: `10.50.0.0/24`) |
| `LETSENCRYPT_EMAIL` | — | E-mail para Let's Encrypt (obrigatório para `ssl`) |
| `CERTBOT_METHOD` | `certbot` | Método de emissão: `certbot` (HTTP-01) ou `dns-01` |
| `PROXY_SSL_VERIFY` | `off` | Verificar TLS do backend (`off`=lab, `on`=produção) |
| `CLIENT_MAX_BODY_SIZE` | `10m` | Tamanho máximo do body HTTP |
| `DMZ_INTERFACE` | `ens3` | Interface de rede na DMZ |
| `DMZ_IP` | — | IP do servidor na DMZ (obrigatório para `migrate-network`) |
| `DMZ_PREFIX` | `24` | Prefixo CIDR |
| `DMZ_GATEWAY` | — | Gateway da DMZ |
| `DMZ_DNS_1/2` | `8.8.8.8 / 1.1.1.1` | Servidores DNS |
| `BACKUP_REMOTE_HOST` | — | Host remoto para backup (opcional) |

---

## Adicionar novo site

```bash
sudo make add-site \
    SITE_FQDN=novo.lab.aplidigital.com.br \
    UPSTREAM=192.168.255.90 \
    UPSTREAM_PORT=8443 \
    UPSTREAM_SCHEME=https
```

O script:
1. Renderiza `templates/site.conf.j2` com as variáveis
2. Valida com `nginx -t`
3. Emite certificado Let's Encrypt
4. Adiciona ao `nginx/sites.list`
5. Recarrega NGINX

---

## Estrutura do repositório

```
apldmz01-nginx/
├── Makefile                        Orquestrador principal
├── README.md                       Esta documentação
├── .env.example                    Template de variáveis (copiar para .env)
├── .gitignore                      Ignora .env e backups
├── scripts/
│   ├── lib.sh                      Funções comuns (log, check_root, backup_file, nginx_test_reload)
│   ├── 00-base-os.sh               Atualização, locale, timezone, chrony, micro
│   ├── 01-harden.sh                CIS hardening completo
│   ├── 02-install-nginx.sh         Instala NGINX oficial + deploya configs
│   ├── 03-create-admin.sh          Cria apli.adm + chave SSH
│   ├── 04-deploy-sites.sh          Gera virtual hosts via envsubst
│   ├── 05-ssl.sh                   Certbot + emissão + timer de renovação
│   ├── 06-backup.sh                Backup com timestamp
│   ├── 07-check-updates.sh         Lista updates pendentes
│   ├── 08-apply-updates.sh         Aplica updates + verifica reboot
│   ├── 09-migrate-network.sh       Migra IP para DMZ (netplan try)
│   ├── add-site.sh                 Adiciona novo site
│   └── update-config.sh            Re-renderiza e recarrega
├── nginx/
│   ├── nginx.conf                  Configuração global hardened
│   ├── conf.d/
│   │   ├── security-headers.conf   HSTS, X-Frame-Options, CSP...
│   │   ├── ssl-params.conf         TLS 1.2/1.3, ciphers, OCSP stapling
│   │   └── ratelimit.conf          Zonas de rate limiting
│   ├── sites-available/            Virtual hosts gerados (1 por FQDN)
│   ├── sites.list                  Tabela FQDN|IP|porta|esquema
│   └── snippets/
│       └── proxy.conf              proxy_set_header padrão
├── templates/
│   └── site.conf.j2                Template ${VAR} para novos virtual hosts
├── netplan/
│   └── dmz.yaml.template           Template de endereçamento DMZ
└── backups/
    └── reports/                    Relatórios Lynis e OpenSCAP
```

---

## Migração de rede — rollback e procedimento

### Antes de executar

1. Confirmar que DNS dos FQDNs já aponta para o novo IP DMZ (ou planejar janela de manutenção)
2. Abrir sessão via **console/IPMI/KVM** (não SSH)
3. Ter o novo IP, máscara, gateway e DNS prontos no `.env`

### Executar

```bash
sudo make migrate-network
# Digitar CONFIRMO quando solicitado
```

O script usa `netplan try --timeout 120`:
- Aplica a nova configuração temporariamente
- Aguarda 120 segundos por confirmação
- **Se não confirmado**: reverte automaticamente para a configuração anterior

### Confirmar (na nova sessão SSH com o novo IP)

```bash
# Na nova sessão SSH:
ssh apli.adm@<NOVO_IP_DMZ>
sudo netplan apply    # confirma permanentemente
```

### Rollback manual

Se necessário, via console:
```bash
sudo mv /etc/netplan/99-dmz.yaml /etc/netplan/99-dmz.yaml.broken
sudo mv /etc/netplan/50-cloud-init.yaml.disabled /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

---

## Verificação pós-deploy

```bash
# NGINX status
sudo systemctl status nginx
sudo nginx -t

# Testar cada FQDN
curl -Ik https://auto.lab.aplidigital.com.br
curl -Ik https://dam-std.lab.aplidigital.com.br

# Verificar TLS (esperar TLSv1.2 ou TLSv1.3)
openssl s_client -connect auto.lab.aplidigital.com.br:443 -brief

# Verificar headers de segurança
curl -sI https://auto.lab.aplidigital.com.br | grep -E "Strict|X-Frame|X-Content|Content-Security"

# Renovação SSL (dry-run)
sudo certbot renew --dry-run

# Firewall
sudo ufw status verbose

# Auditd
sudo auditctl -l
sudo systemctl status auditd

# Lynis (relatório mais recente)
ls -lt backups/reports/lynis_*.txt | head -1

# CIS report (abrir no browser)
# backups/reports/cis_report.html
```

---

## Segurança — avisos importantes

- **Nunca commite o arquivo `.env`** — ele está no `.gitignore`
- **Nunca habilite UFW sem liberar SSH antes** — o script `01-harden.sh` garante a ordem correta
- **Nunca aplique mudanças de SSH sem `sshd -t` antes** — o script valida antes de recarregar
- **`make migrate-network` derruba a sessão atual** — exige confirmação explícita ("CONFIRMO") e console disponível
- `PROXY_SSL_VERIFY=off` é adequado apenas para lab com certificados self-signed nos backends; em produção com CA válida, defina `on`
- Certificados Let's Encrypt têm limite de emissão por domínio — não execute `make ssl` repetidamente

---

## Manutenção recorrente

```bash
# Verificar updates disponíveis (sem aplicar)
sudo make check-updates

# Aplicar updates com backup automático
sudo make apply-updates

# Backup manual
sudo make backup

# Atualizar configuração dos sites (após editar sites.list ou site.conf.j2)
sudo make update-config
```
