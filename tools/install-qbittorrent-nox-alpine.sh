#!/bin/sh
# ============================================================
# Instalação do qBittorrent-nox (WebUI)
# Alpine Linux 3.22 + OpenRC
# ============================================================

set -eu

# 👉 helper de logging (tools/logging.sh)
# Conteúdo esperado do logging.sh:
#   #!/bin/sh
#   set -eu
#   setup_logging() { ... }
. "$(dirname "$0")/logging.sh"

SERVICE_NAME="qbittorrent-nox"
setup_logging "$SERVICE_NAME"

APP_USER="qbittorrent"
APP_GROUP="qbittorrent"
DATA_DIR="/var/lib/qbittorrent"
LOG_DIR="/var/log/qbittorrent"
WEB_PORT="8080"

green="\033[1;32m"
yellow="\033[1;33m"
red="\033[1;31m"
reset="\033[0m"

# Checks básicos
if [ ! -f /etc/alpine-release ]; then
  printf "%b\n" "${red}Este instalador é apenas para Alpine Linux.${reset}"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  printf "%b\n" "${red}Este script precisa ser executado como root.${reset}"
  exit 1
fi

printf "%b\n" "${green}### Instalação do qBittorrent-nox no Alpine 3.22 ###${reset}"

printf "%b\n" "${yellow}==> Instalando pacotes via apk...${reset}"
apk update
apk add qbittorrent-nox qbittorrent-nox-openrc || apk add qbittorrent-nox
apk add --no-cache openrc logrotate iproute2

printf "%b\n" "${yellow}==> Garantindo usuário e grupo ${APP_USER}...${reset}"
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
  addgroup -S "$APP_GROUP"
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  # Usuário de sistema, sem home, sem shell de login
  adduser -S -D -H -s /sbin/nologin -G "$APP_GROUP" "$APP_USER"
fi

printf "%b\n" "${yellow}==> Criando diretórios de dados e logs...${reset}"
mkdir -p "$DATA_DIR" "$LOG_DIR"
chown -R "$APP_USER:$APP_GROUP" "$DATA_DIR" "$LOG_DIR"

# Ajusta /etc/conf.d/qbittorrent-nox para usar usuário, profile e logs em /var/log/qbittorrent
CONF_FILE="/etc/conf.d/qbittorrent-nox"
if [ -f "$CONF_FILE" ]; then
  printf "%b\n" "${yellow}==> Ajustando ${CONF_FILE}...${reset}"

  # command_user
  if grep -q '^command_user=' "$CONF_FILE"; then
    sed -i "s|^command_user=.*|command_user=\"${APP_USER}:${APP_GROUP}\"|g" "$CONF_FILE"
  else
    printf 'command_user="%s:%s"\n' "$APP_USER" "$APP_GROUP" >>"$CONF_FILE"
  fi

  # command_args (profile + porta)
  if grep -q '^command_args=' "$CONF_FILE"; then
    sed -i "s|^command_args=.*|command_args=\"--webui-port=${WEB_PORT} --profile=${DATA_DIR}\"|g" "$CONF_FILE"
  else
    printf 'command_args="--webui-port=%s --profile=%s"\n' "$WEB_PORT" "$DATA_DIR" >>"$CONF_FILE"
  fi

  # logs via OpenRC
  if grep -q '^output_log=' "$CONF_FILE"; then
    sed -i "s|^output_log=.*|output_log=\"${LOG_DIR}/qbittorrent.log\"|g" "$CONF_FILE"
  else
    printf 'output_log="%s/qbittorrent.log"\n' "$LOG_DIR" >>"$CONF_FILE"
  fi

  if grep -q '^error_log=' "$CONF_FILE"; then
    sed -i "s|^error_log=.*|error_log=\"${LOG_DIR}/qbittorrent.err\"|g" "$CONF_FILE"
  else
    printf 'error_log="%s/qbittorrent.err"\n' "$LOG_DIR" >>"$CONF_FILE"
  fi
else
  # Se não existir conf.d, cria um mínimo viável com logs e args
  printf "%b\n" "${yellow}==> Criando ${CONF_FILE} mínimo...${reset}"
  cat >"$CONF_FILE" <<EOF
command_user="${APP_USER}:${APP_GROUP}"
command_args="--webui-port=${WEB_PORT} --profile=${DATA_DIR}"
output_log="${LOG_DIR}/qbittorrent.log"
error_log="${LOG_DIR}/qbittorrent.err"
EOF
fi

# Garante estrutura básica do OpenRC em LXC
if [ ! -d /run/openrc ]; then
  printf "%b\n" "${yellow}==> Inicializando OpenRC em /run/openrc...${reset}"
  mkdir -p /run/openrc
  touch /run/openrc/softlevel
fi

printf "%b\n" "${yellow}==> Adicionando serviço ao boot...${reset}"
rc-update add "$SERVICE_NAME" default || true

# LOGROTATE para /var/log/qbittorrent
printf "%b\n" "${yellow}==> Configurando logrotate para /var/log/qbittorrent...${reset}"
cat >/etc/logrotate.d/qbittorrent <<'EOF'
/var/log/qbittorrent/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 qbittorrent qbittorrent
    sharedscripts
}
EOF

printf "%b\n" "${yellow}==> Iniciando serviço ${SERVICE_NAME}...${reset}"
rc-service "$SERVICE_NAME" restart || rc-service "$SERVICE_NAME" start || true

printf "%b\n" "${yellow}==> Detectando IP local...${reset}"
ip_local="$(
  ip addr show | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/,"",$2); print $2; exit}'
)"

printf "\n"
if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
  printf "%b\n" "${green}qBittorrent-nox está rodando!${reset}"
  if [ -n "$ip_local" ]; then
    printf "%b\n" "Acesse o WebUI em:"
    printf "  %bhttp://%s:%s%b\n" "${green}" "$ip_local" "$WEB_PORT" "${reset}"
  else
    printf "%b\n" "Acesse o WebUI em:"
    printf "  %bhttp://<ip-do-container>:%s%b\n" "${green}" "$WEB_PORT" "${reset}"
  fi
  printf "\n"
  printf "%b\n" "Login padrão:"
  printf "  Usuário : %badmin%b\n" "${yellow}" "${reset}"
  printf "  Senha   : %badminadmin%b\n" "${yellow}" "${reset}"
else
  printf "%b\n" "${red}O serviço ${SERVICE_NAME} NÃO parece estar rodando.${reset}"
  printf "%b\n" "Verifique com:"
  printf "  %brc-service %s status%b\n" "${yellow}" "$SERVICE_NAME" "${reset}"
  printf "%b\n" "Logs em: %b%s%b ou /var/log/messages" "${reset}" "${yellow}" "$LOG_DIR" "${reset}"
fi

printf "\n"
printf "%b\n" "${green}============================================================${reset}"
printf "%b\n" "${green} Instalação do qBittorrent-nox finalizada.${reset}"
printf "  Dados : %s\n" "$DATA_DIR"
printf "  Logs  : %s\n" "$LOG_DIR"
printf "  Serviço OpenRC: %s\n" "$SERVICE_NAME"
printf "%b\n" "${green}============================================================${reset}"
