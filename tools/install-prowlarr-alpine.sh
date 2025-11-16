#!/bin/sh
# Install Prowlarr on Alpine Linux (LXC) - estilo Servarr

set -e

APP_NAME="Prowlarr"
APP_USER="prowlarr"
APP_GROUP="prowlarr"
APP_DIR="/opt/prowlarr"
DATA_DIR="/var/lib/prowlarr"
LOG_DIR="/var/log/prowlarr"
SERVICE_FILE="/etc/init.d/prowlarr"
WRAPPER="/usr/local/bin/prowlarr-run"

echo "==> $APP_NAME - Instalador para Alpine Linux"

if [ "$(id -u)" -ne 0 ]; then
  echo "Este script precisa ser executado como root."
  exit 1
fi

echo "==> Atualizando índices do apk..."
apk update

echo "==> Instalando dependências..."
apk add --no-cache \
  curl \
  ca-certificates \
  icu-libs \
  sqlite-libs \
  libstdc++ \
  gcompat \
  su-exec \
  tini \
  tzdata \
  iproute2

# Criação de usuário/grupo dedicados
echo "==> Criando usuário/grupo '$APP_USER'..."
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
  addgroup -S "$APP_GROUP"
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  adduser -S -D -H -G "$APP_GROUP" -s /sbin/nologin "$APP_USER"
fi

echo "==> Criando diretórios..."
mkdir -p "$APP_DIR" "$DATA_DIR" "$LOG_DIR"
chown -R "$APP_USER:$APP_GROUP" "$DATA_DIR" "$LOG_DIR"

# Descobrir versão mais recente no GitHub
echo "==> Descobrindo a última versão do $APP_NAME no GitHub..."
RELEASE_TAG=$(
  curl -fsSL "https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest" \
  | grep -m1 '"tag_name"' \
  | sed -E 's/.*"v?([^"]+)".*/\1/'
)

if [ -z "$RELEASE_TAG" ]; then
  echo "ERRO: Não foi possível obter a versão mais recente do Prowlarr a partir da API do GitHub."
  exit 1
fi

echo "==> Última versão detectada: v$RELEASE_TAG"

# Preferimos o build Linux Musl (x64) para Alpine
TARBALL="Prowlarr.master.${RELEASE_TAG}.linux-musl-core-x64.tar.gz"
TARBALL_URL="https://github.com/Prowlarr/Prowlarr/releases/download/v${RELEASE_TAG}/${TARBALL}"
TMP_TAR="/tmp/prowlarr.tar.gz"

echo "==> Baixando tarball Musl x64:"
echo "    $TARBALL_URL"
curl -fSL "$TARBALL_URL" -o "$TMP_TAR"

echo "==> Extraindo arquivos..."
# Limpando instalação antiga, se existir
if [ -d "$APP_DIR" ]; then
  rm -rf "$APP_DIR"
fi

tar -xzf "$TMP_TAR" -C /tmp
rm -f "$TMP_TAR"

# O tarball extrai para /tmp/Prowlarr
if [ ! -d "/tmp/Prowlarr" ]; then
  echo "ERRO: diretório /tmp/Prowlarr não encontrado após extração."
  exit 1
fi

mv /tmp/Prowlarr "$APP_DIR"
chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

echo "==> Criando wrapper /usr/local/bin/prowlarr-run..."
cat >"$WRAPPER" <<'EOF'
#!/bin/sh
# Wrapper para iniciar o Prowlarr com tini + su-exec no Alpine (ajustado com cd)

APP_USER="prowlarr"
APP_GROUP="prowlarr"
APP_DIR="/opt/prowlarr"
DATA_DIR="/var/lib/prowlarr"

# Garante que o working directory é o diretório da aplicação
cd "${APP_DIR}" || exit 1

exec /sbin/tini -g -- \
  su-exec "${APP_USER}:${APP_GROUP}" \
  ./Prowlarr \
    -nobrowser \
    -data="${DATA_DIR}"
EOF

chmod +x "$WRAPPER"

echo "==> Criando serviço OpenRC em $SERVICE_FILE..."
cat >"$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="Prowlarr"
description="Prowlarr indexer manager (*arr suite)"

command="/usr/local/bin/prowlarr-run"
command_user="root:root"
command_background="yes"
pidfile="/run/prowlarr.pid"

output_log="/var/log/prowlarr/prowlarr.log"
error_log="/var/log/prowlarr/prowlarr.err"

depend() {
    need net
    use dns logger
}
EOF

chmod +x "$SERVICE_FILE"

echo "==> Garantindo diretórios de log..."
mkdir -p /var/log/prowlarr
chown "$APP_USER:$APP_GROUP" /var/log/prowlarr

echo "==> Adicionando serviço ao boot (runlevel default)..."
rc-update add prowlarr default || true

echo "==> Iniciando serviço Prowlarr..."
rc-service prowlarr start

# Detectar IP do container para exibir URL amigável
HOSTNAME_STR=$(hostname 2>/dev/null || echo "localhost")

IP_ADDR=$(
  ip route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
)

if [ -z "$IP_ADDR" ]; then
  IP_ADDR="127.0.0.1"
fi

echo
echo "============================================================"
echo " $APP_NAME instalado no Alpine com sucesso!"
echo
echo " - Binário : $APP_DIR/Prowlarr"
echo " - Dados   : $DATA_DIR"
echo " - Logs    : $LOG_DIR"
echo " - Serviço : $SERVICE_FILE (OpenRC)"
echo
echo "Acesse a interface web em:"
echo "  http://$IP_ADDR:9696"
echo "  http://$HOSTNAME_STR:9696"
echo "============================================================"
echo
