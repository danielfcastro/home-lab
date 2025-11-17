#!/bin/sh
# Instalador FlareSolverr em Alpine Linux (LXC)
# - Testado com Alpine v3.22
# - Cria usuário dedicado
# - Clona/atualiza repositório oficial
# - Cria venv Python e instala dependências
# - Configura serviço OpenRC com logs em /var/log/flaresolverr
# - Testa API na porta 8191

set -eu

# === Logging centralizado (/var/log/flaresolverr/install.log) ===
# Requer: tools/logging.sh
#   #!/bin/sh
#   set -eu
#   setup_logging() { ... }
. "$(dirname "$0")/logging.sh"

SERVICE_NAME="flaresolverr"
setup_logging "$SERVICE_NAME"

### ===== CORES =====
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"

log() {
  printf "%b[FlareSolverr] %s%b\n" "${C_BLUE}" "$1" "${C_RESET}"
}

ok() {
  printf "%b[OK] %s%b\n" "${C_GREEN}" "$1" "${C_RESET}"
}

warn() {
  printf "%b[AVISO] %s%b\n" "${C_YELLOW}" "$1" "${C_RESET}"
}

err() {
  printf "%b[ERRO] %s%b\n" "${C_RED}" "$1" "${C_RESET}" >&2
}

### ===== CONFIG =====
FLARE_USER="flaresolverr"
FLARE_GROUP="flaresolverr"
FLARE_DIR="/opt/flaresolverr"
FLARE_VENV="${FLARE_DIR}/venv"
FLARE_LOG_DIR="/var/log/flaresolverr"
FLARE_HOME="/home/${FLARE_USER}"

### ===== PRÉ-CHECKS =====
if [ "$(id -u)" != "0" ]; then
  err "Este script precisa ser executado como root."
  exit 1
fi

if [ ! -f /etc/alpine-release ]; then
  err "Este instalador é apenas para Alpine Linux."
  exit 1
fi

log "Iniciando instalação do FlareSolverr em Alpine..."

### ===== PACOTES =====
log "Atualizando repositórios e instalando dependências..."
apk update
apk add --no-cache \
  python3 \
  py3-pip \
  py3-virtualenv \
  git \
  chromium \
  chromium-chromedriver \
  xvfb \
  ttf-freefont \
  nss \
  ca-certificates \
  curl \
  openrc \
  logrotate

ok "Pacotes base instalados."

### ===== USUÁRIO / GRUPO / HOME =====
log "Criando usuário, grupo e diretórios..."

if ! getent group "${FLARE_GROUP}" >/dev/null 2>&1; then
  addgroup -S "${FLARE_GROUP}"
fi

if ! id "${FLARE_USER}" >/dev/null 2>&1; then
  adduser -S -D -H -G "${FLARE_GROUP}" -s /bin/false "${FLARE_USER}"
fi

# Garante home com permissões corretas
mkdir -p "${FLARE_HOME}"
chown "${FLARE_USER}:${FLARE_GROUP}" "${FLARE_HOME}"
chmod 700 "${FLARE_HOME}"

# Diretórios de app e logs
mkdir -p "${FLARE_DIR}" "${FLARE_LOG_DIR}"
chown -R "${FLARE_USER}:${FLARE_GROUP}" "${FLARE_DIR}" "${FLARE_LOG_DIR}"

ok "Usuário, home e diretórios criados."

### ===== CLONE / ATUALIZAÇÃO REPO =====
log "Obtendo repositório oficial FlareSolverr..."

if [ -d "${FLARE_DIR}/.git" ]; then
  log "Repositório já existe, fazendo git pull..."
  cd "${FLARE_DIR}"
  git pull --depth=1 || warn "git pull falhou, continuando com o que já existe."
else
  # Se o diretório existir mas não for git, faz backup
  if [ -d "${FLARE_DIR}" ] && [ "$(ls -A "${FLARE_DIR}" | wc -l)" -gt 0 ]; then
    BACKUP_DIR="${FLARE_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
    warn "Diretório ${FLARE_DIR} não é um repo git. Movendo para ${BACKUP_DIR}..."
    mv "${FLARE_DIR}" "${BACKUP_DIR}"
    mkdir -p "${FLARE_DIR}"
  fi

  log "Clonando repositório..."
  git clone --depth=1 https://github.com/FlareSolverr/FlareSolverr.git "${FLARE_DIR}"
fi

chown -R "${FLARE_USER}:${FLARE_GROUP}" "${FLARE_DIR}"
ok "Repositório pronto em ${FLARE_DIR}."

### ===== VENV E DEPENDÊNCIAS PYTHON =====
log "Criando virtualenv e instalando dependências Python..."

cd "${FLARE_DIR}"

if [ ! -d "${FLARE_VENV}" ]; then
  virtualenv "${FLARE_VENV}"
fi

# shellcheck disable=SC1091
. "${FLARE_VENV}/bin/activate"

pip install --upgrade pip
pip install -r requirements.txt
# Garantir certifi no venv (belt & suspenders)
pip install certifi

deactivate

chown -R "${FLARE_USER}:${FLARE_GROUP}" "${FLARE_DIR}"

ok "Virtualenv e dependências instaladas."

### ===== WRAPPER DE EXECUÇÃO =====
log "Criando wrapper /usr/local/bin/flaresolverr-run..."

cat >/usr/local/bin/flaresolverr-run <<'EOF'
#!/bin/sh
FLARE_DIR="/opt/flaresolverr"
FLARE_VENV="${FLARE_DIR}/venv"

export TZ="Europe/Lisbon"
export PORT="8191"
export HOST="0.0.0.0"

# PATH decente pro serviço
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

cd "$FLARE_DIR" || exit 1

# Ativa o venv e roda o Python do venv em foreground (OpenRC faz o background)
. "$FLARE_VENV/bin/activate"
exec "$FLARE_VENV/bin/python" src/flaresolverr.py
EOF

chmod +x /usr/local/bin/flaresolverr-run

ok "Wrapper criado."

### ===== SERVIÇO OPENRC (com logs em /var/log/flaresolverr) =====
log "Configurando serviço OpenRC /etc/init.d/flaresolverr..."

cat >/etc/init.d/flaresolverr <<'EOF'
#!/sbin/openrc-run

name="FlareSolverr"
description="FlareSolverr - proxy para bypass Cloudflare"

command="/usr/local/bin/flaresolverr-run"
command_user="flaresolverr:flaresolverr"
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
  checkpath --directory --owner flaresolverr:flaresolverr "$log_dir"
}
EOF

chmod +x /etc/init.d/flaresolverr

# Garante estrutura básica do OpenRC em LXC
if [ ! -d /run/openrc ]; then
  log "Inicializando OpenRC em /run/openrc..."
  mkdir -p /run/openrc
  touch /run/openrc/softlevel
fi

rc-update add flaresolverr default || true

ok "Serviço OpenRC configurado."

### ===== LOGROTATE =====
log "Configurando logrotate para /var/log/flaresolverr..."

cat >/etc/logrotate.d/flaresolverr <<'EOF'
/var/log/flaresolverr/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 flaresolverr flaresolverr
    sharedscripts
}
EOF

### ===== SUBIR SERVIÇO =====
log "Subindo serviço FlareSolverr..."

# Mata qualquer resquício anterior
pkill -f flaresolverr.py 2>/dev/null || true
pkill -f flaresolverr-run 2>/dev/null || true

rc-service flaresolverr restart || warn "rc-service retornou erro, verificando logs..."

sleep 5

log "Status do serviço:"
rc-service flaresolverr status || true

### ===== TESTE DA API =====
log "Testando API na porta 8191 (pode levar alguns segundos)..."

TEST_FILE="/tmp/flaresolverr_test.json"

set +e
HTTP_CODE=$(curl -s -o "${TEST_FILE}" -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"request.get","url":"https://www.google.com","maxTimeout":60000}' \
  http://127.0.0.1:8191/v1 2>/dev/null)
CURL_RC=$?
set -e

if [ "${CURL_RC}" -ne 0 ]; then
  warn "curl não conseguiu conectar em 127.0.0.1:8191 (código ${CURL_RC})."
  warn "Verifique logs em ${FLARE_LOG_DIR}."
elif [ "${HTTP_CODE}" != "200" ]; then
  warn "FlareSolverr respondeu HTTP ${HTTP_CODE}. Resposta salva em ${TEST_FILE}."
else
  if grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' "${TEST_FILE}"; then
    ok "FlareSolverr respondeu com status \"ok\". Instalação validada!"
  else
    warn "HTTP 200, mas sem \"status\":\"ok\". Veja ${TEST_FILE} e ${FLARE_LOG_DIR}."
  fi
fi

printf "%b\n" "${C_GREEN}FlareSolverr deve estar ouvindo em http://SEU_IP_LXC:8191/v1 (API, sem interface web).${C_RESET}"
printf "%b\n" "${C_YELLOW}Exemplo de teste a partir de outro host:${C_RESET}\n"
printf "%s\n" "curl -L -X POST 'http://SEU_IP_LXC:8191/v1' \\"
printf "%s\n" "  -H 'Content-Type: application/json' \\"
printf "%s\n" "  --data-raw '{\"cmd\":\"request.get\",\"url\":\"http://www.google.com\",\"maxTimeout\":60000}'"
