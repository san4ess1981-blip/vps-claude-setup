#!/usr/bin/env bash
# =============================================================
# fix-panel.sh — пересоздаёт панель wg-easy с НОВЫМ паролем
# Лечит ошибку "Unauthorized" в панели VPN.
#
# Запуск из консоли Virtarix (от root), одной строкой:
#   curl -fsSL https://raw.githubusercontent.com/san4ess1981-blip/vps-claude-setup/main/fix-panel.sh | bash
# =============================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ОШИБКА: запусти от root" >&2
  exit 1
fi

# Алфавит без похожих символов (нет 0/O, 1/l/I)
PASS_ALPHABET='ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
NEWPASS="$(tr -dc "${PASS_ALPHABET}" </dev/urandom | head -c 20 || true)"

echo "==> Генерирую новый хэш пароля..."
# ВАЖНО: </dev/null — иначе при запуске через curl|bash docker съест остаток скрипта
RAW="$(docker run --rm ghcr.io/wg-easy/wg-easy:14 wgpw "${NEWPASS}" </dev/null | tr -d '\r\n')"
HASH="${RAW#PASSWORD_HASH=\'}"
HASH="${HASH%\'}"

echo "==> Пересоздаю контейнер wg-easy..."
docker rm -f wg-easy >/dev/null 2>&1 || true
docker run -d \
  --name=wg-easy \
  -e WG_HOST=146.103.57.168 \
  -e PASSWORD_HASH="${HASH}" \
  -p 51820:51820/udp \
  -p 51821:51821/tcp \
  -v /opt/wg-easy:/etc/wireguard \
  --cap-add=NET_ADMIN \
  --restart unless-stopped \
  ghcr.io/wg-easy/wg-easy:14 >/dev/null

sleep 2

# Самопроверка: хэш внутри контейнера не должен содержать $$
GOT="$(docker inspect wg-easy --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^PASSWORD_HASH=' || true)"
if [[ "${GOT}" == *'$$'* ]]; then
  echo "ОШИБКА: хэш всё ещё содержит $$ — напиши Кими" >&2
  exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -qx wg-easy; then
  echo "ОШИБКА: контейнер wg-easy не запустился — напиши Кими" >&2
  exit 1
fi

echo
echo "================================================="
echo
echo "   НОВЫЙ ПАРОЛЬ ПАНЕЛИ VPN:"
echo
echo "        ${NEWPASS}"
echo
echo "   Панель: http://146.103.57.168:51821"
echo
echo "   Перепиши пароль ТОЧНО как написано:"
echo "   большие и маленькие буквы — это разные буквы!"
echo
echo "================================================="
