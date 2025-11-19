#!/usr/bin/env bash
# Cria um LXC Alpine no Proxmox com:
# - IP estático
# - SSH habilitado (root login permitido)
# - nano
# - netstat -putona (net-tools)
# - ifconfig (net-tools)
# - ps aux (procps-ng)
# - banner.txt apresentado no login SSH

set -euo pipefail

# ==============================
# CONFIGURAÇÕES FIXAS
# ==============================

STORAGE="local-lvm"
TEMPLATE="alpine-3.22-default_20250617_amd64.tar.xz"
BRIDGE="vmbr0"

# ==============================
# CORES / LOG
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
# HELP / USO
# ==============================

show_help() {
  cat <<EOF
Uso:
  $(basename "$0") \\
    --ctid NUM             \\
    --ip IP/MASK           \\
    --gw GATEWAY           \\
    --disk DISK_SIZE_GB    \\
    --hostname NOME        \\
    --root-password SENHA  \\
    --cores NUM            \\
    --swap SWAP_MB         \\
    --memory MEMORY_MB

Parâmetros (obrigatórios):
  --ctid           ID numérico do container (ex: 210)
  --ip             IP com máscara em notação CIDR (ex: 192.168.100.50/24)
  --gw             Gateway padrão (ex: 192.168.100.1)
  --disk           Tamanho do disco em GiB (ex: 8)
  --hostname       Nome do host dentro do LXC (ex: alpine-tools)
  --root-password  Senha do usuário root no LXC
  --cores          Número de vCPUs (ex: 2)
  --swap           Tamanho de swap em MiB (ex: 512)
  --memory         Tamanho de RAM em MiB (ex: 1024)

Exemplo:
  $(basename "$0") \\
    --ctid 210 \\
    --ip 192.168.100.50/24 \\
    --gw 192.168.100.1 \\
    --disk 8 \\
    --hostname alpine-tools \\
    --root-password MinhaSenhaSup3rF0rt3 \\
    --cores 2 \\
    --swap 512 \\
    --memory 1024

EOF
}

# Se não tiver argumentos, mostra help
if [ "$#" -eq 0 ]; then
  show_help
  exit 1
fi

# ==============================
# PARSE DE PARÂMETROS
# ==============================

CTID=""
IP_MASK=""
GATEWAY=""
DISK_SIZE=""
HOSTNAME=""
ROOT_PASSWORD=""
CORES=""
SWAP=""
MEMORY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)
      CTID="$2"; shift 2 ;;
    --ip)
      IP_MASK="$2"; shift 2 ;;
    --gw)
      GATEWAY="$2"; shift 2 ;;
    --disk)
      DISK_SIZE="$2"; shift 2 ;;
    --hostname)
      HOSTNAME="$2"; shift 2 ;;
    --root-password)
      ROOT_PASSWORD="$2"; shift 2 ;;
    --cores)
      CORES="$2"; shift 2 ;;
    --swap)
      SWAP="$2"; shift 2 ;;
    --memory)
      MEMORY="$2"; shift 2 ;;
    --help|-h)
      show_help; exit 0 ;;
    *)
      log_error "Parâmetro desconhecido: $1"
      show_help
      exit 1 ;;
  esac
done

# Validação básica
MISSING=""
[ -z "$CTID" ]          && MISSING="${MISSING} --ctid"
[ -z "$IP_MASK" ]       && MISSING="${MISSING} --ip"
[ -z "$GATEWAY" ]       && MISSING="${MISSING} --gw"
[ -z "$DISK_SIZE" ]     && MISSING="${MISSING} --disk"
[ -z "$HOSTNAME" ]      && MISSING="${MISSING} --hostname"
[ -z "$ROOT_PASSWORD" ] && MISSING="${MISSING} --root-password"
[ -z "$CORES" ]         && MISSING="${MISSING} --cores"
[ -z "$SWAP" ]          && MISSING="${MISSING} --swap"
[ -z "$MEMORY" ]        && MISSING="${MISSING} --memory"

if [ -n "$MISSING" ]; then
  log_error "Parâmetros obrigatórios faltando:${MISSING}"
  echo
  show_help
  exit 1
fi

NET="name=eth0,bridge=${BRIDGE},ip=${IP_MASK},gw=${GATEWAY}"

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
  if grep -q '^#\?PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  else
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
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

log_info "Configurando banner.txt para login SSH..."

pct exec "$CTID" -- ash -c '
  HOST=$(hostname)
  {
    echo
    figlet "$HOST" 2>/dev/null || echo "### $HOST ###"
    echo
    echo "Bem-vindo ao LXC Alpine do HomeLab!"
    echo
    echo "Host........: $HOST"
    echo "Kernel......: $(uname -r)"
    echo "Data/Hora...: $(date)"
    echo
    echo "Ferramentas disponíveis:"
    echo "  - nano"
    echo "  - netstat -putona"
    echo "  - ifconfig"
    echo "  - ps aux"
    echo
    echo "ATENÇÃO: troque a senha do root com:  passwd"
    echo
  } > /etc/ssh/banner.txt
'

# Ativar o uso de Banner no sshd_config
pct exec "$CTID" -- ash -c "
  if grep -q '^Banner ' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's|^Banner .*|Banner /etc/ssh/banner.txt|' /etc/ssh/sshd_config
  else
    echo 'Banner /etc/ssh/banner.txt' >> /etc/ssh/sshd_config
  fi
  rc-service sshd restart
"

log_ok "banner.txt configurado e ativo no SSH."

# ==============================
# RESUMO
# ==============================

IP_INFO=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' || true)

echo
echo -e "${c_magenta}=============================================${c_reset}"
echo -e "${c_green}LXC Alpine criado com sucesso!${c_reset}"
echo -e "  CTID:       ${c_cyan}$CTID${c_reset}"
echo -e "  Hostname:   ${c_cyan}$HOSTNAME${c_reset}"
echo -e "  Rootfs:     ${c_cyan}${STORAGE}:${DISK_SIZE}G${c_reset}"
echo -e "  CPU/Mem:    ${c_cyan}${CORES} vCPU / ${MEMORY} MiB RAM${c_reset}"
echo -e "  Swap:       ${c_cyan}${SWAP} MiB${c_reset}"
echo -e "  Rede:       ${c_cyan}$NET${c_reset}"
if [ -n "$IP_INFO" ]; then
  echo -e "  IP (eth0):  ${c_cyan}$IP_INFO${c_reset}"
fi
echo -e "  Login SSH:  usuário ${c_cyan}root${c_reset}"
echo -e "  Senha:      ${c_red}${ROOT_PASSWORD}${c_reset}  (troque depois!)"
echo -e "  Banner SSH: ${c_cyan}/etc/ssh/banner.txt${c_reset}"
echo -e "${c_magenta}=============================================${c_reset}"
echo
