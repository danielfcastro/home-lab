#!/bin/sh
# ============================================================
# Instalação do qBittorrent-nox (WebUI)
# Alpine Linux 3.22 + OpenRC
# ============================================================

set -e

SERVICE_NAME="qbittorrent-nox"
APP_USER="qbittorrent"
APP_GROUP="qbittorrent"
DATA_DIR="/var/lib/qbittorrent"
LOG_DIR="/var/log/qbittorrent"
WEB_PORT="8080"

green="\033[1;32m"
yellow="\033[1;33m"
red="\033[1;31m"
reset="\033[0m"

echo -e "${green}### Instalação do qBittorrent-nox no Alpine 3.22 ###${reset}"

echo -e "${yellow}==> Instalando pacotes via apk...${reset}"
# Pacote principal + scripts OpenRC (quando disponível)
apk update
apk add qbittorrent-nox qbittorrent-nox-openrc || apk add qbittorrent-nox

echo -e "${yellow}==> Garantindo usuário e grupo ${APP_USER}...${reset}"
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
  addgroup -S "$APP_GROUP"
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  # Usuário de sistema, sem home, sem shell de login
  adduser -S -D -H -s /sbin/nologin -G "$APP_GROUP" "$APP_USER"
fi

echo -e "${yellow}==> Criando diretórios de dados e logs...${reset}"
mkdir -p "$DATA_DIR" "$LOG_DIR"
chown -R "$APP_USER":"$APP_GROUP" "$DATA_DIR" "$LOG_DIR"

# Ajuste opcional do conf.d:
# Se existir /etc/conf.d/qbittorrent-nox, garantimos que use o usuário e diretório corretos
if [ -f /etc/conf.d/qbittorrent-nox ]; then
  echo -e "${yellow}==> Ajustando /etc/conf.d/qbittorrent-nox...${reset}"

  # Garante command_user
  if grep -q '^command_user=' /etc/conf.d/qbittorrent-nox; then
    sed -i "s|^command_user=.*|command_user=\"${APP_USER}:${APP_GROUP}\"|g" /etc/conf.d/qbittorrent-nox
  else
    echo "command_user=\"${APP_USER}:${APP_GROUP}\"" >> /etc/conf.d/qbittorrent-nox
  fi

  # Garante command_args com profile e porta
  if grep -q '^command_args=' /etc/conf.d/qbittorrent-nox; then
    sed -i "s|^command_args=.*|command_args=\"--webui-port=${WEB_PORT} --profile=${DATA_DIR}\"|g" /etc/conf.d/qbittorrent-nox
  else
    echo "command_args=\"--webui-port=${WEB_PORT} --profile=${DATA_DIR}\"" >> /etc/conf.d/qbittorrent-nox
  fi
fi

echo -e "${yellow}==> Adicionando serviço ao boot...${reset}"
rc-update add "$SERVICE_NAME" default || true

echo -e "${yellow}==> Iniciando serviço ${SERVICE_NAME}...${reset}"
rc-service "$SERVICE_NAME" restart || rc-service "$SERVICE_NAME" start || true

echo -e "${yellow}==> Detectando IP local...${reset}"
ip_local="$(ip addr show | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/,"",$2); print $2; exit}')"

echo ""
if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
  echo -e "${green}qBittorrent-nox está rodando!${reset}"
  if [ -n "$ip_local" ]; then
    echo -e "Acesse o WebUI em:"
    echo -e "  ${green}http://$ip_local:${WEB_PORT}${reset}"
  else
    echo -e "Acesse o WebUI em:"
    echo -e "  ${green}http://<ip-do-container>:${WEB_PORT}${reset}"
  fi
  echo ""
  echo -e "Login padrão:"
  echo -e "  Usuário : ${yellow}admin${reset}"
  echo -e "  Senha   : ${yellow}adminadmin${reset}"
else
  echo -e "${red}O serviço ${SERVICE_NAME} NÃO parece estar rodando.${reset}"
  echo -e "Verifique com:"
  echo -e "  ${yellow}rc-service ${SERVICE_NAME} status${reset}"
  echo -e "Logs podem estar em: ${yellow}$LOG_DIR${reset} ou em /var/log/messages"
fi

echo ""
echo -e "${green}============================================================${reset}"
echo -e "${green} Instalação do qBittorrent-nox finalizada.${reset}"
echo -e "  Dados : $DATA_DIR"
echo -e "  Logs  : $LOG_DIR"
echo -e "  Serviço OpenRC: ${SERVICE_NAME}"
echo -e "${green}============================================================${reset}"
