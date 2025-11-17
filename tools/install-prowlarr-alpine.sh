#!/bin/sh
# Install Prowlarr on Alpine Linux (LXC) - estilo Servarr

set -eu

# 👉 helper de logging (tools/logging.sh)
# Conteúdo esperado do logging.sh:
#   #!/bin/sh
#   set -eu
#   setup_logging() { ... }
. "$(dirname "$0")/logging.sh"

SERVICE_NAME="prowlarr"
setup_logging "$SERVICE_NAME"

APP_NAME="Prowlarr"
APP_USER="prowlarr"
APP_GROUP="prowlarr"
APP_DIR="/opt/prowlarr"
DATA_DIR="/var/lib/prowlarr"
LOG_DIR="/var/log/prowlarr"
SERVICE_FILE="/etc/init.d/prowlarr"
WRAPPER="/usr/local/bin/prowlarr-run"

echo "==> $APP_NAME - Instalador para Alpine Linux"

if [ ! -f /etc/alpine-release ]; then
  echo "Este instalador é apenas para Alpine Linux."
  exit 1
fi

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
  tini \
  tzdata \
  iproute2 \
  openrc \
  logrotate

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

echo "==> Criando wrapper $WRAPPER..."
cat >"$WRAPPER" <<'EOF'
#!/bin/sh
# Wrapper para iniciar o Prowlarr com tini no Alpine

APP_DIR="/opt/prowlarr"
DATA_DIR="/var/lib/prowlarr"

# Garante que o working directory é o diretório da aplicação
cd "${APP_DIR}" || exit 1

exec /sbin/tini -g -- \
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
command_user="prowlarr:prowlarr"
command_background="yes"
pidfile="/run/$RC_SVCNAME.pid"

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
    checkpath --directory --owner prowlarr:prowlarr "$log_dir"
}
EOF

chmod +x "$SERVICE_FILE"

echo "==> Garantindo diretórios de log..."
mkdir -p "$LOG_DIR"
chown "$APP_USER:$APP_GROUP" "$LOG_DIR"

# Garante estrutura básica do OpenRC em LXC
if [ ! -d /run/openrc ]; then
  echo "==> Inicializando OpenRC em /run/openrc..."
  mkdir -p /run/openrc
  touch /run/openrc/softlevel
fi

echo "==> Adicionando serviço ao boot (runlevel default)..."
rc-update add prowlarr default || true

echo "==> Parando instância antiga (se existir) e limpando pidfile..."
rc-service prowlarr stop >/dev/null 2>&1 || true
rm -f /run/prowlarr.pid 2>/dev/null || true

### LOGROTATE
echo "==> Configurando logrotate para /var/log/prowlarr..."
cat >/etc/logrotate.d/prowlarr <<'EOF'
/var/log/prowlarr/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 prowlarr prowlarr
    sharedscripts
}
EOF

echo "==> Iniciando serviço Prowlarr..."
rc-service prowlarr start || true

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
if rc-service prowlarr status >/dev/null 2>&1; then
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
else
  echo " $APP_NAME NÃO iniciou corretamente."
  echo " Verifique o status com: rc-service prowlarr status"
  echo " E os logs em: $LOG_DIR"
fi
echo "============================================================"
echo
