#!/bin/sh
# Install Jellyseerr on Alpine Linux (LXC) - estilo Servarr

set -e

APP_NAME="Jellyseerr"
APP_USER="jellyseerr"
APP_GROUP="jellyseerr"
APP_DIR="/opt/jellyseerr"
DATA_DIR="/var/lib/jellyseerr"
LOG_DIR="/var/log/jellyseerr"
SERVICE_FILE="/etc/init.d/jellyseerr"
WRAPPER="/usr/local/bin/jellyseerr-run"
REPO_URL="https://github.com/Fallenbagel/jellyseerr.git"
APP_PORT="5055"

echo "==> $APP_NAME - Instalador para Alpine Linux"

if [ "$(id -u)" -ne 0 ]; then
  echo "Este script precisa ser executado como root."
  exit 1
fi

echo "==> Atualizando índices do apk..."
apk update

echo "==> Instalando dependências (Node, npm, pnpm, build tools, etc)..."
apk add --no-cache \
  curl \
  ca-certificates \
  tzdata \
  iproute2 \
  su-exec \
  tini \
  git \
  nodejs \
  npm \
  python3 \
  build-base \
  bash

echo "==> Instalando pnpm globalmente..."
npm install -g pnpm

echo "==> Criando usuário/grupo '$APP_USER'..."
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
  addgroup -S "$APP_GROUP"
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  adduser -S -D -H -G "$APP_GROUP" -s /sbin/nologin "$APP_USER"
fi

# Criar /home/jellyseerr para npm/pnpm (cache/logs)
if [ ! -d "/home/$APP_USER" ]; then
  echo "==> Criando /home/$APP_USER para npm/pnpm..."
  mkdir -p "/home/$APP_USER"
  chown "$APP_USER:$APP_GROUP" "/home/$APP_USER"
fi

echo "==> Criando diretórios de dados e log..."
mkdir -p "$APP_DIR" "$DATA_DIR" "$LOG_DIR"
chown -R "$APP_USER:$APP_GROUP" "$DATA_DIR" "$LOG_DIR"

echo "==> Parando instância antiga (se existir)..."
if [ -x "$SERVICE_FILE" ]; then
  rc-service jellyseerr stop >/dev/null 2>&1 || true
fi

echo "==> Limpando instalação antiga (se existir)..."
if [ -d "$APP_DIR" ]; then
  rm -rf "$APP_DIR"
fi

echo "==> Clonando repositório $APP_NAME (branch main)..."
git clone "$REPO_URL" "$APP_DIR"

echo "==> Ajustando permissões do diretório da aplicação..."
chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

echo "==> Instalando dependências com pnpm (ignorando engines)..."
env HOME="$DATA_DIR" \
  PNPM_IGNORE_NODE_ENGINE=1 \
  su-exec "$APP_USER:$APP_GROUP" \
  pnpm install --dir "$APP_DIR"

echo "==> Gerando build de produção (como root, dentro do diretório da app, com mais memória)..."
cd "$APP_DIR"
env HOME="/root" \
  PNPM_IGNORE_NODE_ENGINE=1 \
  NODE_OPTIONS="--max_old_space_size=2048" \
  pnpm build

echo "==> Criando wrapper $WRAPPER..."
cat >"$WRAPPER" <<'EOF'
#!/bin/sh
# Wrapper para iniciar o Jellyseerr com tini + su-exec no Alpine

APP_USER="jellyseerr"
APP_GROUP="jellyseerr"
APP_DIR="/opt/jellyseerr"
DATA_DIR="/var/lib/jellyseerr"

cd "${APP_DIR}" || exit 1

export NODE_ENV=production
export HOME="${DATA_DIR}"
export PNPM_IGNORE_NODE_ENGINE=1

exec /sbin/tini -g -- \
  su-exec "${APP_USER}:${APP_GROUP}" \
  node dist/index.js
EOF

chmod +x "$WRAPPER"

echo "==> Criando serviço OpenRC em $SERVICE_FILE..."
cat >"$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="Jellyseerr"
description="Jellyseerr - Media request manager (Jellyfin/Emby/Plex)"

command="/usr/local/bin/jellyseerr-run"
command_user="root:root"
command_background="yes"
pidfile="/run/jellyseerr.pid"

output_log="/var/log/jellyseerr/jellyseerr.log"
error_log="/var/log/jellyseerr/jellyseerr.err"

depend() {
    need net
    use dns logger
}
EOF

chmod +x "$SERVICE_FILE"

echo "==> Garantindo diretórios de log..."
mkdir -p "$LOG_DIR"
chown "$APP_USER:$APP_GROUP" "$LOG_DIR"

echo "==> Adicionando serviço ao boot (runlevel default)..."
rc-update add jellyseerr default || true

echo "==> Parando instância antiga (se existir) e limpando pidfile..."
rc-service jellyseerr stop >/dev/null 2>&1 || true
rm -f /run/jellyseerr.pid 2>/dev/null || true

echo "==> Iniciando serviço Jellyseerr..."
rc-service jellyseerr start || true

echo
echo "============================================================"

ip_local="$(
  ip addr show 2>/dev/null \
    | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/,"",$2); print $2; exit}'
)"

if rc-service jellyseerr status >/dev/null 2>&1; then
  echo " $APP_NAME instalado no Alpine com sucesso!"
  echo
  echo " - Código  : $APP_DIR"
  echo " - Dados   : $DATA_DIR"
  echo " - Logs    : $LOG_DIR"
  echo " - Serviço : $SERVICE_FILE (OpenRC)"
  echo
  if [ -n "$ip_local" ]; then
    echo "Acesse a interface web em:"
    echo "  http://$ip_local:$APP_PORT"
  else
    echo "Acesse a interface web em:"
    echo "  http://<ip-do-container>:$APP_PORT"
  fi
  echo "============================================================"
else
  echo " $APP_NAME NÃO iniciou corretamente."
  echo " Verifique o status com: rc-service jellyseerr status"
  echo " E os logs em: $LOG_DIR"
  echo "============================================================"
fi
