# apldmz01-nginx — NGINX Reverse Proxy / TLS Terminator (DMZ)

Repositório de infraestrutura como código para o servidor **apldmz01**, responsável por terminar TLS e fazer proxy reverso de 10 aplicações Imperva/Thales na DMZ da Aplidigital.

---

## Arquitetura

```
Usuários externos
      │
      ▼ 443 (DNS: *.lab.aplidigital.com.br → impervadns.net)
┌──────────────────────┐
│  Imperva Cloud WAF   │  45.60.69.210 (impervadns.net)
│  (scrubbing center)  │
└──────────────────────┘
      │ origin: 10.60.0.6
      ▼ 80/443
┌──────────────────────┐
│     apldmz01         │  Ubuntu 26.04 LTS
│  NGINX + CA local    │  IP DMZ: 10.60.0.6/28 (ens33)
│  CIS Hardened        │
└──────────────────────┘
      │
      ├──► auto.lab.aplidigital.com.br        → https://10.50.0.70:443
      ├──► dam-std.lab.aplidigital.com.br     → https://192.168.255.71:8083
      ├──► dam-ls.lab.aplidigital.com.br      → https://192.168.255.74:8083
      ├──► dsf.lab.aplidigital.com.br         → https://192.168.255.77:8443
      ├──► dsf-gw1.lab.aplidigital.com.br     → https://192.168.255.78:8443
      ├──► dsf-gw2.lab.aplidigital.com.br     → https://192.168.255.79:8443
      ├──► dra.lab.aplidigital.com.br         → https://192.168.255.80:8443
      ├──► waf.lab.aplidigital.com.br         → https://192.168.255.82:8083
      ├──► ciphertrust.lab.aplidigital.com.br → https://192.168.255.84:443
      └──► ddc.lab.aplidigital.com.br         → https://192.168.255.85:443
```

### Componentes

| Componente | Descrição |
|------------|-----------|
| NGINX 1.30+ (nginx.org stable) | Reverse proxy + TLS terminator |
| CA local (`/etc/ssl/lab-ca/`) | Certificados autoassinados para ambiente interno |
| UFW | Firewall (apenas 22/80/443 incoming) |
| auditd | Auditoria de sistema (regras CIS) |
| AIDE | Detecção de alterações de integridade |
| Lynis | Auditoria de segurança |
| OpenSCAP | Avaliação CIS Level 1/2 |

### Por que CA local em vez de Let's Encrypt

Os FQDNs `*.lab.aplidigital.com.br` resolvem via `impervadns.net` para o Imperva Cloud WAF (`45.60.69.210`) — não para este servidor diretamente. O desafio HTTP-01 do Let's Encrypt requer que a requisição chegue a este servidor, o que não acontece nesta topologia. Para ambientes com acesso via DNS-01, use `CERTBOT_METHOD=dns-01` + plugin correspondente.

---

## Pré-requisitos

- Ubuntu 26.04 LTS instalado e acessível via SSH como root
- Arquivo `.env` criado a partir de `.env.example` com os valores reais
- Para `migrate-network`: acesso via console/IPMI disponível

```bash
cp .env.example .env
micro .env   # preencher ADMIN_PUBKEY e demais variáveis
```

> **ADMIN_PUBKEY**: manter as aspas duplas — a chave SSH contém espaços.
> ```bash
> # Obter a chave:
> cat ~/.ssh/id_ed25519.pub
> # No .env:
> ADMIN_PUBKEY="ssh-ed25519 AAAAC3... user@host"
> ```

---

## Ordem de execução (novo servidor)

```bash
# Passo a passo recomendado:
sudo make install-nginx          # base OS + NGINX oficial
sudo make create-admin           # usuário apli.adm + chave SSH
sudo make harden                 # CIS hardening completo (após criar apli.adm)
sudo make deploy-sites           # virtual hosts para os 10 FQDNs
sudo make ssl-selfsigned         # CA local + certs autoassinados (ambiente lab)
sudo make backup                 # backup inicial

# Por último — DERRUBA A SESSÃO SSH:
sudo make migrate-network        # muda IP para a DMZ
```

> `make all` executa na mesma sequência, exceto `migrate-network` que é sempre manual.

> **Ordem crítica**: `create-admin` deve preceder `harden` — o hardening aplica `AllowUsers apli.adm` no SSH e bloqueia root. Se `harden` rodar antes, o usuário não existe e você perde acesso.

---

## Targets do Makefile

| Target | Descrição |
|--------|-----------|
| `make help` | Lista todos os targets e variáveis |
| `make all` | Executa tudo na ordem segura (exceto migrate-network) |
| `make install-nginx` | Base OS + instala NGINX do repositório oficial nginx.org |
| `make create-admin` | Cria usuário `apli.adm` com chave SSH e sudo |
| `make harden` | Hardening CIS completo (filesystem, sysctl, UFW, SSH, PAM, auditd, AIDE, Lynis, OpenSCAP) |
| `make deploy-sites` | Gera virtual hosts para todos os FQDNs em `nginx/sites.list` |
| `make ssl` | Emite/renova certificados Let's Encrypt via HTTP-01 (requer DNS apontando para este servidor) |
| `make ssl-selfsigned` | **CA local + certs autoassinados** — usar quando HTTP-01 não é viável (lab/rede interna) |
| `make add-site` | Adiciona novo site via template (requer `SITE_FQDN=`, `UPSTREAM=`) |
| `make update-config` | Re-renderiza todos os sites e recarrega NGINX |
| `make backup` | Backup tar.gz de configurações críticas |
| `make check-updates` | Lista updates pendentes sem aplicar |
| `make apply-updates` | Aplica updates (com backup prévio) e reporta necessidade de reboot |
| `make migrate-network` | **[ÚLTIMO PASSO]** Migra IP para a DMZ via `netplan try` |

---

## Certificados — CA local

O `make ssl-selfsigned` gera:

- CA raiz em `/etc/ssl/lab-ca/lab-ca.crt` (validade 10 anos)
- Um certificado individual por FQDN em `/etc/letsencrypt/live/<fqdn>/` (825 dias)
- Mesmos caminhos que o certbot usa — `deploy-sites.sh` funciona sem alteração

### Importar o CA nos clientes (para evitar aviso no browser)

```bash
# Exportar do servidor
scp root@10.60.0.6:/etc/ssl/lab-ca/lab-ca.crt ~/Desktop/lab-aplidigital-ca.crt

# macOS: clique duplo no arquivo → Keychain → marcar como "Always Trust"
# Windows: clique duplo → Instalar certificado → Autoridades de Certificação Raiz Confiáveis
# Linux: sudo cp lab-aplidigital-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
```

---

## Compatibilidade com consoles Imperva/Thales

Os apps Imperva (SecureSphere DAM, DSF, DRA, WAF, CipherTrust, DDC) têm requisitos específicos de proxy:

| Requisito | Configuração |
|-----------|-------------|
| **WebSocket** | `proxy_set_header Connection $connection_upgrade` (map em nginx.conf) |
| **Timeouts longos** | 120s connect / 300s send+read por location |
| **Sem CSP do nginx** | `Content-Security-Policy` omitido — JS inline dos consoles seria bloqueado |
| **Buffers maiores** | `proxy_buffers 8 32k` para UIs JavaScript pesadas |
| **Sem rate limiting** | `limit_req`/`limit_conn` removidos — causariam 429 no carregamento do UI |

O `security-headers.conf` mantém apenas HSTS, `X-Content-Type-Options` e `Referrer-Policy` — headers que não interferem nos apps.

---

## Variáveis de configuração

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `ADMIN_USER` | `apli.adm` | Nome do usuário administrador |
| `ADMIN_PUBKEY` | — | **Chave pública SSH (obrigatório, com aspas duplas)** |
| `ADMIN_NOPASSWD` | `false` | NOPASSWD no sudo |
| `MGMT_NETWORK` | — | CIDR para restringir SSH (ex: `10.50.0.0/24`) |
| `LETSENCRYPT_EMAIL` | — | E-mail para Let's Encrypt (obrigatório para `make ssl`) |
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

Depois de adicionar, emita o certificado:
```bash
# Se usando CA local:
sudo make ssl-selfsigned

# Se usando Let's Encrypt (DNS apontando para este servidor):
sudo make ssl
```

---

## Estrutura do repositório

```
apldmz01-nginx/
├── Makefile                        Orquestrador principal
├── README.md                       Esta documentação
├── .env.example                    Template de variáveis (copiar para .env)
├── .gitignore                      Ignora .env e backups
├── scripts/
│   ├── lib.sh                      Funções comuns (log, check_root, backup_file)
│   ├── 00-base-os.sh               Atualização, locale, timezone, chrony, micro
│   ├── 01-harden.sh                CIS hardening completo (11 etapas)
│   ├── 02-install-nginx.sh         Instala NGINX oficial + deploya configs
│   ├── 03-create-admin.sh          Cria apli.adm + chave SSH (lê ADMIN_PUBKEY do .env)
│   ├── 04-deploy-sites.sh          Gera virtual hosts via envsubst (idempotente)
│   ├── 05-ssl.sh                   Certbot HTTP-01 com bootstrap HTTP-only
│   ├── 05-ssl-selfsigned.sh        CA local + certs autoassinados por FQDN
│   ├── 06-backup.sh                Backup tar.gz com timestamp
│   ├── 07-check-updates.sh         Lista updates pendentes
│   ├── 08-apply-updates.sh         Aplica updates + verifica reboot
│   ├── 09-migrate-network.sh       Migra IP para DMZ (netplan try, rollback auto)
│   ├── add-site.sh                 Adiciona novo site ao sites.list + cert
│   └── update-config.sh            Re-renderiza e recarrega
├── nginx/
│   ├── nginx.conf                  Config global: map WebSocket, limites, gzip
│   ├── conf.d/
│   │   ├── security-headers.conf   HSTS, X-Content-Type-Options, Referrer-Policy
│   │   │                           (CSP omitido — incompatível com JS inline Imperva)
│   │   ├── ssl-params.conf         TLS 1.2/1.3, ciphers, OCSP stapling
│   │   └── ratelimit.conf          Zonas de rate limiting (definições apenas)
│   ├── sites.list                  Tabela FQDN|IP|porta|esquema
│   └── snippets/
│       └── proxy.conf              Headers de proxy (Connection/Upgrade por location)
├── templates/
│   └── site.conf.j2                Template ${VAR} — http2, WebSocket, timeouts 300s
├── netplan/
│   └── dmz.yaml.template           Template de endereçamento DMZ
└── backups/
    └── reports/                    Relatórios Lynis e OpenSCAP
```

---

## Migração de rede

### Antes de executar

1. Abrir sessão via **console/IPMI/KVM** — a sessão SSH atual será interrompida
2. Confirmar que `DMZ_IP`, `DMZ_GATEWAY` e `DMZ_INTERFACE` estão corretos no `.env`
3. Verificar que a regra de firewall no gateway DMZ libera 80/443 para o novo IP

### Executar

```bash
sudo make migrate-network
# Digitar CONFIRMO quando solicitado
```

O script usa `netplan try --timeout 120`: aplica a configuração temporariamente e reverte automaticamente se não confirmada em 120 segundos.

### Confirmar permanentemente (na nova sessão SSH)

```bash
ssh apli.adm@<NOVO_IP_DMZ>
sudo netplan apply
```

### Rollback manual (via console)

```bash
sudo ip addr add <IP_ANTIGO>/<PREFIX> dev <INTERFACE>
sudo ip route add default via <GATEWAY_ANTIGO>
# Depois reconectar SSH e:
sudo netplan apply   # reverte para config anterior
```

---

## Verificação pós-deploy

```bash
# NGINX status e config
sudo systemctl status nginx
sudo nginx -t

# Testar proxy via IP (aceitar cert autoassinado com -k)
curl -sk --resolve dam-std.lab.aplidigital.com.br:443:127.0.0.1 \
    https://dam-std.lab.aplidigital.com.br/ -I

# Verificar certificado emitido
openssl s_client -connect 127.0.0.1:443 -servername dam-std.lab.aplidigital.com.br \
    </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates

# Firewall
sudo ufw status verbose

# Auditd
sudo auditctl -l
sudo systemctl status auditd

# Relatório de segurança mais recente
ls -lt backups/reports/lynis_*.txt | head -1
```

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

# Renovar certificados autoassinados (quando próximos do vencimento)
sudo make ssl-selfsigned
```

---

## Segurança — avisos importantes

- **Nunca commite o arquivo `.env`** — ele está no `.gitignore`
- **`create-admin` deve preceder `harden`** — hardening bloqueia root e aplica `AllowUsers apli.adm`
- **Nunca habilite UFW sem liberar SSH antes** — `01-harden.sh` garante a ordem
- **`make migrate-network` derruba a sessão** — exige "CONFIRMO" e console disponível
- `PROXY_SSL_VERIFY=off` é adequado para backends com certificados autoassinados; em produção com CA válida, usar `on`
