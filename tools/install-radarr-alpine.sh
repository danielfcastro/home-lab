#!/bin/sh
#
# Script de instalação do Radarr em Alpine Linux (OpenRC)
# Estilo Servarr / Bazarr / Sonarr
#

set -e

# -------------------------------------------------------------------
# Configurações básicas
# -------------------------------------------------------------------
APP_NAME="Radarr"
APP_USER="radarr"
APP_GROUP="radarr"
APP_PORT="7878"

INSTALL_DIR="/opt/radarr"
OLD_INSTALL_DIR="/opt/Radarr"
DATA_DIR="/var/lib/radarr"
LOG_DIR="/var/log/radarr"
SERVICE_FILE="/etc/init.d/radarr"
WRAPPER_BIN="/usr/local/bin/radarr-run"

# URL oficial Servarr — build linuxmusl para Alpine
RADARR_URL="https://radarr.servarr.com/v1/update/master/updatefile?os=linuxmusl&runtime=netcore&arch=x64"

TMP_DIR="/tmp/radarr-install.$$"

# -------------------------------------------------------------------
# Cores
# -------------------------------------------------------------------
green="\033[1;32m"
yellow="\033[1;33m"
red="\033[1;31m"
blue="\033[1;34m"
bold="\033[1m"
reset="\033[0m"

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
info()  { echo -e "${blue}[INFO]${reset}  $*"; }
ok()    { echo -e "${green}[OK]${reset}    $*"; }
warn()  { echo -e "${yellow}[WARN]${reset}  $*"; }
error() { echo -e "${red}[ERRO]${reset}  $*"; }

# -------------------------------------------------------------------
# Verificações iniciais
# -------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  error "Este script precisa ser executado como root."
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)
    ok "Arquitetura detectada: $arch (compatível com build x64 do Radarr)"
    ;;
  *)
    warn "Arquitetura detectada: $arch. Este script foi pensado para x86_64/amd64."
    warn "Se estiver em ARM, ajuste a URL do RADARR_URL para o build correto."
    ;;
esac

echo
echo -e "${bold}=== Instalando ${APP_NAME} no Alpine (OpenRC) ===${reset}"
echo

# -------------------------------------------------------------------
# Pacotes necessários
# -------------------------------------------------------------------
info "Instalando dependências via apk..."

apk add --no-cache \
  ca-certificates \
  wget \
  curl \
  tar \
  tzdata \
  icu-libs \
  libintl \
  sqlite-libs \
  krb5-libs \
  su-exec \
  iproute2 \
  >/dev/null

ok "Pacotes instalados."

# -------------------------------------------------------------------
# Limpeza de instalação anterior (idempotência)
# -------------------------------------------------------------------
info "Limpando instalação anterior (se existir)..."

if command -v rc-service >/dev/null 2>&1; then
  if rc-service radarr status >/dev/null 2>&1; then
    rc-service radarr stop || true
  fi
  rc-service radarr zap >/dev/null 2>&1 || true
fi

if command -v rc-update >/dev/null 2>&1; then
  if rc-update show default 2>/dev/null | grep -q radarr; then
    rc-update del radarr default || true
  fi
fi

# mata qualquer processo órfão antigo só por segurança
if pgrep -f "/opt/radarr/Radarr" >/dev/null 2>&1; then
  warn "Processo antigo do Radarr encontrado em /opt/radarr. Matando..."
  pkill -f "/opt/radarr/Radarr" || true
fi
if pgrep -f "/opt/Radarr/Radarr" >/dev/null 2>&1; then
  warn "Processo antigo do Radarr encontrado em /opt/Radarr. Matando..."
  pkill -f "/opt/Radarr/Radarr" || true
fi

# remove pidfiles antigos
rm -f /run/radarr.pid
rm -f "${DATA_DIR}/radarr.pid"

# remove serviço/wrapper e ambas instalações
rm -f "$SERVICE_FILE" "$WRAPPER_BIN"
rm -rf "$INSTALL_DIR" "$OLD_INSTALL_DIR"

ok "Limpeza concluída. Dados em ${DATA_DIR} serão preservados."

# -------------------------------------------------------------------
# Usuário e diretórios
# -------------------------------------------------------------------
info "Criando usuário, grupo e diretórios..."

# Grupo
if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
  addgroup -S "$APP_GROUP"
fi

# Diretório de dados antes de criar o usuário (para usar como home)
mkdir -p "$DATA_DIR"

# Usuário
if ! id "$APP_USER" >/dev/null 2>&1; then
  adduser -S -D -H -h "$DATA_DIR" -s /sbin/nologin -G "$APP_GROUP" "$APP_USER"
fi

mkdir -p "$INSTALL_DIR" "$LOG_DIR"
chown -R "$APP_USER:$APP_GROUP" "$DATA_DIR" "$LOG_DIR"

ok "Usuário, grupo e diretórios preparados."

# -------------------------------------------------------------------
# Download do Radarr
# -------------------------------------------------------------------
info "Criando diretório temporário e baixando o ${APP_NAME}..."

mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

info "Baixando de:"
echo "  $RADARR_URL"

if ! curl -fL "$RADARR_URL" -o radarr.tar.gz; then
  error "Falha ao baixar o pacote do Radarr."
  exit 1
fi

ok "Download concluído. Extraindo..."

# -------------------------------------------------------------------
# Extração e instalação
# -------------------------------------------------------------------
tar -xzf radarr.tar.gz

# O tar normalmente extrai para um diretório chamado 'Radarr'
if [ ! -d "Radarr" ]; then
  error "Diretório 'Radarr' não encontrado após extração. Estrutura inesperada."
  exit 1
fi

# Garante que o diretório de destino exista e esteja limpo
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Move os arquivos para /opt/radarr
mv Radarr/* "$INSTALL_DIR"/
chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR"

ok "Arquivos do Radarr instalados em ${INSTALL_DIR}."

# -------------------------------------------------------------------
# Wrapper de execução
# -------------------------------------------------------------------
info "Criando wrapper ${WRAPPER_BIN}..."

cat > "$WRAPPER_BIN" <<'EOF'
#!/bin/sh
# Wrapper para rodar Radarr como usuário dedicado no Alpine
exec su-exec radarr:radarr /opt/radarr/Radarr -nobrowser -data=/var/lib/radarr "$@"
EOF

chmod +x "$WRAPPER_BIN"
ok "Wrapper criado em ${WRAPPER_BIN}."

# -------------------------------------------------------------------
# Serviço OpenRC
# -------------------------------------------------------------------
info "Criando serviço OpenRC em ${SERVICE_FILE}..."

cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="radarr"
description="Radarr Service"

command="/usr/local/bin/radarr-run"
command_args=""
command_background="yes"
pidfile="/run/radarr.pid"

# garante que o start-stop-daemon crie/atualize o pidfile corretamente
start_stop_daemon_args="--make-pidfile --pidfile ${pidfile}"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --owner radarr:radarr /run
}
EOF

chmod +x "$SERVICE_FILE"
ok "Serviço OpenRC criado."

# -------------------------------------------------------------------
# Habilitar e iniciar serviço
# -------------------------------------------------------------------
info "Adicionando serviço ao boot (runlevel default)..."
rc-update add radarr default >/dev/null 2>&1 || true

info "Iniciando serviço ${APP_NAME}..."

rc-service radarr zap >/dev/null 2>&1 || true

if ! rc-service radarr start; then
  error "Falha ao iniciar o serviço Radarr. Verifique 'rc-service radarr status' e os logs."
  exit 1
fi

# -------------------------------------------------------------------
# Verificar status e mostrar URL
# -------------------------------------------------------------------
echo
echo "============================================================"

if rc-service radarr status >/dev/null 2>&1; then
  ip_local="$(ip addr show | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/,"",$2); print $2; exit}')"
  echo -e "${green}${APP_NAME} está rodando!${reset}"
  if [ -n "$ip_local" ]; then
    echo -e "Acesse: ${green}http://$ip_local:${APP_PORT}${reset}"
  else
    echo -e "Acesse: ${green}http://<ip-do-container>:${APP_PORT}${reset}"
  fi
else
  echo -e "${red}${APP_NAME} NÃO iniciou.${reset}"
  echo "Veja 'rc-service radarr status' e os logs em:"
  echo "  ${INSTALL_DIR}"
  echo "  ${DATA_DIR}/logs"
fi

echo
echo "Binário : $INSTALL_DIR/Radarr"
echo "Dados   : $DATA_DIR"
echo "Logs    : $LOG_DIR"
echo "Serviço : $SERVICE_FILE"
echo "Wrapper : $WRAPPER_BIN"
echo "============================================================"

# -------------------------------------------------------------------
# Limpeza final
# -------------------------------------------------------------------
info "Limpando arquivos temporários..."
rm -rf "$TMP_DIR"
ok "Instalação do Radarr no Alpine concluída."
