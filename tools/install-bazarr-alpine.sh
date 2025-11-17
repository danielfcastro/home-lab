#!/bin/sh
# Install Bazarr on Alpine Linux + OpenRC (from scratch)

set -eu

# 👉 helper de logging (tools/logging.sh)
# Conteúdo esperado do logging.sh:
#   #!/bin/sh
#   set -eu
#   setup_logging() { ... }
. "$(dirname "$0")/logging.sh"

SERVICE_NAME="bazarr"
setup_logging "$SERVICE_NAME"

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
LOG_DIR="/var/log/bazarr"

### 1. Checks básicos

if [ ! -f /etc/alpine-release ]; then
  printf "%b\n" "${red}Este instalador é apenas para Alpine Linux.${reset}"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  printf "%b\n" "${red}Execute como root.${reset}"
  exit 1
fi

printf "%b\n" "${brown}### Instalação do Bazarr em Alpine + OpenRC ###${reset}"

### 2. Usuário e grupo

# Grupo para acessar mídia (se não existir)
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
  addgroup -S "$APP_GROUP"
  printf "Created Group %b%s%b.\n" "${yellow}" "$APP_GROUP" "${reset}"
fi

# Usuário do Bazarr
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  adduser -S -D -H -G "$APP_GROUP" "$APP_USER"
  printf "Created User %b%s%b\n" "${yellow}" "$APP_USER" "${reset}"
fi

### 3. Diretórios

# limpa instalação anterior
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR"
chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR"

printf "%b\n" "${yellow}Instalando dependências via apk...${reset}"
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
  p7zip \
  openrc \
  logrotate

### 4. Clonar repositório do Bazarr

printf "%b\n" "${yellow}Baixando código do Bazarr (GitHub)...${reset}"
git clone --depth=1 https://github.com/morpheus65535/bazarr.git "$INSTALL_DIR"

cd "$INSTALL_DIR"

### 5. Criar virtualenv e instalar requirements (sem quebrar Python do sistema)

printf "%b\n" "${yellow}Criando virtualenv em $INSTALL_DIR/venv ...${reset}"
python3 -m venv "$INSTALL_DIR/venv"

printf "%b\n" "${yellow}Instalando requirements dentro da venv...${reset}"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip wheel
"$INSTALL_DIR/venv/bin/pip" install -r requirements.txt

chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR" "$DATA_DIR"

### 6. Criar serviço OpenRC (com logs em /var/log/bazarr)

printf "%b\n" "${yellow}Criando serviço OpenRC do Bazarr...${reset}"

cat >/etc/init.d/bazarr <<'EOF'
#!/sbin/openrc-run

name="Bazarr"
description="Bazarr Daemon"

command="/opt/bazarr/venv/bin/python"
command_args="/opt/bazarr/bazarr.py"
command_user="bazarr:media"
directory="/opt/bazarr"
pidfile="/run/$RC_SVCNAME.pid"
command_background="yes"

# Diretório e arquivos de log
log_dir="/var/log/$RC_SVCNAME"
output_log="${output_log:-$log_dir/output.log}"
error_log="${error_log:-$log_dir/error.log}"

depend() {
    need net
    use dns logger
}

start_pre() {
    # Garante que o diretório de log exista e seja do usuário correto
    checkpath --directory --owner bazarr:media "$log_dir"
}
EOF

chmod +x /etc/init.d/bazarr

# Garante estrutura básica do OpenRC em LXC
if [ ! -d /run/openrc ]; then
  printf "%b\n" "${yellow}Inicializando OpenRC em /run/openrc...${reset}"
  mkdir -p /run/openrc
  touch /run/openrc/softlevel
fi

rc-update add bazarr default

### 7. Configurar logrotate para /var/log/bazarr

cat >/etc/logrotate.d/bazarr <<'EOF'
/var/log/bazarr/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 bazarr media
    sharedscripts
}
EOF

### 8. Iniciar Bazarr

printf "%b\n" "${yellow}Iniciando Bazarr...${reset}"
rc-service bazarr restart || rc-service bazarr start || true
sleep 3

### 9. Verificar status e mostrar URL

if rc-service bazarr status >/dev/null 2>&1; then
  ip_local="$(ip addr show | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/,"",$2); print $2; exit}')"
  printf "%b\n" "${green}Bazarr está rodando!${reset}"
  if [ -n "$ip_local" ]; then
    printf "Acesse: %bhttp://%s:%s%b\n" "${green}" "$ip_local" "$APP_PORT" "${reset}"
  else
    printf "Acesse: %bhttp://<ip-do-container>:%s%b\n" "${green}" "$APP_PORT" "${reset}"
  fi
else
  printf "%b\n" "${red}Bazarr NÃO iniciou. Veja 'rc-service bazarr status' e logs em /var/log/bazarr/.${reset}"
fi
