#!/usr/bin/env bash
# Cria um LXC Alpine no Proxmox com:
# - SSH habilitado (root login permitido)
# - nano
# - netstat -putona (net-tools)
# - ifconfig (net-tools)
# - ps aux (procps-ng)
# - banner.txt apresentado no login SSH

set -euo pipefail

# ==============================
# CONFIGURAÇÕES PADRÃO
# ==============================

CTID_DEFAULT=200          # ID padrão do CT
HOSTNAME_DEFAULT="alpine-lxc"
STORAGE_DEFAULT="local-lvm"
DISK_SIZE_DEFAULT="8"     # GiB

CORES_DEFAULT=2
MEMORY_DEFAULT=1024       # MiB
SWAP_DEFAULT=512          # MiB

# Ajuste esse template de acordo com 'pveam available | grep alpine'
TEMPLATE_DEFAULT="alpine-3.20-default_20240606_amd64.tar.zst"

NET_DEFAULT="name=eth0,bridge=vmbr0,ip=dhcp"

# Troque essa senha depois de criar o container!
ROOT_PASSWORD_DEFAULT="changeme"

# ==============================
# CORES
# ==============================

c_reset="\033[0m"
c_red="\033[31m"
c_green="\033[32m"
c_yellow="\033[33m"
c_cyan="\033[36m"
c_magenta="\033[35m"

log_info()  { echo -e "${c_cyan}[INFO]${c_reset}  $*"; }
log_warn()  { echo -e "${c_yellow}[WARN]${c_reset}  $*"; }
log_error() { echo -e "${c_red}[ERRO]${c_reset}  $*" >&2; }
log_ok()    { echo -e "${c_green}[OK]${c_reset}    $*"; }

# ==============================
# PARÂMETROS
# ==============================

CTID="${1:-$CTID_DEFAULT}"
HOSTNAME="${2:-$HOSTNAME_DEFAULT}"

STORAGE="${STORAGE_DEFAULT}"
DISK_SIZE="${DISK_SIZE_DEFAULT}"
CORES="${CORES_DEFAULT}"
MEMORY="${MEMORY_DEFAULT}"
SWAP="${SWAP_DEFAULT}"
TEMPLATE="${TEMPLATE_DEFAULT}"
NET="${NET_DEFAULT}"
ROOT_PASSWORD="${ROOT_PASSWORD_DEFAULT}"

# ==============================
# CHECKS
# ==============================

if ! command -v pct >/dev/null 2>&1; then
  log_error "Este script deve ser executado no host Proxmox (comando 'pct' não encontrado)."
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  log_error "Já existe um container com CTID $CTID. Escolha outro ID."
  exit 1
fi

# ==============================
# TEMPLATE ALPINE
# ==============================

log_info "Atualizando lista de templates..."
pveam update >/dev/null 2>&1 || log_warn "Falha em 'pveam update', seguindo mesmo assim."

if ! pveam available | grep -q "$TEMPLATE"; then
  log_info "Template $TEMPLATE não encontrado. Baixando para 'local'..."
  pveam download local "$TEMPLATE" || {
    log_error "Não consegui baixar o template $TEMPLATE."
    log_error "Rode: pveam available | grep alpine e ajuste TEMPLATE_DEFAULT no script."
    exit 1
  }
else
  log_ok "Template $TEMPLATE disponível."
fi

# ==============================
# CRIAR CONTAINER
# ==============================

log_info "Criando LXC Alpine (CTID=$CTID, hostname=$HOSTNAME)..."

pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  -hostname "$HOSTNAME" \
  -rootfs "${STORAGE}:${DISK_SIZE}" \
  -cores "$CORES" \
  -memory "$MEMORY" \
  -swap "$SWAP" \
  -net0 "$NET" \
  -unprivileged 1 \
  -features nesting=1 \
  -ostype alpine

log_ok "Container $CTID criado."

# ==============================
# INICIAR CONTAINER
# ==============================

log_info "Iniciando container $CTID..."
pct start "$CTID"
sleep 5
log_ok "Container $CTID iniciado."

# ==============================
# PACOTES INTERNOS
# ==============================
# Aqui garantimos:
# - nano
# - openssh (servidor SSH)
# - net-tools (netstat, ifconfig)
# - procps-ng (ps aux completo)
# - figlet (pro banner)

log_info "Instalando pacotes (nano, openssh, net-tools, procps-ng, figlet)..."

pct exec "$CTID" -- ash -c "
  apk update && \
  apk add --no-cache nano openssh net-tools procps-ng figlet
"

log_ok "Pacotes instalados dentro do container."

# ==============================
# CONFIGURAR SSH + ROOT LOGIN
# ==============================

log_info "Configurando sshd para permitir root login e subir no boot..."

# Permitir root login
pct exec "$CTID" -- ash -c "
  if ! grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  else
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  fi
"

# Definir senha do root
pct exec "$CTID" -- ash -c "echo 'root:${ROOT_PASSWORD}' | chpasswd"

# Habilitar sshd no boot e iniciar agora
pct exec "$CTID" -- rc-update add sshd default
pct exec "$CTID" -- rc-service sshd restart || pct exec "$CTID" -- rc-service sshd start

log_ok "SSH configurado (root login permitido, serviço no boot)."

# ==============================
# BANNER SSH (banner.txt)
# ==============================
# Banner apresentado AO CONECTAR via SSH (antes do login).
# Arquivo: /etc/ssh/banner.txt
# Config: Banner /etc/ssh/banner.txt em sshd_config

log_info "Configurando banner.txt para login SSH..."

pct exec "$CTID" -- ash -c '
  HOSTNAME_CUR=$(hostname)

  cat > /etc/ssh/banner.txt <<EOF

$(figlet "$HOSTNAME_CUR" 2>/dev/null || echo "*** $HOSTNAME_CUR ***")

Bem-vindo ao LXC Alpine do HomeLab!

Host........: $HOSTNAME_CUR
Kernel......: $(uname -r)
Data/horário: $(date)

Ferramentas úteis disponíveis:
  - nano
  - netstat -putona
  - ifconfig
  - ps aux

ATENÇÃO: Troque a senha do root com o comando:  passwd

EOF
'

# Ativar o uso de Banner no sshd_config
pct exec "$CTID" -- ash -c "
  if ! grep -q '^Banner ' /etc/ssh/sshd_config 2>/dev/null; then
    echo 'Banner /etc/ssh/banner.txt' >> /etc/ssh/sshd_config
  else
    sed -i 's|^Banner .*|Banner /etc/ssh/banner.txt|' /etc/ssh/sshd_config
  fi
"

# Reiniciar sshd pra aplicar Banner
pct exec "$CTID" -- rc-service sshd restart

log_ok "banner.txt configurado e ativo no SSH."

# ==============================
# RESUMO
# ==============================

IP_INFO=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | awk "/inet / {print \$2}" || true)

echo
echo -e "${c_magenta}=============================================${c_reset}"
echo -e "${c_green}LXC Alpine criado com sucesso!${c_reset}"
echo -e "  CTID:       ${c_cyan}$CTID${c_reset}"
echo -e "  Hostname:   ${c_cyan}$HOSTNAME${c_reset}"
echo -e "  Rootfs:     ${c_cyan}${STORAGE}:${DISK_SIZE}G${c_reset}"
echo -e "  CPU/Mem:    ${c_cyan}${CORES} vCPU / ${MEMORY} MiB RAM${c_reset}"
echo -e "  Rede:       ${c_cyan}$NET${c_reset}"
if [ -n "$IP_INFO" ]; then
  echo -e "  IP (eth0):  ${c_cyan}$IP_INFO${c_reset}"
fi
echo -e "  Login SSH:  usuário ${c_cyan}root${c_reset}"
echo -e "  Senha:      ${c_red}${ROOT_PASSWORD}${c_reset}  (troque depois!)"
echo -e "  Banner SSH: ${c_cyan}/etc/ssh/banner.txt${c_reset}"
echo -e "${c_magenta}=============================================${c_reset}"
echo
