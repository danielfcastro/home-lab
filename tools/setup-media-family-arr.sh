#!/bin/sh
set -e

GID_MEDIA=2000
GROUP_NAME=mediazfs

echo "===> [family-arr] Configurando grupo '${GROUP_NAME}' (GID ${GID_MEDIA}) para acesso ao ZFS..."

# 1) Criar grupo 'mediazfs' com GID 2000 se ainda não existir
EXISTING_GROUP_LINE="$(getent group "${GROUP_NAME}" || true)"
EXISTING_GID_LINE="$(getent group "${GID_MEDIA}" || true)"

if [ -n "${EXISTING_GROUP_LINE}" ]; then
  CURRENT_GID="$(echo "${EXISTING_GROUP_LINE}" | cut -d: -f3)"
  echo "-> Grupo '${GROUP_NAME}' já existe com GID ${CURRENT_GID}."
  if [ "${CURRENT_GID}" != "${GID_MEDIA}" ]; then
    echo "   ATENÇÃO: o GID do grupo '${GROUP_NAME}' não é ${GID_MEDIA}."
    echo "   Ajuste manualmente se quiser alinhamento perfeito com o host."
  fi
else
  if [ -n "${EXISTING_GID_LINE}" ]; then
    OTHER_GROUP="$(echo "${EXISTING_GID_LINE}" | cut -d: -f1)"
    echo "ERRO: GID ${GID_MEDIA} já está em uso pelo grupo '${OTHER_GROUP}' neste LXC."
    echo "      Altere o GID aqui OU no host para manter consistência."
    exit 1
  fi

  echo "-> Criando grupo '${GROUP_NAME}' com GID ${GID_MEDIA}..."
  addgroup -g "${GID_MEDIA}" "${GROUP_NAME}"
fi

echo
echo "-> Adicionando serviços ao grupo '${GROUP_NAME}'..."

for u in sonarr radarr bazarr prowlarr jellyseerr qbittorrent; do
  if id "$u" >/dev/null 2>&1; then
    echo "   - adicionando usuário '$u' ao grupo '${GROUP_NAME}'..."
    addgroup "$u" "${GROUP_NAME}" || true
  else
    echo "   - usuário '$u' NÃO existe neste LXC, ignorando..."
  fi
done

echo
echo "===> [family-arr] Concluído."
echo "Confira, por exemplo, com:"
echo "  id qbittorrent"
echo "  id sonarr"
echo "  id radarr"
echo "Deve aparecer '${GROUP_NAME}' na lista de groups."
