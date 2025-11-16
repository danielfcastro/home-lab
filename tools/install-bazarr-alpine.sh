#!/bin/bash
# Install Bazarr on Alpine Linux + OpenRC (from scratch)

set -euo pipefail

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
brown='\033[0;33m'
reset='\033[0m'

INSTALL_DIR="/opt/bazarr"
DATA_DIR="/var/lib/bazarr"
APP_USER="bazarr"
APP_GROUP="media"
APP_PORT="6767"   # porta padrão do Bazarr

### 1. Checks básicos

if [ ! -f /etc/alpine-release ]; then
  echo -e "${red}Este instalador é apenas para Alpine Linux.${reset}"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${red}Execute como root.${reset}"
  exit 1
fi

echo -e "${brown}### Instalação do Bazarr em Alpine + OpenRC ###${reset}"

### 2. Usuário e grupo

# Grupo para acessar mídia (se não existir)
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
  addgroup -S "$APP_GROUP"
  echo -e "Created Group ${yellow}$APP_GROUP${reset}."
fi

# Usuário do Bazarr
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  adduser -S -D -H -G "$APP_GROUP" "$APP_USER"
  echo -e "Created User ${yellow}$APP_USER${reset}"
fi

### 3. Diretórios

# limpa instalação anterior
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR" "$DATA_DIR"

echo -e "${yellow}Instalando dependências via apk...${reset}"
apk update
apk add --no-cache \
  git \
  python3 \
  py3-pip \
  py3-virtualenv \
  ffmpeg \
  libstdc++ \
  libgcc \
  libc6-compat \
  build-base \
  libffi-dev \
  openssl-dev \
  zlib-dev \
  p7zip

### 4. Clonar repositório do Bazarr

echo -e "${yellow}Baixando código do Bazarr (GitHub)...${reset}"
git clone --depth=1 https://github.com/morpheus65535/bazarr.git "$INSTALL_DIR"

cd "$INSTALL_DIR"

### 5. Criar virtualenv e instalar requirements (sem quebrar Python do sistema)

echo -e "${yellow}Criando virtualenv em $INSTALL_DIR/venv ...${reset}"
python3 -m venv "$INSTALL_DIR/venv"

echo -e "${yellow}Instalando requirements dentro da venv...${reset}"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip wheel
"$INSTALL_DIR/venv/bin/pip" install -r requirements.txt

chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR" "$DATA_DIR"

### 6. Criar serviço OpenRC

echo -e "${yellow}Criando serviço OpenRC do Bazarr...${reset}"

cat >/etc/init.d/bazarr <<EOF
#!/sbin/openrc-run

name="Bazarr"
description="Bazarr Daemon"

command="$INSTALL_DIR/venv/bin/python"
command_args="$INSTALL_DIR/bazarr.py"
command_user="$APP_USER:$APP_GROUP"
directory="$INSTALL_DIR"
pidfile="/run/\$RC_SVCNAME.pid"
command_background="yes"

depend() {
    need net
    use dns logger
}
EOF

chmod +x /etc/init.d/bazarr
rc-update add bazarr default

### 7. Iniciar Bazarr

echo -e "${yellow}Iniciando Bazarr...${reset}"
rc-service bazarr restart || rc-service bazarr start || true
sleep 3

### 8. Verificar status e mostrar URL

if rc-service bazarr status >/dev/null 2>&1; then
  ip_local="$(ip addr show | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/,"",$2); print $2; exit}')"
  echo -e "${green}Bazarr está rodando!${reset}"
  if [ -n "$ip_local" ]; then
    echo -e "Acesse: ${green}http://$ip_local:$APP_PORT${reset}"
  else
    echo -e "Acesse: ${green}http://<ip-do-container>:$APP_PORT${reset}"
  fi
else
  echo -e "${red}Bazarr NÃO iniciou. Veja 'rc-service bazarr status' e logs em $INSTALL_DIR.${reset}"
fi
