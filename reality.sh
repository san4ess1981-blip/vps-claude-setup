#!/usr/bin/env bash
# =============================================================
# reality.sh — свой VPN на сервере: VLESS + Reality (xray)
#
# Запуск от root на сервере:
#   bash reality.sh          # порт 8443 (по умолчанию)
#   bash reality.sh 443      # или любой другой порт
#
# Что делает:
#   1. Ставит xray (ядро VLESS/Reality) официальным скриптом.
#   2. Генерирует UUID, ключи x25519, short id.
#   3. Пишет /usr/local/etc/xray/config.json (TCP, SNI teamviewer.com,
#      fingerprint firefox — проверенная маскировка).
#   4. Открывает порт в UFW, перезапускает xray.
#   5. Печатает vless:// ссылку, QR-код и кладёт всё в /root/reality-info.txt
#      (QR-картинка: /root/reality-qr.png).
# =============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PORT="${1:-8443}"
SNI="teamviewer.com"
NAME="Virtarix-Reality"
INFO=/root/reality-info.txt

echo "=== [1/5] Проверяю, свободен ли порт $PORT ==="
if ss -tln | grep -qE ":${PORT}[[:space:]]"; then
  echo "ОШИБКА: порт $PORT уже занят:"; ss -tlnp | grep -E ":${PORT}[[:space:]]"
  exit 1
fi
echo "Порт $PORT свободен."

echo "=== [2/5] Устанавливаю xray ==="
if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
xray version | head -1

echo "=== [3/5] Генерирую ключи и пишу конфиг ==="
UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIV=$(echo "$KEYS" | awk -F': *' 'tolower($1) ~ /private/ {print $2}')
PUB=$(echo  "$KEYS" | awk -F': *' 'tolower($1) ~ /public/  {print $2}')
SID=$(openssl rand -hex 4)
[ -n "$UUID" ] && [ -n "$PRIV" ] && [ -n "$PUB" ] && [ -n "$SID" ] || { echo "ОШИБКА: не удалось сгенерировать ключи"; exit 1; }

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI}:443",
        "xver": 0,
        "serverNames": ["${SNI}"],
        "privateKey": "${PRIV}",
        "shortIds": ["${SID}"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
if ! xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  echo "ОШИБКА: конфиг xray не прошёл проверку"; xray run -test -config /usr/local/etc/xray/config.json || true
  exit 1
fi
echo "Конфиг валиден."

echo "=== [4/5] Открываю порт и перезапускаю xray ==="
ufw allow ${PORT}/tcp >/dev/null
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { echo "ОШИБКА: xray не запустился"; journalctl -u xray --no-pager -n 20; exit 1; }
ss -tln | grep -qE ":${PORT}[[:space:]]" || { echo "ОШИБКА: xray не слушает $PORT"; exit 1; }
echo "xray запущен и слушает ${PORT}/tcp."

echo "=== [5/5] Генерирую ссылку и QR-код ==="
LINK="vless://${UUID}@146.103.57.168:${PORT}?security=reality&encryption=none&pbk=${PUB}&fp=firefox&sni=${SNI}&sid=${SID}&flow=xtls-rprx-vision&type=tcp#${NAME}"

command -v qrencode >/dev/null 2>&1 || apt-get install -y -q qrencode >/dev/null
qrencode -o /root/reality-qr.png -s 8 -m 2 "$LINK"

cat > "$INFO" <<EOF
===== ВАШ VPN (VLESS+Reality) =====
Ссылка для импорта в Happ / v2rayNG / Streisand / FoXray:

${LINK}

Параметры по отдельности (если вводить руками):
  Адрес сервера : 146.103.57.168
  Порт          : ${PORT}
  UUID          : ${UUID}
  Flow          : xtls-rprx-vision
  Security      : reality
  SNI           : ${SNI}
  Public key    : ${PUB}
  Short ID      : ${SID}
  Fingerprint   : firefox
  Транспорт     : tcp

QR-код картинкой: /root/reality-qr.png
EOF
chmod 600 "$INFO" /root/reality-qr.png

echo
echo "============================================================"
echo " ГОТОВО! Ваша ссылка:"
echo
echo " ${LINK}"
echo
echo " QR-код (отсканируйте Happ'ом с телефона):"
echo "============================================================"
qrencode -t ansiutf8 -m 1 "$LINK"
echo
echo "Информация сохранена в ${INFO}"
