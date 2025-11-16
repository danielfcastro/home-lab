#!/bin/sh
#
# Menu central para instalar e configurar serviços *arr no Alpine
#

# ==== Configuração de cores ====
red="\033[1;31m"
green="\033[1;32m"
yellow="\033[1;33m"
cyan="\033[1;36m"
reset="\033[0m"

# ==== Verificar root ====
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${red}Este script precisa ser executado como root.${reset}"
  exit 1
fi

# ==== Caminhos dos scripts ====
SCRIPT_DIR="$(dirname "$0")/tools"

SCRIPT_BAZARR="$SCRIPT_DIR/install-bazarr-alpine.sh"
SCRIPT_SONARR="$SCRIPT_DIR/install-sonarr-alpine.sh"
SCRIPT_RADARR="$SCRIPT_DIR/install-radarr-alpine.sh"
SCRIPT_PROWLARR="$SCRIPT_DIR/install-prowlarr-alpine.sh"
SCRIPT_JELLYSEERR="$SCRIPT_DIR/install-jellyseerr-alpine.sh"
SCRIPT_FLARESOLVERR="$SCRIPT_DIR/install-flaresolverr-alpine.sh"

# ==== Funções ====
pause() {
  echo
  read -r -p "Pressione ENTER para voltar ao menu... " _
}

executar_script() {
  script="$1"
  nome="$2"

  echo
  if [ ! -f "$script" ]; then
    echo -e "${red}Script $script não encontrado.${reset}"
    pause
    return
  fi

  if [ ! -x "$script" ]; then
    echo -e "${yellow}Script encontrado mas não é executável. Corrigindo...${reset}"
    chmod +x "$script"
  fi

  echo -e "${cyan}Iniciando instalação de ${nome}...${reset}"
  echo "========================================"
  sh "$script"
  ret=$?
  echo "========================================"

  if [ $ret -eq 0 ]; then
    echo -e "${green}${nome} instalado com sucesso.${reset}"
  else
    echo -e "${red}A instalação de ${nome} terminou com erro (código $ret).${reset}"
  fi

  pause
}

criar_diretorios_midias() {
  echo
  echo -e "${cyan}== Criar diretórios padrão de mídia e downloads ==${reset}"
  echo "Informe o caminho base onde seu volume (ZFS, USB-C, etc.) será montado."
  echo

  read -r -p "Caminho base: " BASE_PATH

  if [ -z "$BASE_PATH" ]; then
    echo -e "${red}Caminho vazio. Cancelado.${reset}"
    pause
    return
  fi

  BASE_PATH="${BASE_PATH%/}"

  MEDIA_ROOT="${BASE_PATH}/media"
  DOWNLOADS_ROOT="${BASE_PATH}/downloads"

  echo
  echo "Serão criados:"
  echo "  ${MEDIA_ROOT}/movies"
  echo "  ${MEDIA_ROOT}/tv"
  echo "  ${MEDIA_ROOT}/anime"
  echo "  ${MEDIA_ROOT}/music"
  echo "  ${DOWNLOADS_ROOT}/complete"
  echo "  ${DOWNLOADS_ROOT}/incomplete"
  echo

  read -r -p "Confirmar? (s/N): " resp
  case "$resp" in
    s|S|y|Y) ;;
    *) echo -e "${yellow}Cancelado.${reset}"; pause; return;;
  esac

  mkdir -p \
    "${MEDIA_ROOT}/movies" \
    "${MEDIA_ROOT}/tv" \
    "${MEDIA_ROOT}/anime" \
    "${MEDIA_ROOT}/music" \
    "${DOWNLOADS_ROOT}/complete" \
    "${DOWNLOADS_ROOT}/incomplete"

  echo -e "${green}Diretórios criados!${reset}"
  pause
}

criar_grupo_midias() {
  echo
  echo -e "${cyan}== Criar grupo de mídias ==${reset}"
  GROUP_NAME="media"

  if getent group "$GROUP_NAME" >/dev/null 2>&1; then
    echo -e "${yellow}Grupo '${GROUP_NAME}' já existe.${reset}"
  else
    addgroup -S "$GROUP_NAME"
    echo -e "${green}Grupo '${GROUP_NAME}' criado.${reset}"
  fi

  echo
  echo "Adicionando serviços ao grupo (se existirem):"
  USERS="bazarr radarr sonarr prowlarr jellyseerr flaresolverr"
  for u in $USERS; do
    if id "$u" >/dev/null 2>&1; then
      addgroup "$u" "$GROUP_NAME" >/dev/null 2>&1
      echo " - $u adicionado"
    fi
  done

  pause
}

mostrar_menu() {
  clear
  echo -e "${cyan}=========================================${reset}"
  echo -e "${cyan}   FAMILY-ARR - MENU DE INSTALAÇÃO       ${reset}"
  echo -e "${cyan}=========================================${reset}"
  echo
  echo " [1] Instalar Bazarr"
  echo " [2] Instalar Sonarr"
  echo " [3] Instalar Radarr"
  echo " [4] Instalar Prowlarr"
  echo " [5] Instalar Jellyseerr"
  echo " [6] Instalar FlareSolverr"
  echo "-----------------------------------------"
  echo " [7] Criar diretórios de mídia/downloads"
  echo " [8] Criar grupo de mídias (media)"
  echo "-----------------------------------------"
  echo " [q] Sair"
  echo
}

# ==== Loop principal ====
while true; do
  mostrar_menu
  read -r -p "Escolha: " opcao

  case "$opcao" in
    1) executar_script "$SCRIPT_BAZARR" "Bazarr" ;;
    2) executar_script "$SCRIPT_SONARR" "Sonarr" ;;
    3) executar_script "$SCRIPT_RADARR" "Radarr" ;;
    4) executar_script "$SCRIPT_PROWLARR" "Prowlarr" ;;
    5) executar_script "$SCRIPT_JELLYSEERR" "Jellyseerr" ;;
    6) executar_script "$SCRIPT_FLARESOLVERR" "FlareSolverr" ;;
    7) criar_diretorios_midias ;;
    8) criar_grupo_midias ;;
    q|Q) echo -e "${green}Saindo...${reset}"; exit 0 ;;
    *) echo -e "${red}Opção inválida.${reset}"; pause ;;
  esac
done
